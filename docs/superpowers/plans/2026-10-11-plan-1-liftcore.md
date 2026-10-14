# Plan 1 — LiftCore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `LiftCore`, the Swift package with no UI and no HTTP/MCP that:
- stores jobs
- keeps the bundled recipes in the workdir
- installs a model, downloads its weights and verifies them when the user chooses to use it
- runs Python workers
- measures memory
- schedules steps
- exposes every operation as a typed command

It's tested end to end with the Test Cube recipe and runs in CI.

**Architecture:** One SwiftPM package at the repo root with a `LiftCore` library target. A `Lift` actor owns the GRDB store, the recipe catalog, installs, weight checks and the live workers. On open it copies or refreshes the bundled recipes into `<workdir>/recipes/bundled/`. On every state change it builds a `SchedulerInput` and applies the pure `Scheduler.decide` result. A step that would start a new worker for a recipe with weights first waits for a `WeightsVerifier` pass. Workers are `python -m lift_worker` processes inside each model's venv. They talk JSON lines (protocol v1, spec §8) over pipes through swift-subprocess. `lift_worker` (stdlib-only Python, `python/lift_worker/`) loads the recipe's `launcher.py` once and runs jobs on a thread pool. Commands are `public` methods on `Lift` (in `Commands/`), and risky ones return `Gated.confirmationRequired` until called with `confirm: true`. Plan 2's HTTP/MCP and Plan 3's UI call only those methods.

**Tech Stack:**
- Swift 6 (swift-tools-version 6.2; Xcode 26.6 / Swift 6.3.3 locally), macOS 26
- GRDB.swift 7.11.1+, Yams 6.2.2+, swift-subprocess 1.0.1+
- Swift Testing; CryptoKit and URLSession from the SDK
- Python 3.11 through uv, pytest, and trimesh for the Test Cube

**Spec:** `docs/superpowers/specs/2026-10-11-lift-design.md`, milestone 1. Relevant sections: §3 layout and bundled recipes; §4 recipes; §6 toolchain (native Homebrew), install and weights; §7 jobs; §8 scheduler, workers, resources and protocol; §10 commands; §11 first launch; §13 errors; §14 testing and CI. Plan 0 (`docs/superpowers/plans/2026-10-11-plan-0-shim-and-go-no-go.md`) and the findings (`docs/superpowers/findings/2026-10-go-no-go.md`) define the `LIFT_SHIM` contract and `lift_shim`, which this plan consumes but doesn't change. The shim overhead benchmark came out at about 0%, so `TorchFunctionMode` stays.

**Out of scope here (and where it goes):**
- **Plan 4:** real-model recipes (Pixal3D, Pixal3D-MV, UniRig, TRELLIS.2), written from the go/no-go findings. Model specifics live only in each recipe's `launcher.py`. The only concrete recipe here is `dev-recipes/test-cube`. Also Plan 4: the Metal and `torch_scatter`/`torch_cluster` entries of `shared/substitutes.yaml`, and a recipe flag for "needs the Metal Toolchain".
- **Plan 4:** the Exporter (GLB/USDZ/OBJ/FBX conversion, export dir copy, `cleanup_after_export`, the job `export` field, `jobs_export`). In Plan 1 a job's outputs stay in `jobs/<id>/steps/<n>/`.
- **Plan 4:** `image_set` presets (4-view and orbit). Plan 1 accepts an `image_set` as a folder.
- **Plan 2:** `server_status`, `server_set_lan`, `server_rotate_token`, `secrets_set_hf_token`, Keychain. Plan 1 reads the Hugging Face token through `LiftConfig.hfToken` (default `$HF_TOKEN`).
- **Plan 3:** the first-launch wizard UI; copying `dev-recipes/` and `python/lift_worker/src` into Lift.app (an Xcode build phase; `LiftConfig.bundledRecipes` and `.workerRuntime` then point there); moving the working directory; resetting learned estimates. LiftCore already does the first-launch copy itself (Task 9 and Task 11).

## Global Constraints

- Platform: macOS 26+, Apple Silicon. `platforms: [.macOS(.v26)]`, `// swift-tools-version: 6.2`, Swift 6 language mode (strict concurrency).
- Swift packages, exactly these in Plan 1: `https://github.com/groue/GRDB.swift` from `7.11.1`, `https://github.com/jpsim/Yams` from `6.2.2`, `https://github.com/swiftlang/swift-subprocess` from `1.0.1` (module `Subprocess`). Commit `Package.resolved`. Don't add Hummingbird, MCP, KeychainAccess, GLTFKit2, ArgumentParser, swift-log or OpenAPI packages yet.
- Swift tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), never XCTest.
- Python 3.11 for every venv, managed by uv. `lift_worker` uses only the standard library, because it runs inside every model venv.
- **User rule: no weight downloads and no prerequisite installs during development.** Tests use the Test Cube plus fakes: `FakeRunner` for brew/git/hf commands, `FakeMetadata` for the Hugging Face API, temp Homebrew prefixes and a temp Hugging Face cache. The install code is real but never runs against the machine in tests. The only real installs in tests are the Test Cube's own (a uv venv in a temp workdir with `trimesh`, `numpy` and `lift_shim`, which is the product path for that recipe).
- **User rule: nothing outside Lift's own files is ever deleted, in dev steps or product code.** Deletions are limited to paths Lift created in the workdir: `models/<id>/`, `jobs/<id>/`, Lift's unedited copy in `recipes/bundled/`, and git sources Lift cloned. Weights in the shared Hugging Face cache are never deleted. Edited bundled recipes are moved to `recipes/bundled-local/`, never removed. The spec's "uninstall: also delete weights" is dropped because of this rule.
- Never edit upstream code. The installer only clones, checks out the pin, creates the venv and runs install commands (spec principle 1).
- **Native Homebrew only** (spec §6): `/opt/homebrew/bin/brew` counts only if `brew --version` succeeds and `brew config` reports `HOMEBREW_PREFIX: /opt/homebrew` on arm64. An Intel/Rosetta Homebrew in `/usr/local` is reported and never used. `/usr/local` isn't on Lift's tool search path, because an x86_64 uv would build x86_64 venvs.
- **Nothing is cloned or downloaded until the user chooses a model** (spec §4). `models_install` (Install/Use) does it all for that one model: brew prerequisites, clone at the pin, venv, install steps, substitutes, shim, weight download, verify.
- Lift executes and the caller decides. The scheduler orders by priority, then manual position, then submission time. It never reorders by model warmth and never evicts a worker to make room. It reports facts as wait reasons (spec principle 2, §8).
- Confirm gates (spec §10): `jobs_force_start`, `jobs_delete`, `jobs_cancel` of a loading/running job, `models_install`, `models_reinstall`, `models_set_pin`, `models_uninstall`, `models_download_weights`, `recipes_add_source`, `recipes_remove_source`, `workers_unload` of a busy worker, and `system_install_prereqs`. Without `confirm: true` they return `Gated.confirmationRequired(impact)` and change nothing.
- `LIFT_SHIM` contract: JSON `{"aliases":{…},"standins":[…],"patches":[…],"env":{…}}`. The `.pth` is written with `python -c "import site, lift_shim.pth as p; p.write_pth(site.getsitepackages()[0])"`.
- Workdir layout (spec §3): `<workdir>/lift.sqlite`; `recipes/{bundled,bundled-local,<git source>}/`; `models/<id>/{repo,venv,recipe,install.log,state.json,shim.json}`; `jobs/<id>/{inputs/,steps/<n>/,log.txt}`.
- Defaults (spec §8): `max_slots` 1, `memory_budget_gb` 48, `idle_unload_minutes` 10. Every recipe's `max_concurrent_per_process` defaults to 1.
- The first test run needs network so uv can fetch Python 3.11, `trimesh`, `numpy` and `hatchling`. After that, the uv cache serves them.
- Work on branch `oshricohenme/7jtm2` and don't push. Every commit message ends with a blank line and then `Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw`.

## Schema and protocol decisions (fold into the spec)

These fill gaps the spec leaves open. Plan 4's real recipes rely on them.

1. **`recipe.yaml` additions to schema v1:**
   - `shim: {aliases, standins, patches, env}`: every field is optional, and the whole block's presence turns the shim on. When it's on, Lift installs `lift_shim` plus its `.pth` and sets `LIFT_SHIM` for workers. trellis2-mac leaves it out.
   - `brew: [pkg]`: native Homebrew packages.
   - `weights: [{repo, revision = "main", gated = false}]`.
   - `developer: bool`: the Test Cube sets it, and it's hidden unless the `dev_recipes` setting or `LIFT_DEV_RECIPES=1` is on.
   - `stages: [{pattern}]`: Python `re` patterns with the named groups `name`, `pct` (0–100), or `n` and `total`. They're applied to every tagged log line. A match without `name` keeps the previous stage name.
   - `resources.disk_gb` (default 5): checked before install.
   - `repo` and `commit` are optional, but must appear together. Without them the model's `repo/` is an empty folder (Test Cube).
   - `tasks[].entry` is informational only. The launcher decides how to call upstream.
2. **Launcher contract** (`<recipe>/launcher.py`): optional `load(ctx) -> state`, where `ctx.repo_dir` and `ctx.recipe_dir` are set and the call happens once per worker. Required `run(state, job) -> list[str]` returns output paths. `job` has `id`, `step`, `task`, `inputs`, `settings`, `out_dir`, `cancelled` (poll it) and `stage(name, fraction=None)`. The worker's working directory is `models/<id>/repo` and `repo_dir` is on `sys.path`.
3. **Substitute registry** (`<source>/shared/substitutes.yaml`): `name: {install: [cmd…], alias: module, standin: name, patches: [name]}`. A recipe's `substitutes:` add their install commands after the recipe's own steps. Their alias, stand-in and patches merge with the recipe's `shim:` into the `LIFT_SHIM` JSON, saved as `models/<id>/shim.json`. A substitute that needs the shim in a recipe without `shim:` is an error.
4. **Bundled recipes** (spec §3, §4, §11): `Lift.open` runs `BundledRecipes.sync()`.
   - Changes are tracked through `<workdir>/recipes/bundled/.lift-bundle.json`, a manifest of SHA-256 digests per top-level folder.
   - The first open copies `LiftConfig.bundledRecipes` there, skipping `.venv`, `__pycache__`, `.pytest_cache` and `.DS_Store`.
   - When the bundle's digests change (an app update), every folder in the copy that differs from the manifest is moved to `recipes/bundled-local/<name>` before the fresh copy goes in. That covers folders you edited and folders you added. An older kept copy is moved aside to a hidden `.<name>-<ms>`.
   - Source order: `bundled-local` (your edits win; the duplicate shows as a warning), then `bundled`, then git sources.
   - A `bundled-local` recipe uses `bundled-local/shared/` if it exists, else `bundled/shared/`.
5. **Install order:** preflight → `brew install <recipe.brew>` (first, so native builds can link against them) → clone → `uv venv` → install steps → substitute installs → `lift_shim` + `.pth` → recipe copy and `shim.json` → `lift_worker --check` → `state.json`. Then `models_install` downloads the weights (unless `downloadWeights: false`) and verifies them. If `recipe.brew` isn't empty, the worker environment gets `DYLD_FALLBACK_LIBRARY_PATH=<native prefix>/lib:/usr/lib`. That replaces dyld's default fallback, which includes `/usr/local/lib`.
6. **Weights** (spec §6):
   - `models_download_weights` (confirm) runs `<venv>/bin/hf download <repo> --revision <rev>` with `HF_HUB_CACHE` and `HF_TOKEN` set, appending to `install.log`. The venv must provide `hf` (huggingface_hub), so recipes with weights include it in their install steps.
   - `WeightsVerifier` gets each repo's file list (sizes and LFS SHA-256) from `GET https://huggingface.co/api/models/<repo>/revision/<rev>?blobs=true`. It checks `<hub>/models--org--name/snapshots/<commit>/<path>` (symlinks resolved) for presence, then size, then the SHA-256 of LFS files.
   - Hashes are cached in the `weightHash` table per (resolved path, size, mtime).
   - The `weightCheck` table keeps the last good check's file lists. When Lift is offline it re-checks against them and says so (`metadataFrom`, `note`). Offline without a good check, or an HTTP error, gives `unknown`.
   - Results: `missing` takes precedence over `corrupt`. Model status becomes `weightsMissing([WeightProblem])` or `weightsCorrupt(...)`.
   - When a step would start a new worker for a recipe with weights, the job waits `weights_unverified` and a background check starts. Checks repeat at most every `weightsRecheckInterval`, default 30 s. A pass allows one worker start, and spawning consumes it ("before every worker start").
   - `workers_load` verifies inline, and `models_verify_weights` runs a check on demand.
7. **Worker start:** `<venv>/bin/python -u -m lift_worker '<config json>'` with the environment `PYTHONPATH=<lift_worker dir>`, `VIRTUAL_ENV`, `PATH=<venv>/bin:…`, `LIFT_SHIM` (if shimmed), `DYLD_FALLBACK_LIBRARY_PATH` (if `brew:`), `HF_HUB_CACHE` and `HF_TOKEN` (if set). Config keys: `launcher`, `repo_dir`, `recipe_dir`, `max_concurrent`, `stages`, `heartbeat_seconds`, `setting_types`. `python -m lift_worker --check '<config>'` imports the launcher and compiles the stage patterns. That's the installer's smoke test.
8. **Protocol v1 details** beyond spec §8:
   - A worker exits when its stdin closes, so a crashed app never leaves a loaded model behind.
   - A load failure is `{"ev":"error","job":null,…}`, after which the worker exits with code 1.
   - JSON can't tell `1` from `1.0`, so `lift_worker` turns `float`-typed settings back into floats using `setting_types`.
   - A line printed by a thread upstream started is tagged with the job when exactly one job is running. Swift does the same for stderr lines.
   - Swift sees the process events `started(pid)`, `stderr(line)`, `malformed(line)` and `exited(code)` as well as the protocol events.
9. **Scheduler:**
   - Each candidate is judged on its own, in order, and resources are deducted as starts are decided, so one job waiting for memory doesn't hold back a smaller one behind it. That's mechanical, not a choice.
   - `force_start` skips the budget and system-memory checks but not the slot check. It doesn't override a paused queue or unverified weights.
10. **Memory accounting:**
    - `need.load` = learned load (max of last 5), else the recipe value. `need.job` = learned job, else recipe value − learned load, else 0.
    - A new worker needs `load + job`, and a step on a worker with free capacity needs `job`.
    - A worker reserves `max(last footprint, baseline + Σ claims of its running steps)`. The baseline is `need.load` until `ready`, then the footprint measured at `ready`.
    - A footprint is `max(phys_footprint, heartbeat mps_allocated)`.
11. **Model status** comes from files: `models/<id>/state.json` is written last and holds `installed`, `commit` and the recipe digest. An in-flight install or download is tracked in memory as `installing(phase:)`, where the phase is installing, downloading weights or verifying weights. A changed source recipe (SHA-256 of `recipe.yaml` + `launcher.py`) or a changed pin shows `updateAvailable`. Workers run the installed copy at `models/<id>/recipe/`.
12. **Toolchain:**
    - Each tool counts only if it runs (`--version`). `/usr/bin/git` is tried only after `xcode-select -p` succeeds, because without the Command Line Tools it pops up an installer dialog.
    - Native Homebrew is installed with one administrator dialog: `osascript … do shell script "mkdir -p /opt/homebrew && chown -R <user>:admin /opt/homebrew" with administrator privileges`. Then, as the user, the official installer's own approach runs: `git init`, set `origin`, `fetch`, `checkout --force -B main origin/main`, then `brew update`.
    - That checkout replaces any files a stopped Homebrew attempt left in `/opt/homebrew` with Homebrew's own, and deletes nothing. It's the only write outside the workdir and the caches, and it only happens on the user's confirmed `system_install_prereqs`.

## Review Focus

1. **The app crashes or quits while a worker holds a model.** The worker must exit by itself (stdin EOF), and the job must come back as `interrupted` on the next launch, not stay `running`. Pinned by `test_stdin_eof_exits_even_while_busy` (Task 2) and `interruptedJobsAfterRelaunch` (Task 11).
2. **Cancel or unload a worker stuck in native code** that never reads stdin again. It must still die within seconds (SIGKILL by pid). Pinned by `killStopsABusyWorker` (Task 7) and `cancelRunningStopsTheWorker` (Task 13).
3. **An app update arrives after the user edited a bundled recipe or added their own.** Their files must survive in `bundled-local/` and keep working, and a second update must not overwrite the first kept copy. Pinned by `appUpdateRefreshesAndKeepsEdits` and `anOlderKeptCopyIsMovedAsideNotReplaced` (Task 9).
4. **Weights are verified while Lift is offline.** A model that passed before must still pass, against the remembered file lists and saying so, rather than blocking every job. A model never verified must show `unknown`, not `ok`. Pinned by `offlineFallsBackToTheLastGoodCheck` and `offlineWithoutAGoodCheckIsUnknown` (Task 8).
5. **The machine has only an Intel/Rosetta Homebrew, or a half-installed `/opt/homebrew`.** Lift must not use it: `brew:` packages get no Rosetta libraries, and a partial prefix counts as missing. Pinned by `rosettaBrewIsReportedNeverUsed` and `nativeBrewMustReportItsArm64Prefix` (Task 4), and by the `DYLD_FALLBACK_LIBRARY_PATH` check in `runsEveryStepInOrderAndMarksInstalled` (Task 10).

Also pinned, though not in the top five: native output kept off the protocol (Task 2, Task 7), float settings arriving as floats (Task 2), and an offline recipe refresh marking the source stale while keeping its recipes (Task 12).

---

## File Structure

```
Package.swift                                   LiftCore library + LiftCoreTests (Task 1)
Package.resolved                                committed (Task 1)
Sources/LiftCore/
├─ LiftError.swift                              FieldError, LiftError (Task 1)
├─ Support/Lines.swift                          Tail (ring of lines), LogFile, TerminationStatus.code (Task 1)
├─ Store/Records.swift                          JobState, Priority, JobSource, WaitReason, job/step/event/worker/sample/setting records (Task 1)
├─ Store/Store.swift                            DatabaseQueue + migration v1, incl. weightHash/weightCheck tables (Task 1)
├─ Store/Settings.swift                         Settings (setting rows), RecipeSourceRef (Task 1)
├─ Recipes/SettingValue.swift                   SettingValue (Task 1: records need it)
├─ Recipes/Recipe.swift                         recipe.yaml schema v1, RecipeLoad (Task 3)
├─ Recipes/Validation.swift                     recipe problems, settings/input validation (Task 3)
├─ Recipes/Catalog.swift                        RecipeSourceDir, Catalog, Substitute registry, ShimConfig, RecipeSources (git) (Task 9)
├─ Recipes/Bundled.swift                        BundledRecipes: first-launch copy, update refresh, kept edits (Task 9)
├─ Toolchain/CommandRunner.swift                ShellCommand, CommandRunner, SubprocessRunner (Task 4)
├─ Toolchain/Toolchain.swift                    native brew/git/uv/Metal detection, GUI-safe Homebrew install (Task 4)
├─ Scheduler/Scheduler.swift                    MemoryNeed, Candidate, WorkerSnapshot, Scheduler.decide (Task 5)
├─ Resources/Memory.swift                       phys_footprint, host free memory (Task 6)
├─ Resources/Estimates.swift                    recipe values, overrides, learned max-of-5 (Task 6)
├─ Workers/WorkerProtocol.swift                 WorkerOp encode, WorkerEvent decode (Task 7)
├─ Workers/WorkerProcess.swift                  one lift_worker process over swift-subprocess (Task 7)
├─ Weights/Weights.swift                        RepoSnapshot, WeightsMetadata + HFHubAPI, WeightsVerifier, hash cache (Task 8)
├─ Installer/Installer.swift                    preflight → brew → clone → venv → steps → shim → smoke; status; hf download (Task 10)
├─ Engine/Lift.swift                            the actor: open/sync/recover, tick, weights gating, workers, events, idle unload (Task 11)
└─ Commands/
   ├─ Gated.swift                               confirm-gate result (Task 11)
   ├─ JobCommands.swift                         jobs_* and queue_* (Task 11)
   ├─ ModelCommands.swift                       models_* (incl. download/verify weights) and recipes_* (Task 12)
   └─ SystemCommands.swift                      workers_*, resources_*, settings_*, system_* (Task 12)
Tests/LiftCoreTests/
├─ Support.swift                                Fixtures paths/temp dirs/files/fakeBin, eventually(), fieldErrors() (Task 1)
├─ LinesTests.swift · StoreTests.swift          (Task 1)
├─ RecipeTests.swift · ValidationTests.swift    writeRecipe(), pixalYAML fixture (Task 3)
├─ FakeRunner.swift · ToolchainTests.swift      scripted CommandRunner, Fixtures.python() (Task 4)
├─ SchedulerTests.swift                         (Task 5)
├─ ResourceTests.swift                          MemoryTests, EstimatesTests (Task 6)
├─ WorkerProtocolTests.swift · WorkerProcessTests.swift   (Task 7)
├─ WeightsTests.swift                           FakeMetadata, writeHFCache(), sha256Hex() (Task 8)
├─ CatalogTests.swift · BundledTests.swift      (Task 9)
├─ InstallerTests.swift                         (Task 10)
├─ EngineTests.swift                            Fixtures.lift() (Task 11)
├─ CommandTests.swift                           weightedBundle() (Task 12)
└─ CubeIntegrationTests.swift                   real install + real workers (Task 13)
python/lift_worker/
├─ pyproject.toml
├─ src/lift_worker/__init__.py · __main__.py · stages.py · streams.py · worker.py
└─ tests/conftest.py · test_stages.py · test_streams.py · test_worker.py · fixtures/launcher.py   (Task 2)
dev-recipes/test-cube/recipe.yaml · launcher.py (Task 9)
dev-recipes/shared/substitutes.yaml             (Task 9; lift_shim/ exists from Plan 0)
.github/workflows/test.yml                      (Task 14)
```

## Dependency graph and parallel execution

```
Task 1 Store ─┬─> Task 3 Recipes ─┬─> Task 6 Resources ──────────────────────────────┐
              │                   ├─> Task 8 Weights ─────────────────────┐          │
              │                   └─> Task 9 Catalog + bundled + Cube ─┐  │          │
              ├─> Task 4 Toolchain ─┬─> Task 9                         v  v          │
              │                     ├─────────────────────────────> Task 10 Installer┤
              │                     └─> Task 7 Workers (Swift) ──────────────────────┤
              └─> Task 5 Scheduler ───> Task 6                                       │
Task 2 lift_worker (Python) ──────────> Task 7, Task 9 (launcher contract)           │
                                                                                     v
                   Task 11 Engine + job commands ─> Task 12 other commands ─> Task 13 integration ─> Task 14 CI
```

| Wave | Tasks that can run at the same time | Needs |
|---|---|---|
| A | **1**, **2** | none |
| B | **3**, **4**, **5** (and 2 if still running) | 1 |
| C | **6** (3, 5), **7** (1, 2, 4), **8** (1, 3), **9** (2, 3, 4) | as listed |
| D | **10** | 3, 4, 8, 9 |
| E | **11** | 5, 6, 7, 8, 9, 10 |
| F | **12** | 11 |
| G | **13** | 12 |
| H | **14** | 13 (it runs every test) |

All Swift tests share one test target. A half-written file from one task breaks `swift build` for every other task in the same tree, so tasks in the same wave must each run in their own git worktree (`isolation: "worktree"`) and be merged in task-number order. Tasks only add files, so merges are conflict-free. Task 1 is the only one that touches `Package.swift` and `.gitignore`. The one exception: Task 2 is Python-only and can share the main tree with any Swift task.

---

### Task 1: Package skeleton, store, settings

**Files:**
- Create: `Package.swift`, `Package.resolved` (generated)
- Create: `Sources/LiftCore/LiftError.swift`, `Sources/LiftCore/Support/Lines.swift`, `Sources/LiftCore/Recipes/SettingValue.swift`
- Create: `Sources/LiftCore/Store/Records.swift`, `Sources/LiftCore/Store/Store.swift`, `Sources/LiftCore/Store/Settings.swift`
- Test: `Tests/LiftCoreTests/Support.swift`, `Tests/LiftCoreTests/LinesTests.swift`, `Tests/LiftCoreTests/StoreTests.swift`
- Modify: `.gitignore` (append `test-results/`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `FieldError(_ field: String, _ message: String)` (`field`, `message`); `enum LiftError: Error, Equatable { notFound(String), invalidInput([FieldError]), invalidState(String), prerequisite(String), commandFailed(command: String, exitCode: Int32, tail: [String]) }`.
  - `enum SettingValue: Codable, Hashable { bool(Bool), int(Int), float(Double), string(String) }`. Decoding tries Bool, then Int, then Double, then String. `description`; internal `number: Double?` for numeric comparisons.
  - `final class Tail(limit:)` with `append(_:)` and `lines: [String]`; `final class LogFile(_ url: URL) throws` with `write(_ line:)` (appends, creating the file if missing); internal `TerminationStatus.code: Int32` (exit code, or 128 + signal).
  - `enum JobState: String` with the cases `queued waiting loading running succeeded failed cancelled interrupted`, plus `isTerminal` and `isActive` (loading/running). `enum Priority: String { low, normal, high }` with `rank`. `enum JobSource: String { ui, http, mcp }`. `enum WaitReason { noFreeSlot, memory(needed: Int, free: Int), modelInstalling, modelNotInstalled, modelUnsupported, weightsUnverified, queuePaused }`, encoded as `{"reason":"no_free_slot"}`, `{"reason":"weights_unverified"}` and `{"reason":"memory","needed":…,"free":…}`.
  - GRDB records (all `Codable, Sendable, Equatable, FetchableRecord`): `JobRecord` (table `job`; `id, title, priority, position: Double, source, state, waitReason?, forceStart, currentStep, error?, createdAt, updatedAt, finishedAt?`), `StepRecord` (table `step`, key `["jobId","idx"]`; `jobId, idx, recipe, task, inputs: [String:String], settings: [String:SettingValue], state, waitReason?, stage?, fraction?, outputs: [String], error?, workerId?, startedAt?, finishedAt?`), `EventRecord` (`id: Int64?, jobId, stepIdx?, at, kind, detail`), `WorkerRecord` (`id, recipe, pid: Int32, startedAt, loadSeconds?, endedAt?, endReason?`), `MemorySampleRecord` (`id?, recipe, task, keyValues, kind: .load|.job, bytes: Int, at`), `SettingRecord` (`key, value` JSON text).
  - `final class Store: Sendable` with `let db: DatabaseQueue`, `init(path:)` and `init()` (in memory). Migration `"v1"` creates `job`, `step`, `event`, `worker`, `memorySample`, `setting`, `weightHash (path PK, size, mtime, sha256)` and `weightCheck (recipe PK, at, snapshots JSON)`. Steps and events cascade on job delete. Task 8 adds the record types for the two weights tables.
  - `struct Settings: Codable, Equatable` with the fields `maxSlots = 1`, `memoryBudgetGB = 48`, `idleUnloadMinutes = 10`, `devRecipes = false`, `queuePaused = false`, `recipeSources: [RecipeSourceRef]`, `pinOverrides: [String: String]`. JSON keys are snake_case (`max_slots`, …). Also `memoryBudgetBytes`; `static userKeys`; `static func load(_ db: Database) throws -> Settings`; `func save(_ db: Database) throws`; `func setting(_ key: String, to: SettingValue) throws(LiftError) -> Settings`. `RecipeSourceRef(name:url:)`.
  - `Settings.devRecipes` (`dev_recipes`) means "show developer recipes" (the Test Cube).
  - Test helpers: `Fixtures.root`, `.workerRuntime` (`python/lift_worker/src`), `.devRecipes` (the repo's `dev-recipes/`, which is also the app's bundle), `.fixtureLauncher`, `.tempDir()`, `.image(named:)`, `.fakeBin([String]) -> URL`; `eventually(_ seconds:_ condition:) async throws -> Bool`; `fieldErrors(_ body:) async -> [String]`.

- [ ] **Step 1: Create the package manifest**

`Package.swift`:
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LiftCore", targets: ["LiftCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.1"),
    ],
    targets: [
        .target(name: "LiftCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .testTarget(name: "LiftCoreTests", dependencies: ["LiftCore"]),
    ]
)
```

Append to `.gitignore`:
```
test-results/
```

- [ ] **Step 2: Write the failing tests**

`Tests/LiftCoreTests/Support.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

enum Fixtures {
    /// The repository root (this file is Tests/LiftCoreTests/Support.swift).
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let workerRuntime = root.appending(path: "python/lift_worker/src")
    static let devRecipes = root.appending(path: "dev-recipes")
    static let fixtureLauncher = root.appending(path: "python/lift_worker/tests/fixtures/launcher.py")

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lift-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small file to use as an image input.
    static func image(named name: String = "photo.png") throws -> String {
        let url = try tempDir().appending(path: name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url.path
    }

    /// A folder of empty executables with these names (stand-ins for brew, git, uv).
    static func fakeBin(_ names: [String]) throws -> URL {
        let dir = try tempDir()
        for n in names {
            let f = dir.appending(path: n)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        return dir
    }
}

/// Polls `condition` every 50 ms for up to `seconds`.
func eventually(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// The `field`s of the `invalidInput` error `body` throws (empty if it doesn't throw).
func fieldErrors(_ body: () async throws -> Void) async -> [String] {
    do { try await body() } catch let LiftError.invalidInput(errors) { return errors.map(\.field) } catch { return ["unexpected \(error)"] }
    return []
}
```

`Tests/LiftCoreTests/LinesTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct LinesTests {
    @Test func tailKeepsTheLastLines() {
        let t = Tail(limit: 2)
        for l in ["a", "b", "c"] { t.append(l) }
        #expect(t.lines == ["b", "c"])
    }

    @Test func logFileAppendsAcrossOpens() throws {
        let url = try Fixtures.tempDir().appending(path: "sub/log.txt")
        try LogFile(url).write("one")
        try LogFile(url).write("two")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func fieldErrorsDescribeThemselves() {
        let e = LiftError.invalidInput([FieldError("steps[0].settings.size", "must be ≥ 0.01")])
        #expect(e.description == "invalid input: steps[0].settings.size: must be ≥ 0.01")
    }
}
```

`Tests/LiftCoreTests/StoreTests.swift`:
```swift
import Foundation
import GRDB
import Testing
@testable import LiftCore

@Suite struct StoreTests {
    func job(_ id: String, state: JobState = .queued) -> JobRecord {
        JobRecord(id: id, title: "t", priority: .high, position: 1, source: .ui, state: state, forceStart: false,
                  currentStep: 0, createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000))  // whole ms: SQLite keeps ms
    }

    @Test func jobAndStepRoundTripWithJSONColumns() async throws {
        let store = try Store()
        var waiting = job("a", state: .waiting)
        waiting.waitReason = .memory(needed: 10, free: 3)
        let j = waiting
        let s = StepRecord(jobId: "a", idx: 0, recipe: "r", task: "t", inputs: ["image": "/x.png"],
                           settings: ["size": .float(1.5), "seed": .int(42), "low_vram": .bool(true), "mode": .string("fast")],
                           state: .waiting, waitReason: .noFreeSlot, outputs: ["/o.glb"])
        try await store.db.write { db in
            try j.insert(db)
            try s.insert(db)
        }
        let (j2, s2) = try await store.db.read { db in
            (try JobRecord.fetchOne(db, key: "a"), try StepRecord.fetchOne(db, key: ["jobId": "a", "idx": 0]))
        }
        #expect(j2 == j)
        #expect(s2 == s)
        let raw = try await store.db.read { try String.fetchOne($0, sql: "SELECT waitReason FROM job") }
        #expect(raw?.contains(#""reason":"memory""#) == true)  // stored as JSON text
    }

    @Test func deletingAJobCascades() async throws {
        let store = try Store()
        try await store.db.write { db in
            try job("a").insert(db)
            try StepRecord(jobId: "a", idx: 0, recipe: "r", task: "t", inputs: [:], settings: [:], state: .queued, outputs: []).insert(db)
            var e = EventRecord(id: nil, jobId: "a", stepIdx: 0, at: Date(), kind: "state", detail: "queued")
            try e.insert(db)
            _ = try JobRecord.deleteOne(db, key: "a")
        }
        let counts = try await store.db.read { db in (try StepRecord.fetchCount(db), try EventRecord.fetchCount(db)) }
        #expect(counts == (0, 0))
    }

    @Test func settingsDefaultsAndRoundTrip() async throws {
        let store = try Store()
        let defaults = try await store.db.read { try Settings.load($0) }
        #expect(defaults == Settings())
        #expect(defaults.maxSlots == 1 && defaults.memoryBudgetGB == 48 && defaults.idleUnloadMinutes == 10)
        var s = defaults
        s.recipeSources = [RecipeSourceRef(name: "lift-recipes", url: "https://example.com/lift-recipes.git")]
        s.pinOverrides = ["pixal3d": String(repeating: "a", count: 40)]
        s.queuePaused = true
        let saved = s
        try await store.db.write { try saved.save($0) }
        #expect(try await store.db.read { try Settings.load($0) } == saved)
    }

    @Test func settingValidation() throws {
        let s = Settings()
        #expect(try s.setting("max_slots", to: .int(3)).maxSlots == 3)
        #expect(try s.setting("memory_budget_gb", to: .int(64)).memoryBudgetGB == 64)
        #expect(throws: LiftError.self) { try s.setting("max_slots", to: .int(0)) }
        #expect(throws: LiftError.self) { try s.setting("max_slots", to: .string("two")) }
        #expect(throws: LiftError.self) { try s.setting("queue_paused", to: .bool(true)) }  // has its own command
        #expect(throws: LiftError.self) { try s.setting("nope", to: .int(1)) }
    }

    @Test func waitReasonCoding() throws {
        for r: WaitReason in [.noFreeSlot, .memory(needed: 5, free: 1), .modelInstalling, .modelNotInstalled, .modelUnsupported, .weightsUnverified, .queuePaused] {
            #expect(try JSONDecoder().decode(WaitReason.self, from: JSONEncoder().encode(r)) == r)
        }
        #expect(String(decoding: try JSONEncoder().encode(WaitReason.noFreeSlot), as: UTF8.self) == #"{"reason":"no_free_slot"}"#)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL. The first run resolves the packages (and writes `Package.resolved`), then stops with `error: cannot find 'Store' in scope`, `cannot find type 'JobRecord' in scope` and similar.

- [ ] **Step 4: Implement**

`Sources/LiftCore/LiftError.swift`:
```swift
import Foundation

/// One problem with one field of a request, e.g. `steps[0].settings.size`.
public struct FieldError: Codable, Sendable, Equatable {
    public var field: String
    public var message: String
    public init(_ field: String, _ message: String) {
        self.field = field
        self.message = message
    }
}

public enum LiftError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidInput([FieldError])
    case invalidState(String)
    case prerequisite(String)
    /// A shell command failed: the exact command and the end of its output.
    case commandFailed(command: String, exitCode: Int32, tail: [String])

    public var description: String {
        switch self {
        case .notFound(let what): "not found: \(what)"
        case .invalidInput(let errors): "invalid input: " + errors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
        case .invalidState(let why): why
        case .prerequisite(let why): why
        case .commandFailed(let command, let code, let tail):
            "`\(command)` failed with exit code \(code)\n" + tail.joined(separator: "\n")
        }
    }
}
```

`Sources/LiftCore/Support/Lines.swift`:
```swift
import Foundation
import Subprocess
import Synchronization

/// A thread-safe ring of the last `limit` lines.
public final class Tail: Sendable {
    private let state: Mutex<[String]>
    private let limit: Int

    public init(limit: Int) {
        self.limit = limit
        state = Mutex([])
    }

    public func append(_ line: String) {
        state.withLock { lines in
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    public var lines: [String] { state.withLock { $0 } }
}

/// Appends lines to a file (created if missing); thread-safe.
public final class LogFile: Sendable {
    private let handle: Mutex<FileHandle>

    public init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = Mutex(h)
    }

    public func write(_ line: String) {
        handle.withLock { _ = try? $0.write(contentsOf: Data((line + "\n").utf8)) }
    }
}

extension TerminationStatus {
    /// The exit code, or 128 + signal like a shell.
    var code: Int32 {
        switch self {
        case .exited(let c): c
        case .signaled(let s): 128 + s
        }
    }
}
```

`Sources/LiftCore/Recipes/SettingValue.swift`:
```swift
import Foundation

/// A setting value: from recipe YAML, from a request (JSON), or stored in a step.
public enum SettingValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .float(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .float(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var description: String {
        switch self {
        case .bool(let v): "\(v)"
        case .int(let v): "\(v)"
        case .float(let v): "\(v)"
        case .string(let v): v
        }
    }

    /// Numeric view for min/max checks and loose enum matching (1024 == 1024.0).
    var number: Double? {
        switch self {
        case .int(let v): Double(v)
        case .float(let v): v
        default: nil
        }
    }
}
```

`Sources/LiftCore/Store/Records.swift`:
```swift
import Foundation
import GRDB

public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued, waiting, loading, running, succeeded, failed, cancelled, interrupted

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    public var isActive: Bool { self == .loading || self == .running }
}

public enum Priority: String, Codable, Sendable, CaseIterable {
    case low, normal, high

    public var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        }
    }
}

public enum JobSource: String, Codable, Sendable {
    case ui, http, mcp
}

/// Why a step is not running. Facts only; encoded as `{"reason": "memory", "needed": …, "free": …}`.
public enum WaitReason: Codable, Sendable, Equatable {
    case noFreeSlot
    case memory(needed: Int, free: Int)
    case modelInstalling
    case modelNotInstalled
    case modelUnsupported
    case weightsUnverified
    case queuePaused

    private enum CodingKeys: String, CodingKey { case reason, needed, free }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .reason) {
        case "no_free_slot": self = .noFreeSlot
        case "memory": self = .memory(needed: try c.decode(Int.self, forKey: .needed), free: try c.decode(Int.self, forKey: .free))
        case "model_installing": self = .modelInstalling
        case "model_not_installed": self = .modelNotInstalled
        case "model_unsupported": self = .modelUnsupported
        case "weights_unverified": self = .weightsUnverified
        case "queue_paused": self = .queuePaused
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "unknown wait reason \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noFreeSlot: try c.encode("no_free_slot", forKey: .reason)
        case .memory(let needed, let free):
            try c.encode("memory", forKey: .reason)
            try c.encode(needed, forKey: .needed)
            try c.encode(free, forKey: .free)
        case .modelInstalling: try c.encode("model_installing", forKey: .reason)
        case .modelNotInstalled: try c.encode("model_not_installed", forKey: .reason)
        case .modelUnsupported: try c.encode("model_unsupported", forKey: .reason)
        case .weightsUnverified: try c.encode("weights_unverified", forKey: .reason)
        case .queuePaused: try c.encode("queue_paused", forKey: .reason)
        }
    }
}

public struct JobRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
    public var id: String
    public var title: String
    public var priority: Priority
    /// Manual order within a priority. Set to max + 1 on submit; `jobs_move` renumbers.
    public var position: Double
    public var source: JobSource
    public var state: JobState
    public var waitReason: WaitReason?
    public var forceStart: Bool
    /// Index of the step that runs next (or ran last).
    public var currentStep: Int
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
}

public struct StepRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "step"
    public var jobId: String
    public var idx: Int
    public var recipe: String
    public var task: String
    /// Input name → absolute path inside `jobs/<id>/inputs/` (or the text itself for `text` inputs).
    /// A chained step's first input is filled from the previous step's first output when it starts.
    public var inputs: [String: String]
    public var settings: [String: SettingValue]
    public var state: JobState
    public var waitReason: WaitReason?
    public var stage: String?
    public var fraction: Double?
    public var outputs: [String]
    public var error: String?
    public var workerId: String?
    public var startedAt: Date?
    public var finishedAt: Date?
}

public struct EventRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "event"
    public var id: Int64?
    public var jobId: String
    public var stepIdx: Int?
    public var at: Date
    /// `state` for now; `detail` is the new state, its wait reason and any error.
    public var kind: String
    public var detail: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct WorkerRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "worker"
    public var id: String
    public var recipe: String
    public var pid: Int32
    public var startedAt: Date
    public var loadSeconds: Double?
    public var endedAt: Date?
    public var endReason: String?
}

public struct MemorySampleRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "memorySample"
    public enum Kind: String, Codable, Sendable { case load, job }
    public var id: Int64?
    public var recipe: String
    public var task: String
    /// Canonical JSON of the recipe's `memory_keys` values, e.g. `{"low_vram":true}`.
    public var keyValues: String
    public var kind: Kind
    public var bytes: Int
    public var at: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SettingRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"
    public var key: String
    /// JSON text of the value.
    public var value: String
}
```

`Sources/LiftCore/Store/Store.swift`:
```swift
import Foundation
import GRDB

/// The SQLite database (`<workdir>/lift.sqlite`). Records are in Records.swift; queries live with their callers.
public final class Store: Sendable {
    public let db: DatabaseQueue

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    /// For tests.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("position", .double).notNull()
                t.column("source", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("waitReason", .text)
                t.column("forceStart", .boolean).notNull()
                t.column("currentStep", .integer).notNull()
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "step") { t in
                t.column("jobId", .text).notNull().references("job", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.primaryKey(["jobId", "idx"])
                t.column("recipe", .text).notNull()
                t.column("task", .text).notNull()
                t.column("inputs", .text).notNull()
                t.column("settings", .text).notNull()
                t.column("state", .text).notNull()
                t.column("waitReason", .text)
                t.column("stage", .text)
                t.column("fraction", .double)
                t.column("outputs", .text).notNull()
                t.column("error", .text)
                t.column("workerId", .text)
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jobId", .text).notNull().indexed().references("job", onDelete: .cascade)
                t.column("stepIdx", .integer)
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("detail", .text).notNull()
            }
            try db.create(table: "worker") { t in
                t.primaryKey("id", .text)
                t.column("recipe", .text).notNull()
                t.column("pid", .integer).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("loadSeconds", .double)
                t.column("endedAt", .datetime)
                t.column("endReason", .text)
            }
            try db.create(table: "memorySample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recipe", .text).notNull()
                t.column("task", .text).notNull()
                t.column("keyValues", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("at", .datetime).notNull()
            }
            try db.create(table: "weightHash") { t in
                t.primaryKey("path", .text)
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("sha256", .text).notNull()
            }
            try db.create(table: "weightCheck") { t in
                t.primaryKey("recipe", .text)
                t.column("at", .datetime).notNull()
                t.column("snapshots", .text).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }
}
```

`Sources/LiftCore/Store/Settings.swift`:
```swift
import Foundation
import GRDB

public struct RecipeSourceRef: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
}

/// App settings, one `setting` row per key (snake_case key, JSON value). Missing rows mean the default.
public struct Settings: Codable, Sendable, Equatable {
    public var maxSlots = 1
    public var memoryBudgetGB = 48.0
    public var idleUnloadMinutes = 10.0
    public var devRecipes = false
    public var queuePaused = false
    /// Git recipe sources in the order they were added (first wins on duplicate ids).
    public var recipeSources: [RecipeSourceRef] = []
    /// Recipe id → commit set by `models_set_pin`.
    public var pinOverrides: [String: String] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case maxSlots = "max_slots", memoryBudgetGB = "memory_budget_gb", idleUnloadMinutes = "idle_unload_minutes"
        case devRecipes = "dev_recipes", queuePaused = "queue_paused"
        case recipeSources = "recipe_sources", pinOverrides = "pin_overrides"
    }

    /// Keys `settings_set` accepts. The rest have their own commands (queue_pause, recipes_*, models_set_pin).
    public static let userKeys: Set<String> = ["max_slots", "memory_budget_gb", "idle_unload_minutes", "dev_recipes"]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        maxSlots = try c.decodeIfPresent(Int.self, forKey: .maxSlots) ?? d.maxSlots
        memoryBudgetGB = try c.decodeIfPresent(Double.self, forKey: .memoryBudgetGB) ?? d.memoryBudgetGB
        idleUnloadMinutes = try c.decodeIfPresent(Double.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        devRecipes = try c.decodeIfPresent(Bool.self, forKey: .devRecipes) ?? d.devRecipes
        queuePaused = try c.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? d.queuePaused
        recipeSources = try c.decodeIfPresent([RecipeSourceRef].self, forKey: .recipeSources) ?? d.recipeSources
        pinOverrides = try c.decodeIfPresent([String: String].self, forKey: .pinOverrides) ?? d.pinOverrides
    }

    public var memoryBudgetBytes: Int { Int(memoryBudgetGB * 1_000_000_000) }

    func validate() throws(LiftError) {
        var errors: [FieldError] = []
        if maxSlots < 1 { errors.append(FieldError("max_slots", "must be ≥ 1")) }
        if memoryBudgetGB <= 0 { errors.append(FieldError("memory_budget_gb", "must be > 0")) }
        if idleUnloadMinutes < 0 { errors.append(FieldError("idle_unload_minutes", "must be ≥ 0")) }
        if !errors.isEmpty { throw .invalidInput(errors) }
    }

    /// Reads all rows over the defaults.
    static func load(_ db: Database) throws -> Settings {
        var object: [String: Any] = [:]
        for row in try SettingRecord.fetchAll(db) {
            object[row.key] = try JSONSerialization.jsonObject(with: Data(row.value.utf8), options: .fragmentsAllowed)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    /// Writes every key (cheap: a handful of rows).
    func save(_ db: Database) throws {
        let data = try JSONEncoder().encode(self)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in object {
            let json = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            try SettingRecord(key: key, value: String(decoding: json, as: UTF8.self)).save(db)
        }
    }

    /// Returns a copy with one user key changed; type errors and range errors throw `invalidInput`.
    public func setting(_ key: String, to value: SettingValue) throws(LiftError) -> Settings {
        guard Self.userKeys.contains(key) else {
            throw .invalidInput([FieldError(key, "unknown setting; known: \(Self.userKeys.sorted().joined(separator: ", "))")])
        }
        let updated: Settings
        do {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
            object[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
            updated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw .invalidInput([FieldError(key, "wrong type: \(value)")])
        }
        try updated.validate()
        return updated
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "StoreTests|LinesTests"`
Expected: `✔ Test run with 8 tests in 2 suites passed`. Dates written to SQLite keep millisecond precision, which is why the test record uses a whole-second date.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved .gitignore Sources/LiftCore Tests/LiftCoreTests
git commit -m "feat(core): LiftCore package, GRDB store and settings

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 2: `lift_worker` Python runtime (protocol v1, worker side)

**Files:**
- Create: `python/lift_worker/pyproject.toml`
- Create: `python/lift_worker/src/lift_worker/__init__.py`, `__main__.py`, `stages.py`, `streams.py`, `worker.py`
- Test: `python/lift_worker/tests/conftest.py`, `test_stages.py`, `test_streams.py`, `test_worker.py`, `tests/fixtures/launcher.py`

**Interfaces:**
- Consumes: nothing (stdlib only).
- Produces (the contract Tasks 7, 9, 10 and 11 rely on):
  - CLI: `python -m lift_worker '<config json>'` runs the worker, and `python -m lift_worker --check '<config json>'` imports the launcher, compiles `stages`, prints `lift_worker: launcher OK` and exits 0 (non-zero on any error).
  - Config keys: `launcher` (path), `repo_dir`, `recipe_dir`, `max_concurrent` (default 1), `stages` (`[{"pattern": …}]`), `heartbeat_seconds` (default 2.0), `setting_types` (`{task: {key: "int"|"float"|…}}`).
  - stdin ops: `{"op":"run","job","step","task","inputs","settings","out_dir"}`, `{"op":"cancel","job"}`, `{"op":"shutdown"}`. stdin EOF means shutdown. Both exit with `os._exit(0)` right away, even while busy.
  - Protocol out (on a private dup of the original stdout; fd 1 → stderr): `ready{protocol:1, load_seconds}`, `log{job, line}`, `stage{job, name, fraction|null}`, `done{job, outputs:[abs paths]}`, `error{job|null, message, traceback}`, `heartbeat{mps_allocated}`. A load failure sends `error` with `job: null` and exits 1.
  - Launcher API: `load(ctx)` (optional; `ctx.repo_dir`, `ctx.recipe_dir`) and `run(state, job) -> list[str]`, where `job` has `.id .step .task .inputs .settings .out_dir .cancelled .stage(name, fraction=None)`.
  - `lift_worker.stages.StageParser(patterns).feed(line) -> (name, fraction|None) | None`; `lift_worker.streams.TaggedStream(on_line, job_of)` with `.write/.drain`; `separate_fds() -> int`; `Channel(fd).send(**msg)`.

- [ ] **Step 1: Create the project file**

`python/lift_worker/pyproject.toml`:
```toml
[project]
name = "lift-worker"
version = "0.1.0"
description = "Lift worker runtime: runs a recipe launcher and speaks the JSON-lines worker protocol v1"
requires-python = ">=3.10"
dependencies = []          # stdlib only: it runs inside every model venv

[dependency-groups]
dev = ["pytest>=8"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/lift_worker"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
```

- [ ] **Step 2: Write the failing tests**

`python/lift_worker/tests/fixtures/launcher.py`. Job settings drive this fixture launcher:
```python
"""Test launcher: behaviour is driven by job settings."""
import os
import sys
import threading
import time


def load(ctx):
    print("loading model")             # untagged: goes to stderr
    os.write(1, b"native noise at load\n")  # fd 1 now points at stderr
    if os.environ.get("FIXTURE_LOAD_FAIL"):
        raise RuntimeError("load failed on purpose")
    return {"repo_dir": ctx.repo_dir}


def run(state, job):
    s = job.settings
    print(f"start {job.id}")
    if "scale" in s:
        print(f"scale is {type(s['scale']).__name__}")
    os.write(1, b"native noise in job\n")
    if s.get("stages"):
        print("[Stage] Sampling")
        sys.stderr.write("Sampling:  50%|#####     | 1/2\r")
        sys.stderr.write("Sampling: 100%|##########| 2/2\n")
    if s.get("thread_log"):
        t = threading.Thread(target=lambda: print("from upstream thread"))
        t.start()
        t.join()
    end = time.monotonic() + float(s.get("sleep", 0))
    while time.monotonic() < end:
        if job.cancelled:
            raise RuntimeError("cancelled by request")
        time.sleep(0.02)
    if s.get("exit"):
        sys.exit(3)
    if s.get("raise"):
        raise ValueError("boom")
    if s.get("crash"):
        os._exit(7)
    print("no newline at end", end="")
    path = os.path.join(job.out_dir, "out.txt")
    with open(path, "w") as f:
        f.write(job.id)
    return [path]
```

`python/lift_worker/tests/conftest.py`:
```python
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "launcher.py"


class WorkerProc:
    """Drives `python -m lift_worker` over real pipes, like the app does."""

    def __init__(self, tmp_path, env=None, **cfg):
        config = {"launcher": str(FIXTURE), "repo_dir": str(tmp_path), "recipe_dir": str(tmp_path),
                  "max_concurrent": 1, "stages": [], "heartbeat_seconds": 60, **cfg}
        self.tmp = tmp_path
        self.p = subprocess.Popen(
            [sys.executable, "-m", "lift_worker", json.dumps(config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "PYTHONPATH": str(SRC), **(env or {})},
        )
        self.events: queue.Queue = queue.Queue()
        self.raw_stdout: list[str] = []
        self.stderr: list[str] = []
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()

    def _pump_out(self):
        for line in self.p.stdout:
            self.raw_stdout.append(line)
            self.events.put(json.loads(line))  # a non-JSON line fails the test thread loudly

    def _pump_err(self):
        for line in self.p.stderr:
            self.stderr.append(line.rstrip("\n"))

    def send(self, **op):
        self.p.stdin.write(json.dumps(op) + "\n")
        self.p.stdin.flush()

    def run(self, job, **settings):
        self.send(op="run", job=job, step=0, task="t", inputs={}, settings=settings,
                  out_dir=str(self.tmp / job))

    def until(self, pred, timeout=10.0):
        """Collect events until pred(event) is true; return all collected."""
        got, end = [], time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                ev = self.events.get(timeout=0.1)
            except queue.Empty:
                continue
            got.append(ev)
            if pred(ev):
                return got
        raise AssertionError(f"timed out; got {got}; stderr {self.stderr}")

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait(5)


@pytest.fixture
def worker(tmp_path):
    procs = []

    def make(**kw):
        w = WorkerProc(tmp_path, **kw)
        procs.append(w)
        return w

    yield make
    for w in procs:
        w.close()
```

`python/lift_worker/tests/test_stages.py`:
```python
from lift_worker.stages import StageParser

TAG = {"pattern": r"^\[Stage\] (?P<name>.+)$"}
TQDM = {"pattern": r"^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|"}
COUNT = {"pattern": r"step (?P<n>\d+)/(?P<total>\d+)"}


def test_stage_tag_without_fraction():
    assert StageParser([TAG]).feed("[Stage] Loading model") == ("Loading model", None)


def test_tqdm_percent():
    assert StageParser([TQDM]).feed("Sampling:  45%|####5     | 9/20 [00:03<00:04]") == ("Sampling", 0.45)


def test_count_keeps_previous_name():
    p = StageParser([TAG, COUNT])
    p.feed("[Stage] Decoding")
    assert p.feed("step 3/4") == ("Decoding", 0.75)


def test_no_match():
    assert StageParser([TAG, TQDM]).feed("just a log line") is None


def test_fraction_clamped():
    assert StageParser([TQDM]).feed("X: 140%|") == ("X", 1.0)
```

`python/lift_worker/tests/test_streams.py`:
```python
import threading

from lift_worker.streams import TaggedStream


def collect():
    lines = []
    return lines, (lambda job, line: lines.append((job, line)))


def test_splits_lines_and_carriage_returns():
    lines, sink = collect()
    s = TaggedStream(sink, lambda: "j1")
    s.write("a\nb\rc")
    assert lines == [("j1", "a"), ("j1", "b")]
    s.write("\r\n")
    assert lines[-1] == ("j1", "c")


def test_partial_line_waits_for_drain():
    lines, sink = collect()
    s = TaggedStream(sink, lambda: None)
    s.write("partial")
    assert lines == []
    s.drain()
    assert lines == [(None, "partial")]


def test_buffers_are_per_thread():
    lines, sink = collect()
    local = threading.local()
    s = TaggedStream(sink, lambda: getattr(local, "job", None))

    def work(job):
        local.job = job
        s.write(f"from {job} ")
        s.write("done\n")

    threads = [threading.Thread(target=work, args=(j,)) for j in ("a", "b")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(lines) == [("a", "from a done"), ("b", "from b done")]
```

`python/lift_worker/tests/test_worker.py`:
```python
import json
import os
import subprocess
import sys
import time

from conftest import FIXTURE, SRC

TAG = {"pattern": r"^\[Stage\] (?P<name>.+)$"}
TQDM = {"pattern": r"^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|"}


def is_ev(name, job=None):
    return lambda e: e["ev"] == name and (job is None or e.get("job") == job)


def test_ready_and_native_output_kept_off_protocol(worker):
    w = worker()
    ready = w.until(is_ev("ready"))[-1]
    assert ready["protocol"] == 1 and ready["load_seconds"] >= 0
    w.run("j1")
    w.until(is_ev("done", "j1"))
    assert all(json.loads(line) for line in w.raw_stdout)  # every protocol line is JSON
    time.sleep(0.2)
    assert "native noise at load" in w.stderr and "loading model" in w.stderr


def test_run_logs_tagged_and_done(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1")
    evs = w.until(is_ev("done", "j1"))
    logs = [e["line"] for e in evs if e["ev"] == "log"]
    assert "start j1" in logs
    assert "no newline at end" in logs  # partial last line drained before done
    done = evs[-1]
    assert done["outputs"] == [os.path.abspath(w.tmp / "j1" / "out.txt")]
    assert (w.tmp / "j1" / "out.txt").read_text() == "j1"


def test_thread_started_by_upstream_tagged_to_only_job(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", thread_log=True)
    evs = w.until(is_ev("done", "j1"))
    assert {"ev": "log", "job": "j1", "line": "from upstream thread"} in evs


def test_concurrent_jobs_tagged_separately(worker):
    w = worker(max_concurrent=2)
    w.until(is_ev("ready"))
    t = time.monotonic()
    w.run("a", sleep=0.6)
    w.run("b", sleep=0.6)
    done = set()
    evs = w.until(lambda e: e["ev"] == "done" and (done.add(e["job"]) or done == {"a", "b"}))
    assert time.monotonic() - t < 1.1  # overlapped, not sequential
    assert {"ev": "log", "job": "a", "line": "start a"} in evs
    assert {"ev": "log", "job": "b", "line": "start b"} in evs


def test_stages_parsed_from_output(worker):
    w = worker(stages=[TAG, TQDM])
    w.until(is_ev("ready"))
    w.run("j1", stages=True)
    stages = [(e["name"], e["fraction"]) for e in w.until(is_ev("done", "j1")) if e["ev"] == "stage"]
    assert stages == [("Sampling", None), ("Sampling", 0.5), ("Sampling", 1.0)]


def test_system_exit_fails_job_not_worker(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", exit=True)
    err = w.until(is_ev("error", "j1"))[-1]
    assert err["message"].startswith("SystemExit") and "Traceback" in err["traceback"]
    w.run("j2")
    w.until(is_ev("done", "j2"))


def test_exception_reported(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", **{"raise": True})
    assert w.until(is_ev("error", "j1"))[-1]["message"] == "ValueError: boom"


def test_cancel_sets_flag(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", sleep=30)
    w.until(lambda e: e.get("line") == "start j1")
    w.send(op="cancel", job="j1")
    assert "cancelled by request" in w.until(is_ev("error", "j1"), timeout=3)[-1]["message"]


def test_heartbeat(worker):
    w = worker(heartbeat_seconds=0.1)
    hb = w.until(is_ev("heartbeat"))[-1]
    assert isinstance(hb["mps_allocated"], int)


def test_shutdown_op_exits(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.send(op="shutdown")
    assert w.p.wait(5) == 0


def test_stdin_eof_exits_even_while_busy(worker):
    w = worker()
    w.until(is_ev("ready"))
    w.run("j1", sleep=30)
    w.until(lambda e: e.get("line") == "start j1")
    w.p.stdin.close()  # the app died: the worker must not outlive it
    assert w.p.wait(5) == 0


def test_load_failure_reports_and_exits(worker):
    w = worker(env={"FIXTURE_LOAD_FAIL": "1"})
    err = w.until(is_ev("error"))[-1]
    assert err["job"] is None and "load failed on purpose" in err["message"]
    assert w.p.wait(5) == 1


def test_check_mode(tmp_path):
    cfg = json.dumps({"launcher": str(FIXTURE), "stages": [TAG]})
    r = subprocess.run([sys.executable, "-m", "lift_worker", "--check", cfg], capture_output=True, text=True,
                       env={**os.environ, "PYTHONPATH": str(SRC)})
    assert r.returncode == 0, r.stderr
    bad = json.dumps({"launcher": str(FIXTURE), "stages": [{"pattern": "("}]})
    r = subprocess.run([sys.executable, "-m", "lift_worker", "--check", bad], capture_output=True, text=True,
                       env={**os.environ, "PYTHONPATH": str(SRC)})
    assert r.returncode != 0


def test_float_settings_arrive_as_float(worker):
    w = worker(setting_types={"t": {"scale": "float"}})
    w.until(is_ev("ready"))
    w.run("j1", scale=2)  # JSON 2 for a float setting
    assert {"ev": "log", "job": "j1", "line": "scale is float"} in w.until(is_ev("done", "j1"))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd python/lift_worker && uv run --python 3.11 pytest -q`
Expected: FAIL. Collection errors such as `ModuleNotFoundError: No module named 'lift_worker.stages'`.

- [ ] **Step 4: Implement**

`python/lift_worker/src/lift_worker/__init__.py`:
```python
"""lift_worker — the Python side of Lift's worker protocol (version 1).

Shipped with the app, not with recipes. Run as `python -m lift_worker '<config json>'`
inside a model venv; `--check` imports the launcher and exits.
"""
PROTOCOL = 1
```

`python/lift_worker/src/lift_worker/stages.py`:
```python
"""Progress stages parsed from upstream output with recipe-declared regexes."""
from __future__ import annotations

import re


class StageParser:
    """Each pattern may use the named groups `name`, `pct` (0-100), or `n` and `total`.

    A match without `name` keeps the previous stage name (e.g. a bare tqdm bar).
    """

    def __init__(self, patterns: list[dict]):
        self._rx = [re.compile(p["pattern"]) for p in patterns]
        self._name = ""

    def feed(self, line: str) -> tuple[str, float | None] | None:
        for rx in self._rx:
            m = rx.search(line)
            if not m:
                continue
            g = m.groupdict()
            if g.get("name"):
                self._name = g["name"].strip()
            fraction = None
            if g.get("pct") is not None:
                fraction = float(g["pct"]) / 100
            elif g.get("n") is not None and g.get("total"):
                fraction = int(g["n"]) / int(g["total"])
            if fraction is not None:
                fraction = max(0.0, min(1.0, fraction))
            return self._name, fraction
        return None
```

`python/lift_worker/src/lift_worker/streams.py`:
```python
"""fd separation and per-thread line tagging."""
from __future__ import annotations

import io
import json
import os
import re
import threading

_SPLIT = re.compile(r"\r\n|\r|\n")


def separate_fds() -> int:
    """Duplicate fd 1 for the protocol, then point fd 1 at stderr, so native prints can't corrupt it."""
    proto = os.dup(1)
    os.dup2(2, 1)
    return proto


class Channel:
    """Protocol writer: one JSON object per line on a private fd. Thread-safe."""

    def __init__(self, fd: int):
        self._f = os.fdopen(fd, "w", buffering=1, encoding="utf-8")
        self._lock = threading.Lock()

    def send(self, **msg) -> None:
        line = json.dumps(msg, ensure_ascii=False, default=str)
        with self._lock:
            self._f.write(line + "\n")
            self._f.flush()


class TaggedStream(io.TextIOBase):
    """Stands in for sys.stdout / sys.stderr.

    Text is buffered per thread; each complete line (split on \\n or \\r, so tqdm
    redraws count) goes to on_line(job_of(), line).
    """

    encoding = "utf-8"

    def __init__(self, on_line, job_of):
        super().__init__()
        self._on_line = on_line
        self._job_of = job_of
        self._local = threading.local()

    def writable(self) -> bool:
        return True

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        return 2  # code that writes to the raw fd lands on stderr, outside the protocol

    def write(self, s: str) -> int:
        *lines, rest = _SPLIT.split(getattr(self._local, "text", "") + s)
        self._local.text = rest
        for line in lines:
            if line:
                self._on_line(self._job_of(), line)
        return len(s)

    def drain(self) -> None:
        """Emit this thread's partial last line, if any."""
        rest = getattr(self._local, "text", "")
        self._local.text = ""
        if rest:
            self._on_line(self._job_of(), rest)

    def flush(self) -> None:
        pass  # partial lines stay buffered until a newline or drain()
```

`python/lift_worker/src/lift_worker/worker.py`:
```python
"""The worker: loads the recipe launcher once, runs jobs on a thread pool, reports over the channel."""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

from . import PROTOCOL
from .stages import StageParser


def load_launcher(cfg: dict):
    """Import the recipe's launcher.py and check its stage patterns compile."""
    StageParser(cfg.get("stages", []))
    repo = cfg.get("repo_dir")
    if repo and repo not in sys.path:
        sys.path.insert(0, repo)
    spec = importlib.util.spec_from_file_location("lift_launcher", cfg["launcher"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "run", None)):
        raise TypeError(f"{cfg['launcher']} must define run(state, job)")
    return module


def _mps_allocated() -> int:
    torch = sys.modules.get("torch")  # never import torch here: it is the launcher's choice
    try:
        if torch is not None and torch.backends.mps.is_available():
            return int(torch.mps.driver_allocated_memory())
    except Exception:  # noqa: BLE001 - a heartbeat must never fail
        pass
    return 0


def coerce_settings(settings: dict, types: dict) -> dict:
    """JSON can't tell 1 from 1.0: make `float` settings floats again (bools stay bools)."""
    out = dict(settings)
    for key, typ in types.items():
        v = out.get(key)
        if typ == "float" and isinstance(v, int) and not isinstance(v, bool):
            out[key] = float(v)
    return out


class Job:
    """What launcher.run(state, job) receives."""

    def __init__(self, msg: dict, patterns: list[dict], types: dict | None = None):
        self.id: str = msg["job"]
        self.step: int = msg.get("step", 0)
        self.task: str = msg["task"]
        self.inputs: dict = msg.get("inputs", {})
        self.settings: dict = coerce_settings(msg.get("settings", {}), (types or {}).get(self.task, {}))
        self.out_dir: str = msg["out_dir"]
        self.parser = StageParser(patterns)
        self._cancel = threading.Event()
        self._channel = None

    @property
    def cancelled(self) -> bool:
        """Launchers may poll this; upstream code is never interrupted."""
        return self._cancel.is_set()

    def stage(self, name: str, fraction: float | None = None) -> None:
        """Launchers may report a stage directly."""
        self._channel.send(ev="stage", job=self.id, name=name, fraction=fraction)


class Worker:
    def __init__(self, cfg: dict, channel):
        self.cfg = cfg
        self.ch = channel
        self.pool = ThreadPoolExecutor(max_workers=max(1, int(cfg.get("max_concurrent", 1))),
                                       thread_name_prefix="lift-job")
        self.jobs: dict[str, Job] = {}
        self.lock = threading.Lock()
        self.local = threading.local()
        self.streams: list = []
        self.launcher = None
        self.state = None

    # --- log routing -------------------------------------------------------
    def current_job(self) -> str | None:
        job = getattr(self.local, "job", None)
        if job:
            return job
        with self.lock:  # a line from a thread upstream started: the only running job owns it
            return next(iter(self.jobs)) if len(self.jobs) == 1 else None

    def on_line(self, job_id: str | None, line: str) -> None:
        job = self.jobs.get(job_id) if job_id else None
        if job is None:
            os.write(2, (line + "\n").encode("utf-8", "replace"))
            return
        self.ch.send(ev="log", job=job_id, line=line)
        parsed = job.parser.feed(line)
        if parsed:
            self.ch.send(ev="stage", job=job_id, name=parsed[0], fraction=parsed[1])

    # --- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        threading.Thread(target=self._heartbeat, daemon=True, name="lift-heartbeat").start()
        t0 = time.perf_counter()
        try:
            self.launcher = load_launcher(self.cfg)
            ctx = SimpleNamespace(repo_dir=self.cfg.get("repo_dir"), recipe_dir=self.cfg.get("recipe_dir"))
            load = getattr(self.launcher, "load", None)
            self.state = load(ctx) if callable(load) else None
        except BaseException as e:  # noqa: BLE001 - includes SystemExit from upstream
            for s in self.streams:
                s.drain()
            self.ch.send(ev="error", job=None, message=f"{type(e).__name__}: {e}", traceback=traceback.format_exc())
            os._exit(1)
        for s in self.streams:
            s.drain()
        self.ch.send(ev="ready", protocol=PROTOCOL, load_seconds=round(time.perf_counter() - t0, 3))

    def _heartbeat(self) -> None:
        every = float(self.cfg.get("heartbeat_seconds", 2.0))
        while True:
            time.sleep(every)
            self.ch.send(ev="heartbeat", mps_allocated=_mps_allocated())

    def serve(self, stdin) -> None:
        """Read ops until shutdown or EOF (EOF means the app went away), then exit at once."""
        for raw in stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            op = msg.get("op")
            if op == "run":
                job = Job(msg, self.cfg.get("stages", []), self.cfg.get("setting_types"))
                job._channel = self.ch
                with self.lock:
                    self.jobs[job.id] = job
                self.pool.submit(self._run, job)
            elif op == "cancel":
                job = self.jobs.get(msg.get("job"))
                if job:
                    job._cancel.set()
            elif op == "shutdown":
                break
        os._exit(0)

    def _run(self, job: Job) -> None:
        self.local.job = job.id
        try:
            os.makedirs(job.out_dir, exist_ok=True)
            outputs = self.launcher.run(self.state, job) or []
            for s in self.streams:
                s.drain()
            self.ch.send(ev="done", job=job.id, outputs=[os.path.abspath(o) for o in outputs])
        except BaseException as e:  # noqa: BLE001 - SystemExit from upstream fails the job, not the worker
            for s in self.streams:
                s.drain()
            self.ch.send(ev="error", job=job.id, message=f"{type(e).__name__}: {e}", traceback=traceback.format_exc())
        finally:
            self.local.job = None
            with self.lock:
                self.jobs.pop(job.id, None)
```

`python/lift_worker/src/lift_worker/__main__.py`:
```python
"""Entry: python -m lift_worker [--check] '<config json>'.

Config keys: launcher (path to launcher.py), repo_dir, recipe_dir, max_concurrent,
stages ([{pattern}]), heartbeat_seconds, setting_types ({task: {key: type}}).
"""
from __future__ import annotations

import json
import sys

from .streams import Channel, TaggedStream, separate_fds
from .worker import Worker, load_launcher


def main(argv: list[str]) -> int:
    check = bool(argv) and argv[0] == "--check"
    cfg = json.loads(argv[-1])
    if check:
        load_launcher(cfg)
        print("lift_worker: launcher OK")
        return 0
    channel = Channel(separate_fds())
    worker = Worker(cfg, channel)
    out, err = TaggedStream(worker.on_line, worker.current_job), TaggedStream(worker.on_line, worker.current_job)
    worker.streams = [out, err]
    sys.stdout, sys.stderr = out, err
    worker.start()
    worker.serve(sys.stdin)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd python/lift_worker && uv run --python 3.11 pytest -q`
Expected: `22 passed`.

- [ ] **Step 6: Commit**

```bash
git add python/lift_worker
git commit -m "feat(worker): lift_worker runtime for worker protocol v1

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 3: Recipe schema v1 and validation

**Files:**
- Create: `Sources/LiftCore/Recipes/Recipe.swift`, `Sources/LiftCore/Recipes/Validation.swift`
- Test: `Tests/LiftCoreTests/RecipeTests.swift`, `Tests/LiftCoreTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `SettingValue`, `LiftError`, `FieldError` (Task 1); `Fixtures.tempDir()` (Task 1).
- Produces:
  - `enum IOType: String { text, image, imageSet = "image_set", mesh, riggedMesh = "rigged_mesh", video, audio }` with `accepts(_ output: IOType) -> Bool` (same type, or `mesh` accepting `rigged_mesh`).
  - `enum SettingType: String { int, float, bool, enum, string, path }`; `struct SettingDef { key, label, type, options: [SettingValue]?, default: SettingValue?, min: Double?, max: Double?, help?, group? }` (memberwise init used in tests); `struct TaskInput { name, type: IOType }`; `struct RecipeTask { id, modality, label, inputs, output: IOType, entry: String?, settings: [SettingDef] }`.
  - `struct Recipe { schema, id, name, publisher?, license?, homepage?, repo?, commit?, python = "3.11", platform: Platform{status: .supported|.unsupported, reason?}, install: [String], substitutes: [String], shim: Shim?{aliases: [String:String], standins: [String], patches: [String], env: [String:String]}, brew: [String], weights: [Weight{repo, revision = "main", gated = false}], developer: Bool, resources: Resources{memoryGB, memoryKeys, memoryOverrides: [MemoryOverride{when: [String:SettingValue], memoryGB}], maxConcurrentPerProcess = 1, diskGB = 5}, stages: [StagePattern{pattern}], tasks: [RecipeTask] }`, plus `static supportedSchema = 1` and `task(_ id:) -> RecipeTask?`. `Recipe.Weight(repo:revision:gated:)` has a memberwise init with defaults. All fields are `var`.
  - `enum RecipeLoad: Equatable { ok(Recipe), needsNewerLift(id:schema:), invalid(String) }` and `static func read(directory: URL, matchFolder: Bool = true) -> RecipeLoad`. Use `matchFolder: false` for an installed copy.
  - `RecipeTask.validated(settings: [String: SettingValue], prefix: String) throws(LiftError) -> [String: SettingValue]` fills defaults and coerces int↔float and enum options, throwing `invalidInput` with fields `"\(prefix).\(key)"`. `RecipeTask.validated(inputs: [String: String], chained: Bool, prefix: String) throws(LiftError) -> [String: String]` checks names and that files/folders exist; a chained step may leave its first input out.
  - Test helpers: `writeRecipe(_ yaml: String, id: String, in dir: URL, launcher: Bool = true) throws -> URL` and `let pixalYAML: String` (the spec §4 example, with `shim: {patches, env}`, `brew: [libusb]` and a gated weight at a revision).

- [ ] **Step 1: Write the failing tests**

`Tests/LiftCoreTests/RecipeTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

/// Writes `<dir>/<id>/recipe.yaml` (+ launcher.py) and returns the folder.
func writeRecipe(_ yaml: String, id: String, in dir: URL, launcher: Bool = true) throws -> URL {
    let folder = dir.appending(path: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try yaml.write(to: folder.appending(path: "recipe.yaml"), atomically: true, encoding: .utf8)
    if launcher { try "def run(state, job):\n    return []\n".write(to: folder.appending(path: "launcher.py"), atomically: true, encoding: .utf8) }
    return folder
}

let pixalYAML = """
schema: 1
id: pixal3d
name: Pixal3D
publisher: TencentARC
license: MIT
homepage: https://github.com/TencentARC/Pixal3D
repo: https://github.com/TencentARC/Pixal3D
commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94
python: "3.11"
platform: { status: supported, reason: "" }
install:
  - uv pip install torch torchvision
substitutes: [flash_attn]
shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }
brew: [libusb]
weights:
  - { repo: TencentARC/Pixal3D, gated: false }
  - { repo: briaai/RMBG-2.0, revision: 1f3e2a7c, gated: true }
resources:
  memory_gb: 18
  memory_keys: [low_vram, resolution]
  memory_overrides: [{ when: { low_vram: true }, memory_gb: 12 }]
  max_concurrent_per_process: 1
stages:
  - { pattern: '^\\[Stage\\] (?P<name>.+)$' }
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: inference:run_inference
    settings:
      - { key: resolution, label: Resolution, type: enum, options: [1024, 1536], default: 1536, group: basic }
      - { key: low_vram, label: Low memory mode, type: bool, default: false, group: basic }
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: manual_fov, label: Camera FOV, type: float, default: -1.0, help: "radians; <0 = auto", group: basic }
      - { key: ss_sampling_steps, label: Sparse structure steps, type: int, min: 1, max: 50, default: 12, group: advanced }
"""

@Suite struct RecipeTests {
    @Test func parsesTheSpecExample() throws {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { Issue.record("\(RecipeLoad.read(directory: folder))"); return }
        #expect(r.commit == "f7cf38429b0bd264f1995f0f8743a88b1c728b94")
        #expect(r.substitutes == ["flash_attn"] && r.brew == ["libusb"] && !r.developer)
        #expect(r.shim?.patches == ["transformers_fa2_to_sdpa"] && r.shim?.env == ["ATTN_BACKEND": "sdpa"] && r.shim?.aliases == [:])
        #expect(r.weights == [Recipe.Weight(repo: "TencentARC/Pixal3D"), Recipe.Weight(repo: "briaai/RMBG-2.0", revision: "1f3e2a7c", gated: true)])
        #expect(r.resources.memoryOverrides == [Recipe.MemoryOverride(when: ["low_vram": .bool(true)], memoryGB: 12)])
        #expect(r.resources.diskGB == 5)  // default
        let t = try #require(r.task("image_to_3d"))
        #expect(t.output == .mesh && t.inputs == [TaskInput(name: "image", type: .image)])
        #expect(t.settings.first?.options == [.int(1024), .int(1536)])
        #expect(t.settings.first { $0.key == "manual_fov" }?.default == .float(-1.0))
        #expect(r.stages == [Recipe.StagePattern(pattern: #"^\[Stage\] (?P<name>.+)$"#)])
    }

    @Test func newerSchemaIsReportedNotParsed() throws {
        let folder = try writeRecipe("schema: 2\nid: future\nsomething_new: true\n", id: "future", in: try Fixtures.tempDir())
        #expect(RecipeLoad.read(directory: folder) == .needsNewerLift(id: "future", schema: 2))
    }

    @Test(arguments: [
        ("id: pixal3d", "id: other", "must match its folder"),
        ("commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94", "commit: f7cf384", "40-character"),
        ("type: enum, options: [1024, 1536], default: 1536", "type: enum, default: 1536", "enum needs options"),
        ("min: 1, max: 50, default: 12", "min: 1, max: 50, default: 99", "default must be ≤ 50"),
        ("memory_keys: [low_vram, resolution]", "memory_keys: [low_vram, nope]", "nope is not a setting"),
        ("platform: { status: supported, reason: \"\" }", "platform: { status: unsupported }", "reason is required"),
        ("repo: TencentARC/Pixal3D, gated", "repo: Pixal3D, gated", "must be owner/name"),
    ])
    func invalidRecipes(original: String, replacement: String, message: String) throws {
        let yaml = pixalYAML.replacingOccurrences(of: original, with: replacement)
        let folder = try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.contains(message))
    }

    @Test func noShimMeansNone() throws {
        let yaml = pixalYAML.replacingOccurrences(of: "shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }\n", with: "")
        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected ok"); return }
        #expect(r.shim == nil)
    }

    @Test func missingLauncherIsInvalid() throws {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir(), launcher: false)
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.contains("launcher.py is missing"))
    }

    @Test func undecodableYAMLIsInvalid() throws {
        let folder = try writeRecipe("schema: 1\nid: x\n", id: "x", in: try Fixtures.tempDir())
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.hasPrefix("recipe.yaml:"))
    }
}
```

`Tests/LiftCoreTests/ValidationTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct ValidationTests {
    func task() throws -> RecipeTask {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return r.tasks[0]
    }

    func fields(_ body: () throws -> Void) -> [String] {
        do { try body() } catch let LiftError.invalidInput(errors) { return errors.map(\.field) } catch { return ["unexpected \(error)"] }
        return []
    }

    @Test func defaultsAreFilled() throws {
        let s = try task().validated(settings: [:], prefix: "settings")
        #expect(s == ["resolution": .int(1536), "low_vram": .bool(false), "seed": .int(42), "manual_fov": .float(-1), "ss_sampling_steps": .int(12)])
    }

    @Test func valuesAreCoerced() throws {
        let s = try task().validated(settings: ["resolution": .float(1024), "manual_fov": .int(1), "seed": .float(7)], prefix: "settings")
        #expect(s["resolution"] == .int(1024) && s["manual_fov"] == .float(1) && s["seed"] == .int(7))
    }

    @Test func badValuesNameTheirFields() throws {
        let t = try task()
        #expect(fields { _ = try t.validated(settings: ["resolution": .int(999)], prefix: "s") } == ["s.resolution"])
        #expect(fields { _ = try t.validated(settings: ["ss_sampling_steps": .int(0)], prefix: "s") } == ["s.ss_sampling_steps"])
        #expect(fields { _ = try t.validated(settings: ["seed": .float(1.5)], prefix: "s") } == ["s.seed"])
        #expect(fields { _ = try t.validated(settings: ["low_vram": .string("yes")], prefix: "s") } == ["s.low_vram"])
        #expect(fields { _ = try t.validated(settings: ["bogus": .int(1), "seed": .string("x")], prefix: "s") } == ["s.bogus", "s.seed"])
    }

    @Test func requiredWithoutDefault() throws {
        var t = try task()
        t.settings.append(SettingDef(key: "prompt", label: "Prompt", type: .string))
        #expect(fields { _ = try t.validated(settings: [:], prefix: "s") } == ["s.prompt"])
    }

    @Test func inputs() throws {
        let t = try task()
        let dir = try Fixtures.tempDir()
        let file = dir.appending(path: "a.png")
        try Data([1]).write(to: file)
        #expect(try t.validated(inputs: ["image": file.path], chained: false, prefix: "i") == ["image": file.path])
        #expect(fields { _ = try t.validated(inputs: [:], chained: false, prefix: "i") } == ["i.image"])
        #expect(try t.validated(inputs: [:], chained: true, prefix: "i") == [:])  // filled from the previous step
        #expect(fields { _ = try t.validated(inputs: ["image": dir.appending(path: "missing.png").path], chained: false, prefix: "i") } == ["i.image"])
        #expect(fields { _ = try t.validated(inputs: ["image": dir.path], chained: false, prefix: "i") } == ["i.image"])  // a folder, not a file
        #expect(fields { _ = try t.validated(inputs: ["image": file.path, "extra": file.path], chained: false, prefix: "i") } == ["i.extra"])
    }

    @Test func imageSetNeedsAFolder() throws {
        var t = try task()
        t.inputs = [TaskInput(name: "views", type: .imageSet)]
        let dir = try Fixtures.tempDir()
        #expect(try t.validated(inputs: ["views": dir.path], chained: false, prefix: "i") == ["views": dir.path])
        let file = dir.appending(path: "a.png")
        try Data([1]).write(to: file)
        #expect(fields { _ = try t.validated(inputs: ["views": file.path], chained: false, prefix: "i") } == ["i.views"])
    }

    @Test func chainTypes() {
        #expect(IOType.mesh.accepts(.mesh) && IOType.mesh.accepts(.riggedMesh))
        #expect(!IOType.riggedMesh.accepts(.mesh) && !IOType.image.accepts(.mesh))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find 'RecipeLoad' in scope`, `cannot find type 'RecipeTask' in scope` and similar.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Recipes/Recipe.swift`:
```swift
import Foundation
import Yams

public enum IOType: String, Codable, Sendable, CaseIterable {
    case text, image, imageSet = "image_set", mesh, riggedMesh = "rigged_mesh", video, audio

    /// Whether a step whose first input is `self` can follow a step that outputs `output` (spec §4).
    public func accepts(_ output: IOType) -> Bool {
        output == self || (self == .mesh && output == .riggedMesh)
    }
}

public enum SettingType: String, Codable, Sendable {
    case int, float, bool, `enum`, string, path
}

public struct SettingDef: Codable, Sendable, Equatable {
    public var key: String
    public var label: String
    public var type: SettingType
    public var options: [SettingValue]?
    public var `default`: SettingValue?
    public var min: Double?
    public var max: Double?
    public var help: String?
    public var group: String?
}

public struct TaskInput: Codable, Sendable, Equatable {
    public var name: String
    public var type: IOType
}

public struct RecipeTask: Codable, Sendable, Equatable {
    public var id: String
    public var modality: String
    public var label: String
    public var inputs: [TaskInput]
    public var output: IOType
    /// Informational (`module:function` inside repo/); the launcher decides how to call upstream.
    public var entry: String?
    public var settings: [SettingDef]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modality = try c.decode(String.self, forKey: .modality)
        label = try c.decode(String.self, forKey: .label)
        inputs = try c.decode([TaskInput].self, forKey: .inputs)
        output = try c.decode(IOType.self, forKey: .output)
        entry = try c.decodeIfPresent(String.self, forKey: .entry)
        settings = try c.decodeIfPresent([SettingDef].self, forKey: .settings) ?? []
    }
}

/// `recipe.yaml`, schema v1 (spec §4), plus `shim`, `brew`, `stages`, `developer` and `weights[].revision`
/// (see the plan's schema notes).
public struct Recipe: Codable, Sendable, Equatable {
    public static let supportedSchema = 1

    public struct Platform: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case supported, unsupported }
        public var status: Status
        public var reason: String?
    }

    /// A Hugging Face model repo the recipe needs, at a branch, tag or commit.
    public struct Weight: Codable, Sendable, Equatable {
        public var repo: String
        public var revision: String
        public var gated: Bool

        public init(repo: String, revision: String = "main", gated: Bool = false) {
            self.repo = repo
            self.revision = revision
            self.gated = gated
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decode(String.self, forKey: .repo)
            revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? "main"
            gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
        }
    }

    /// `shim:`, merged with what the substitutes add into the `LIFT_SHIM` JSON.
    public struct Shim: Codable, Sendable, Equatable {
        public var aliases: [String: String]
        public var standins: [String]
        /// Named `lift_shim` runtime patches, e.g. `transformers_fa2_to_sdpa`.
        public var patches: [String]
        public var env: [String: String]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
            standins = try c.decodeIfPresent([String].self, forKey: .standins) ?? []
            patches = try c.decodeIfPresent([String].self, forKey: .patches) ?? []
            env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        }
    }

    public struct MemoryOverride: Codable, Sendable, Equatable {
        public var when: [String: SettingValue]
        public var memoryGB: Double
        enum CodingKeys: String, CodingKey { case when, memoryGB = "memory_gb" }
    }

    public struct Resources: Codable, Sendable, Equatable {
        public var memoryGB: Double
        public var memoryKeys: [String]
        public var memoryOverrides: [MemoryOverride]
        public var maxConcurrentPerProcess: Int
        public var diskGB: Double

        enum CodingKeys: String, CodingKey {
            case memoryGB = "memory_gb", memoryKeys = "memory_keys", memoryOverrides = "memory_overrides"
            case maxConcurrentPerProcess = "max_concurrent_per_process", diskGB = "disk_gb"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            memoryGB = try c.decode(Double.self, forKey: .memoryGB)
            memoryKeys = try c.decodeIfPresent([String].self, forKey: .memoryKeys) ?? []
            memoryOverrides = try c.decodeIfPresent([MemoryOverride].self, forKey: .memoryOverrides) ?? []
            maxConcurrentPerProcess = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentPerProcess) ?? 1
            diskGB = try c.decodeIfPresent(Double.self, forKey: .diskGB) ?? 5
        }
    }

    public struct StagePattern: Codable, Sendable, Equatable {
        /// Python `re` syntax; named groups `name`, `pct`, or `n` + `total`.
        public var pattern: String
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var publisher: String?
    public var license: String?
    public var homepage: String?
    public var repo: String?
    public var commit: String?
    public var python: String
    public var platform: Platform
    public var install: [String]
    public var substitutes: [String]
    /// Present: install `lift_shim` + its `.pth` and set `LIFT_SHIM` for the worker. Absent: no shim.
    public var shim: Shim?
    /// Native Homebrew packages (e.g. `libusb`); their `lib/` goes on the worker's `DYLD_FALLBACK_LIBRARY_PATH`.
    public var brew: [String]
    public var weights: [Weight]
    /// Developer-only (the Test Cube): hidden unless the `dev_recipes` setting or `LIFT_DEV_RECIPES=1` is on.
    public var developer: Bool
    public var resources: Resources
    public var stages: [StagePattern]
    public var tasks: [RecipeTask]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? "3.11"
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? Platform(status: .supported, reason: nil)
        install = try c.decodeIfPresent([String].self, forKey: .install) ?? []
        substitutes = try c.decodeIfPresent([String].self, forKey: .substitutes) ?? []
        shim = try c.decodeIfPresent(Shim.self, forKey: .shim)
        brew = try c.decodeIfPresent([String].self, forKey: .brew) ?? []
        weights = try c.decodeIfPresent([Weight].self, forKey: .weights) ?? []
        developer = try c.decodeIfPresent(Bool.self, forKey: .developer) ?? false
        resources = try c.decode(Resources.self, forKey: .resources)
        stages = try c.decodeIfPresent([StagePattern].self, forKey: .stages) ?? []
        tasks = try c.decode([RecipeTask].self, forKey: .tasks)
    }

    public func task(_ id: String) -> RecipeTask? { tasks.first { $0.id == id } }
}

/// The outcome of reading one recipe folder.
public enum RecipeLoad: Sendable, Equatable {
    case ok(Recipe)
    case needsNewerLift(id: String, schema: Int)
    case invalid(String)

    /// `matchFolder: false` for a model's installed copy, which lives in `models/<id>/recipe/`.
    public static func read(directory: URL, matchFolder: Bool = true) -> RecipeLoad {
        let file = directory.appending(path: "recipe.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .invalid("cannot read \(file.path)")
        }
        struct Header: Decodable { var schema: Int; var id: String }
        do {
            let header = try YAMLDecoder().decode(Header.self, from: text)
            if header.schema > Recipe.supportedSchema {
                return .needsNewerLift(id: header.id, schema: header.schema)
            }
            let recipe = try YAMLDecoder().decode(Recipe.self, from: text)
            let problems = recipe.problems(folder: directory, matchFolder: matchFolder)
            return problems.isEmpty ? .ok(recipe) : .invalid(problems.joined(separator: "; "))
        } catch {
            return .invalid("recipe.yaml: \(error)")
        }
    }
}
```

`Sources/LiftCore/Recipes/Validation.swift`:
```swift
import Foundation

extension Recipe {
    /// Structural checks beyond decoding. Empty means valid.
    func problems(folder: URL, matchFolder: Bool) -> [String] {
        var out: [String] = []
        if id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) == nil {
            out.append("id must be lowercase letters, digits and dashes")
        }
        if matchFolder && folder.lastPathComponent != id { out.append("id \(id) must match its folder name \(folder.lastPathComponent)") }
        if (repo == nil) != (commit == nil) { out.append("repo and commit go together") }
        if let commit, commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) == nil {
            out.append("commit must be a full 40-character sha")
        }
        if platform.status == .unsupported && (platform.reason ?? "").isEmpty {
            out.append("platform.reason is required when unsupported")
        }
        for w in weights where w.repo.split(separator: "/").count != 2 {
            out.append("weights: \(w.repo) must be owner/name")
        }
        if resources.maxConcurrentPerProcess < 1 { out.append("resources.max_concurrent_per_process must be ≥ 1") }
        if resources.memoryGB <= 0 { out.append("resources.memory_gb must be > 0") }
        if tasks.isEmpty { out.append("at least one task is required") }
        if Set(tasks.map(\.id)).count != tasks.count { out.append("task ids must be unique") }
        let allKeys = Set(tasks.flatMap { $0.settings.map(\.key) })
        for key in resources.memoryKeys where !allKeys.contains(key) {
            out.append("resources.memory_keys: \(key) is not a setting")
        }
        for task in tasks {
            if task.inputs.isEmpty { out.append("task \(task.id): at least one input is required") }
            if Set(task.settings.map(\.key)).count != task.settings.count {
                out.append("task \(task.id): setting keys must be unique")
            }
            for def in task.settings {
                if def.type == .enum && (def.options ?? []).isEmpty {
                    out.append("task \(task.id): \(def.key): enum needs options")
                }
                if let d = def.default, case .failure(let message) = def.check(d) {
                    out.append("task \(task.id): \(def.key): default \(message)")
                }
            }
        }
        if !FileManager.default.fileExists(atPath: folder.appending(path: "launcher.py").path) {
            out.append("launcher.py is missing")
        }
        return out
    }
}

enum Checked { case success(SettingValue), failure(String) }

extension SettingDef {
    /// Type, option and range check; returns the value coerced to the declared type.
    func check(_ value: SettingValue) -> Checked {
        let coerced: SettingValue
        switch (type, value) {
        case (.int, .int): coerced = value
        case (.int, .float(let d)) where d.rounded() == d: coerced = .int(Int(d))
        case (.float, .float): coerced = value
        case (.float, .int(let i)): coerced = .float(Double(i))
        case (.bool, .bool): coerced = value
        case (.string, .string), (.path, .string): coerced = value
        case (.enum, _):
            guard let match = options?.first(where: { $0 == value || ($0.number != nil && $0.number == value.number) }) else {
                return .failure("must be one of \((options ?? []).map(\.description).joined(separator: ", "))")
            }
            coerced = match
        default:
            return .failure("must be \(type.rawValue)")
        }
        if let n = coerced.number {
            if let min, n < min { return .failure("must be ≥ \(min.formatted())") }
            if let max, n > max { return .failure("must be ≤ \(max.formatted())") }
        }
        if type == .path, case .string(let p) = coerced, !FileManager.default.fileExists(atPath: p) {
            return .failure("path does not exist: \(p)")
        }
        return .success(coerced)
    }
}

extension RecipeTask {
    /// Validates request settings and fills defaults. `prefix` names the field path in errors.
    public func validated(settings: [String: SettingValue], prefix: String) throws(LiftError) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        var errors: [FieldError] = []
        let known = Set(self.settings.map(\.key))
        for key in settings.keys.sorted() where !known.contains(key) {
            errors.append(FieldError("\(prefix).\(key)", "unknown setting"))
        }
        for def in self.settings {
            guard let value = settings[def.key] ?? def.default else {
                errors.append(FieldError("\(prefix).\(def.key)", "required"))
                continue
            }
            switch def.check(value) {
            case .success(let v): out[def.key] = v
            case .failure(let message): errors.append(FieldError("\(prefix).\(def.key)", message))
            }
        }
        if !errors.isEmpty { throw .invalidInput(errors) }
        return out
    }

    /// Checks input names and that files exist. A chained step may leave its first input out.
    public func validated(inputs: [String: String], chained: Bool, prefix: String) throws(LiftError) -> [String: String] {
        var errors: [FieldError] = []
        let known = Set(self.inputs.map(\.name))
        for name in inputs.keys.sorted() where !known.contains(name) {
            errors.append(FieldError("\(prefix).\(name)", "unknown input"))
        }
        for (i, input) in self.inputs.enumerated() {
            guard let value = inputs[input.name] else {
                if !(chained && i == 0) { errors.append(FieldError("\(prefix).\(input.name)", "required")) }
                continue
            }
            var isDir: ObjCBool = false
            switch input.type {
            case .text:
                break
            case .imageSet:
                if !FileManager.default.fileExists(atPath: value, isDirectory: &isDir) || !isDir.boolValue {
                    errors.append(FieldError("\(prefix).\(input.name)", "must be an existing folder: \(value)"))
                }
            default:
                if !FileManager.default.fileExists(atPath: value, isDirectory: &isDir) || isDir.boolValue {
                    errors.append(FieldError("\(prefix).\(input.name)", "must be an existing file: \(value)"))
                }
            }
        }
        if !errors.isEmpty { throw .invalidInput(errors) }
        return inputs
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "RecipeTests|ValidationTests"`
Expected: `✔ Test run with 13 tests in 2 suites passed`. A parameterized test counts once.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Recipes Tests/LiftCoreTests/RecipeTests.swift Tests/LiftCoreTests/ValidationTests.swift
git commit -m "feat(core): recipe.yaml schema v1, settings and input validation

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 4: Command runner and toolchain

**Files:**
- Create: `Sources/LiftCore/Toolchain/CommandRunner.swift`, `Sources/LiftCore/Toolchain/Toolchain.swift`
- Test: `Tests/LiftCoreTests/FakeRunner.swift`, `Tests/LiftCoreTests/ToolchainTests.swift`

**Interfaces:**
- Consumes: `LiftError`, `Tail`, `TerminationStatus.code` (Task 1); `Fixtures.tempDir/fakeBin` (Task 1).
- Produces:
  - `struct ShellCommand: Equatable { executable, arguments, environment: [String:String] (overrides on the inherited env), workingDirectory: String? }` with `init(_ executable:, _ arguments: = [], environment: = [:], workingDirectory: = nil)` and `display: String` (for `/bin/sh -c X` it's just `X`; otherwise the executable and arguments joined by spaces).
  - `protocol CommandRunner: Sendable { func run(_: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 }`. Extensions: `check(_:onLine:)` throws `LiftError.commandFailed(command: display, exitCode:, tail: last 40 lines)`, and `output(_:) -> String`.
  - `struct SubprocessRunner: CommandRunner` (swift-subprocess, stdout and stderr merged, line by line).
  - `struct ToolPaths: Codable, Equatable { brew? (native only), git?, uv?, rosettaBrew? }` with `init(brew: = nil, git: = nil, uv: = nil, rosettaBrew: = nil)`; `struct Prereqs: Codable, Equatable { tools: ToolPaths, metalToolchain: Bool? }`.
  - `struct Toolchain(runner:, searchDirs: [String]? = nil, homebrewPrefix: = "/opt/homebrew", rosettaPrefix: = "/usr/local")` with `let homebrewPrefix`. The default search order is `<homebrewPrefix>/bin`, `~/.local/bin`, `~/.cargo/bin`, then `$PATH` minus anything under the Rosetta prefix, then `/usr/bin` and `/bin`, deduplicated.
  - Methods:
    - `find(_:) -> String?`
    - `nativeBrew() async -> String?`: `<prefix>/bin/brew` counts only if `--version` exits 0 and `brew config` shows `HOMEBREW_PREFIX: <prefix>` and `arm64`.
    - `detect() async -> ToolPaths`: every tool must run its `--version`, and `/usr/bin/git` only after `xcode-select -p` succeeds.
    - `environment: ["PATH": searchDirs joined]`
    - `metalToolchainInstalled() async -> Bool`: `/usr/bin/xcrun metal --version` exits 0.
    - `installHomebrew(git:onLine:)`: one `osascript … with administrator privileges` that does `mkdir -p` + `chown -R <user>:admin` on the prefix, then as the user `git -C <prefix>` `init -q`, `config remote.origin.url https://github.com/Homebrew/brew`, `config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*`, `fetch --force --quiet origin`, `checkout --force -B main origin/main`, and finally `<prefix>/bin/brew update --force --quiet`.
    - `brewInstall(_ names:onLine:)`: native brew only, else `.prerequisite`.
    - `installMetalToolchain(onLine:)`: `xcodebuild -downloadComponent MetalToolchain`.
  - Test helpers: `final class FakeRunner: CommandRunner` with `on(_ match: String, code: Int32 = 0, lines: [String] = [])`, `commands`, `displays`; unmatched commands exit 0. `Fixtures.python() async throws -> String` (`uv python find 3.11`).

- [ ] **Step 1: Write the failing tests**

`Tests/LiftCoreTests/FakeRunner.swift`:
```swift
import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// Records commands and answers from a script: the first rule whose `match` is contained in the
/// command's display string decides the exit code and output lines. Unmatched commands succeed silently.
final class FakeRunner: CommandRunner {
    struct Rule: Sendable {
        var match: String
        var code: Int32
        var lines: [String]
    }

    private let state = Mutex<(commands: [ShellCommand], rules: [Rule])>(([], []))

    func on(_ match: String, code: Int32 = 0, lines: [String] = []) {
        state.withLock { $0.rules.append(Rule(match: match, code: code, lines: lines)) }
    }

    var commands: [ShellCommand] { state.withLock { $0.commands } }
    var displays: [String] { commands.map(\.display) }

    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let rule = state.withLock { s -> Rule? in
            s.commands.append(command)
            return s.rules.first { command.display.contains($0.match) }
        }
        for line in rule?.lines ?? [] { onLine(line) }
        return rule?.code ?? 0
    }
}

extension Fixtures {
    /// A uv-managed Python 3.11 (uv downloads it if missing).
    static func python() async throws -> String {
        let uv = try #require(Toolchain(runner: SubprocessRunner()).find("uv"), "uv must be installed")
        return try await SubprocessRunner().output(ShellCommand(uv, ["python", "find", "3.11"])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

`Tests/LiftCoreTests/ToolchainTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

/// Nothing here runs a real install: every command goes to `FakeRunner`, and the Homebrew
/// prefixes are temp folders.
@Suite struct ToolchainTests {
    /// A temp prefix with `bin/brew`.
    func prefix() throws -> String {
        let bin = try Fixtures.fakeBin(["brew"])
        let p = bin.deletingLastPathComponent().appending(path: "prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bin, to: p.appending(path: "bin"))
        return p.path
    }

    func config(_ prefix: String, arch: String = "26.4-arm64") -> [String] {
        ["HOMEBREW_VERSION: 4.6.0", "HOMEBREW_PREFIX: \(prefix)", "macOS: \(arch)"]
    }

    @Test func detectsInSearchOrderAndRequiresWorkingTools() async throws {
        let first = try Fixtures.fakeBin(["git"]), second = try Fixtures.fakeBin(["git", "uv"])
        let runner = FakeRunner()
        runner.on("\(second.path)/uv --version", code: 1)  // present but broken
        let t = Toolchain(runner: runner, searchDirs: [first.path, second.path], homebrewPrefix: "/nonexistent-brew", rosettaPrefix: "/nonexistent-rosetta")
        #expect(await t.detect() == ToolPaths(git: first.path + "/git"))
        #expect(t.environment["PATH"] == "\(first.path):\(second.path)")
    }

    @Test func nonExecutableIsIgnored() throws {
        let dir = try Fixtures.tempDir()
        try "x".write(to: dir.appending(path: "uv"), atomically: true, encoding: .utf8)
        #expect(Toolchain(runner: FakeRunner(), searchDirs: [dir.path]).find("uv") == nil)
    }

    @Test func nativeBrewMustReportItsArm64Prefix() async throws {
        let p = try prefix()
        let good = FakeRunner()
        good.on("brew config", lines: config(p))
        #expect(await Toolchain(runner: good, searchDirs: [], homebrewPrefix: p).nativeBrew() == "\(p)/bin/brew")
        let partial = FakeRunner()
        partial.on("brew --version", code: 127)  // the empty scaffold seen on the dev machine
        #expect(await Toolchain(runner: partial, searchDirs: [], homebrewPrefix: p).nativeBrew() == nil)
        let rosetta = FakeRunner()
        rosetta.on("brew config", lines: config(p, arch: "26.4-x86_64"))
        #expect(await Toolchain(runner: rosetta, searchDirs: [], homebrewPrefix: p).nativeBrew() == nil)
    }

    @Test func rosettaBrewIsReportedNeverUsed() async throws {
        let rosetta = try prefix()
        let runner = FakeRunner()
        let t = Toolchain(runner: runner, searchDirs: [], homebrewPrefix: "/nonexistent-brew", rosettaPrefix: rosetta)
        let tools = await t.detect()
        #expect(tools.rosettaBrew == "\(rosetta)/bin/brew" && tools.brew == nil)
        await #expect(throws: LiftError.self) { try await t.brewInstall(["libusb"], onLine: { _ in }) }
        #expect(!runner.displays.contains { $0.contains("install libusb") })
    }

    @Test func homebrewInstallIsOneAdminDialogThenUserSteps() async throws {
        let runner = FakeRunner()
        let t = Toolchain(runner: runner, searchDirs: ["/usr/bin"], homebrewPrefix: "/opt/homebrew")
        try await t.installHomebrew(git: "/usr/bin/git", onLine: { _ in })
        let d = runner.displays
        #expect(d.count == 7)
        #expect(d[0].hasPrefix("/usr/bin/osascript -e do shell script \"/bin/mkdir -p /opt/homebrew && /usr/sbin/chown -R "))
        #expect(d[0].hasSuffix(":admin /opt/homebrew\" with administrator privileges"))
        #expect(d[1...5] == ["/usr/bin/git -C /opt/homebrew init -q",
                             "/usr/bin/git -C /opt/homebrew config remote.origin.url https://github.com/Homebrew/brew",
                             "/usr/bin/git -C /opt/homebrew config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*",
                             "/usr/bin/git -C /opt/homebrew fetch --force --quiet origin",
                             "/usr/bin/git -C /opt/homebrew checkout --force -B main origin/main"])
        #expect(d[6] == "/opt/homebrew/bin/brew update --force --quiet")
        #expect(!d.contains { $0.contains("rm ") })
    }

    @Test func brewAndMetalInstallsGoThroughTheRunner() async throws {
        let p = try prefix()
        let runner = FakeRunner()
        runner.on("brew config", lines: config(p))
        runner.on("xcrun metal", code: 1)
        let t = Toolchain(runner: runner, searchDirs: [], homebrewPrefix: p)
        #expect(await t.metalToolchainInstalled() == false)
        try await t.brewInstall(["git", "uv"], onLine: { _ in })
        try await t.installMetalToolchain(onLine: { _ in })
        #expect(runner.displays.contains("\(p)/bin/brew install git uv"))
        #expect(runner.displays.last == "/usr/bin/xcodebuild -downloadComponent MetalToolchain")
    }

    @Test func failedCommandCarriesItsTail() async throws {
        let runner = FakeRunner()
        runner.on("boom", code: 2, lines: ["one", "two"])
        await #expect(throws: LiftError.commandFailed(command: "boom", exitCode: 2, tail: ["one", "two"])) {
            try await runner.check(ShellCommand("/bin/sh", ["-c", "boom"]))
        }
    }

    @Test func realRunnerStreamsLinesAndExitCodes() async throws {
        let lines = Tail(limit: 10)
        let code = try await SubprocessRunner().run(ShellCommand("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"]), onLine: { lines.append($0) })
        #expect(code == 3)
        #expect(Set(lines.lines) == ["out", "err"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find type 'CommandRunner' in scope` and `cannot find 'Toolchain' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Toolchain/CommandRunner.swift`:
```swift
import Foundation
import Subprocess
import System

/// One external command. Install steps are `/bin/sh -c <step>`.
public struct ShellCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Overrides on top of the inherited environment.
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// What logs and errors show.
    public var display: String {
        if executable == "/bin/sh", arguments.first == "-c", arguments.count == 2 { return arguments[1] }
        return ([executable] + arguments).joined(separator: " ")
    }
}

/// Runs commands; injectable so tests never install anything.
public protocol CommandRunner: Sendable {
    /// Runs to completion, streaming stdout and stderr merged, line by line. Returns the exit code
    /// (128 + signal when killed).
    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32
}

extension CommandRunner {
    /// Runs and throws `LiftError.commandFailed` with the last 40 lines on a non-zero exit.
    public func check(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let tail = Tail(limit: 40)
        let code = try await run(command) { line in
            tail.append(line)
            onLine(line)
        }
        if code != 0 { throw LiftError.commandFailed(command: command.display, exitCode: code, tail: tail.lines) }
    }

    /// Runs and returns the whole output, or throws on a non-zero exit.
    public func output(_ command: ShellCommand) async throws -> String {
        let all = Tail(limit: .max)
        try await check(command) { all.append($0) }
        return all.lines.joined(separator: "\n")
    }
}

/// The real runner, on swift-subprocess.
public struct SubprocessRunner: CommandRunner {
    public init() {}

    public func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        var overrides: [Environment.Key: String?] = [:]
        for (k, v) in command.environment { overrides[Environment.Key(rawValue: k)!] = v }
        let result = try await Subprocess.run(
            .path(FilePath(command.executable)),
            arguments: Arguments(command.arguments),
            environment: .inherit.updating(overrides),
            workingDirectory: command.workingDirectory.map { FilePath($0) },
            input: .none,
            output: .sequence,
            error: .combinedWithOutput
        ) { execution in
            for try await line in execution.standardOutput.strings(bufferingPolicy: .unbounded) {
                onLine(line)
            }
        }
        return result.terminationStatus.code
    }
}
```

`Sources/LiftCore/Toolchain/Toolchain.swift`:
```swift
import Foundation

/// Absolute paths of the tools Lift drives. `nil` means not found or not working.
public struct ToolPaths: Codable, Sendable, Equatable {
    /// Native arm64 Homebrew, only when `brew --version` and `brew config` both check out.
    public var brew: String?
    public var git: String?
    public var uv: String?
    /// An Intel/Rosetta Homebrew (`/usr/local/bin/brew`). Reported, never used: its libraries are x86_64.
    public var rosettaBrew: String?

    public init(brew: String? = nil, git: String? = nil, uv: String? = nil, rosettaBrew: String? = nil) {
        self.brew = brew
        self.git = git
        self.uv = uv
        self.rosettaBrew = rosettaBrew
    }
}

public struct Prereqs: Codable, Sendable, Equatable {
    public var tools: ToolPaths
    /// Checked only when asked for (a recipe needs it): `nil` means not checked.
    public var metalToolchain: Bool?
}

/// Finds and installs native Homebrew / git / uv / the Metal Toolchain (spec §6).
/// A GUI app's PATH is minimal, so tools are looked up in fixed directories. The Rosetta prefix
/// (`/usr/local`) is never searched: an x86_64 uv would build x86_64 venvs.
public struct Toolchain: Sendable {
    public static let brewRepo = "https://github.com/Homebrew/brew"

    let runner: any CommandRunner
    let searchDirs: [String]
    public let homebrewPrefix: String
    let rosettaPrefix: String

    public init(runner: any CommandRunner, searchDirs: [String]? = nil, homebrewPrefix: String = "/opt/homebrew", rosettaPrefix: String = "/usr/local") {
        self.runner = runner
        self.homebrewPrefix = homebrewPrefix
        self.rosettaPrefix = rosettaPrefix
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { !$0.hasPrefix(rosettaPrefix) }
        var seen = Set<String>()
        self.searchDirs = (searchDirs ?? (["\(homebrewPrefix)/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"] + fromPath + ["/usr/bin", "/bin"]))
            .filter { seen.insert($0).inserted }
    }

    public func find(_ name: String) -> String? {
        searchDirs.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func works(_ executable: String, _ arguments: [String] = ["--version"]) async -> Bool {
        (try? await runner.run(ShellCommand(executable, arguments), onLine: { _ in })) == 0
    }

    /// `<prefix>/bin/brew`, if it runs and `brew config` reports this prefix on arm64.
    /// An empty or partial `/opt/homebrew` counts as missing.
    public func nativeBrew() async -> String? {
        let brew = "\(homebrewPrefix)/bin/brew"
        guard FileManager.default.isExecutableFile(atPath: brew), await works(brew),
              let config = try? await runner.output(ShellCommand(brew, ["config"])),
              config.contains("HOMEBREW_PREFIX: \(homebrewPrefix)"), config.contains("arm64") else { return nil }
        return brew
    }

    /// Each tool counts only if it runs. `/usr/bin/git` is a stub that pops up an installer dialog
    /// without the Command Line Tools, so it's only tried when `xcode-select -p` succeeds.
    public func detect() async -> ToolPaths {
        var git = find("git")
        if git == "/usr/bin/git", !(await works("/usr/bin/xcode-select", ["-p"])) { git = nil }
        if let g = git, !(await works(g)) { git = nil }
        var uv = find("uv")
        if let u = uv, !(await works(u)) { uv = nil }
        let rosetta = "\(rosettaPrefix)/bin/brew"
        return ToolPaths(brew: await nativeBrew(), git: git, uv: uv,
                         rosettaBrew: FileManager.default.isExecutableFile(atPath: rosetta) ? rosetta : nil)
    }

    /// PATH for child processes: the search directories, so `uv` and `git` resolve inside install steps.
    public var environment: [String: String] {
        ["PATH": searchDirs.joined(separator: ":")]
    }

    public func metalToolchainInstalled() async -> Bool {
        await works("/usr/bin/xcrun", ["metal", "--version"])
    }

    /// The GUI-safe native install (spec §6). Homebrew's own installer refuses root and needs a terminal
    /// for sudo, so: one administrator dialog creates the prefix and gives it to the user, then, as the user,
    /// Homebrew `main` is fetched into it (like the official installer: files already there are
    /// overwritten by Homebrew's own, nothing is deleted) and `brew update` runs.
    public func installHomebrew(git: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let p = homebrewPrefix
        let admin = "/bin/mkdir -p \(p) && /usr/sbin/chown -R \(NSUserName()):admin \(p)"
        try await runner.check(ShellCommand("/usr/bin/osascript", ["-e", "do shell script \"\(admin)\" with administrator privileges"]), onLine: onLine)
        for args in [["init", "-q"], ["config", "remote.origin.url", Self.brewRepo],
                     ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
                     ["fetch", "--force", "--quiet", "origin"], ["checkout", "--force", "-B", "main", "origin/main"]] {
            try await runner.check(ShellCommand(git, ["-C", p] + args, environment: environment), onLine: onLine)
        }
        try await runner.check(ShellCommand("\(p)/bin/brew", ["update", "--force", "--quiet"], environment: environment), onLine: onLine)
    }

    /// `brew install <names>` with the native brew only.
    public func brewInstall(_ names: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = await nativeBrew() else { throw LiftError.prerequisite("native Homebrew (\(homebrewPrefix)) is not installed") }
        try await runner.check(ShellCommand(brew, ["install"] + names, environment: environment), onLine: onLine)
    }

    public func installMetalToolchain(onLine: @escaping @Sendable (String) -> Void) async throws {
        try await runner.check(ShellCommand("/usr/bin/xcodebuild", ["-downloadComponent", "MetalToolchain"]), onLine: onLine)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ToolchainTests`
Expected: `✔ Test run with 8 tests in 1 suite passed`. Nothing gets installed: every install and probe goes through `FakeRunner`, and the Homebrew prefixes are temp folders. The one real command is `/bin/sh -c "echo …; exit 3"`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Toolchain Tests/LiftCoreTests/FakeRunner.swift Tests/LiftCoreTests/ToolchainTests.swift
git commit -m "feat(core): injectable command runner; native-Homebrew/git/uv/Metal toolchain

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 5: Scheduler

**Files:**
- Create: `Sources/LiftCore/Scheduler/Scheduler.swift`
- Test: `Tests/LiftCoreTests/SchedulerTests.swift`

**Interfaces:**
- Consumes: `Priority`, `WaitReason` (Task 1).
- Produces:
  - `struct MemoryNeed: Equatable { load: Int, job: Int, newWorker: Int (= load + job) }` (bytes).
  - `enum ModelReadiness { ready, installing, notInstalled, unsupported, weightsUnverified }`. Each non-ready value maps to the wait reason with the same name.
  - `struct Candidate(jobId:recipe:priority: = .normal, position:createdAt: = epoch, forceStart: = false, model: = .ready, need:)`.
  - `struct WorkerSnapshot(recipe:freeCapacity:reserved:)`.
  - `struct SchedulerInput(candidates:workers: = [], runningSteps: = 0, maxSlots: = 1, budget:systemFree:paused: = false)`.
  - `enum Decision: Equatable { start(String), wait(String, WaitReason) }`.
  - `enum Scheduler { static func order(_:_:) -> Bool; static func decide(_: SchedulerInput) -> [Decision] }`. Decisions come back in scheduling order, one per candidate.

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/SchedulerTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct SchedulerTests {
    let gb = 1_000_000_000

    func c(_ id: String, recipe: String = "r", priority: Priority = .normal, position: Double = 1, created: Double = 0,
           force: Bool = false, model: ModelReadiness = .ready, load: Int = 10, job: Int = 2) -> Candidate {
        Candidate(jobId: id, recipe: recipe, priority: priority, position: position, createdAt: Date(timeIntervalSince1970: created),
                  forceStart: force, model: model, need: MemoryNeed(load: load * gb, job: job * gb))
    }

    func run(_ cs: [Candidate], workers: [WorkerSnapshot] = [], running: Int = 0, slots: Int = 1, budget: Int = 48, free: Int = 64, paused: Bool = false) -> [Decision] {
        Scheduler.decide(SchedulerInput(candidates: cs, workers: workers, runningSteps: running, maxSlots: slots,
                                        budget: budget * gb, systemFree: free * gb, paused: paused))
    }

    @Test func oneSlotStartsTheFirst() {
        #expect(run([c("a", position: 1), c("b", position: 2)]) == [.start("a"), .wait("b", .noFreeSlot)])
    }

    @Test func orderIsPriorityThenPositionThenFIFO() {
        let d = run([c("low", priority: .low, position: 0), c("late", position: 2, created: 1), c("early", position: 2, created: 0),
                     c("moved", position: 1), c("high", priority: .high, position: 9)], slots: 5, budget: 100, free: 100)
        #expect(d == [.start("high"), .start("moved"), .start("early"), .start("late"), .start("low")])
    }

    @Test func runningStepsUseSlots() {
        #expect(run([c("a")], running: 1) == [.wait("a", .noFreeSlot)])
    }

    @Test func budgetCountsReservedWorkers() {
        let w = WorkerSnapshot(recipe: "other", freeCapacity: 1, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.wait("a", .memory(needed: 12 * gb, free: 8 * gb))])
    }

    @Test func systemFreeMemoryIsChecked() {
        #expect(run([c("a")], free: 5) == [.wait("a", .memory(needed: 12 * gb, free: 5 * gb))])
    }

    @Test func existingWorkerNeedsOnlyJobMemory() {
        let w = WorkerSnapshot(recipe: "r", freeCapacity: 1, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.start("a")])  // 2 GB fits in 48 − 40
    }

    @Test func busyWorkerMeansANewOne() {
        let w = WorkerSnapshot(recipe: "r", freeCapacity: 0, reserved: 40 * gb)
        #expect(run([c("a")], workers: [w], slots: 2) == [.wait("a", .memory(needed: 12 * gb, free: 8 * gb))])
    }

    @Test func startsDeductResources() {
        #expect(run([c("a", position: 1, load: 20), c("b", position: 2, load: 20), c("c", position: 3, load: 20)], slots: 3)
                == [.start("a"), .start("b"), .wait("c", .memory(needed: 22 * gb, free: 4 * gb))])
    }

    @Test func aWaitingJobDoesNotBlockSmallerOnes() {
        #expect(run([c("big", position: 1, load: 60), c("small", position: 2, load: 1)], slots: 2)
                == [.wait("big", .memory(needed: 62 * gb, free: 48 * gb)), .start("small")])
    }

    @Test func forceStartSkipsMemoryButNotSlots() {
        #expect(run([c("a", force: true, load: 100)]) == [.start("a")])
        #expect(run([c("a", force: true, load: 100)], running: 1) == [.wait("a", .noFreeSlot)])
    }

    @Test func modelStatesAndPause() {
        #expect(run([c("i", model: .installing), c("n", model: .notInstalled), c("u", model: .unsupported), c("w", model: .weightsUnverified)], slots: 4)
                == [.wait("i", .modelInstalling), .wait("n", .modelNotInstalled), .wait("u", .modelUnsupported), .wait("w", .weightsUnverified)])
        #expect(run([c("a", force: true)], paused: true) == [.wait("a", .queuePaused)])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find type 'Candidate' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Scheduler/Scheduler.swift`:
```swift
import Foundation

/// What one step needs, in bytes (spec §8 "Memory estimates").
public struct MemoryNeed: Sendable, Equatable {
    /// Loading the model in a new worker.
    public var load: Int
    /// One job's working memory on top of a loaded model.
    public var job: Int
    public var newWorker: Int { load + job }
}

/// How a candidate's model stands, as far as starting it goes. `weightsUnverified`: installed, but a new
/// worker would be needed and its weights haven't passed verification for that start.
public enum ModelReadiness: Sendable, Equatable {
    case ready, installing, notInstalled, unsupported, weightsUnverified
}

/// A job whose current step could start.
public struct Candidate: Sendable, Equatable {
    public var jobId: String
    public var recipe: String
    public var priority: Priority
    public var position: Double
    public var createdAt: Date
    public var forceStart: Bool
    public var model: ModelReadiness
    public var need: MemoryNeed

    public init(jobId: String, recipe: String, priority: Priority = .normal, position: Double, createdAt: Date = Date(timeIntervalSince1970: 0),
                forceStart: Bool = false, model: ModelReadiness = .ready, need: MemoryNeed) {
        self.jobId = jobId
        self.recipe = recipe
        self.priority = priority
        self.position = position
        self.createdAt = createdAt
        self.forceStart = forceStart
        self.model = model
        self.need = need
    }
}

public struct WorkerSnapshot: Sendable, Equatable {
    public var recipe: String
    /// `max_concurrent_per_process` minus steps on it.
    public var freeCapacity: Int
    /// Bytes this worker holds: max(measured footprint, baseline + running claims).
    public var reserved: Int

    public init(recipe: String, freeCapacity: Int, reserved: Int) {
        self.recipe = recipe
        self.freeCapacity = freeCapacity
        self.reserved = reserved
    }
}

public struct SchedulerInput: Sendable {
    public var candidates: [Candidate]
    public var workers: [WorkerSnapshot]
    public var runningSteps: Int
    public var maxSlots: Int
    public var budget: Int
    public var systemFree: Int
    public var paused: Bool

    public init(candidates: [Candidate], workers: [WorkerSnapshot] = [], runningSteps: Int = 0, maxSlots: Int = 1,
                budget: Int, systemFree: Int, paused: Bool = false) {
        self.candidates = candidates
        self.workers = workers
        self.runningSteps = runningSteps
        self.maxSlots = maxSlots
        self.budget = budget
        self.systemFree = systemFree
        self.paused = paused
    }
}

public enum Decision: Sendable, Equatable {
    case start(String)
    case wait(String, WaitReason)
}

/// Pure start decisions (spec §8). Order: priority, then manual position, then submission time.
/// Each candidate is judged on its own, in order, with resources deducted as starts are decided;
/// one that can't start doesn't hold back the ones after it. No reordering by model warmth.
public enum Scheduler {
    public static func order(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.priority.rank != b.priority.rank { return a.priority.rank > b.priority.rank }
        if a.position != b.position { return a.position < b.position }
        return a.createdAt < b.createdAt
    }

    public static func decide(_ input: SchedulerInput) -> [Decision] {
        var slots = input.maxSlots - input.runningSteps
        var reserved = input.workers.reduce(0) { $0 + $1.reserved }
        var systemFree = input.systemFree
        var capacity = input.workers.map { ($0.recipe, $0.freeCapacity) }
        var out: [Decision] = []
        for c in input.candidates.sorted(by: order) {
            if input.paused { out.append(.wait(c.jobId, .queuePaused)); continue }
            switch c.model {
            case .installing: out.append(.wait(c.jobId, .modelInstalling)); continue
            case .notInstalled: out.append(.wait(c.jobId, .modelNotInstalled)); continue
            case .unsupported: out.append(.wait(c.jobId, .modelUnsupported)); continue
            case .weightsUnverified: out.append(.wait(c.jobId, .weightsUnverified)); continue
            case .ready: break
            }
            guard slots > 0 else { out.append(.wait(c.jobId, .noFreeSlot)); continue }
            let shared = capacity.firstIndex { $0.0 == c.recipe && $0.1 > 0 }
            let needed = shared == nil ? c.need.newWorker : c.need.job
            let budgetFree = input.budget - reserved
            if !c.forceStart && (needed > budgetFree || needed > systemFree) {
                out.append(.wait(c.jobId, .memory(needed: needed, free: max(0, min(budgetFree, systemFree)))))
                continue
            }
            out.append(.start(c.jobId))
            slots -= 1
            reserved += needed
            systemFree -= needed
            if let shared { capacity[shared].1 -= 1 }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SchedulerTests`
Expected: `✔ Test run with 11 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Scheduler Tests/LiftCoreTests/SchedulerTests.swift
git commit -m "feat(core): scheduler — slots, memory budget, system free, priority/position/FIFO

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 6: Memory facts and learned estimates

**Files:**
- Create: `Sources/LiftCore/Resources/Memory.swift`, `Sources/LiftCore/Resources/Estimates.swift`
- Test: `Tests/LiftCoreTests/ResourceTests.swift`

**Interfaces:**
- Consumes: `Recipe`, `RecipeLoad`, `writeRecipe`, `pixalYAML` (Task 3); `MemoryNeed` (Task 5); `Store`, `MemorySampleRecord` (Task 1).
- Produces:
  - `enum Memory { static func footprint(pid: pid_t) -> Int?; @Sendable static func systemFree() -> Int; static var physical: Int }`. `footprint` is `ri_phys_footprint` from `proc_pid_rusage(RUSAGE_INFO_V4)`, and `systemFree` is (free + inactive pages) × page size from `host_statistics64`.
  - `enum Estimates`, with `keyValues(_ recipe:, settings:) -> String` (sorted-key JSON of the `memory_keys` values), `recipeBytes(_:settings:) -> Int` (first matching `memory_overrides` entry, else `memory_gb`, in decimal GB), `learned(_ db:, recipe:, task:, keyValues:, kind:) throws -> Int?` (max of the last 5), `need(_ db:, recipe:, task:, settings:) throws -> MemoryNeed`, and `record(_ db:, recipe:, task:, keyValues:, kind:, bytes:) throws`.

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/ResourceTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct MemoryTests {
    @Test func footprintOfThisProcess() {
        #expect((Memory.footprint(pid: getpid()) ?? 0) > 1_000_000)
        #expect(Memory.footprint(pid: 999_999) == nil)
    }

    @Test func systemFreeIsPlausible() {
        let free = Memory.systemFree()
        #expect(free > 0 && free < Memory.physical)
    }
}

@Suite struct EstimatesTests {
    func recipe() throws -> Recipe {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return r
    }

    @Test func recipeValueAndOverrides() throws {
        let r = try recipe()
        #expect(Estimates.recipeBytes(r, settings: ["low_vram": .bool(false)]) == 18_000_000_000)
        #expect(Estimates.recipeBytes(r, settings: ["low_vram": .bool(true)]) == 12_000_000_000)
    }

    @Test func keyValuesAreCanonical() throws {
        let r = try recipe()
        #expect(Estimates.keyValues(r, settings: ["seed": .int(1), "resolution": .int(1024), "low_vram": .bool(true)])
                == #"{"low_vram":true,"resolution":1024}"#)
    }

    @Test func learnedIsMaxOfLastFive() async throws {
        let store = try Store()
        try await store.db.write { db in
            for bytes in [100, 900, 200, 300, 400, 500, 250] {  // 900 is the 6th newest: dropped
                try Estimates.record(db, recipe: "r", task: "t", keyValues: "{}", kind: .job, bytes: bytes)
            }
        }
        #expect(try await store.db.read { try Estimates.learned($0, recipe: "r", task: "t", keyValues: "{}", kind: .job) } == 500)
        #expect(try await store.db.read { try Estimates.learned($0, recipe: "r", task: "t", keyValues: "{}", kind: .load) } == nil)
    }

    @Test func needFallsBackToTheRecipe() async throws {
        let store = try Store()
        let r = try recipe()
        let s: [String: SettingValue] = ["low_vram": .bool(true), "resolution": .int(1024)]
        let keys = Estimates.keyValues(r, settings: s)
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 12_000_000_000, job: 0))
        try await store.db.write { try Estimates.record($0, recipe: "pixal3d", task: "image_to_3d", keyValues: keys, kind: .load, bytes: 8_000_000_000) }
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 8_000_000_000, job: 4_000_000_000))
        try await store.db.write { try Estimates.record($0, recipe: "pixal3d", task: "image_to_3d", keyValues: keys, kind: .job, bytes: 1_000_000_000) }
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 8_000_000_000, job: 1_000_000_000))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find 'Memory' in scope` and `cannot find 'Estimates' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Resources/Memory.swift`:
```swift
import Darwin
import Foundation

/// Memory facts from the kernel. Bytes throughout.
public enum Memory {
    /// A process's `phys_footprint` (includes unified/GPU memory), via `proc_pid_rusage`.
    public static func footprint(pid: pid_t) -> Int? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) : nil
    }

    /// Free + inactive pages, via `host_statistics64` (spec §8, condition 3).
    @Sendable public static func systemFree() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return (Int(stats.free_count) + Int(stats.inactive_count)) * Int(getpagesize())
    }

    public static var physical: Int { Int(ProcessInfo.processInfo.physicalMemory) }
}
```

`Sources/LiftCore/Resources/Estimates.swift`:
```swift
import Foundation
import GRDB

public enum Estimates {
    static let gb = 1_000_000_000.0

    /// Canonical JSON of the recipe's memory_keys values in these settings, e.g. `{"low_vram":true}`.
    public static func keyValues(_ recipe: Recipe, settings: [String: SettingValue]) -> String {
        let picked = settings.filter { recipe.resources.memoryKeys.contains($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(picked), as: UTF8.self)
    }

    /// `memory_gb`, or the first `memory_overrides` entry whose `when` all match.
    public static func recipeBytes(_ recipe: Recipe, settings: [String: SettingValue]) -> Int {
        let match = recipe.resources.memoryOverrides.first { o in
            o.when.allSatisfy { key, value in
                guard let s = settings[key] else { return false }
                return s == value || (s.number != nil && s.number == value.number)
            }
        }
        return Int((match?.memoryGB ?? recipe.resources.memoryGB) * gb)
    }

    /// Max of the last 5 samples, or nil when there are none.
    public static func learned(_ db: Database, recipe: String, task: String, keyValues: String, kind: MemorySampleRecord.Kind) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT MAX(bytes) FROM (SELECT bytes FROM memorySample
            WHERE recipe = ? AND task = ? AND keyValues = ? AND kind = ? ORDER BY id DESC LIMIT 5)
            """, arguments: [recipe, task, keyValues, kind.rawValue])
    }

    /// Learned values replace the recipe value once a sample exists. Without a job sample, the job part
    /// is the recipe value minus the learned load (0 when nothing is learned, so a new worker needs the recipe value).
    public static func need(_ db: Database, recipe: Recipe, task: String, settings: [String: SettingValue]) throws -> MemoryNeed {
        let keys = keyValues(recipe, settings: settings)
        let total = recipeBytes(recipe, settings: settings)
        let load = try learned(db, recipe: recipe.id, task: task, keyValues: keys, kind: .load)
        let job = try learned(db, recipe: recipe.id, task: task, keyValues: keys, kind: .job)
        return MemoryNeed(load: load ?? total, job: job ?? load.map { max(0, total - $0) } ?? 0)
    }

    public static func record(_ db: Database, recipe: String, task: String, keyValues: String, kind: MemorySampleRecord.Kind, bytes: Int) throws {
        var sample = MemorySampleRecord(id: nil, recipe: recipe, task: task, keyValues: keyValues, kind: kind, bytes: bytes, at: Date())
        try sample.insert(db)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "MemoryTests|EstimatesTests"`
Expected: `✔ Test run with 6 tests in 2 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Resources Tests/LiftCoreTests/ResourceTests.swift
git commit -m "feat(core): phys_footprint, host free memory and learned estimates

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 7: Worker protocol and worker process (Swift side)

**Files:**
- Create: `Sources/LiftCore/Workers/WorkerProtocol.swift`, `Sources/LiftCore/Workers/WorkerProcess.swift`
- Test: `Tests/LiftCoreTests/WorkerProtocolTests.swift`, `Tests/LiftCoreTests/WorkerProcessTests.swift`

**Interfaces:**
- Consumes: `SettingValue`, `TerminationStatus.code` (Task 1); the `lift_worker` CLI and `tests/fixtures/launcher.py` (Task 2); `Fixtures.python()` (Task 4).
- Produces:
  - `enum WorkerOp: Equatable { run(job:step:task:inputs:settings:outDir:), cancel(job:), shutdown }` with `line: String` (sorted-key JSON, unescaped slashes, `\n` at the end; `outDir` → `out_dir`).
  - `enum WorkerEvent: Equatable { started(pid: Int32), ready(protocol: Int, loadSeconds: Double), log(job:line:), stage(job:name:fraction: Double?), done(job:outputs:), error(job: String?, message:, traceback: String?), heartbeat(mpsAllocated: Int), stderr(String), malformed(String), exited(Int32) }` with `static func decode(_ line: String) -> WorkerEvent`.
  - `final class WorkerProcess: Sendable` with `init(executable:arguments:environment:workingDirectory:)` (starts it immediately), `events: AsyncStream<WorkerEvent>` (consume it once; it finishes after `.exited`), `send(_ op: WorkerOp)` and `kill()` (SIGKILL by pid; cancels the task if the process hasn't started yet).

- [ ] **Step 1: Write the failing tests**

`Tests/LiftCoreTests/WorkerProtocolTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct WorkerProtocolTests {
    @Test func encodesOps() {
        let run = WorkerOp.run(job: "j", step: 1, task: "image_to_3d", inputs: ["image": "/in/a.png"], settings: ["size": .float(2)], outDir: "/out")
        #expect(run.line == #"{"inputs":{"image":"/in/a.png"},"job":"j","op":"run","out_dir":"/out","settings":{"size":2},"step":1,"task":"image_to_3d"}"# + "\n")
        #expect(WorkerOp.cancel(job: "j").line == #"{"job":"j","op":"cancel"}"# + "\n")
        #expect(WorkerOp.shutdown.line == #"{"op":"shutdown"}"# + "\n")
    }

    @Test(arguments: [
        (#"{"ev":"ready","protocol":1,"load_seconds":2.5}"#, WorkerEvent.ready(protocol: 1, loadSeconds: 2.5)),
        (#"{"ev":"log","job":"j","line":"hi"}"#, .log(job: "j", line: "hi")),
        (#"{"ev":"stage","job":"j","name":"Sampling","fraction":0.5}"#, .stage(job: "j", name: "Sampling", fraction: 0.5)),
        (#"{"ev":"stage","job":"j","name":"Load","fraction":null}"#, .stage(job: "j", name: "Load", fraction: nil)),
        (#"{"ev":"done","job":"j","outputs":["/o.glb"]}"#, .done(job: "j", outputs: ["/o.glb"])),
        (#"{"ev":"error","job":"j","message":"boom","traceback":"tb"}"#, .error(job: "j", message: "boom", traceback: "tb")),
        (#"{"ev":"error","job":null,"message":"load failed"}"#, .error(job: nil, message: "load failed", traceback: nil)),
        (#"{"ev":"heartbeat","mps_allocated":123}"#, .heartbeat(mpsAllocated: 123)),
        (#"{"ev":"mystery"}"#, .malformed(#"{"ev":"mystery"}"#)),
        ("not json", .malformed("not json")),
        (#"{"ev":"log","job":"j"}"#, .malformed(#"{"ev":"log","job":"j"}"#)),
    ])
    func decodesEvents(line: String, expected: WorkerEvent) {
        #expect(WorkerEvent.decode(line) == expected)
    }
}
```

`Tests/LiftCoreTests/WorkerProcessTests.swift`:
```swift
import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// Consumes a worker's events once and lets a test wait for one.
final class EventRecorder: Sendable {
    private let seen = Mutex<[WorkerEvent]>([])

    init(_ w: WorkerProcess) {
        Task { [self] in
            for await e in w.events { self.seen.withLock { $0.append(e) } }
        }
    }

    var events: [WorkerEvent] { seen.withLock { $0 } }

    /// Waits up to 20 s for an event matching ; returns everything seen so far.
    func wait(for match: (WorkerEvent) -> Bool) async throws -> [WorkerEvent] {
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            let now = events
            if now.contains(where: match) { return now }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out; saw \(events)")
        throw CancellationError()
    }
}

func isReady(_ e: WorkerEvent) -> Bool { if case .ready = e { true } else { false } }
func isDone(_ e: WorkerEvent) -> Bool { if case .done = e { true } else { false } }
func isExited(_ e: WorkerEvent) -> Bool { if case .exited = e { true } else { false } }

@Suite struct WorkerProcessTests {
    func launch(_ dir: URL, maxConcurrent: Int = 1) async throws -> WorkerProcess {
        let config = #"{"launcher":"\#(Fixtures.fixtureLauncher.path)","repo_dir":"\#(dir.path)","recipe_dir":"\#(dir.path)","max_concurrent":\#(maxConcurrent),"stages":[],"heartbeat_seconds":0.2}"#
        return WorkerProcess(executable: try await Fixtures.python(), arguments: ["-u", "-m", "lift_worker", config],
                             environment: ["PYTHONPATH": Fixtures.workerRuntime.path], workingDirectory: dir.path)
    }

    @Test func runsAJobAndReportsEverything() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        let start = try await r.wait(for: isReady)
        #expect(start.contains { if case .started(let pid) = $0 { pid > 0 } else { false } })
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: [:], outDir: dir.appending(path: "out").path))
        let evs = try await r.wait(for: isDone)
        #expect(evs.contains(.stderr("native noise at load")))
        #expect(evs.contains(.stderr("native noise in job")))  // native output never reaches the protocol
        #expect(evs.contains(.log(job: "j1", line: "start j1")))
        #expect(evs.contains(.done(job: "j1", outputs: [dir.appending(path: "out/out.txt").path])))
        #expect(!evs.contains { if case .malformed = $0 { true } else { false } })
        w.send(.shutdown)
        #expect(try await r.wait(for: isExited).last == .exited(0))
    }

    @Test func killStopsABusyWorker() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        _ = try await r.wait(for: isReady)
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: ["sleep": .int(60)], outDir: dir.path))
        _ = try await r.wait { $0 == .log(job: "j1", line: "start j1") }
        let t0 = ContinuousClock.now
        w.kill()
        #expect(try await r.wait(for: isExited).last == .exited(128 + SIGKILL))
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func crashReportsExitCode() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        _ = try await r.wait(for: isReady)
        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: ["crash": .bool(true)], outDir: dir.path))
        #expect(try await r.wait(for: isExited).last == .exited(7))
    }

    @Test func heartbeatsArrive() async throws {
        let dir = try Fixtures.tempDir()
        let w = try await launch(dir)
        let r = EventRecorder(w)
        let evs = try await r.wait { if case .heartbeat = $0 { true } else { false } }
        #expect(evs.contains(.heartbeat(mpsAllocated: 0)))
        w.kill()
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find type 'WorkerEvent' in scope` and `cannot find 'WorkerProcess' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Workers/WorkerProtocol.swift`:
```swift
import Foundation

/// App → worker messages (protocol v1, spec §8).
public enum WorkerOp: Sendable, Equatable {
    case run(job: String, step: Int, task: String, inputs: [String: String], settings: [String: SettingValue], outDir: String)
    case cancel(job: String)
    case shutdown

    /// One JSON line, newline included.
    public var line: String {
        var object: [String: AnyEncodable] = [:]
        switch self {
        case .run(let job, let step, let task, let inputs, let settings, let outDir):
            object = ["op": .init("run"), "job": .init(job), "step": .init(step), "task": .init(task),
                      "inputs": .init(inputs), "settings": .init(settings), "out_dir": .init(outDir)]
        case .cancel(let job):
            object = ["op": .init("cancel"), "job": .init(job)]
        case .shutdown:
            object = ["op": .init("shutdown")]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(object), as: UTF8.self) + "\n"
    }
}

struct AnyEncodable: Encodable {
    let value: any Encodable & Sendable
    init(_ value: any Encodable & Sendable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

/// Worker → app messages, plus what the process itself does (start, stderr lines, exit).
public enum WorkerEvent: Sendable, Equatable {
    case started(pid: Int32)
    case ready(protocol: Int, loadSeconds: Double)
    case log(job: String, line: String)
    case stage(job: String, name: String, fraction: Double?)
    case done(job: String, outputs: [String])
    /// `job == nil`: the launcher failed to load; the worker exits.
    case error(job: String?, message: String, traceback: String?)
    case heartbeat(mpsAllocated: Int)
    case stderr(String)
    /// A protocol line that isn't valid JSON or isn't a known event.
    case malformed(String)
    case exited(Int32)

    public static func decode(_ line: String) -> WorkerEvent {
        struct Raw: Decodable {
            var ev: String
            var `protocol`: Int?
            var load_seconds: Double?
            var job: String?
            var line: String?
            var name: String?
            var fraction: Double?
            var outputs: [String]?
            var message: String?
            var traceback: String?
            var mps_allocated: Int?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else { return .malformed(line) }
        switch raw.ev {
        case "ready": return .ready(protocol: raw.protocol ?? 0, loadSeconds: raw.load_seconds ?? 0)
        case "log": if let j = raw.job, let l = raw.line { return .log(job: j, line: l) }
        case "stage": if let j = raw.job, let n = raw.name { return .stage(job: j, name: n, fraction: raw.fraction) }
        case "done": if let j = raw.job { return .done(job: j, outputs: raw.outputs ?? []) }
        case "error": return .error(job: raw.job, message: raw.message ?? "unknown error", traceback: raw.traceback)
        case "heartbeat": return .heartbeat(mpsAllocated: raw.mps_allocated ?? 0)
        default: break
        }
        return .malformed(line)
    }
}
```

`Sources/LiftCore/Workers/WorkerProcess.swift`. A long-lived worker is a `Task` that runs the swift-subprocess body for the life of the process. Ops reach stdin through an `AsyncStream`, and everything that comes out is yielded into `events`. Cancelling that task isn't enough to stop a busy worker: on cancel the stdin writer finishes, which only *asks* the worker to exit. That's why `kill()` signals the pid.
```swift
import Foundation
import Subprocess
import Synchronization
import System

/// One running `python -m lift_worker` process. Ops go in through `send`; everything that comes out
/// (`.started(pid)`, protocol events, stderr lines, `.exited`) arrives on `events`, which finishes after `.exited`.
public final class WorkerProcess: Sendable {
    public let events: AsyncStream<WorkerEvent>
    private let ops: AsyncStream<String>.Continuation
    private let task: Task<Void, Never>
    private let pid = PID()

    private final class PID: Sendable {
        let value = Mutex<pid_t>(0)
    }

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        let (events, eventsOut) = AsyncStream.makeStream(of: WorkerEvent.self)
        let (opsIn, ops) = AsyncStream.makeStream(of: String.self)
        self.events = events
        self.ops = ops
        var overrides: [Environment.Key: String?] = [:]
        for (k, v) in environment { overrides[Environment.Key(rawValue: k)!] = v }
        let env = Environment.inherit.updating(overrides)
        let pid = self.pid
        task = Task {
            var code: Int32
            do {
                let result = try await Subprocess.run(
                    .path(FilePath(executable)),
                    arguments: Arguments(arguments),
                    environment: env,
                    workingDirectory: workingDirectory.map { FilePath($0) },
                    input: .inputWriter,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    pid.value.withLock { $0 = execution.processIdentifier.value }
                    eventsOut.yield(.started(pid: execution.processIdentifier.value))
                    async let stderr: Void = {
                        for try await line in execution.standardError.strings(bufferingPolicy: .unbounded) {
                            eventsOut.yield(.stderr(line))
                        }
                    }()
                    async let writer: Void = {
                        for await line in opsIn {
                            _ = try await execution.standardInputWriter.write(line)
                        }
                        try await execution.standardInputWriter.finish()
                    }()
                    for try await line in execution.standardOutput.strings(bufferingPolicy: .unbounded) {
                        eventsOut.yield(WorkerEvent.decode(line))
                    }
                    ops.finish()  // stdout closed: the process is going away
                    try? await writer
                    try? await stderr
                }
                code = result.terminationStatus.code
            } catch {
                code = 128 + SIGKILL  // cancelled before start: swift-subprocess tears it down with SIGKILL
            }
            pid.value.withLock { $0 = 0 }  // never signal a reused pid
            eventsOut.yield(.exited(code))
            eventsOut.finish()
        }
    }

    public func send(_ op: WorkerOp) {
        ops.yield(op.line)
    }

    /// Stops the process now with SIGKILL, even if it is stuck in native code.
    public func kill() {
        let p = pid.value.withLock { $0 }
        if p > 0 { Darwin.kill(p, SIGKILL) } else { task.cancel() }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "WorkerProtocolTests|WorkerProcessTests"`
Expected: `✔ Test run with 6 tests in 2 suites passed`. The first run may take a few seconds while uv provides Python 3.11.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Workers Tests/LiftCoreTests/WorkerProtocolTests.swift Tests/LiftCoreTests/WorkerProcessTests.swift
git commit -m "feat(core): worker protocol v1 codec and lift_worker process wrapper

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 8: Weights verifier

**Files:**
- Create: `Sources/LiftCore/Weights/Weights.swift`
- Test: `Tests/LiftCoreTests/WeightsTests.swift`

**Interfaces:**
- Consumes: `Store` and its `weightHash` / `weightCheck` tables (Task 1); `Recipe`, `Recipe.Weight`, `writeRecipe`, `pixalYAML` (Task 3).
- Produces:
  - `struct RemoteFile(path:size:sha256: = nil)` and `struct RepoSnapshot(repo:revision:commit:files:)`, both `Codable, Equatable`.
  - `enum WeightsMetadataError: Error, Equatable { offline, http(status: Int, repo: String) }`; `protocol WeightsMetadata: Sendable { func snapshot(repo: String, revision: String) async throws -> RepoSnapshot }`.
  - `struct HFHubAPI(endpoint: = https://huggingface.co, token:) : WeightsMetadata` (`GET /api/models/<repo>/revision/<rev>?blobs=true`; `URLError` → `.offline`, non-200 → `.http`), plus `static var defaultCache: URL` (`$HF_HUB_CACHE`, `$HF_HOME/hub`, `$XDG_CACHE_HOME/huggingface/hub`, `~/.cache/huggingface/hub`). The tests never call it.
  - `struct WeightProblem: Codable, Equatable { repo, path, issue: .missing | .wrongSize | .wrongHash, detail: String? }`.
  - `struct WeightsReport: Codable, Equatable { state: .ok | .missing | .corrupt | .unknown, problems, checkedAt, hashedFiles: Int, metadataFrom: Date?, note: String? }`.
  - `WeightHashRecord` and `WeightCheckRecord` (GRDB records for the Task 1 tables).
  - `struct WeightsVerifier(metadata:hub:store:)` with `snapshotDir(repo:commit:) -> URL`, `totalBytes(_ recipe) async -> Int?` and `verify(_ recipe) async throws -> WeightsReport`. It only reads the cache.
  - Test helpers: `final class FakeMetadata: WeightsMetadata` with `set(_ repo:, revision: = "main", _ answer: Result<RepoSnapshot, WeightsMetadataError>)` (unknown repos answer 404); `writeHFCache(hub:repo:commit:files: [String: Data], lfs: Set<String>) throws -> RepoSnapshot`, which lays out `blobs/<sha>` plus `snapshots/<commit>/<path>` symlinks the way `hf download` does; `sha256Hex(_ data:) -> String`.

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/WeightsTests.swift`:
```swift
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// File lists by `repo@revision`; `nil` value = offline. Never touches the network.
final class FakeMetadata: WeightsMetadata {
    private let answers = Mutex<[String: Result<RepoSnapshot, WeightsMetadataError>]>([:])

    func set(_ repo: String, revision: String = "main", _ answer: Result<RepoSnapshot, WeightsMetadataError>) {
        answers.withLock { $0["\(repo)@\(revision)"] = answer }
    }

    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot {
        guard let a = answers.withLock({ $0["\(repo)@\(revision)"] }) else { throw WeightsMetadataError.http(status: 404, repo: repo) }
        return try a.get()
    }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Writes files the way `hf download` lays them out: `blobs/<sha>` plus `snapshots/<commit>/<path>` symlinks.
/// Returns the snapshot the API would report.
@discardableResult
func writeHFCache(hub: URL, repo: String, commit: String, files: [String: Data], lfs: Set<String>) throws -> RepoSnapshot {
    let root = hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
    var remote: [RemoteFile] = []
    for (path, data) in files.sorted(by: { $0.key < $1.key }) {
        let sha = sha256Hex(data)
        let blob = root.appending(path: "blobs/\(sha)")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: blob)
        let link = root.appending(path: "snapshots/\(commit)/\(path)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        remote.append(RemoteFile(path: path, size: data.count, sha256: lfs.contains(path) ? sha : nil))
    }
    return RepoSnapshot(repo: repo, revision: "main", commit: commit, files: remote)
}

@Suite struct WeightsTests {
    let commit = String(repeating: "c", count: 40)

    func recipe(_ weights: [Recipe.Weight] = [Recipe.Weight(repo: "org/model")]) throws -> Recipe {
        guard case .ok(var r) = RecipeLoad.read(directory: try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())) else {
            throw LiftError.invalidState("fixture")
        }
        r.weights = weights
        return r
    }

    func setup() throws -> (FakeMetadata, URL, WeightsVerifier) {
        let meta = FakeMetadata(), hub = try Fixtures.tempDir()
        return (meta, hub, WeightsVerifier(metadata: meta, hub: hub, store: try Store()))
    }

    @Test func completeCacheVerifiesAndHashesAreCached() async throws {
        let (meta, hub, v) = try setup()
        let snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit,
                                    files: ["model.safetensors": Data(repeating: 7, count: 4096), "config.json": Data("{}".utf8)], lfs: ["model.safetensors"])
        meta.set("org/model", .success(snap))
        let first = try await v.verify(try recipe())
        #expect(first.state == .ok && first.problems.isEmpty && first.hashedFiles == 1)
        #expect(try await v.verify(try recipe()).hashedFiles == 0)  // size + mtime unchanged: cached hash
        #expect(await v.totalBytes(try recipe()) == 4098)
    }

    @Test func missingFileIsListed() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1])], lfs: [])
        snap.files.append(RemoteFile(path: "sub/b.bin", size: 9, sha256: String(repeating: "0", count: 64)))
        meta.set("org/model", .success(snap))
        let r = try await v.verify(try recipe())
        #expect(r.state == .missing)
        #expect(r.problems == [WeightProblem(repo: "org/model", path: "sub/b.bin", issue: .missing)])
    }

    @Test func revisionNotDownloadedMeansAllMissing() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .success(RepoSnapshot(repo: "org/model", revision: "main", commit: commit, files: [RemoteFile(path: "a", size: 1), RemoteFile(path: "b", size: 2)])))
        #expect(try await v.verify(try recipe()).problems.map(\.path) == ["a", "b"])
    }

    @Test func wrongSizeAndWrongHashAreCorrupt() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit,
                                    files: ["big.bin": Data(repeating: 1, count: 100), "w.safetensors": Data(repeating: 2, count: 50)], lfs: ["w.safetensors"])
        snap.files[0].size = 101
        snap.files[1].sha256 = String(repeating: "f", count: 64)
        meta.set("org/model", .success(snap))
        let r = try await v.verify(try recipe())
        #expect(r.state == .corrupt)
        #expect(r.problems.map(\.issue) == [.wrongSize, .wrongHash])
    }

    @Test func revisionsAreRespected() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a": Data([1])], lfs: [])
        snap.revision = "v2"
        meta.set("org/model", revision: "v2", .success(snap))
        #expect(try await v.verify(try recipe([Recipe.Weight(repo: "org/model", revision: "v2")])).state == .ok)
        #expect(try await v.verify(try recipe()).state == .unknown)  // main isn't known to the fake: 404
    }

    @Test func offlineFallsBackToTheLastGoodCheck() async throws {
        let (meta, hub, v) = try setup()
        let snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1, 2])], lfs: ["a.bin"])
        meta.set("org/model", .success(snap))
        #expect(try await v.verify(try recipe()).state == .ok)
        meta.set("org/model", .failure(.offline))
        let offline = try await v.verify(try recipe())
        #expect(offline.state == .ok && offline.metadataFrom != nil && offline.note?.contains("offline") == true)
    }

    @Test func offlineWithoutAGoodCheckIsUnknown() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .failure(.offline))
        let r = try await v.verify(try recipe())
        #expect(r.state == .unknown && r.metadataFrom == nil)
    }

    @Test func gatedRefusalSaysSo() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .failure(.http(status: 401, repo: "org/model")))
        #expect(try await v.verify(try recipe()).note?.contains("gated") == true)
    }

    @Test func noWeightsIsOK() async throws {
        let (_, _, v) = try setup()
        #expect(try await v.verify(try recipe([])).state == .ok)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find type 'WeightsMetadata' in scope` and `cannot find 'WeightsVerifier' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Weights/Weights.swift`:
```swift
import CryptoKit
import Foundation
import GRDB

/// One file of a Hugging Face repo at a commit. `sha256` is set for LFS files.
public struct RemoteFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int
    public var sha256: String?

    public init(path: String, size: Int, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// A repo's file list at a revision, as the Hugging Face API reports it.
public struct RepoSnapshot: Codable, Sendable, Equatable {
    public var repo: String
    public var revision: String
    /// The commit the revision resolves to; the local cache keeps files under `snapshots/<commit>/`.
    public var commit: String
    public var files: [RemoteFile]

    public init(repo: String, revision: String, commit: String, files: [RemoteFile]) {
        self.repo = repo
        self.revision = revision
        self.commit = commit
        self.files = files
    }
}

public enum WeightsMetadataError: Error, Sendable, Equatable {
    /// No network (or Hugging Face unreachable): verification may fall back to the last good check.
    case offline
    case http(status: Int, repo: String)
}

/// Where file lists come from. Tests inject a fake; nothing in the test suite talks to Hugging Face.
public protocol WeightsMetadata: Sendable {
    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot
}

/// `GET /api/models/<repo>/revision/<revision>?blobs=true`: commit sha, file sizes and LFS SHA-256.
public struct HFHubAPI: WeightsMetadata {
    let endpoint: URL
    let token: @Sendable () -> String?

    public init(endpoint: URL = URL(string: "https://huggingface.co")!, token: @escaping @Sendable () -> String?) {
        self.endpoint = endpoint
        self.token = token
    }

    public func snapshot(repo: String, revision: String) async throws -> RepoSnapshot {
        let rev = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? revision
        var request = URLRequest(url: URL(string: "\(endpoint.absoluteString)/api/models/\(repo)/revision/\(rev)?blobs=true")!)
        if let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch is URLError { throw WeightsMetadataError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WeightsMetadataError.http(status: status, repo: repo) }
        struct Info: Decodable {
            struct Sibling: Decodable {
                struct LFS: Decodable { var sha256: String; var size: Int }
                var rfilename: String
                var size: Int?
                var lfs: LFS?
            }
            var sha: String
            var siblings: [Sibling]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return RepoSnapshot(repo: repo, revision: revision, commit: info.sha, files: info.siblings.map {
            RemoteFile(path: $0.rfilename, size: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.sha256)
        })
    }

    /// The shared cache `hf download` writes to: `$HF_HUB_CACHE`, `$HF_HOME/hub`, `$XDG_CACHE_HOME/huggingface/hub`
    /// or `~/.cache/huggingface/hub`.
    public static var defaultCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["HF_HUB_CACHE"] { return URL(filePath: v) }
        if let v = env["HF_HOME"] { return URL(filePath: v).appending(path: "hub") }
        if let v = env["XDG_CACHE_HOME"] { return URL(filePath: v).appending(path: "huggingface/hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }
}

public struct WeightProblem: Codable, Sendable, Equatable {
    public enum Issue: String, Codable, Sendable { case missing, wrongSize = "wrong_size", wrongHash = "wrong_hash" }
    public var repo: String
    public var path: String
    public var issue: Issue
    public var detail: String?
}

public struct WeightsReport: Codable, Sendable, Equatable {
    /// `unknown`: couldn't be checked (offline and never verified, or Hugging Face refused).
    public enum State: String, Codable, Sendable { case ok, missing, corrupt, unknown }
    public var state: State
    public var problems: [WeightProblem]
    public var checkedAt: Date
    /// Files hashed in this run; cached hashes are reused while size and mtime are unchanged.
    public var hashedFiles: Int
    /// Set when Lift was offline and checked against the file lists of the last good check, made at this time.
    public var metadataFrom: Date?
    public var note: String?
}

/// A cached SHA-256 of one weight file, valid while its size and mtime are unchanged.
public struct WeightHashRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "weightHash"
    /// Resolved path of the blob in the Hugging Face cache.
    public var path: String
    public var size: Int
    public var mtime: Double
    public var sha256: String
}

/// The last successful verification of a recipe's weights, kept so an offline check can reuse its file lists.
public struct WeightCheckRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "weightCheck"
    public var recipe: String
    public var at: Date
    public var snapshots: [RepoSnapshot]
}

/// Checks a recipe's weights in the local Hugging Face cache (spec §6): every file present at the
/// revision's commit, sizes equal, LFS files hashed. Read-only on the cache.
public struct WeightsVerifier: Sendable {
    let metadata: any WeightsMetadata
    let hub: URL
    let store: Store

    public init(metadata: any WeightsMetadata, hub: URL, store: Store) {
        self.metadata = metadata
        self.hub = hub
        self.store = store
    }

    /// `models--org--name/snapshots/<commit>` for a repo.
    public func snapshotDir(repo: String, commit: String) -> URL {
        hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--")).appending(path: "snapshots/\(commit)")
    }

    /// Total bytes of the recipe's weights, or nil when the file lists can't be fetched.
    public func totalBytes(_ recipe: Recipe) async -> Int? {
        var total = 0
        for w in recipe.weights {
            guard let s = try? await metadata.snapshot(repo: w.repo, revision: w.revision) else { return nil }
            total += s.files.reduce(0) { $0 + $1.size }
        }
        return total
    }

    public func verify(_ recipe: Recipe) async throws -> WeightsReport {
        let now = Date()
        var report = WeightsReport(state: .ok, problems: [], checkedAt: now, hashedFiles: 0)
        guard !recipe.weights.isEmpty else { return report }
        var snapshots: [RepoSnapshot] = []
        do {
            for w in recipe.weights { snapshots.append(try await metadata.snapshot(repo: w.repo, revision: w.revision)) }
        } catch WeightsMetadataError.offline {
            let wanted = Set(recipe.weights.map { "\($0.repo)@\($0.revision)" })
            guard let last = try await store.db.read({ try WeightCheckRecord.fetchOne($0, key: recipe.id) }),
                  Set(last.snapshots.map { "\($0.repo)@\($0.revision)" }) == wanted else {
                report.state = .unknown
                report.note = "offline, and these weights have never been verified"
                return report
            }
            snapshots = last.snapshots
            report.metadataFrom = last.at
            report.note = "offline: checked against the file lists from the last good check"
        } catch WeightsMetadataError.http(let status, let repo) {
            report.state = .unknown
            report.note = "Hugging Face answered \(status) for \(repo)" + ([401, 403].contains(status) ? " (gated: needs a token with access)" : "")
            return report
        }

        for s in snapshots {
            let dir = snapshotDir(repo: s.repo, commit: s.commit)
            for f in s.files {
                let url = dir.appending(path: f.path).resolvingSymlinksInPath()
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .missing))
                    continue
                }
                let size = (attrs[.size] as? Int) ?? -1
                guard size == f.size else {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .wrongSize, detail: "\(size) bytes, expected \(f.size)"))
                    continue
                }
                guard let expected = f.sha256 else { continue }
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let cached = try await store.db.read { try WeightHashRecord.fetchOne($0, key: url.path) }
                var sha = cached.flatMap { $0.size == size && $0.mtime == mtime ? $0.sha256 : nil }
                if sha == nil {
                    let computed = try Self.sha256(url)
                    report.hashedFiles += 1
                    try await store.db.write { try WeightHashRecord(path: url.path, size: size, mtime: mtime, sha256: computed).save($0) }
                    sha = computed
                }
                if sha != expected {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .wrongHash, detail: "sha256 \(sha!), expected \(expected)"))
                }
            }
        }
        if report.problems.contains(where: { $0.issue == .missing }) { report.state = .missing }
        else if !report.problems.isEmpty { report.state = .corrupt }
        if report.state == .ok && report.metadataFrom == nil {
            let record = WeightCheckRecord(recipe: recipe.id, at: now, snapshots: snapshots)
            try await store.db.write { try record.save($0) }
        }
        return report
    }

    /// Streams the file through SHA-256 in 8 MB chunks.
    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hash = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WeightsTests`
Expected: `✔ Test run with 9 tests in 1 suite passed`. Everything happens in temp folders, with no network.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Weights Tests/LiftCoreTests/WeightsTests.swift
git commit -m "feat(core): weights verifier — HF file lists, cache presence/size/LFS sha256, hash cache, offline fallback

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 9: Recipe catalog, bundled recipes, substitutes and the Test Cube recipe

**Files:**
- Create: `Sources/LiftCore/Recipes/Catalog.swift`, `Sources/LiftCore/Recipes/Bundled.swift`
- Create: `dev-recipes/test-cube/recipe.yaml`, `dev-recipes/test-cube/launcher.py`, `dev-recipes/shared/substitutes.yaml`
- Test: `Tests/LiftCoreTests/CatalogTests.swift`, `Tests/LiftCoreTests/BundledTests.swift`

**Interfaces:**
- Consumes: `Recipe`, `RecipeLoad` (Task 3); `CommandRunner`, `ShellCommand` (Task 4); the launcher contract (Task 2); `writeRecipe`, `FakeRunner` (Tasks 3 and 4).
- Produces:
  - `struct CatalogEntry: Equatable { recipe, source: String, directory: URL, shared: URL }`.
  - `enum CatalogProblem: Codable, Equatable { invalid(source:folder:message:), needsNewerLift(source:id:schema:), duplicate(id:kept:ignored:) }`.
  - `struct RecipeSourceDir(name:dir:shared: URL? = nil)`, where `shared` defaults to `dir/shared`.
  - `struct Catalog { entries: [String: CatalogEntry], problems: [CatalogProblem], static func scan(_ sources: [RecipeSourceDir], includeDeveloper: Bool = false) -> Catalog }`. Sources are scanned in order and the first one wins. `shared/` is skipped, and `developer: true` recipes are hidden unless `includeDeveloper`.
  - `struct Substitute: Codable { install: [String], alias: String?, standin: String?, patches: [String] }` and `static func registry(shared: URL) throws -> [String: Substitute]` (empty if the file is missing).
  - `struct ShimConfig: Codable, Equatable { aliases, standins, patches, env }` with `static func build(_ recipe: Recipe, registry:) throws(LiftError) -> ShimConfig?`. It returns nil without `shim:`. It throws `.prerequisite` for an unknown substitute, or for a substitute that needs the shim when there's no `shim:`. Also `json: String` (sorted keys).
  - `struct BundledRecipes(bundle:recipes:)` with `copyDir` (`recipes/bundled`), `localDir` (`recipes/bundled-local`), `sync() throws -> Result` and `struct Result: Codable, Equatable { copied: Bool, keptLocal: [String] }`, plus `static ignored: Set<String>`. See decision 4 at the top of this plan. The bundle itself is only read.
  - `struct RecipeSources(runner:root:git:environment:)` with `directory(_:)`, `static name(for url:, taken:) -> String`, `clone(url:name:onLine:) async throws` (`git clone --filter=blob:none`), `pull(name:) async -> Bool` (`git pull --ff-only`) and `remove(name:) throws`.
  - `dev-recipes/test-cube` (`developer: true`): tasks `image_to_3d` (image→mesh; settings `size` float 1.0 [0.01, 100], `delay` float 0 [0, 600] seconds, `fail` bool, `crash` bool → `os._exit(3)`) and `fake_rig` (mesh→rigged_mesh, copies the GLB; `delay`). Also `shim: { env: { TEST_CUBE_SHIM: "on" } }` (the launcher logs `shim env: on`, proving `LIFT_SHIM` reached the worker), `substitutes: [flash_attn]`, `memory_gb: 0.5`, `disk_gb: 0.5`, no weights, and stage patterns for `[Stage] X` and `X: NN%|`.
  - `dev-recipes/shared/substitutes.yaml`: `flash_attn` and `spconv` stand-ins.

- [ ] **Step 1: Write the failing tests**

`Tests/LiftCoreTests/CatalogTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct CatalogTests {
    let cubeYAML = try! String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)

    @Test func testCubeInDevRecipesIsValid() throws {
        guard case .ok(let r) = RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "test-cube")) else {
            Issue.record("\(RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "test-cube")))")
            return
        }
        #expect(r.repo == nil && r.tasks.map(\.id) == ["image_to_3d", "fake_rig"])
    }

    @Test func firstSourceWinsAndProblemsAreListed() throws {
        let a = try Fixtures.tempDir(), b = try Fixtures.tempDir()
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: a)
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: b)
        _ = try writeRecipe("schema: 9\nid: future\n", id: "future", in: b)
        _ = try writeRecipe("schema: 1\nid: broken\n", id: "broken", in: b)
        try FileManager.default.createDirectory(at: b.appending(path: "shared/lift_shim"), withIntermediateDirectories: true)
        let c = Catalog.scan([RecipeSourceDir(name: "a", dir: a), RecipeSourceDir(name: "b", dir: b)], includeDeveloper: true)
        #expect(c.entries.keys.sorted() == ["test-cube"])
        #expect(c.entries["test-cube"]?.source == "a")
        #expect(c.entries["test-cube"]?.shared == a.appending(path: "shared"))
        #expect(c.problems.contains(.duplicate(id: "test-cube", kept: "a", ignored: "b")))
        #expect(c.problems.contains(.needsNewerLift(source: "b", id: "future", schema: 9)))
        #expect(c.problems.contains { if case .invalid("b", "broken", _) = $0 { true } else { false } })
    }

    @Test func missingSourceFolderIsEmpty() {
        #expect(Catalog.scan([RecipeSourceDir(name: "gone", dir: URL(filePath: "/nonexistent-lift-source"))]).entries.isEmpty)
    }

    @Test func developerRecipesAreHiddenByDefault() throws {
        let source = [RecipeSourceDir(name: "bundled", dir: Fixtures.devRecipes)]
        #expect(Catalog.scan(source).entries["test-cube"] == nil)
        #expect(Catalog.scan(source, includeDeveloper: true).entries["test-cube"] != nil)
    }

    @Test func sharedFallsBackToAnotherSource() throws {
        let local = try Fixtures.tempDir()
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: local)
        let c = Catalog.scan([RecipeSourceDir(name: "bundled-local", dir: local, shared: Fixtures.devRecipes.appending(path: "shared"))], includeDeveloper: true)
        #expect(c.entries["test-cube"]?.shared == Fixtures.devRecipes.appending(path: "shared"))
    }

    func recipe(_ yaml: String) throws -> Recipe {
        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "test-cube", in: try Fixtures.tempDir())) else {
            throw LiftError.invalidState("fixture")
        }
        return r
    }

    @Test func substitutesAndTheRecipeShimMakeLIFTSHIM() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        #expect(registry["flash_attn"]?.standin == "flash_attn")
        #expect(registry["spconv"]?.standin == "spconv")
        let yaml = cubeYAML.replacingOccurrences(of: "substitutes: [flash_attn]", with: "substitutes: [flash_attn, spconv]")
        let config = try #require(try ShimConfig.build(try recipe(yaml), registry: registry))
        #expect(config.json == #"{"aliases":{},"env":{"TEST_CUBE_SHIM":"on"},"patches":[],"standins":["flash_attn","spconv"]}"#)
        #expect(throws: LiftError.self) { try ShimConfig.build(try self.recipe(cubeYAML.replacingOccurrences(of: "[flash_attn]", with: "[nope]")), registry: registry) }
    }

    @Test func substituteThatNeedsTheShimRequiresShim() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        let noShim = try recipe(cubeYAML.replacingOccurrences(of: "shim: { env: { TEST_CUBE_SHIM: \"on\" } }", with: ""))
        #expect(noShim.shim == nil)
        #expect(throws: LiftError.self) { try ShimConfig.build(noShim, registry: registry) }
        var none = noShim
        none.substitutes = []
        #expect(try ShimConfig.build(none, registry: registry) == nil)
    }

    @Test func sourceNames() {
        #expect(RecipeSources.name(for: "https://github.com/oshricohenme/lift-recipes.git", taken: []) == "lift-recipes")
        #expect(RecipeSources.name(for: "https://github.com/x/lift-recipes", taken: ["lift-recipes"]) == "lift-recipes-2")
    }

    @Test func cloneAndPullRunGit() async throws {
        let runner = FakeRunner()
        runner.on("pull --ff-only", code: 1)
        let root = try Fixtures.tempDir()
        let sources = RecipeSources(runner: runner, root: root, git: "/usr/bin/git", environment: [:])
        try await sources.clone(url: "https://example.com/r.git", name: "r")
        #expect(await sources.pull(name: "r") == false)
        #expect(runner.displays == ["/usr/bin/git clone --filter=blob:none https://example.com/r.git \(root.path)/r",
                                    "/usr/bin/git -C \(root.path)/r pull --ff-only"])
    }
}
```

`Tests/LiftCoreTests/BundledTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct BundledTests {
    /// A fake app bundle: two recipe folders and shared/, with dev leftovers that must not be copied.
    func bundle() throws -> URL {
        let b = try Fixtures.tempDir()
        for (path, text) in ["a/recipe.yaml": "a1", "b/recipe.yaml": "b1", "shared/substitutes.yaml": "s1",
                             "shared/lift_shim/.venv/huge": "x", "a/__pycache__/x.pyc": "x"] {
            let url = b.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return b
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func firstLaunchCopiesWithoutDevLeftovers() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        #expect(try sync.sync() == .init(copied: true, keptLocal: []))
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
        #expect(!FileManager.default.fileExists(atPath: sync.copyDir.appending(path: "shared/lift_shim/.venv").path))
        #expect(!FileManager.default.fileExists(atPath: sync.copyDir.appending(path: "a/__pycache__").path))
        #expect(try sync.sync() == .init(copied: false, keptLocal: []))  // same bundle: nothing to do
    }

    @Test func appUpdateRefreshesAndKeepsEdits() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        try "a-edited".write(to: sync.copyDir.appending(path: "a/recipe.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sync.copyDir.appending(path: "mine"), withIntermediateDirectories: true)
        try "m".write(to: sync.copyDir.appending(path: "mine/recipe.yaml"), atomically: true, encoding: .utf8)
        #expect(try sync.sync() == .init(copied: false, keptLocal: []))  // edits alone don't trigger a refresh
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)  // the app update
        #expect(try sync.sync() == .init(copied: true, keptLocal: ["a", "mine"]))
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
        #expect(try read(sync.copyDir.appending(path: "b/recipe.yaml")) == "b2")
        #expect(try read(sync.localDir.appending(path: "a/recipe.yaml")) == "a-edited")
        #expect(try read(sync.localDir.appending(path: "mine/recipe.yaml")) == "m")
        #expect(try read(b.appending(path: "a/recipe.yaml")) == "a1")  // the bundle is only read
    }

    @Test func anOlderKeptCopyIsMovedAsideNotReplaced() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        for (edit, update) in [("first edit", "b2"), ("second edit", "b3")] {
            try edit.write(to: sync.copyDir.appending(path: "a/recipe.yaml"), atomically: true, encoding: .utf8)
            try update.write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)
            _ = try sync.sync()
        }
        #expect(try read(sync.localDir.appending(path: "a/recipe.yaml")) == "second edit")
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: sync.localDir.path).first { $0.hasPrefix(".a-") })
        #expect(try read(sync.localDir.appending(path: "\(aside)/recipe.yaml")) == "first edit")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find 'Catalog' in scope`, `cannot find 'RecipeSourceDir' in scope` and `cannot find 'BundledRecipes' in scope`.

- [ ] **Step 3: Write the Test Cube recipe and the substitute registry**

`dev-recipes/test-cube/recipe.yaml`:
```yaml
# Test Cube: a fake image→3D recipe for Lift's own tests (spec §4). Hidden unless the developer setting is on.
schema: 1
id: test-cube
name: Test Cube
developer: true
publisher: Lift
license: MIT
python: "3.11"
platform: { status: supported }
install:
  - uv pip install "trimesh>=4,<5" numpy
shim: { env: { TEST_CUBE_SHIM: "on" } }   # exercises lift_shim + .pth + LIFT_SHIM end to end
substitutes: [flash_attn]
resources:
  memory_gb: 0.5
  memory_keys: [size]
  max_concurrent_per_process: 1
  disk_gb: 0.5
stages:
  - { pattern: '^\[Stage\] (?P<name>.+)$' }
  - { pattern: '^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|' }
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D (cube)
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: launcher:run
    settings:
      - { key: size, label: Cube size, type: float, default: 1.0, min: 0.01, max: 100, group: basic }
      - { key: delay, label: Delay (seconds), type: float, default: 0.0, min: 0, max: 600, group: advanced }
      - { key: fail, label: Fail on purpose, type: bool, default: false, group: advanced }
      - { key: crash, label: Crash the worker, type: bool, default: false, group: advanced }
  - id: fake_rig
    modality: 3d
    label: Mesh → rigged mesh (copy)
    inputs: [{ name: mesh, type: mesh }]
    output: rigged_mesh
    entry: launcher:run
    settings:
      - { key: delay, label: Delay (seconds), type: float, default: 0.0, min: 0, max: 600, group: advanced }
```

`dev-recipes/test-cube/launcher.py`:
```python
"""Test Cube launcher: writes a cube GLB with trimesh. Settings: size, delay, fail, crash."""
import os
import shutil
import sys
import time

import trimesh


def load(ctx):
    print("[Stage] Loading")
    return {}


def _wait(job, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if job.cancelled:
            raise RuntimeError("cancelled")
        time.sleep(0.05)


def run(state, job):
    s = job.settings
    print(f"shim env: {os.environ.get('TEST_CUBE_SHIM')}")  # set only if lift_shim's autoload ran
    print("[Stage] Generating")
    for i in range(1, 5):
        _wait(job, float(s.get("delay", 0)) / 4)
        print(f"Generating: {i * 25}%|", file=sys.stderr)
    if s.get("crash"):
        os._exit(3)
    if s.get("fail"):
        raise RuntimeError("failed on purpose (fail=true)")
    if job.task == "fake_rig":
        out = os.path.join(job.out_dir, "rigged.glb")
        shutil.copyfile(job.inputs["mesh"], out)
        return [out]
    out = os.path.join(job.out_dir, "cube.glb")
    trimesh.creation.box(extents=[float(s["size"])] * 3).export(out)
    return [out]
```

`dev-recipes/shared/substitutes.yaml`:
```yaml
# Substitute registry (spec §5): CUDA-only package → how to provide it on Apple Silicon.
# Keys are the names recipes list under `substitutes:`. Fields:
#   install: commands run in models/<id>/ with the venv active
#   alias:   `import <key>` resolves to this installed module (lift_shim alias)
#   standin: a lift_shim built-in stand-in
#   patches: named lift_shim runtime patches the substitute needs
# Recipes using alias/standin/patches must have `shim:`. Metal substitutes (flex_gemm, nvdiffrast,
# o_voxel, cumesh) and torch_scatter/torch_cluster are added in Plan 4 from the go/no-go findings.
flash_attn: { standin: flash_attn }
spconv: { standin: spconv }
```

- [ ] **Step 4: Implement the catalog and the bundled-recipes sync**

`Sources/LiftCore/Recipes/Catalog.swift`:
```swift
import Foundation
import Yams

/// One recipe found in a source.
public struct CatalogEntry: Sendable, Equatable {
    public var recipe: Recipe
    public var source: String
    /// The recipe folder (`recipe.yaml`, `launcher.py`, optional `files/`).
    public var directory: URL
    /// The source's `shared/` folder (`lift_shim/`, `substitutes.yaml`).
    public var shared: URL
}

public enum CatalogProblem: Codable, Sendable, Equatable {
    case invalid(source: String, folder: String, message: String)
    case needsNewerLift(source: String, id: String, schema: Int)
    case duplicate(id: String, kept: String, ignored: String)
}

/// A folder of recipe folders, and the `shared/` its recipes use.
public struct RecipeSourceDir: Sendable, Equatable {
    public var name: String
    public var dir: URL
    public var shared: URL

    public init(name: String, dir: URL, shared: URL? = nil) {
        self.name = name
        self.dir = dir
        self.shared = shared ?? dir.appending(path: "shared")
    }
}

/// All recipes across sources. Sources are scanned in order; the first to define an id wins.
/// Developer recipes (the Test Cube) are left out unless `includeDeveloper`.
public struct Catalog: Sendable {
    public var entries: [String: CatalogEntry] = [:]
    public var problems: [CatalogProblem] = []

    public init() {}

    public static func scan(_ sources: [RecipeSourceDir], includeDeveloper: Bool = false) -> Catalog {
        var catalog = Catalog()
        for source in sources {
            let (name, dir) = (source.name, source.dir)
            let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where folder.lastPathComponent != "shared" && FileManager.default.fileExists(atPath: folder.appending(path: "recipe.yaml").path) {
                switch RecipeLoad.read(directory: folder) {
                case .ok(let recipe) where recipe.developer && !includeDeveloper:
                    continue
                case .ok(let recipe):
                    if let kept = catalog.entries[recipe.id] {
                        catalog.problems.append(.duplicate(id: recipe.id, kept: kept.source, ignored: name))
                    } else {
                        catalog.entries[recipe.id] = CatalogEntry(recipe: recipe, source: name, directory: folder, shared: source.shared)
                    }
                case .needsNewerLift(let id, let schema):
                    catalog.problems.append(.needsNewerLift(source: name, id: id, schema: schema))
                case .invalid(let message):
                    catalog.problems.append(.invalid(source: name, folder: folder.lastPathComponent, message: message))
                }
            }
        }
        return catalog
    }
}

/// One entry of `shared/substitutes.yaml`: how to provide a CUDA-only package on Apple Silicon.
public struct Substitute: Codable, Sendable, Equatable {
    /// Install commands, run in the model folder with the venv active.
    public var install: [String]
    /// `import <name>` resolves to this installed module (a `lift_shim` alias).
    public var alias: String?
    /// A `lift_shim` built-in stand-in of this name.
    public var standin: String?
    /// Named `lift_shim` runtime patches this substitute needs.
    public var patches: [String]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        install = try c.decodeIfPresent([String].self, forKey: .install) ?? []
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        standin = try c.decodeIfPresent(String.self, forKey: .standin)
        patches = try c.decodeIfPresent([String].self, forKey: .patches) ?? []
    }

    var needsShim: Bool { alias != nil || standin != nil || !patches.isEmpty }

    public static func registry(shared: URL) throws -> [String: Substitute] {
        let file = shared.appending(path: "substitutes.yaml")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try YAMLDecoder().decode([String: Substitute].self, from: String(contentsOf: file, encoding: .utf8))
    }
}

/// The `LIFT_SHIM` contract: `{"aliases":{…},"standins":[…],"patches":[…],"env":{…}}`.
public struct ShimConfig: Codable, Sendable, Equatable {
    public var aliases: [String: String] = [:]
    public var standins: [String] = []
    public var patches: [String] = []
    public var env: [String: String] = [:]

    /// The recipe's `shim:` plus what its substitutes add. `nil` when the recipe has no `shim:`;
    /// a substitute that needs the shim then is an error.
    public static func build(_ recipe: Recipe, registry: [String: Substitute]) throws(LiftError) -> ShimConfig? {
        var config = ShimConfig()
        if let shim = recipe.shim {
            config.aliases = shim.aliases
            config.standins = shim.standins
            config.patches = shim.patches
            config.env = shim.env
        }
        for name in recipe.substitutes {
            guard let sub = registry[name] else {
                throw .prerequisite("unknown substitute \(name); add it to shared/substitutes.yaml")
            }
            if sub.needsShim && recipe.shim == nil { throw .prerequisite("substitute \(name) needs `shim:` in the recipe") }
            if let alias = sub.alias { config.aliases[name] = alias }
            if let standin = sub.standin, !config.standins.contains(standin) { config.standins.append(standin) }
            for p in sub.patches where !config.patches.contains(p) { config.patches.append(p) }
        }
        return recipe.shim == nil ? nil : config
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// Git recipe sources under `<workdir>/recipes/<name>/`.
public struct RecipeSources: Sendable {
    let runner: any CommandRunner
    let root: URL
    let environment: [String: String]
    let git: String

    public init(runner: any CommandRunner, root: URL, git: String, environment: [String: String]) {
        self.runner = runner
        self.root = root
        self.git = git
        self.environment = environment
    }

    public func directory(_ name: String) -> URL { root.appending(path: name) }

    /// Folder name for a URL: its last path component without `.git`, made unique among `taken`.
    public static func name(for url: String, taken: Set<String>) -> String {
        var base = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "source"
        if base.isEmpty || base == "/" { base = "source" }
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    public func clone(url: String, name: String, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runner.check(ShellCommand(git, ["clone", "--filter=blob:none", url, directory(name).path], environment: environment), onLine: onLine)
    }

    /// `git pull --ff-only`. On failure the checkout is untouched, so recipes keep their last good version.
    public func pull(name: String) async -> Bool {
        let code = try? await runner.run(ShellCommand(git, ["-C", directory(name).path, "pull", "--ff-only"], environment: environment), onLine: { _ in })
        return code == 0
    }

    public func remove(name: String) throws {
        try FileManager.default.removeItem(at: directory(name))
    }
}
```

`Sources/LiftCore/Recipes/Bundled.swift`:
```swift
import CryptoKit
import Foundation

/// Keeps `<workdir>/recipes/bundled/` in step with the recipes built into the app (spec §4, §11).
/// The first launch copies them. An app update with different recipes refreshes the copy, and any
/// top-level folder you edited (or added) is moved to `bundled-local/` first, never deleted.
/// The app bundle itself is only read.
public struct BundledRecipes: Sendable {
    /// Development leftovers that never belong in the copy.
    public static let ignored: Set<String> = [".venv", "__pycache__", ".pytest_cache", ".DS_Store", manifestName]
    static let manifestName = ".lift-bundle.json"

    public struct Result: Codable, Sendable, Equatable {
        /// A fresh copy was written (first launch, or the bundle changed).
        public var copied: Bool
        /// Folders moved to `bundled-local/` because they differed from what Lift had copied.
        public var keptLocal: [String]
    }

    struct Manifest: Codable {
        var bundle: String
        var folders: [String: String]
    }

    let bundle: URL
    let recipes: URL

    public init(bundle: URL, recipes: URL) {
        self.bundle = bundle
        self.recipes = recipes
    }

    public var copyDir: URL { recipes.appending(path: "bundled") }
    public var localDir: URL { recipes.appending(path: "bundled-local") }
    var manifestURL: URL { copyDir.appending(path: Self.manifestName) }

    public func sync() throws -> Result {
        let fm = FileManager.default
        let fresh = try Self.digests(bundle)
        let freshDigest = Self.combined(fresh)
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        if manifest?.bundle == freshDigest { return Result(copied: false, keptLocal: []) }

        var kept: [String] = []
        if fm.fileExists(atPath: copyDir.path) {
            for (name, digest) in try Self.digests(copyDir) where digest != manifest?.folders[name] {
                try keep(name)
                kept.append(name)
            }
            try fm.removeItem(at: copyDir)  // only unedited copies Lift made are left in it
        }
        try Self.copy(bundle, to: copyDir)
        try JSONEncoder().encode(Manifest(bundle: freshDigest, folders: fresh)).write(to: manifestURL)
        return Result(copied: true, keptLocal: kept.sorted())
    }

    /// Moves `bundled/<name>` to `bundled-local/<name>`. An older kept copy is moved aside to a hidden
    /// `.<name>-<timestamp>`, so nothing is lost.
    func keep(_ name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        let dest = localDir.appending(path: name)
        if fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: dest, to: localDir.appending(path: ".\(name)-\(Int(Date().timeIntervalSince1970 * 1000))"))
        }
        try fm.moveItem(at: copyDir.appending(path: name), to: dest)
    }

    /// SHA-256 per top-level entry, over relative paths and contents, skipping `ignored`.
    static func digests(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where !ignored.contains(name) {
            var hash = SHA256()
            for file in files(root.appending(path: name)) {
                hash.update(data: Data(file.relative.utf8))
                hash.update(data: try Data(contentsOf: file.url))
            }
            out[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    static func combined(_ digests: [String: String]) -> String {
        let text = digests.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Regular files under `url` (or `url` itself), sorted, skipping `ignored` names at any depth.
    static func files(_ url: URL) -> [(relative: String, url: URL)] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [("", url)] }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return children.filter { !ignored.contains($0) }.sorted().flatMap { name in
            files(url.appending(path: name)).map { (name + ($0.relative.isEmpty ? "" : "/" + $0.relative), $0.url) }
        }
    }

    static func copy(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: from.path) where !ignored.contains(name) {
            for file in files(from.appending(path: name)) {
                let dest = to.appending(path: name + (file.relative.isEmpty ? "" : "/" + file.relative))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.url, to: dest)
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "CatalogTests|BundledTests"`
Expected: `✔ Test run with 12 tests in 2 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiftCore/Recipes/Catalog.swift Sources/LiftCore/Recipes/Bundled.swift dev-recipes/test-cube dev-recipes/shared/substitutes.yaml \
  Tests/LiftCoreTests/CatalogTests.swift Tests/LiftCoreTests/BundledTests.swift
git commit -m "feat(core): recipe catalog, bundled-recipes sync, git sources, substitute registry; Test Cube recipe

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 10: Installer

**Files:**
- Create: `Sources/LiftCore/Installer/Installer.swift`
- Test: `Tests/LiftCoreTests/InstallerTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `ShellCommand`, `ToolPaths` (Task 4); `WeightProblem` (Task 8); `CatalogEntry`, `Substitute`, `ShimConfig` (Task 9); `Recipe`, `RecipeLoad` (Task 3); `LogFile` (Task 1); the `lift_worker --check` CLI (Task 2).
- Produces:
  - `enum ModelStatus: Codable, Equatable { notInstalled, installing(phase: String), installed(commit: String?), updateAvailable(installedCommit:recipeCommit:), installFailed(command: String, exitCode: Int32), unsupported(reason: String), weightsMissing([WeightProblem]), weightsCorrupt([WeightProblem]) }`. The engine sets `installing` and the weights cases (Task 11).
  - `struct UpstreamStatus: Codable, Equatable { pin: String?, head: String, commitsAhead: Int? }`.
  - `struct Installer(runner:models:workerRuntime:tools:toolEnvironment:hfToken:hfHub:)`.
    - Paths: `dir(_ id) -> URL`, `logURL(_:)`, `venvPython(_:) -> String`, `installedRecipeDir(_:)`, `shimURL(_:)`.
    - `status(id:source:pin:) -> ModelStatus` and `installedRecipe(_:) -> Recipe?`.
    - `preflight(_ entry:) throws -> (registry:, shim: ShimConfig?)`: unsupported, git/uv, `brew:` without native brew, gated weights without a token, disk space and bad substitutes all give `LiftError.prerequisite`.
    - `install(_ entry:, pin: String?, onLine:) async throws`.
    - `workerConfig(_ recipe:, maxConcurrent:, heartbeat:) -> String`: the lift_worker JSON argument.
    - `workerEnvironment(_ recipe:) -> [String: String]`.
    - `downloadWeights(_ recipe:, onLine:) async throws`: `<venv>/bin/hf download <repo> --revision <rev>` per weight, appended to `install.log`. Without `hf` in the venv, or with gated weights and no token, it throws `.prerequisite`.
    - `uninstall(_ id) throws`: removes only `models/<id>/`.
    - `checkUpstream(_ recipe:, pin:) async throws -> UpstreamStatus`.
  - Install order: delete the old `repo venv recipe state.json shim.json install.log` (all Lift's own) → `brew install <recipe.brew>` with the native brew → `git clone --filter=blob:none <repo> repo` → `git -C repo checkout --quiet <pin>` (or `mkdir repo` when there's no repo) → `uv venv --python <py> venv` → each `install:` step and then each substitute's install commands as `/bin/sh -c` in `models/<id>/` with the venv active → with a shim, `uv pip install <shared>/lift_shim` and the `.pth` one-liner → copy the recipe folder to `models/<id>/recipe/` and write `shim.json` → `venv/bin/python -m lift_worker --check …` → write `state.json`. Every command is logged as `$ <display>` followed by its output.

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/InstallerTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

@Suite struct InstallerTests {
    /// A source with pixal3d (repo, shim, flash_attn substitute) and the shared registry.
    func source(_ yaml: String = pixalYAML) throws -> CatalogEntry {
        let root = try Fixtures.tempDir()
        let folder = try writeRecipe(yaml, id: "pixal3d", in: root)
        let shared = root.appending(path: "shared")
        try FileManager.default.createDirectory(at: shared.appending(path: "lift_shim"), withIntermediateDirectories: true)
        try "flash_attn: { standin: flash_attn }\n".write(to: shared.appending(path: "substitutes.yaml"), atomically: true, encoding: .utf8)
        guard case .ok(let recipe) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return CatalogEntry(recipe: recipe, source: "test", directory: folder, shared: shared)
    }

    func installer(_ runner: FakeRunner, token: String? = "hf_x", brew: String? = "/brew/bin/brew") throws -> Installer {
        Installer(runner: runner, models: try Fixtures.tempDir(), workerRuntime: URL(filePath: "/lift/runtime"),
                  tools: ToolPaths(brew: brew, git: "/bin/git", uv: "/bin/uv"), toolEnvironment: ["PATH": "/bin"],
                  hfToken: { token }, hfHub: URL(filePath: "/hf/hub"))
    }

    @Test func runsEveryStepInOrderAndMarksInstalled() async throws {
        let runner = FakeRunner()
        let entry = try source()
        let inst = try installer(runner)
        let m = inst.dir("pixal3d").path
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(runner.displays == [
            "/brew/bin/brew install libusb",
            "/bin/git clone --filter=blob:none https://github.com/TencentARC/Pixal3D \(m)/repo",
            "/bin/git -C \(m)/repo checkout --quiet f7cf38429b0bd264f1995f0f8743a88b1c728b94",
            "/bin/uv venv --python 3.11 \(m)/venv",
            "uv pip install torch torchvision",
            "/bin/uv pip install \(entry.shared.path)/lift_shim",
            "\(m)/venv/bin/python -c import site, lift_shim.pth as p; p.write_pth(site.getsitepackages()[0])",
            "\(m)/venv/bin/python -m lift_worker --check \(inst.workerConfig(entry.recipe, maxConcurrent: 1, heartbeat: 2))",
        ])
        let step = runner.commands[4]
        #expect(step.environment["VIRTUAL_ENV"] == "\(m)/venv" && step.environment["PATH"] == "\(m)/venv/bin:/bin" && step.workingDirectory == m)
        let smoke = runner.commands[7].environment
        #expect(smoke["LIFT_SHIM"] == #"{"aliases":{},"env":{"ATTN_BACKEND":"sdpa"},"patches":["transformers_fa2_to_sdpa"],"standins":["flash_attn"]}"#)
        #expect(smoke["PYTHONPATH"] == "/lift/runtime" && smoke["HF_HUB_CACHE"] == "/hf/hub" && smoke["HF_TOKEN"] == "hf_x")
        #expect(smoke["DYLD_FALLBACK_LIBRARY_PATH"] == "/brew/lib:/usr/lib")  // native brew only, never /usr/local
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .installed(commit: entry.recipe.commit))
        #expect(inst.installedRecipe("pixal3d") == entry.recipe)
        let log = try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8)
        #expect(log.contains("$ uv pip install torch torchvision") && log.contains("installed pixal3d"))
    }

    @Test func failureKeepsTheLogAndNeverCountsAsInstalled() async throws {
        let runner = FakeRunner()
        runner.on("uv pip install torch", code: 1, lines: ["error: no matching distribution"])
        let entry = try source()
        let inst = try installer(runner)
        await #expect(throws: LiftError.commandFailed(command: "uv pip install torch torchvision", exitCode: 1, tail: ["error: no matching distribution"])) {
            try await inst.install(entry, pin: nil, onLine: { _ in })
        }
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .installFailed(command: "uv pip install torch torchvision", exitCode: 1))
        #expect(inst.installedRecipe("pixal3d") == nil)
        #expect(try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8).contains("error: no matching distribution"))
        #expect(!runner.displays.contains { $0.contains("lift_worker --check") })
    }

    @Test func brewPackagesNeedNativeHomebrew() async throws {
        let runner = FakeRunner()
        await #expect(throws: LiftError.self) { try await self.installer(runner, brew: nil).install(try self.source(), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    @Test func gatedWeightsNeedAToken() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner, token: nil)
        await #expect(throws: LiftError.self) { try await inst.install(try source(), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    @Test func notEnoughDiskIsRefused() async throws {
        let runner = FakeRunner()
        let yaml = pixalYAML.replacingOccurrences(of: "max_concurrent_per_process: 1", with: "max_concurrent_per_process: 1\n  disk_gb: 1000000000")
        await #expect(throws: LiftError.self) { try await self.installer(runner).install(try self.source(yaml), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    @Test func unsupportedIsRefused() async throws {
        let yaml = pixalYAML.replacingOccurrences(of: "platform: { status: supported, reason: \"\" }", with: "platform: { status: unsupported, reason: \"needs CUDA\" }")
        let entry = try source(yaml)
        let inst = try installer(FakeRunner())
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .unsupported(reason: "needs CUDA"))
        await #expect(throws: LiftError.prerequisite("Pixal3D is unsupported on this Mac: needs CUDA")) { try await inst.install(entry, pin: nil, onLine: { _ in }) }
    }

    @Test func changedRecipeOrPinMeansUpdateAvailable() async throws {
        let entry = try source()
        let inst = try installer(FakeRunner())
        try await inst.install(entry, pin: nil, onLine: { _ in })
        let other = String(repeating: "b", count: 40)
        #expect(inst.status(id: "pixal3d", source: entry, pin: other) == .updateAvailable(installedCommit: entry.recipe.commit, recipeCommit: other))
        try "def run(state, job):\n    return ['x']\n".write(to: entry.directory.appending(path: "launcher.py"), atomically: true, encoding: .utf8)
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .updateAvailable(installedCommit: entry.recipe.commit, recipeCommit: entry.recipe.commit))
    }

    @Test func pinOverrideIsCheckedOut() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let pin = String(repeating: "c", count: 40)
        try await inst.install(try source(), pin: pin, onLine: { _ in })
        #expect(runner.displays[2].hasSuffix("checkout --quiet \(pin)"))
    }

    @Test func checkUpstreamCountsCommitsPastThePin() async throws {
        let runner = FakeRunner()
        let head = String(repeating: "d", count: 40)
        runner.on("ls-remote", lines: ["\(head)\tHEAD"])
        runner.on("rev-list --count", lines: ["7"])
        let entry = try source()
        let inst = try installer(runner)
        #expect(try await inst.checkUpstream(entry.recipe, pin: nil) == UpstreamStatus(pin: entry.recipe.commit, head: head, commitsAhead: nil))
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try FileManager.default.createDirectory(at: inst.dir("pixal3d").appending(path: "repo"), withIntermediateDirectories: true)
        #expect(try await inst.checkUpstream(entry.recipe, pin: nil) == UpstreamStatus(pin: entry.recipe.commit, head: head, commitsAhead: 7))
    }

    @Test func downloadWeightsRunsHFFromTheVenv() async throws {
        let runner = FakeRunner()
        let entry = try source()
        let inst = try installer(runner)
        await #expect(throws: LiftError.self) { try await inst.downloadWeights(entry.recipe, onLine: { _ in }) }  // no hf yet
        let bin = inst.dir("pixal3d").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try await inst.downloadWeights(entry.recipe, onLine: { _ in })
        #expect(runner.displays == ["\(bin.path)/hf download TencentARC/Pixal3D --revision main",
                                    "\(bin.path)/hf download briaai/RMBG-2.0 --revision 1f3e2a7c"])
        #expect(runner.commands.allSatisfy { $0.environment["HF_HUB_CACHE"] == "/hf/hub" && $0.environment["HF_TOKEN"] == "hf_x" })
        #expect(try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8).contains("$ \(bin.path)/hf download TencentARC/Pixal3D"))
        await #expect(throws: LiftError.self) { try await self.installer(runner, token: nil).downloadWeights(entry.recipe, onLine: { _ in }) }
    }

    @Test func uninstallRemovesOnlyTheModelFolder() async throws {
        let entry = try source()
        let inst = try installer(FakeRunner())
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try inst.uninstall("pixal3d")
        #expect(!FileManager.default.fileExists(atPath: inst.dir("pixal3d").path))
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .notInstalled)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find 'Installer' in scope`.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Installer/Installer.swift`:
```swift
import CryptoKit
import Foundation

/// Where a model stands (spec §6). `installing` and the weights states come from the engine.
public enum ModelStatus: Codable, Sendable, Equatable {
    case notInstalled
    /// `phase`: installing, downloading weights, verifying weights.
    case installing(phase: String)
    case installed(commit: String?)
    /// Installed, but the source recipe (or its pin) changed since. Reinstall to update.
    case updateAvailable(installedCommit: String?, recipeCommit: String?)
    case installFailed(command: String, exitCode: Int32)
    case unsupported(reason: String)
    /// Installed, but the last weights check found files missing / wrong.
    case weightsMissing([WeightProblem])
    case weightsCorrupt([WeightProblem])
}

/// `models/<id>/state.json`: written last, so a partial install never counts as installed.
struct InstallState: Codable {
    var installed: Bool
    var commit: String?
    /// SHA-256 of the source recipe.yaml + launcher.py at install time.
    var digest: String
    var failedCommand: String?
    var exitCode: Int32?
    var at: Date
}

public struct UpstreamStatus: Codable, Sendable, Equatable {
    public var pin: String?
    public var head: String
    /// Commits upstream is past the pin; nil when not installed (only `git ls-remote` was run).
    public var commitsAhead: Int?
}

/// brew prerequisites → clone pinned commit → uv venv → install steps → substitutes → lift_shim + .pth →
/// recipe copy → smoke import; then, separately, weight downloads. Only ever writes inside `models/<id>/`
/// (and, through `brew` and `hf download`, Homebrew's prefix and the Hugging Face cache).
public struct Installer: Sendable {
    let runner: any CommandRunner
    let models: URL
    let workerRuntime: URL
    let tools: ToolPaths
    let toolEnvironment: [String: String]
    let hfToken: @Sendable () -> String?
    let hfHub: URL

    public init(runner: any CommandRunner, models: URL, workerRuntime: URL, tools: ToolPaths,
                toolEnvironment: [String: String], hfToken: @escaping @Sendable () -> String?, hfHub: URL) {
        self.runner = runner
        self.models = models
        self.workerRuntime = workerRuntime
        self.tools = tools
        self.toolEnvironment = toolEnvironment
        self.hfToken = hfToken
        self.hfHub = hfHub
    }

    /// Native Homebrew's prefix (`/opt/homebrew`), from the detected brew.
    var brewPrefix: String? { tools.brew.map { URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().path } }

    public func dir(_ id: String) -> URL { models.appending(path: id) }
    public func logURL(_ id: String) -> URL { dir(id).appending(path: "install.log") }
    func stateURL(_ id: String) -> URL { dir(id).appending(path: "state.json") }
    public func venvPython(_ id: String) -> String { dir(id).appending(path: "venv/bin/python").path }
    /// The installed copy of the recipe folder; workers run this, not the source.
    public func installedRecipeDir(_ id: String) -> URL { dir(id).appending(path: "recipe") }
    public func shimURL(_ id: String) -> URL { dir(id).appending(path: "shim.json") }

    static func digest(_ recipeDir: URL) -> String {
        var hash = SHA256()
        for name in ["recipe.yaml", "launcher.py"] {
            hash.update(data: (try? Data(contentsOf: recipeDir.appending(path: name))) ?? Data())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func readState(_ id: String) -> InstallState? {
        guard let data = try? Data(contentsOf: stateURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallState.self, from: data)
    }

    func writeState(_ state: InstallState, id: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL(id))
    }

    /// Status from the files on disk. `source` is the recipe as the sources have it now (nil if gone).
    public func status(id: String, source: CatalogEntry?, pin: String?) -> ModelStatus {
        guard let state = readState(id) else {
            if let source, source.recipe.platform.status == .unsupported {
                return .unsupported(reason: source.recipe.platform.reason ?? "")
            }
            return .notInstalled
        }
        guard state.installed else { return .installFailed(command: state.failedCommand ?? "", exitCode: state.exitCode ?? -1) }
        if let source, state.digest != Self.digest(source.directory) || state.commit != (pin ?? source.recipe.commit) {
            return .updateAvailable(installedCommit: state.commit, recipeCommit: pin ?? source.recipe.commit)
        }
        return .installed(commit: state.commit)
    }

    /// The installed recipe, read from the model's own copy.
    public func installedRecipe(_ id: String) -> Recipe? {
        guard readState(id)?.installed == true, case .ok(let recipe) = RecipeLoad.read(directory: installedRecipeDir(id), matchFolder: false) else { return nil }
        return recipe
    }

    /// Checks that run before anything is touched: platform, tools, native brew for `brew:` packages,
    /// Hugging Face token, disk space, substitutes. Returns the substitute registry and the `LIFT_SHIM` config.
    public func preflight(_ entry: CatalogEntry) throws -> (registry: [String: Substitute], shim: ShimConfig?) {
        let recipe = entry.recipe
        guard recipe.platform.status == .supported else {
            throw LiftError.prerequisite("\(recipe.name) is unsupported on this Mac: \(recipe.platform.reason ?? "")")
        }
        guard tools.git != nil, tools.uv != nil else { throw LiftError.prerequisite("git and uv are required; run system_install_prereqs") }
        if !recipe.brew.isEmpty && tools.brew == nil {
            throw LiftError.prerequisite("\(recipe.name) needs native Homebrew for \(recipe.brew.joined(separator: ", ")); run system_install_prereqs")
        }
        if recipe.weights.contains(where: \.gated) && hfToken() == nil {
            let gated = recipe.weights.filter(\.gated).map(\.repo).joined(separator: ", ")
            throw LiftError.prerequisite("\(recipe.name) needs a Hugging Face token with access to \(gated)")
        }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let needed = Int64(recipe.resources.diskGB * 1_000_000_000)
        if let free = (try? models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw LiftError.prerequisite("not enough disk space: \(recipe.resources.diskGB) GB needed, \(Double(free) / 1e9) GB free")
        }
        let registry = try Substitute.registry(shared: entry.shared)
        return (registry, try ShimConfig.build(recipe, registry: registry))
    }

    /// Runs the whole install. Every command and its output go to `install.log` and `onLine`.
    /// Throws `LiftError.prerequisite` before touching anything, or `.commandFailed` with the log kept
    /// and state.json marked failed.
    public func install(_ entry: CatalogEntry, pin: String?, onLine: @escaping @Sendable (String) -> Void) async throws {
        let (registry, shimConfig) = try preflight(entry)
        let recipe = entry.recipe
        let commit = pin ?? recipe.commit
        let git = tools.git!, uv = tools.uv!
        let fm = FileManager.default
        let root = dir(recipe.id)
        for name in ["repo", "venv", "recipe", "state.json", "shim.json", "install.log"] {
            try? fm.removeItem(at: root.appending(path: name))
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try LogFile(logURL(recipe.id))
        let lines: @Sendable (String) -> Void = { line in
            log.write(line)
            onLine(line)
        }
        let venv = root.appending(path: "venv").path
        var env = toolEnvironment
        env["PATH"] = "\(venv)/bin:" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        env["VIRTUAL_ENV"] = venv
        let repo = root.appending(path: "repo").path

        var steps: [ShellCommand] = []
        if !recipe.brew.isEmpty, let brew = tools.brew {
            // First, so install steps that build native code can link against them.
            steps.append(ShellCommand(brew, ["install"] + recipe.brew, environment: toolEnvironment))
        }
        if let url = recipe.repo, let commit {
            steps.append(ShellCommand(git, ["clone", "--filter=blob:none", url, repo], environment: toolEnvironment))
            steps.append(ShellCommand(git, ["-C", repo, "checkout", "--quiet", commit], environment: toolEnvironment))
        } else {
            try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        }
        steps.append(ShellCommand(uv, ["venv", "--python", recipe.python, venv], environment: toolEnvironment, workingDirectory: root.path))
        let shell = recipe.install + recipe.substitutes.flatMap { registry[$0]?.install ?? [] }
        steps += shell.map { ShellCommand("/bin/sh", ["-c", $0], environment: env, workingDirectory: root.path) }
        if shimConfig != nil {
            steps.append(ShellCommand(uv, ["pip", "install", entry.shared.appending(path: "lift_shim").path], environment: env, workingDirectory: root.path))
            steps.append(ShellCommand(venvPython(recipe.id), ["-c", "import site, lift_shim.pth as p; p.write_pth(site.getsitepackages()[0])"], environment: env))
        }

        do {
            for step in steps {
                lines("$ \(step.display)")
                try await runner.check(step, onLine: lines)
            }
            try fm.copyItem(at: entry.directory, to: installedRecipeDir(recipe.id))
            if let shimConfig { try shimConfig.json.write(to: shimURL(recipe.id), atomically: true, encoding: .utf8) }
            let smoke = ShellCommand(venvPython(recipe.id), ["-m", "lift_worker", "--check", workerConfig(recipe, maxConcurrent: 1, heartbeat: 2)],
                                     environment: workerEnvironment(recipe), workingDirectory: repo)
            lines("$ \(smoke.display)")
            try await runner.check(smoke, onLine: lines)
            try writeState(InstallState(installed: true, commit: commit, digest: Self.digest(entry.directory), at: Date()), id: recipe.id)
            lines("installed \(recipe.id)")
        } catch let error as LiftError {
            if case .commandFailed(let command, let code, _) = error {
                try? writeState(InstallState(installed: false, commit: commit, digest: "", failedCommand: command, exitCode: code, at: Date()), id: recipe.id)
            }
            lines("install failed: \(error)")
            throw error
        }
    }

    /// The JSON argument for `python -m lift_worker`.
    public func workerConfig(_ recipe: Recipe, maxConcurrent: Int, heartbeat: Double) -> String {
        struct Config: Encodable {
            var launcher: String
            var repo_dir: String
            var recipe_dir: String
            var max_concurrent: Int
            var stages: [Recipe.StagePattern]
            var heartbeat_seconds: Double
            var setting_types: [String: [String: String]]
        }
        let config = Config(launcher: installedRecipeDir(recipe.id).appending(path: "launcher.py").path,
                            repo_dir: dir(recipe.id).appending(path: "repo").path,
                            recipe_dir: installedRecipeDir(recipe.id).path,
                            max_concurrent: maxConcurrent, stages: recipe.stages, heartbeat_seconds: heartbeat,
                            setting_types: Dictionary(uniqueKeysWithValues: recipe.tasks.map { task in
                                (task.id, Dictionary(uniqueKeysWithValues: task.settings.map { ($0.key, $0.type.rawValue) }))
                            }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(config), as: UTF8.self)
    }

    /// Environment for a worker or the smoke check: lift_worker on PYTHONPATH, the venv first on PATH,
    /// `LIFT_SHIM` when the recipe uses the shim, native brew's `lib/` for `brew:` packages, the
    /// Hugging Face cache and token.
    public func workerEnvironment(_ recipe: Recipe) -> [String: String] {
        let venv = dir(recipe.id).appending(path: "venv").path
        var env = toolEnvironment
        env["PATH"] = "\(venv)/bin:" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        env["VIRTUAL_ENV"] = venv
        env["PYTHONPATH"] = workerRuntime.path
        env["PYTHONUNBUFFERED"] = "1"
        if let shim = try? String(contentsOf: shimURL(recipe.id), encoding: .utf8) { env["LIFT_SHIM"] = shim }
        // dyld's default fallback includes /usr/local/lib, where a Rosetta Homebrew keeps x86_64 libraries.
        if !recipe.brew.isEmpty, let prefix = brewPrefix { env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(prefix)/lib:/usr/lib" }
        env["HF_HUB_CACHE"] = hfHub.path
        if let token = hfToken() { env["HF_TOKEN"] = token }
        return env
    }

    /// `hf download <repo> --revision <rev>` for each weight, from the model's venv into the shared cache.
    /// Appends to `install.log`. Only ever started by an explicit user action (spec §6).
    public func downloadWeights(_ recipe: Recipe, onLine: @escaping @Sendable (String) -> Void) async throws {
        let hf = dir(recipe.id).appending(path: "venv/bin/hf").path
        guard FileManager.default.isExecutableFile(atPath: hf) else {
            throw LiftError.prerequisite("\(recipe.id)'s venv has no `hf` (huggingface_hub); add it to the recipe's install steps")
        }
        if recipe.weights.contains(where: \.gated) && hfToken() == nil {
            throw LiftError.prerequisite("\(recipe.name) has gated weights; set a Hugging Face token first")
        }
        let log = try LogFile(logURL(recipe.id))
        let lines: @Sendable (String) -> Void = { line in
            log.write(line)
            onLine(line)
        }
        for w in recipe.weights {
            let command = ShellCommand(hf, ["download", w.repo, "--revision", w.revision], environment: workerEnvironment(recipe))
            lines("$ \(command.display)")
            try await runner.check(command, onLine: lines)
        }
    }

    /// Removes `models/<id>/` — Lift's own folder. Weights in the shared Hugging Face cache are never deleted.
    public func uninstall(_ id: String) throws {
        try? FileManager.default.removeItem(at: dir(id))
    }

    /// `git ls-remote` for upstream HEAD; when installed, also fetch and count commits past the pin.
    public func checkUpstream(_ recipe: Recipe, pin: String?) async throws -> UpstreamStatus {
        guard let url = recipe.repo, let git = tools.git else { throw LiftError.invalidState("\(recipe.id) has no upstream repo") }
        let head = try await runner.output(ShellCommand(git, ["ls-remote", url, "HEAD"], environment: toolEnvironment))
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let pin = pin ?? recipe.commit
        let repo = dir(recipe.id).appending(path: "repo").path
        guard readState(recipe.id)?.installed == true, let pin, FileManager.default.fileExists(atPath: repo) else {
            return UpstreamStatus(pin: pin, head: head, commitsAhead: nil)
        }
        try await runner.check(ShellCommand(git, ["-C", repo, "fetch", "--quiet", "origin", head], environment: toolEnvironment))
        let count = try await runner.output(ShellCommand(git, ["-C", repo, "rev-list", "--count", "\(pin)..\(head)"], environment: toolEnvironment))
        return UpstreamStatus(pin: pin, head: head, commitsAhead: Int(count.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter InstallerTests`
Expected: `✔ Test run with 11 tests in 1 suite passed`. Every command goes to `FakeRunner`, so nothing is cloned, installed or downloaded.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Installer Tests/LiftCoreTests/InstallerTests.swift
git commit -m "feat(core): installer — brew deps, pinned clone, uv venv, steps, substitutes, lift_shim, smoke check, hf download

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 11: The `Lift` engine and the job and queue commands

**Files:**
- Create: `Sources/LiftCore/Engine/Lift.swift`
- Create: `Sources/LiftCore/Commands/Gated.swift`, `Sources/LiftCore/Commands/JobCommands.swift`
- Test: `Tests/LiftCoreTests/EngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 and 3–10: `Store`, `Settings`, `Catalog`, `RecipeSourceDir`, `BundledRecipes`, `Installer`, `Toolchain`, `Scheduler`, `Estimates`, `Memory`, `WeightsVerifier`, `WeightsMetadata`, `HFHubAPI`, `WorkerProcess`, `WorkerOp/WorkerEvent`, `Tail`, `LogFile`. Test fixtures: `FakeMetadata` (Task 8), `FakeRunner` (Task 4).
- Produces:
  - `struct LiftConfig(workdir:workerRuntime:bundledRecipes:runner: = SubprocessRunner(), toolSearchDirs: = nil, homebrewPrefix: = "/opt/homebrew", rosettaPrefix: = "/usr/local", housekeepingInterval: = .seconds(15), heartbeatSeconds: = 2, systemFree: = Memory.systemFree, hfToken: = { $HF_TOKEN }, hfHub: = HFHubAPI.defaultCache, weightsMetadata: (any WeightsMetadata)? = nil → HFHubAPI(token:), weightsRecheckInterval: = .seconds(30))`.
  - `actor Lift` with `nonisolated let config` and `nonisolated let store`.
  - `static func open(_ config: LiftConfig) async throws -> Lift` does, in order:
    1. Create the workdir and migrate.
    2. Mark jobs/steps left `loading`/`running` as `interrupted`, and open worker rows as ended with `app_restart`.
    3. `BundledRecipes.sync()`: the first-launch copy, or the refresh after an app update.
    4. Detect the toolchain (async), scan recipes, start housekeeping, tick.
    It clones and downloads nothing.
  - `close()` kills workers. Their jobs become `interrupted` on the next open.
  - Sources come in the order `bundled-local` (if it exists), `bundled`, then `settings.recipeSources` under `<workdir>/recipes/<name>`. Developer recipes are shown only when `settings.devRecipes` or `LIFT_DEV_RECIPES=1` is set.
  - Weights gating:
    - A `.ready` candidate whose recipe has weights, and which has no worker with free capacity and no `verifiedForStart` entry, becomes `.weightsUnverified`. A background `WeightsVerifier.verify` then starts, at most once per `weightsRecheckInterval`.
    - `verified(_ id, _ report)` records the report and, on `ok`, inserts into `verifiedForStart`. `spawn` removes the entry.
    - `status` maps a missing/corrupt report on an installed model to `weightsMissing`/`weightsCorrupt`.
  - Internal API for Task 12: `settings`, `catalog`, `installed`, `installing`, `phases`, `staleSources`, `bundleSync`, `weightReports`, `verifying`, `verifiedForStart`, `workers: [String: WorkerHandle]`, `installer`, `verifier`, `bundled`, `toolchain`, `tools`, `jobsDir`, `recipesDir`, `sourceDirs: [RecipeSourceDir]`, `developerMode`, `rescan()`, `status(_ id) -> ModelStatus`, `recipe(_ id) -> Recipe?`, `saveSettings(_:) throws`, `tick()`, `verified(_:_:)`, `spawn(_ recipe:, baseline:) -> WorkerHandle`, `stop(_ w: WorkerHandle)` (shutdown, then SIGKILL after 5 s). `WorkerHandle` has `id, recipe, process, capacity, pid, ready, stopping, assigned: [jobId: Assignment], baseline, lastFootprint, idleSince, freeCapacity, reserved`.
  - `enum Gated<T: Sendable> { done(T), confirmationRequired(String) }` with `value: T?` and `impact: String?`.
  - Requests: `StepRequest(recipe:task:inputs: = [:], settings: = [:])`, `SubmitRequest(steps:title: = nil, priority: = .normal, source: = .ui)`, `JobFilter(states:recipe:modality:text:)`, `MoveTarget { before(String), after(String), index(Int) }`, `InterruptedAction { requeue, discard }`. Views: `JobView { job, steps, outputs }`, `QueueStatus { paused, maxSlots, running, jobs }`.
  - Commands: `jobsSubmit(_:) throws -> JobView`, `jobsGet(_:)`, `jobsList(_: JobFilter = .init()) -> [JobView]` (newest first), `nonisolated jobsWait(_ id:, timeout: Duration, onProgress:) async throws -> JobView`, `jobsCancel(_:confirm:) -> Gated<JobView>`, `jobsRetry(_:settings:) -> JobView`, `jobsMove(_:to:) -> JobView`, `jobsSetPriority(_:_:) -> JobView`, `jobsForceStart(_:confirm:) -> Gated<JobView>`, `jobsDelete(_:confirm:) -> Gated<Bool>`, `jobsListInterrupted() -> [JobView]`, `jobsResolveInterrupted(ids: = nil, action:) -> [JobView]`, `queueStatus()`, `queuePause()`, `queueResume() -> QueueStatus`.
  - Test helper: `Fixtures.lift(_ runner: FakeRunner = .init(), workdir: URL? = nil, searchDirs: [String] = [], bundle: URL = devRecipes, metadata: FakeMetadata = .init(), hub: URL? = nil) async throws -> Lift`. It seeds `dev_recipes = true` and uses nonexistent Homebrew prefixes, a temp HF cache, `hfToken` nil, fixed system free memory of 64 GB, 1 h housekeeping and a 100 ms weights recheck.

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/EngineTests.swift`:
```swift
import Foundation
import GRDB
import Testing
@testable import LiftCore

extension Fixtures {
    /// A Lift on a fresh workdir with developer recipes shown, a fake runner, fake weights metadata,
    /// a temp Hugging Face cache, no Homebrew and fixed system memory. Nothing real is installed or
    /// downloaded, so jobs wait with `model_not_installed`.
    static func lift(_ runner: FakeRunner = FakeRunner(), workdir: URL? = nil, searchDirs: [String] = [],
                     bundle: URL = devRecipes, metadata: FakeMetadata = FakeMetadata(), hub: URL? = nil) async throws -> Lift {
        let workdir = try workdir ?? tempDir()
        let seed = try Store(path: workdir.appending(path: "lift.sqlite").path)
        try await seed.db.write { db in
            var s = try Settings.load(db)
            s.devRecipes = true
            try s.save(db)
        }
        return try await Lift.open(LiftConfig(workdir: workdir, workerRuntime: workerRuntime, bundledRecipes: bundle,
                                              runner: runner, toolSearchDirs: searchDirs,
                                              homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                              housekeepingInterval: .seconds(3600), systemFree: { 64_000_000_000 },
                                              hfToken: { nil }, hfHub: try hub ?? tempDir(), weightsMetadata: metadata,
                                              weightsRecheckInterval: .milliseconds(100)))
    }
}

@Suite struct EngineTests {
    func cube(_ image: String, _ settings: [String: SettingValue] = [:]) -> StepRequest {
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": image], settings: settings)
    }

    @Test func submitRejectsBadInputPerField() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [])) } == ["steps"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "nope", task: "x")])) } == ["steps[0].recipe"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "x")])) } == ["steps[0].task"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [self.cube(image, ["size": .int(0)])])) } == ["steps[0].settings.size"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d")])) } == ["steps[0].inputs.image"])
        let wrongChain = SubmitRequest(steps: [cube(image), StepRequest(recipe: "test-cube", task: "image_to_3d")])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(wrongChain) } == ["steps[1].task"])
        #expect(try await lift.jobsList().isEmpty)
    }

    @Test func submitCopiesInputsAndWaitsForTheModel() async throws {
        let lift = try await Fixtures.lift()
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")]))
        #expect(v.job.title == "photo")
        let input = try #require(v.steps[0].inputs["image"])
        #expect(input.hasPrefix(lift.config.workdir.appending(path: "jobs/\(v.job.id)/inputs").path))
        #expect(FileManager.default.fileExists(atPath: input))
        // Defaults filled. Stored as JSON, so 1.0 reads back as 1; the worker makes float settings floats again.
        #expect(v.steps[0].settings.mapValues(\.description) == ["size": "1", "delay": "0", "fail": "false", "crash": "false"])
        let now = try await lift.jobsGet(v.job.id)
        #expect(now.job.state == .waiting && now.job.waitReason == .modelNotInstalled)
    }

    @Test func pauseAndResume() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        _ = try await lift.queuePause()
        #expect(try await lift.jobsGet(id).job.waitReason == .queuePaused)
        _ = try await lift.queueResume()
        #expect(try await lift.jobsGet(id).job.waitReason == .modelNotInstalled)
    }

    @Test func moveAndPriorityChangeTheOrder() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        var ids: [String] = []
        for _ in 0..<3 { ids.append(try await lift.jobsSubmit(SubmitRequest(steps: [cube(image)])).job.id) }
        func order() async throws -> [String] { try await lift.queueStatus().jobs.map(\.job.id) }
        #expect(try await order() == ids)
        _ = try await lift.jobsMove(ids[2], to: .before(ids[0]))
        #expect(try await order() == [ids[2], ids[0], ids[1]])
        _ = try await lift.jobsMove(ids[2], to: .index(2))
        #expect(try await order() == [ids[0], ids[1], ids[2]])
        _ = try await lift.jobsMove(ids[0], to: .after(ids[1]))
        #expect(try await order() == [ids[1], ids[0], ids[2]])
        _ = try await lift.jobsSetPriority(ids[2], .high)
        #expect(try await order() == [ids[2], ids[1], ids[0]])
    }

    @Test func cancelRetryAndDelete() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        #expect(try await lift.jobsCancel(id).value?.job.state == .cancelled)  // not running: no confirm needed
        await #expect(throws: LiftError.self) { try await lift.jobsCancel(id) }
        #expect(await fieldErrors { _ = try await lift.jobsRetry(id, settings: ["size": .int(-1)]) } == ["settings.size"])
        let retried = try await lift.jobsRetry(id, settings: ["size": .int(3)])
        #expect(retried.steps[0].settings["size"]?.number == 3 && retried.job.state != .cancelled)
        #expect(try await lift.jobsDelete(id).impact != nil)
        #expect(try await lift.jobsGet(id).job.id == id)  // unconfirmed: nothing changed
        #expect(try await lift.jobsDelete(id, confirm: true).value == true)
        await #expect(throws: LiftError.notFound("job \(id)")) { try await lift.jobsGet(id) }
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(id)").path))
    }

    @Test func firstOpenCopiesTheBundledRecipes() async throws {
        let lift = try await Fixtures.lift()
        let copy = lift.config.workdir.appending(path: "recipes/bundled")
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "test-cube/recipe.yaml").path))
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "shared/lift_shim/pyproject.toml").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "shared/lift_shim/.venv").path))
        #expect(await lift.bundleSync.copied)
        #expect(await lift.sourceDirs.map(\.name) == ["bundled"])
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "models").path))  // nothing installed
    }

    @Test func forceStartNeedsConfirm() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        #expect(try await lift.jobsForceStart(id).impact != nil)
        #expect(try await lift.jobsGet(id).job.forceStart == false)
        #expect(try await lift.jobsForceStart(id, confirm: true).value?.job.forceStart == true)
    }

    @Test func interruptedJobsAfterRelaunch() async throws {
        let workdir = try Fixtures.tempDir()
        let first = try await Fixtures.lift(workdir: workdir)
        let steps = [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")]
        let a = try await first.jobsSubmit(SubmitRequest(steps: steps)).job.id
        let b = try await first.jobsSubmit(SubmitRequest(steps: steps)).job.id
        await first.close()
        // Simulate a crash mid-run: step 0 finished, step 1 running.
        try await first.store.db.write { db in
            for id in [a, b] {
                try db.execute(sql: "UPDATE step SET state = 'succeeded', outputs = '[\"/x/cube.glb\"]' WHERE jobId = ? AND idx = 0", arguments: [id])
                try db.execute(sql: "UPDATE step SET state = 'running' WHERE jobId = ? AND idx = 1", arguments: [id])
                try db.execute(sql: "UPDATE job SET state = 'running', currentStep = 1 WHERE id = ?", arguments: [id])
            }
        }
        let lift = try await Fixtures.lift(workdir: workdir)
        #expect(try await lift.jobsListInterrupted().map(\.job.id).sorted() == [a, b].sorted())
        #expect(try await lift.jobsGet(a).steps.map(\.state) == [.succeeded, .interrupted])
        let requeued = try await lift.jobsResolveInterrupted(ids: [a], action: .requeue)
        #expect(requeued.first?.steps.map(\.state) == [.succeeded, .waiting])  // restarts from step 1
        #expect(requeued.first?.job.currentStep == 1)
        _ = try await lift.jobsResolveInterrupted(action: .discard)
        #expect(try await lift.jobsGet(b).job.state == .cancelled)
        #expect(try await lift.jobsListInterrupted().isEmpty)
    }

}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `cannot find type 'Lift' in scope` and `cannot find 'SubmitRequest' in scope`.

- [ ] **Step 3: Implement the engine**

`Sources/LiftCore/Engine/Lift.swift`. The state machine follows spec §7: `queued → waiting(reason) → loading → running → succeeded | failed | cancelled | interrupted`. The job mirrors its current step. A finished non-final step moves the job to the next step and puts it back to `queued`. A worker that exits fails every active step on it with the last 20 stderr lines, unless it was stopped on purpose or the app is closing. `tick()` keeps the GRDB read to the estimates and does readiness and verification requests on the actor.
```swift
import Foundation
import GRDB

public struct LiftConfig: Sendable {
    /// `<workdir>/` from spec §3: lift.sqlite, recipes/, models/, jobs/.
    public var workdir: URL
    /// The folder that contains the `lift_worker` package (`python/lift_worker/src` in this repo; the app bundle later).
    public var workerRuntime: URL
    /// The recipes built into the app: this repo's `dev-recipes/` (recipes + `shared/`). Copied to
    /// `<workdir>/recipes/bundled/` on open; only read here.
    public var bundledRecipes: URL
    public var runner: any CommandRunner
    public var toolSearchDirs: [String]?
    public var homebrewPrefix: String
    public var rosettaPrefix: String
    public var housekeepingInterval: Duration
    public var heartbeatSeconds: Double
    public var systemFree: @Sendable () -> Int
    /// Plan 2 replaces this with the Keychain.
    public var hfToken: @Sendable () -> String?
    /// The shared Hugging Face cache `hf download` writes to and verification reads.
    public var hfHub: URL
    /// Weight file lists (the Hugging Face API by default; a fake in tests).
    public var weightsMetadata: any WeightsMetadata
    /// How long a failed or unknown weights check waits before a waiting job triggers another.
    public var weightsRecheckInterval: Duration

    public init(workdir: URL, workerRuntime: URL, bundledRecipes: URL, runner: any CommandRunner = SubprocessRunner(),
                toolSearchDirs: [String]? = nil, homebrewPrefix: String = "/opt/homebrew", rosettaPrefix: String = "/usr/local",
                housekeepingInterval: Duration = .seconds(15), heartbeatSeconds: Double = 2,
                systemFree: @escaping @Sendable () -> Int = Memory.systemFree,
                hfToken: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment["HF_TOKEN"] },
                hfHub: URL = HFHubAPI.defaultCache, weightsMetadata: (any WeightsMetadata)? = nil,
                weightsRecheckInterval: Duration = .seconds(30)) {
        self.workdir = workdir
        self.workerRuntime = workerRuntime
        self.bundledRecipes = bundledRecipes
        self.runner = runner
        self.toolSearchDirs = toolSearchDirs
        self.homebrewPrefix = homebrewPrefix
        self.rosettaPrefix = rosettaPrefix
        self.housekeepingInterval = housekeepingInterval
        self.heartbeatSeconds = heartbeatSeconds
        self.systemFree = systemFree
        self.hfToken = hfToken
        self.hfHub = hfHub
        self.weightsMetadata = weightsMetadata ?? HFHubAPI(token: hfToken)
        self.weightsRecheckInterval = weightsRecheckInterval
    }
}

/// One step placed on a worker.
struct Assignment {
    var step: Int
    var task: String
    var keyValues: String
    var claim: Int
    var sent = false
    var startFootprint = 0
    var peak = 0
}

/// A live worker process, owned by the `Lift` actor.
final class WorkerHandle {
    let id: String
    let recipe: Recipe
    let process: WorkerProcess
    let capacity: Int
    var pid: Int32 = 0
    var ready = false
    /// Shut down or killed on purpose: its exit is not a crash.
    var stopping = false
    var assigned: [String: Assignment] = [:]
    /// Model load cost: the estimate until ready, then the footprint measured at ready.
    var baseline: Int
    var lastFootprint = 0
    var idleSince: ContinuousClock.Instant?
    var loadError: String?
    let tail = Tail(limit: 40)

    init(id: String, recipe: Recipe, process: WorkerProcess, baseline: Int) {
        self.id = id
        self.recipe = recipe
        self.process = process
        self.capacity = recipe.resources.maxConcurrentPerProcess
        self.baseline = baseline
    }

    var freeCapacity: Int { stopping ? 0 : capacity - assigned.count }
    var reserved: Int { max(lastFootprint, baseline + assigned.values.reduce(0) { $0 + $1.claim }) }
}

/// LiftCore's engine: store, catalog, installs, workers and the scheduler loop. Commands (Commands/*.swift)
/// are its public API; UI, HTTP and MCP call only those.
public actor Lift {
    public nonisolated let config: LiftConfig
    public nonisolated let store: Store
    let toolchain: Toolchain
    var tools: ToolPaths
    var settings: Settings
    var catalog = Catalog()
    /// Installed recipes, read from each model's own copy.
    var installed: [String: Recipe] = [:]
    var installing: [String: Task<Void, Never>] = [:]
    /// What an install or download is doing now: installing, downloading weights, verifying weights.
    var phases: [String: String] = [:]
    var staleSources: Set<String> = []
    /// The last bundled-recipes sync (first launch or app update).
    var bundleSync = BundledRecipes.Result(copied: false, keptLocal: [])
    var weightReports: [String: WeightsReport] = [:]
    var verifying: Set<String> = []
    /// Recipes whose weights passed a check since their last worker start (spec §6: before every start).
    var verifiedForStart: Set<String> = []
    var lastVerify: [String: ContinuousClock.Instant] = [:]
    var workers: [String: WorkerHandle] = [:]
    var logs: [String: LogFile] = [:]
    var housekeeping: Task<Void, Never>?
    var closing = false

    var jobsDir: URL { config.workdir.appending(path: "jobs") }
    var recipesDir: URL { config.workdir.appending(path: "recipes") }

    var installer: Installer {
        Installer(runner: config.runner, models: config.workdir.appending(path: "models"), workerRuntime: config.workerRuntime,
                  tools: tools, toolEnvironment: toolchain.environment, hfToken: config.hfToken, hfHub: config.hfHub)
    }

    var verifier: WeightsVerifier { WeightsVerifier(metadata: config.weightsMetadata, hub: config.hfHub, store: store) }
    var bundled: BundledRecipes { BundledRecipes(bundle: config.bundledRecipes, recipes: recipesDir) }

    /// Opens the workdir, copies or refreshes the bundled recipes, marks jobs left loading/running as
    /// interrupted, detects the toolchain, scans recipes and starts scheduling. Nothing is cloned or downloaded.
    public static func open(_ config: LiftConfig) async throws -> Lift {
        let lift = try Lift(config: config)
        await lift.start()
        return lift
    }

    init(config: LiftConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.workdir, withIntermediateDirectories: true)
        store = try Store(path: config.workdir.appending(path: "lift.sqlite").path)
        toolchain = Toolchain(runner: config.runner, searchDirs: config.toolSearchDirs,
                              homebrewPrefix: config.homebrewPrefix, rosettaPrefix: config.rosettaPrefix)
        tools = ToolPaths()
        settings = try store.db.read { try Settings.load($0) }
        try store.db.write { try Self.recoverInterrupted($0) }
        bundleSync = try BundledRecipes(bundle: config.bundledRecipes, recipes: config.workdir.appending(path: "recipes")).sync()
    }

    func start() async {
        tools = await toolchain.detect()
        rescan()
        let interval = config.housekeepingInterval
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.housekeep()
            }
        }
        tick()
    }

    /// Stops all workers. Jobs still running stay `running` in the database and become
    /// `interrupted` on the next open (spec §7).
    public func close() {
        closing = true
        housekeeping?.cancel()
        for w in workers.values {
            w.stopping = true
            w.process.kill()
        }
    }

    static func recoverInterrupted(_ db: Database) throws {
        let now = Date()
        let ids = try String.fetchAll(db, sql: "SELECT id FROM job WHERE state IN ('loading', 'running')")
        try db.execute(sql: "UPDATE step SET state = 'interrupted', workerId = NULL WHERE state IN ('loading', 'running')")
        try db.execute(sql: "UPDATE job SET state = 'interrupted', updatedAt = ? WHERE state IN ('loading', 'running')", arguments: [now])
        for id in ids {
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "interrupted")
            try e.insert(db)
        }
        try db.execute(sql: "UPDATE worker SET endedAt = ?, endReason = 'app_restart' WHERE endedAt IS NULL", arguments: [now])
    }

    // MARK: recipes and models

    /// `bundled-local` (your edited bundled recipes) first, then `bundled`, then git sources in the order added.
    var sourceDirs: [RecipeSourceDir] {
        let b = bundled
        var out: [RecipeSourceDir] = []
        if FileManager.default.fileExists(atPath: b.localDir.path) {
            let localShared = b.localDir.appending(path: "shared")
            out.append(RecipeSourceDir(name: "bundled-local", dir: b.localDir,
                                       shared: FileManager.default.fileExists(atPath: localShared.path) ? localShared : b.copyDir.appending(path: "shared")))
        }
        out.append(RecipeSourceDir(name: "bundled", dir: b.copyDir))
        out += settings.recipeSources.map { RecipeSourceDir(name: $0.name, dir: recipesDir.appending(path: $0.name)) }
        return out
    }

    var developerMode: Bool { settings.devRecipes || ProcessInfo.processInfo.environment["LIFT_DEV_RECIPES"] == "1" }

    func rescan() {
        catalog = Catalog.scan(sourceDirs, includeDeveloper: developerMode)
        let models = config.workdir.appending(path: "models")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
        installed = Dictionary(uniqueKeysWithValues: ids.compactMap { id in installer.installedRecipe(id).map { (id, $0) } })
    }

    func status(_ id: String) -> ModelStatus {
        if installing[id] != nil { return .installing(phase: phases[id] ?? "installing") }
        let base = installer.status(id: id, source: catalog.entries[id], pin: settings.pinOverrides[id])
        switch (base, weightReports[id]?.state) {
        case (.installed, .missing?), (.updateAvailable, .missing?): return .weightsMissing(weightReports[id]!.problems)
        case (.installed, .corrupt?), (.updateAvailable, .corrupt?): return .weightsCorrupt(weightReports[id]!.problems)
        default: return base
        }
    }

    /// The recipe a job step is validated and run against: the installed copy, else the source.
    func recipe(_ id: String) -> Recipe? { installed[id] ?? catalog.entries[id]?.recipe }

    func readiness(_ id: String) -> ModelReadiness {
        switch status(id) {
        case .installing: .installing
        case .installed, .updateAvailable, .weightsMissing, .weightsCorrupt: installed[id] == nil ? .notInstalled : .ready
        case .unsupported: .unsupported
        case .notInstalled, .installFailed: .notInstalled
        }
    }

    func saveSettings(_ new: Settings) throws {
        try store.db.write { try new.save($0) }
        settings = new
    }

    // MARK: scheduling

    /// Runs on every state change (spec §8).
    func tick() {
        guard !closing else { return }
        do {
            let pending = try store.db.read { db -> [(JobRecord, StepRecord)] in
                try JobRecord.filter([JobState.queued.rawValue, JobState.waiting.rawValue].contains(Column("state"))).fetchAll(db)
                    .compactMap { job in try StepRecord.fetchOne(db, key: ["jobId": job.id, "idx": job.currentStep]).map { (job, $0) } }
            }
            let recipes = pending.map { recipe($0.1.recipe) }
            let needs = try store.db.read { db in
                try zip(pending, recipes).map { pair, recipe in
                    try recipe.map { try Estimates.need(db, recipe: $0, task: pair.1.task, settings: pair.1.settings) } ?? MemoryNeed(load: 0, job: 0)
                }
            }
            var candidates: [Candidate] = []
            for (i, (job, step)) in pending.enumerated() {
                var model = recipes[i] == nil ? ModelReadiness.notInstalled : readiness(step.recipe)
                if model == .ready, let r = installed[step.recipe], needsVerifiedStart(r) {
                    model = .weightsUnverified
                    requestVerify(r)
                }
                candidates.append(Candidate(jobId: job.id, recipe: step.recipe, priority: job.priority, position: job.position,
                                            createdAt: job.createdAt, forceStart: job.forceStart, model: model, need: needs[i]))
            }
            let input = SchedulerInput(
                candidates: candidates,
                workers: workers.values.map { WorkerSnapshot(recipe: $0.recipe.id, freeCapacity: $0.freeCapacity, reserved: $0.reserved) },
                runningSteps: workers.values.reduce(0) { $0 + $1.assigned.count },
                maxSlots: settings.maxSlots, budget: settings.memoryBudgetBytes, systemFree: config.systemFree(), paused: settings.queuePaused)
            let byId = Dictionary(uniqueKeysWithValues: pending.map { ($0.0.id, $0) })
            for decision in Scheduler.decide(input) {
                switch decision {
                case .wait(let id, let reason):
                    guard let (job, step) = byId[id], job.state != .waiting || job.waitReason != reason else { continue }
                    try store.db.write { db in try self.setState(db, job: job, step: step, .waiting, reason: reason) }
                case .start(let id):
                    if let (job, step) = byId[id] { try startStep(job: job, step: step) }
                }
            }
        } catch {
            print("lift: scheduler tick failed: \(error)")
        }
    }

    @discardableResult
    func setState(_ db: Database, job: JobRecord, step: StepRecord?, _ state: JobState, reason: WaitReason? = nil, error: String? = nil) throws -> JobRecord {
        let now = Date()
        var job = job
        job.state = state
        job.waitReason = reason
        job.updatedAt = now
        if let error { job.error = error }
        if state.isTerminal { job.finishedAt = now }
        try job.update(db)
        if var step {
            step.state = state
            step.waitReason = reason
            if let error { step.error = error }
            if state.isTerminal { step.finishedAt = now }
            try step.update(db)
        }
        var detail = state.rawValue
        if let reason, let data = try? JSONEncoder().encode(reason) { detail += " " + String(decoding: data, as: UTF8.self) }
        if let error { detail += ": " + error }
        var e = EventRecord(id: nil, jobId: job.id, stepIdx: step?.idx, at: now, kind: "state", detail: detail)
        try e.insert(db)
        return job
    }

    func startStep(job: JobRecord, step: StepRecord) throws {
        guard let recipe = installed[step.recipe] else { return }
        let need = try store.db.read { try Estimates.need($0, recipe: recipe, task: step.task, settings: step.settings) }
        let worker = workers.values.first { $0.recipe.id == recipe.id && $0.freeCapacity > 0 } ?? spawn(recipe, baseline: need.load)
        worker.idleSince = nil
        worker.assigned[job.id] = Assignment(step: step.idx, task: step.task, keyValues: Estimates.keyValues(recipe, settings: step.settings), claim: need.job)
        var step = step
        // A chained step's first input comes from the previous step's first output (refilled on every start, so retries see new outputs).
        let stepsDir = jobsDir.appending(path: "\(job.id)/steps").path
        if step.idx > 0, let first = recipe.task(step.task)?.inputs.first, step.inputs[first.name]?.hasPrefix(stepsDir) != false {
            let previous = try store.db.read { try StepRecord.fetchOne($0, key: ["jobId": job.id, "idx": step.idx - 1]) }
            step.inputs[first.name] = previous?.outputs.first
        }
        step.workerId = worker.id
        step.startedAt = Date()
        step.stage = nil
        step.fraction = nil
        try store.db.write { db in try self.setState(db, job: job, step: step, worker.ready ? .running : .loading) }
        if worker.ready { try send(worker, job: job.id) }
    }

    // MARK: weights

    /// A step would start a new worker for a recipe with weights that haven't passed a check since its last start.
    func needsVerifiedStart(_ r: Recipe) -> Bool {
        !r.weights.isEmpty && !verifiedForStart.contains(r.id) && !workers.values.contains { $0.recipe.id == r.id && $0.freeCapacity > 0 }
    }

    /// Starts a background weights check, at most once per `weightsRecheckInterval` per recipe.
    func requestVerify(_ r: Recipe) {
        if verifying.contains(r.id) { return }
        if let last = lastVerify[r.id], ContinuousClock.now - last < config.weightsRecheckInterval { return }
        verifying.insert(r.id)
        lastVerify[r.id] = .now
        let verifier = self.verifier
        Task {
            let report = try? await verifier.verify(r)
            await self.verified(r.id, report)
        }
    }

    func verified(_ id: String, _ report: WeightsReport?) {
        verifying.remove(id)
        weightReports[id] = report ?? WeightsReport(state: .unknown, problems: [], checkedAt: Date(), hashedFiles: 0, note: "the check itself failed")
        if report?.state == .ok { verifiedForStart.insert(id) } else { verifiedForStart.remove(id) }
        tick()
    }

    func spawn(_ recipe: Recipe, baseline: Int) -> WorkerHandle {
        verifiedForStart.remove(recipe.id)
        let id = "w-" + UUID().uuidString.prefix(8).lowercased()
        let process = WorkerProcess(
            executable: installer.venvPython(recipe.id),
            arguments: ["-u", "-m", "lift_worker", installer.workerConfig(recipe, maxConcurrent: recipe.resources.maxConcurrentPerProcess, heartbeat: config.heartbeatSeconds)],
            environment: installer.workerEnvironment(recipe),
            workingDirectory: installer.dir(recipe.id).appending(path: "repo").path)
        let handle = WorkerHandle(id: id, recipe: recipe, process: process, baseline: baseline)
        workers[id] = handle
        Task { [weak self] in
            for await event in process.events { await self?.handle(id, event) }
        }
        return handle
    }

    func send(_ w: WorkerHandle, job id: String) throws {
        guard var a = w.assigned[id], !a.sent else { return }
        let step = try store.db.read { try StepRecord.fetchOne($0, key: ["jobId": id, "idx": a.step]) }
        guard let step else { return }
        let outDir = jobsDir.appending(path: "\(id)/steps/\(step.idx)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        a.sent = true
        a.startFootprint = w.lastFootprint
        w.assigned[id] = a
        w.process.send(.run(job: id, step: step.idx, task: step.task, inputs: step.inputs, settings: step.settings, outDir: outDir.path))
    }

    // MARK: worker events

    func footprint(_ w: WorkerHandle, mps: Int = 0) -> Int {
        max(Memory.footprint(pid: w.pid) ?? 0, mps)
    }

    func handle(_ workerId: String, _ event: WorkerEvent) {
        guard let w = workers[workerId] else { return }
        do {
            switch event {
            case .started(let pid):
                w.pid = pid
                try store.db.write { try WorkerRecord(id: w.id, recipe: w.recipe.id, pid: pid, startedAt: Date()).insert($0) }
            case .ready(_, let loadSeconds):
                w.ready = true
                w.lastFootprint = footprint(w)
                w.baseline = w.lastFootprint
                try store.db.write { db in
                    try db.execute(sql: "UPDATE worker SET loadSeconds = ? WHERE id = ?", arguments: [loadSeconds, w.id])
                    if let a = w.assigned.values.first {
                        try Estimates.record(db, recipe: w.recipe.id, task: a.task, keyValues: a.keyValues, kind: .load, bytes: w.baseline)
                    }
                }
                for (job, a) in w.assigned where !a.sent {
                    try store.db.write { db in
                        if let j = try JobRecord.fetchOne(db, key: job), let s = try StepRecord.fetchOne(db, key: ["jobId": job, "idx": a.step]), s.state == .loading {
                            try self.setState(db, job: j, step: s, .running)
                        }
                    }
                    try send(w, job: job)
                }
            case .log(let job, let line):
                appendLog(job, line)
            case .stage(let job, let name, let fraction):
                guard let a = w.assigned[job] else { return }
                try store.db.write { db in
                    try db.execute(sql: "UPDATE step SET stage = ?, fraction = ? WHERE jobId = ? AND idx = ? AND state = 'running'",
                                   arguments: [name, fraction, job, a.step])
                }
            case .done(let job, let outputs):
                try finish(w, job: job, outputs: outputs, error: nil)
            case .error(let job?, let message, let traceback):
                if let traceback { appendLog(job, traceback) }
                try finish(w, job: job, outputs: [], error: message)
            case .error(nil, let message, let traceback):
                w.loadError = message
                for line in (traceback ?? "").split(separator: "\n") { w.tail.append(String(line)) }
            case .heartbeat(let mps):
                w.lastFootprint = footprint(w, mps: mps)
                for (job, var a) in w.assigned where a.sent {
                    a.peak = max(a.peak, w.lastFootprint)
                    w.assigned[job] = a
                }
            case .stderr(let line):
                w.tail.append(line)
                if w.assigned.count == 1, let job = w.assigned.keys.first { appendLog(job, line) }
            case .malformed(let line):
                w.tail.append("[malformed protocol line] " + line)
            case .exited(let code):
                try exited(w, code: code)
            }
        } catch {
            print("lift: handling \(event) from \(workerId) failed: \(error)")
        }
    }

    func appendLog(_ job: String, _ line: String) {
        if logs[job] == nil { logs[job] = try? LogFile(jobsDir.appending(path: "\(job)/log.txt")) }
        logs[job]?.write(line)
    }

    func finish(_ w: WorkerHandle, job id: String, outputs: [String], error: String?) throws {
        guard var a = w.assigned.removeValue(forKey: id) else { return }
        if w.assigned.isEmpty { w.idleSince = .now }
        w.lastFootprint = footprint(w)
        a.peak = max(a.peak, w.lastFootprint)
        let jobBytes = max(0, a.peak - a.startFootprint)
        try store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id),
                  var step = try StepRecord.fetchOne(db, key: ["jobId": id, "idx": a.step]),
                  step.state == .running else { return }  // cancelled meanwhile: the result is discarded
            if let error {
                try self.setState(db, job: job, step: step, .failed, error: error)
                return
            }
            try Estimates.record(db, recipe: w.recipe.id, task: a.task, keyValues: a.keyValues, kind: .job, bytes: jobBytes)
            step.outputs = outputs
            step.fraction = 1
            let stepCount = try StepRecord.filter(Column("jobId") == id).fetchCount(db)
            if step.idx + 1 < stepCount {
                step.state = .succeeded
                step.finishedAt = Date()
                try step.update(db)
                job.currentStep = step.idx + 1
                try self.setState(db, job: job, step: nil, .queued)
            } else {
                try self.setState(db, job: job, step: step, .succeeded)
            }
        }
        if try store.db.read({ try JobRecord.fetchOne($0, key: id)?.state.isTerminal }) == true { logs[id] = nil }
        tick()
    }

    func exited(_ w: WorkerHandle, code: Int32) throws {
        workers[w.id] = nil
        let reason = w.stopping ? "stopped" : "exited with code \(code)"
        try store.db.write { db in
            try db.execute(sql: "UPDATE worker SET endedAt = ?, endReason = ? WHERE id = ?", arguments: [Date(), reason, w.id])
        }
        guard !closing else { return }
        let message = ([w.loadError ?? "worker \(reason)"] + w.tail.lines.suffix(20)).joined(separator: "\n")
        for (id, a) in w.assigned {
            try store.db.write { db in
                if let job = try JobRecord.fetchOne(db, key: id), let step = try StepRecord.fetchOne(db, key: ["jobId": id, "idx": a.step]), step.state.isActive {
                    try self.setState(db, job: job, step: step, .failed, error: message)
                }
            }
            logs[id] = nil
        }
        tick()
    }

    // MARK: housekeeping

    func housekeep() {
        let limit = Duration.seconds(settings.idleUnloadMinutes * 60)
        for w in workers.values where w.assigned.isEmpty && !w.stopping {
            if let idle = w.idleSince, ContinuousClock.now - idle >= limit { stop(w) }
        }
    }

    /// Asks a worker to exit, and kills it if it hasn't within 5 s.
    func stop(_ w: WorkerHandle) {
        w.stopping = true
        w.process.send(.shutdown)
        let process = w.process
        Task {
            try? await Task.sleep(for: .seconds(5))
            process.kill()
        }
    }
}
```

- [ ] **Step 4: Implement the job and queue commands**

`Sources/LiftCore/Commands/Gated.swift`:
```swift
import Foundation

/// The result of a risky command (spec §10). Without `confirm: true` it changes nothing and
/// returns `confirmationRequired` with a description of the impact.
public enum Gated<T: Sendable>: Sendable {
    case done(T)
    case confirmationRequired(String)

    public var value: T? {
        if case .done(let v) = self { v } else { nil }
    }

    public var impact: String? {
        if case .confirmationRequired(let s) = self { s } else { nil }
    }
}
```

`Sources/LiftCore/Commands/JobCommands.swift`:
```swift
import Foundation
import GRDB

public struct StepRequest: Codable, Sendable, Equatable {
    public var recipe: String
    public var task: String
    /// Input name → file/folder path (or text). A chained step may leave its first input out.
    public var inputs: [String: String]
    public var settings: [String: SettingValue]

    public init(recipe: String, task: String, inputs: [String: String] = [:], settings: [String: SettingValue] = [:]) {
        self.recipe = recipe
        self.task = task
        self.inputs = inputs
        self.settings = settings
    }
}

public struct SubmitRequest: Codable, Sendable, Equatable {
    public var steps: [StepRequest]
    public var title: String?
    public var priority: Priority
    public var source: JobSource

    public init(steps: [StepRequest], title: String? = nil, priority: Priority = .normal, source: JobSource = .ui) {
        self.steps = steps
        self.title = title
        self.priority = priority
        self.source = source
    }
}

public struct JobFilter: Codable, Sendable, Equatable {
    public var states: [JobState]?
    public var recipe: String?
    public var modality: String?
    /// Case-insensitive match on the title.
    public var text: String?

    public init(states: [JobState]? = nil, recipe: String? = nil, modality: String? = nil, text: String? = nil) {
        self.states = states
        self.recipe = recipe
        self.modality = modality
        self.text = text
    }
}

public struct JobView: Codable, Sendable, Equatable {
    public var job: JobRecord
    public var steps: [StepRecord]
    /// The last step's outputs once the job succeeded.
    public var outputs: [String] { job.state == .succeeded ? steps.last?.outputs ?? [] : [] }

    static func fetch(_ db: Database, _ id: String) throws -> JobView? {
        guard let job = try JobRecord.fetchOne(db, key: id) else { return nil }
        return JobView(job: job, steps: try StepRecord.filter(Column("jobId") == id).order(Column("idx")).fetchAll(db))
    }
}

public enum MoveTarget: Codable, Sendable, Equatable {
    case before(String)
    case after(String)
    /// 0-based index among unfinished jobs ordered by position.
    case index(Int)
}

public enum InterruptedAction: String, Codable, Sendable {
    case requeue, discard
}

extension Lift {
    func view(_ id: String) throws -> JobView {
        guard let v = try store.db.read({ try JobView.fetch($0, id) }) else { throw LiftError.notFound("job \(id)") }
        return v
    }

    // MARK: jobs_submit

    /// Validates every step (recipe, task, settings, inputs, chain types), copies inputs into
    /// `jobs/<id>/inputs/`, and queues the job. Bad input throws `invalidInput` with per-field errors.
    public func jobsSubmit(_ request: SubmitRequest) throws -> JobView {
        guard !request.steps.isEmpty else { throw LiftError.invalidInput([FieldError("steps", "at least one step is required")]) }
        var errors: [FieldError] = []
        var checked: [(StepRequest, RecipeTask)] = []
        for (i, s) in request.steps.enumerated() {
            let prefix = "steps[\(i)]"
            guard let recipe = recipe(s.recipe) else { errors.append(FieldError("\(prefix).recipe", "unknown recipe \(s.recipe)")); continue }
            guard let task = recipe.task(s.task) else { errors.append(FieldError("\(prefix).task", "unknown task \(s.task)")); continue }
            if i > 0, let previous = checked.last?.1, let first = task.inputs.first, !first.type.accepts(previous.output) {
                errors.append(FieldError("\(prefix).task", "\(task.id) takes \(first.type.rawValue) but the previous step outputs \(previous.output.rawValue)"))
            }
            var step = s
            do { step.settings = try task.validated(settings: s.settings, prefix: "\(prefix).settings") } catch { if case .invalidInput(let e) = error { errors += e } }
            do { step.inputs = try task.validated(inputs: s.inputs, chained: i > 0, prefix: "\(prefix).inputs") } catch { if case .invalidInput(let e) = error { errors += e } }
            checked.append((step, task))
        }
        if !errors.isEmpty { throw LiftError.invalidInput(errors) }

        let id = UUID().uuidString.lowercased()
        let now = Date()
        var steps: [StepRecord] = []
        for (i, (s, task)) in checked.enumerated() {
            var inputs: [String: String] = [:]
            for input in task.inputs {
                guard let value = s.inputs[input.name] else { continue }
                if input.type == .text { inputs[input.name] = value; continue }
                let source = URL(filePath: value)
                let dest = jobsDir.appending(path: "\(id)/inputs/\(i)-\(input.name)/\(source.lastPathComponent)")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: dest)
                inputs[input.name] = dest.path
            }
            steps.append(StepRecord(jobId: id, idx: i, recipe: s.recipe, task: s.task, inputs: inputs, settings: s.settings,
                                    state: .queued, outputs: []))
        }
        let firstInput = request.steps[0].inputs.values.first.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
        try store.db.write { db in
            let position = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM job") ?? 0) + 1
            let job = JobRecord(id: id, title: request.title ?? firstInput ?? request.steps[0].recipe, priority: request.priority,
                                position: position, source: request.source, state: .queued, forceStart: false, currentStep: 0,
                                createdAt: now, updatedAt: now)
            try job.insert(db)
            for step in steps { try step.insert(db) }
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "queued")
            try e.insert(db)
        }
        tick()
        return try view(id)
    }

    // MARK: reading

    public func jobsGet(_ id: String) throws -> JobView { try view(id) }

    /// Newest first.
    public func jobsList(_ filter: JobFilter = JobFilter()) throws -> [JobView] {
        let modalityRecipes = filter.modality.map { m in Set((catalog.entries.values.map(\.recipe) + installed.values).filter { $0.tasks.contains { $0.modality == m } }.map(\.id)) }
        return try store.db.read { db in
            var request = JobRecord.order(Column("createdAt").desc)
            if let states = filter.states { request = request.filter(states.map(\.rawValue).contains(Column("state"))) }
            if let text = filter.text { request = request.filter(Column("title").like("%\(text)%")) }
            return try request.fetchAll(db).compactMap { try JobView.fetch(db, $0.id) }.filter { v in
                (filter.recipe == nil || v.steps.contains { $0.recipe == filter.recipe })
                    && (modalityRecipes == nil || v.steps.contains { modalityRecipes!.contains($0.recipe) })
            }
        }
    }

    /// Waits until the job finishes or `timeout` passes, calling `onProgress` on every change
    /// (state, stage, fraction). Returns the job as it is at the end.
    public nonisolated func jobsWait(_ id: String, timeout: Duration, onProgress: @escaping @Sendable (JobView) -> Void = { _ in }) async throws -> JobView {
        let store = self.store
        return try await withThrowingTaskGroup(of: JobView?.self) { group in
            group.addTask {
                for try await v in ValueObservation.tracking({ try JobView.fetch($0, id) }).values(in: store.db) {
                    guard let v else { throw LiftError.notFound("job \(id)") }
                    onProgress(v)
                    if v.job.state.isTerminal { return v }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            guard let v = try await store.db.read({ try JobView.fetch($0, id) }) else { throw LiftError.notFound("job \(id)") }
            return v
        }
    }

    // MARK: changing jobs

    /// Queued, waiting or interrupted jobs are cancelled at once. A running job needs `confirm`:
    /// with concurrency 1 its worker is stopped; otherwise the job is marked cancelled and its result discarded.
    public func jobsCancel(_ id: String, confirm: Bool = false) throws -> Gated<JobView> {
        let v = try view(id)
        guard !v.job.state.isTerminal else { throw LiftError.invalidState("job \(id) already \(v.job.state.rawValue)") }
        let step = v.steps[v.job.currentStep]
        if v.job.state.isActive {
            guard confirm else { return .confirmationRequired("Job \"\(v.job.title)\" is \(v.job.state.rawValue); cancelling stops its work and discards any result.") }
            try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
            if let w = workers.values.first(where: { $0.assigned[id] != nil }) {
                if w.capacity == 1 {
                    w.stopping = true
                    w.process.kill()
                } else {
                    w.process.send(.cancel(job: id))
                }
            }
        } else {
            try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
        }
        tick()
        return .done(try view(id))
    }

    /// Re-queues a finished job from its first unfinished step (all steps if it succeeded).
    /// `settings` replaces that step's settings (validated) when given.
    public func jobsRetry(_ id: String, settings: [String: SettingValue]? = nil) throws -> JobView {
        let v = try view(id)
        guard v.job.state.isTerminal || v.job.state == .interrupted else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue); only finished jobs can be retried") }
        let from = v.steps.firstIndex { $0.state != .succeeded } ?? 0
        var newSettings: [String: SettingValue]?
        if let settings {
            let s = v.steps[from]
            guard let task = recipe(s.recipe)?.task(s.task) else { throw LiftError.notFound("recipe \(s.recipe)") }
            newSettings = try task.validated(settings: settings, prefix: "settings")
        }
        try store.db.write { db in
            for var s in v.steps where s.idx >= from {
                s.state = .queued
                s.waitReason = nil
                s.error = nil
                s.outputs = []
                s.stage = nil
                s.fraction = nil
                s.workerId = nil
                s.startedAt = nil
                s.finishedAt = nil
                if s.idx == from, let newSettings { s.settings = newSettings }
                try s.update(db)
            }
            var job = v.job
            job.currentStep = from
            job.error = nil
            job.finishedAt = nil
            try self.setState(db, job: job, step: nil, .queued)
        }
        tick()
        return try view(id)
    }

    /// Sets the job's manual position among unfinished jobs and renumbers them 1…n.
    public func jobsMove(_ id: String, to target: MoveTarget) throws -> JobView {
        try store.db.write { db in
            var order = try JobRecord.filter(![JobState.succeeded.rawValue, JobState.failed.rawValue, JobState.cancelled.rawValue].contains(Column("state")))
                .order(Column("position")).fetchAll(db)
            guard let from = order.firstIndex(where: { $0.id == id }) else { throw LiftError.notFound("unfinished job \(id)") }
            let job = order.remove(at: from)
            let index: Int
            switch target {
            case .before(let other):
                guard let i = order.firstIndex(where: { $0.id == other }) else { throw LiftError.notFound("unfinished job \(other)") }
                index = i
            case .after(let other):
                guard let i = order.firstIndex(where: { $0.id == other }) else { throw LiftError.notFound("unfinished job \(other)") }
                index = i + 1
            case .index(let i):
                index = min(max(0, i), order.count)
            }
            order.insert(job, at: index)
            for (n, var j) in order.enumerated() where j.position != Double(n + 1) {
                j.position = Double(n + 1)
                try j.update(db)
            }
        }
        tick()
        return try view(id)
    }

    public func jobsSetPriority(_ id: String, _ priority: Priority) throws -> JobView {
        try store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else { throw LiftError.notFound("job \(id)") }
            job.priority = priority
            try job.update(db)
        }
        tick()
        return try view(id)
    }

    /// Skips the memory checks for this job (not the slot check).
    public func jobsForceStart(_ id: String, confirm: Bool = false) throws -> Gated<JobView> {
        let v = try view(id)
        guard v.job.state == .queued || v.job.state == .waiting else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue)") }
        guard confirm else {
            return .confirmationRequired("Starts \"\(v.job.title)\" without checking the memory budget or free system memory; the Mac may swap or the worker may run out of memory.")
        }
        try store.db.write { db in
            var job = v.job
            job.forceStart = true
            try job.update(db)
        }
        tick()
        return .done(try view(id))
    }

    /// Deletes the job record and its folder. A running job is stopped first.
    public func jobsDelete(_ id: String, confirm: Bool = false) throws -> Gated<Bool> {
        let v = try view(id)
        guard confirm else { return .confirmationRequired("Deletes job \"\(v.job.title)\", its inputs, outputs and log. This can't be undone.") }
        if !v.job.state.isTerminal { _ = try jobsCancel(id, confirm: true) }
        _ = try store.db.write { try JobRecord.deleteOne($0, key: id) }
        logs[id] = nil
        try? FileManager.default.removeItem(at: jobsDir.appending(path: id))
        return .done(true)
    }

    public func jobsListInterrupted() throws -> [JobView] {
        try jobsList(JobFilter(states: [.interrupted]))
    }

    /// `requeue` restarts from the interrupted step (finished steps are kept); `discard` cancels.
    /// `ids == nil` means every interrupted job.
    public func jobsResolveInterrupted(ids: [String]? = nil, action: InterruptedAction) throws -> [JobView] {
        let targets = try jobsListInterrupted().filter { ids == nil || ids!.contains($0.job.id) }
        try store.db.write { db in
            for v in targets {
                let step = v.steps[v.job.currentStep]
                switch action {
                case .requeue:
                    var s = step
                    s.stage = nil
                    s.fraction = nil
                    try self.setState(db, job: v.job, step: s, .queued)
                case .discard:
                    try self.setState(db, job: v.job, step: step, .cancelled)
                }
            }
        }
        tick()
        return try targets.map { try view($0.job.id) }
    }

    // MARK: queue

    public func queueStatus() throws -> QueueStatus {
        let pending = try jobsList(JobFilter(states: [.queued, .waiting, .loading, .running]))
        let order = pending.sorted { a, b in
            if a.job.priority.rank != b.job.priority.rank { return a.job.priority.rank > b.job.priority.rank }
            if a.job.position != b.job.position { return a.job.position < b.job.position }
            return a.job.createdAt < b.job.createdAt
        }
        return QueueStatus(paused: settings.queuePaused, maxSlots: settings.maxSlots,
                           running: workers.values.reduce(0) { $0 + $1.assigned.count }, jobs: order)
    }

    public func queuePause() throws -> QueueStatus {
        var s = settings
        s.queuePaused = true
        try saveSettings(s)
        tick()
        return try queueStatus()
    }

    public func queueResume() throws -> QueueStatus {
        var s = settings
        s.queuePaused = false
        try saveSettings(s)
        tick()
        return try queueStatus()
    }
}

public struct QueueStatus: Codable, Sendable, Equatable {
    public var paused: Bool
    public var maxSlots: Int
    public var running: Int
    /// Unfinished jobs in scheduling order.
    public var jobs: [JobView]
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter EngineTests`
Expected: `✔ Test run with 8 tests in 1 suite passed`. No worker is spawned because nothing is installed, so jobs wait with `model_not_installed`. `firstOpenCopiesTheBundledRecipes` checks that the copy has no `.venv` and that `models/` doesn't exist.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiftCore/Engine Sources/LiftCore/Commands Tests/LiftCoreTests/EngineTests.swift
git commit -m "feat(core): Lift engine — bundled sync, state machine, scheduling, weights gating, workers; job and queue commands

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 12: Model, recipe, worker, resource, settings and system commands

**Files:**
- Create: `Sources/LiftCore/Commands/ModelCommands.swift`, `Sources/LiftCore/Commands/SystemCommands.swift`
- Test: `Tests/LiftCoreTests/CommandTests.swift`

**Interfaces:**
- Consumes: the internal `Lift` API and `Gated` (Task 11); `Installer` (Task 10); `RecipeSources`, `CatalogProblem`, `BundledRecipes.Result` (Task 9); `WeightsReport`, `WeightsVerifier` (Task 8); `Toolchain`, `Prereqs` (Task 4); `Estimates` (Task 6). Test fixtures: `FakeMetadata`, `writeHFCache`, `sha256Hex` (Task 8).
- Produces:
  - Views:
    - `ModelView { id, name, source?, status, recipe, pin?, diskBytes?, weights: WeightsReport? }`
    - `RecipeSourcesView { sources: [Source{name, url, stale, recipes}], problems, bundle: BundledRecipes.Result }`
    - `WorkerView { id, recipe, pid, ready, jobs, maxConcurrent, footprintBytes, reservedBytes }`
    - `EstimateView { recipe, task, keyValues, loadBytes?, jobBytes? }`
    - `ResourcesView { maxSlots, budgetBytes, reservedBytes, systemFreeBytes, workers, estimates }`
  - Models:
    - `modelsList() -> [ModelView]` and `modelsGet(_:) -> ModelView` (with disk size).
    - `modelsInstall(_:confirm:wait: = false, downloadWeights: = true) async throws -> Gated<ModelView>` is Install/Use. The impact lists the brew packages and the weight repos with their total size from the API. It runs the preflight synchronously, stops idle workers, then in the background installs → downloads weights → verifies.
    - `modelsReinstall(_:confirm:wait:)` and `modelsSetPin(_:commit:confirm:wait:)`.
    - `modelsDownloadWeights(_:confirm:wait:) async throws -> Gated<ModelView>` (installed models only) and `modelsVerifyWeights(_:) async throws -> WeightsReport`.
    - `modelsCheckUpstream(_:) async throws -> UpstreamStatus`.
    - `modelsUninstall(_:confirm:) -> Gated<ModelView?>`: `models/<id>/` only, never the HF cache.
    - `modelsInstallLog(_:) -> String`.
  - Recipes: `recipesListSources() -> RecipeSourcesView`, `recipesAddSource(_ url:confirm:) async throws -> Gated<RecipeSourcesView>`, `recipesRemoveSource(_ name:confirm:) -> Gated<RecipeSourcesView>`, `recipesRefresh(_ name: String? = nil) async throws -> RecipeSourcesView`.
  - Workers and resources: `workersList() -> [WorkerView]`, `workersLoad(_ recipe:) async throws -> WorkerView` (verifies weights first), `workersUnload(_ id:confirm:) -> Gated<[WorkerView]>`, `resourcesGet() -> ResourcesView`, `resourcesSet(maxSlots:memoryBudgetGB:idleUnloadMinutes:) -> Settings`.
  - Settings and system:
    - `settingsGet() -> Settings` and `settingsSet(_ key:, _ value: SettingValue) -> Settings` (only `Settings.userKeys`; changing `dev_recipes` rescans).
    - `systemPrereqs(checkMetal: = false) async -> Prereqs`.
    - `systemInstallPrereqs(metal: = false, confirm: = false, onLine:) async throws -> Gated<Prereqs>`. It installs native Homebrew (leaving a Rosetta one as it is), then `brew install` for the missing git/uv, then the Metal Toolchain.
  - Test helper: `weightedBundle() throws -> URL`, a bundle with the Test Cube plus `weighted` (the cube with one `org/weights` weight).

- [ ] **Step 1: Write the failing test**

`Tests/LiftCoreTests/CommandTests.swift`:
```swift
import Foundation
import Testing
@testable import LiftCore

/// A bundle with the Test Cube and `weighted`, a copy of it that needs one Hugging Face file.
func weightedBundle() throws -> URL {
    let b = try Fixtures.tempDir()
    try FileManager.default.copyItem(at: Fixtures.devRecipes.appending(path: "test-cube"), to: b.appending(path: "test-cube"))
    try FileManager.default.createDirectory(at: b.appending(path: "shared"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Fixtures.devRecipes.appending(path: "shared/substitutes.yaml"), to: b.appending(path: "shared/substitutes.yaml"))
    let cube = try String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)
    _ = try writeRecipe(cube.replacingOccurrences(of: "id: test-cube", with: "id: weighted")
        .replacingOccurrences(of: "resources:", with: "weights:\n  - { repo: org/weights }\nresources:"), id: "weighted", in: b)
    return b
}

@Suite struct CommandTests {
    let commit = String(repeating: "c", count: 40)

    @Test func riskyCommandsChangeNothingWithoutConfirm() async throws {
        let runner = FakeRunner()
        let meta = FakeMetadata()
        meta.set("org/weights", .success(RepoSnapshot(repo: "org/weights", revision: "main", commit: commit, files: [RemoteFile(path: "w.bin", size: 2048)])))
        let lift = try await Fixtures.lift(runner, bundle: try weightedBundle(), metadata: meta)
        #expect(try await lift.modelsInstall("test-cube").impact?.contains("Test Cube") == true)
        let weighted = try #require(try await lift.modelsInstall("weighted").impact)
        #expect(weighted.contains("org/weights@main") && weighted.contains("2 KB"))
        #expect(try await lift.modelsReinstall("test-cube").impact != nil)
        #expect(try await lift.modelsSetPin("test-cube", commit: String(repeating: "a", count: 40)).impact != nil)
        #expect(try await lift.settingsGet().pinOverrides.isEmpty)
        #expect(try await lift.modelsUninstall("test-cube").impact?.contains("stay in the Hugging Face cache") == true)
        #expect(try await lift.recipesAddSource("https://example.com/recipes.git").impact != nil)
        #expect(try await lift.recipesListSources().sources.map(\.name) == ["bundled"])
        #expect(try await lift.systemInstallPrereqs().impact?.contains("install native Homebrew") == true)
        #expect(runner.commands.isEmpty)
        #expect(try await lift.modelsGet("test-cube").status == .notInstalled)
        await #expect(throws: LiftError.self) { try await lift.modelsDownloadWeights("weighted") }  // not installed
    }

    @Test func jobsWaitForVerifiedWeights() async throws {
        let meta = FakeMetadata()
        let hub = try Fixtures.tempDir()
        meta.set("org/weights", .success(RepoSnapshot(repo: "org/weights", revision: "main", commit: commit,
                                                      files: [RemoteFile(path: "w.bin", size: 3, sha256: sha256Hex(Data([1, 2, 3])))])))
        let lift = try await Fixtures.lift(FakeRunner(), searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path],
                                           bundle: try weightedBundle(), metadata: meta, hub: hub)
        // A fake install: no `hf` in the venv, so the download fails and verification finds the file missing.
        let model = try await lift.modelsInstall("weighted", confirm: true, wait: true).value
        #expect(model?.status == .weightsMissing([WeightProblem(repo: "org/weights", path: "w.bin", issue: .missing)]))
        #expect(try await lift.modelsDownloadWeights("weighted").impact?.contains("org/weights@main") == true)
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "weighted", task: "image_to_3d",
                                                                              inputs: ["image": try Fixtures.image()])])).job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.waitReason == .weightsUnverified })
        try writeHFCache(hub: hub, repo: "org/weights", commit: commit, files: ["w.bin": Data([1, 2, 3])], lfs: ["w.bin"])  // the user downloaded it
        #expect(try await lift.modelsVerifyWeights("weighted").state == .ok)
        #expect(try await lift.modelsGet("weighted").status == .installed(commit: nil))
        // Verified, so the job leaves the queue. (Its fake venv can't start a worker; it then fails, which is fine here.)
        #expect(try await eventually { try await lift.jobsGet(id).job.state != .waiting })
    }

    @Test func settingsAndResources() async throws {
        let lift = try await Fixtures.lift()
        #expect(try await lift.resourcesSet(maxSlots: 2, memoryBudgetGB: 32).maxSlots == 2)
        #expect(try await lift.resourcesGet().budgetBytes == 32_000_000_000)
        await #expect(throws: LiftError.self) { try await lift.resourcesSet(idleUnloadMinutes: -1) }
        await #expect(throws: LiftError.self) { try await lift.settingsSet("max_slots", .string("many")) }
        #expect(try await lift.settingsGet().maxSlots == 2)
    }

    @Test func developerRecipesNeedTheSetting() async throws {
        let lift = try await Fixtures.lift()
        _ = try await lift.settingsSet("dev_recipes", .bool(false))
        #expect(try await lift.modelsList().isEmpty)  // the Test Cube is the only bundled recipe so far, and it's hidden
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
    }

    @Test func failedRefreshMarksTheSourceStaleAndKeepsItsRecipes() async throws {
        let runner = FakeRunner()
        runner.on("pull --ff-only", code: 1, lines: ["fatal: unable to access: Could not resolve host"])
        let lift = try await Fixtures.lift(runner, searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        _ = try await lift.recipesAddSource("https://example.com/more-recipes.git", confirm: true)
        // The fake clone wrote nothing; put a recipe where the clone would be.
        let cube = try String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)
        _ = try writeRecipe(cube.replacingOccurrences(of: "id: test-cube", with: "id: cube-two"), id: "cube-two",
                            in: lift.config.workdir.appending(path: "recipes/more-recipes"))
        let after = try await lift.recipesRefresh()
        let source = try #require(after.sources.first { $0.name == "more-recipes" })
        #expect(source.stale && source.recipes == ["cube-two"])
    }

    @Test func modelsAndRecipesAreListed() async throws {
        let lift = try await Fixtures.lift()
        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
        let sources = await lift.recipesListSources()
        #expect(sources.sources.first?.recipes == ["test-cube"])
        #expect(sources.problems.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: FAIL with `value of type 'Lift' has no member 'modelsInstall'` and similar.

- [ ] **Step 3: Implement**

`Sources/LiftCore/Commands/ModelCommands.swift`:
```swift
import Foundation

public struct ModelView: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// The recipe source it comes from; nil when only the installed copy is left.
    public var source: String?
    public var status: ModelStatus
    /// The installed copy when installed, else the source recipe.
    public var recipe: Recipe
    public var pin: String?
    /// Size of `models/<id>/`; only filled by `models_get`.
    public var diskBytes: Int?
    /// The last weights check this session (nil until one ran).
    public var weights: WeightsReport?
}

public struct RecipeSourcesView: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        /// A git URL, or the local folder for `bundled` / `bundled-local`.
        public var url: String
        public var stale: Bool
        public var recipes: [String]
    }
    public var sources: [Source]
    public var problems: [CatalogProblem]
    /// What the last bundled-recipes sync did (first launch / app update), including edits kept as `bundled-local`.
    public var bundle: BundledRecipes.Result
}

extension Lift {
    func modelView(_ id: String, disk: Bool = false) throws -> ModelView {
        let entry = catalog.entries[id]
        guard let recipe = installed[id] ?? entry?.recipe else { throw LiftError.notFound("model \(id)") }
        return ModelView(id: id, name: recipe.name, source: entry?.source, status: status(id), recipe: recipe,
                         pin: settings.pinOverrides[id] ?? entry?.recipe.commit ?? recipe.commit,
                         diskBytes: disk ? Self.diskSize(installer.dir(id)) : nil, weights: weightReports[id])
    }

    static func diskSize(_ url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    // MARK: models

    public func modelsList() throws -> [ModelView] {
        try Set(catalog.entries.keys).union(installed.keys).sorted().map { try modelView($0) }
    }

    public func modelsGet(_ id: String) throws -> ModelView { try modelView(id, disk: true) }

    /// "Using" a model (spec §4): in the background, install it, then download its weights (unless
    /// `downloadWeights` is false) and verify them. `wait` waits for all of it. Progress goes to `install.log`.
    public func modelsInstall(_ id: String, confirm: Bool = false, wait: Bool = false, downloadWeights: Bool = true) async throws -> Gated<ModelView> {
        guard let entry = catalog.entries[id] else { throw LiftError.notFound("recipe \(id)") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is already installing") }
        let r = entry.recipe
        guard confirm else {
            let pin = settings.pinOverrides[id] ?? r.commit
            var text = "Installs \(r.name): "
            if let repo = r.repo { text += "clones \(repo) at \(pin ?? "?"), " }
            if !r.brew.isEmpty { text += "installs \(r.brew.joined(separator: ", ")) with Homebrew, " }
            text += "creates a Python \(r.python) environment and runs \(r.install.count) install steps (about \(r.resources.diskGB.formatted()) GB)."
            if downloadWeights && !r.weights.isEmpty { text += " " + (await weightsImpact(r)) }
            return .confirmationRequired(text)
        }
        _ = try installer.preflight(entry)  // prerequisite problems reach the caller, not just the log
        try stopWorkers(of: id)
        let installer = self.installer, verifier = self.verifier
        let pin = settings.pinOverrides[id]
        phases[id] = "installing"
        let task = Task {
            let ok = (try? await installer.install(entry, pin: pin, onLine: { _ in })) != nil
            await self.rescan()
            if ok && downloadWeights && !r.weights.isEmpty {
                await self.setPhase(id, "downloading weights")
                try? await installer.downloadWeights(r, onLine: { _ in })
            }
            if ok {
                await self.setPhase(id, "verifying weights")
                await self.verified(id, try? await verifier.verify(r))
            }
            await self.installFinished(id)
        }
        installing[id] = task
        tick()
        if wait { await task.value }
        return .done(try modelView(id))
    }

    /// "Downloads N GB from Hugging Face: repo@rev (gated), …", sizes from the API (unknown when offline).
    func weightsImpact(_ r: Recipe) async -> String {
        let size = await verifier.totalBytes(r).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "an unknown amount (offline)"
        let repos = r.weights.map { "\($0.repo)@\($0.revision)" + ($0.gated ? " (gated)" : "") }
        return "Downloads \(size) of weights from Hugging Face into the shared cache: \(repos.joined(separator: ", "))."
    }

    func setPhase(_ id: String, _ phase: String) {
        phases[id] = phase
    }

    func installFinished(_ id: String) {
        installing[id] = nil
        phases[id] = nil
        rescan()
        tick()
    }

    /// Downloads the model's weights with `hf download` from its venv, then verifies them.
    public func modelsDownloadWeights(_ id: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard let r = installed[id] else { throw LiftError.invalidState("\(id) is not installed") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is busy: \(phases[id] ?? "installing")") }
        guard !r.weights.isEmpty else { return .done(try modelView(id)) }
        guard confirm else { return .confirmationRequired(await weightsImpact(r)) }
        let installer = self.installer, verifier = self.verifier
        phases[id] = "downloading weights"
        let task = Task {
            try? await installer.downloadWeights(r, onLine: { _ in })
            await self.setPhase(id, "verifying weights")
            await self.verified(id, try? await verifier.verify(r))
            await self.installFinished(id)
        }
        installing[id] = task
        tick()
        if wait { await task.value }
        return .done(try modelView(id))
    }

    /// Checks the model's weights now. A passing check also counts for the next worker start.
    public func modelsVerifyWeights(_ id: String) async throws -> WeightsReport {
        guard let r = recipe(id) else { throw LiftError.notFound("model \(id)") }
        verifying.insert(id)
        let report = try await verifier.verify(r)
        verified(id, report)
        return report
    }

    public func modelsReinstall(_ id: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard confirm else { return .confirmationRequired("Deletes and rebuilds \(id)'s repo and environment. Downloaded weights are kept.") }
        return try await modelsInstall(id, confirm: true, wait: wait)
    }

    /// Pins the model to `commit` and reinstalls it there.
    public func modelsSetPin(_ id: String, commit: String, confirm: Bool = false, wait: Bool = false) async throws -> Gated<ModelView> {
        guard commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw LiftError.invalidInput([FieldError("commit", "must be a full 40-character sha")])
        }
        guard catalog.entries[id] != nil else { throw LiftError.notFound("recipe \(id)") }
        guard confirm else { return .confirmationRequired("Pins \(id) to \(commit) and reinstalls it at that commit.") }
        var s = settings
        s.pinOverrides[id] = commit
        try saveSettings(s)
        return try await modelsInstall(id, confirm: true, wait: wait)
    }

    public func modelsCheckUpstream(_ id: String) async throws -> UpstreamStatus {
        guard let recipe = recipe(id) else { throw LiftError.notFound("model \(id)") }
        return try await installer.checkUpstream(recipe, pin: settings.pinOverrides[id])
    }

    /// Removes `models/<id>/` only. Weights in the shared Hugging Face cache are never deleted: Lift
    /// doesn't delete files it didn't create, and the cache is shared with other tools.
    public func modelsUninstall(_ id: String, confirm: Bool = false) throws -> Gated<ModelView?> {
        guard let recipe = recipe(id) else { throw LiftError.notFound("model \(id)") }
        guard installing[id] == nil else { throw LiftError.invalidState("\(id) is installing") }
        guard confirm else {
            return .confirmationRequired("Removes \(recipe.name)'s repo and environment (models/\(id)). Downloaded weights stay in the Hugging Face cache.")
        }
        try stopWorkers(of: id)
        try installer.uninstall(id)
        weightReports[id] = nil
        verifiedForStart.remove(id)
        rescan()
        tick()
        return .done(try? modelView(id))
    }

    public func modelsInstallLog(_ id: String) throws -> String {
        guard let text = try? String(contentsOf: installer.logURL(id), encoding: .utf8) else { throw LiftError.notFound("install log for \(id)") }
        return text
    }

    /// Model changes need its workers gone; a busy one is an error (cancel its jobs first).
    func stopWorkers(of id: String) throws {
        let mine = workers.values.filter { $0.recipe.id == id }
        if mine.contains(where: { !$0.assigned.isEmpty }) { throw LiftError.invalidState("\(id) has running jobs; cancel them first") }
        for w in mine { stop(w) }
    }

    // MARK: recipes

    public func recipesListSources() -> RecipeSourcesView {
        RecipeSourcesView(
            sources: sourceDirs.map { s in
                let url = settings.recipeSources.first { $0.name == s.name }?.url ?? s.dir.path
                return .init(name: s.name, url: url, stale: staleSources.contains(s.name),
                             recipes: catalog.entries.values.filter { $0.source == s.name }.map(\.recipe.id).sorted())
            },
            problems: catalog.problems, bundle: bundleSync)
    }

    public func recipesAddSource(_ url: String, confirm: Bool = false) async throws -> Gated<RecipeSourcesView> {
        guard !url.isEmpty else { throw LiftError.invalidInput([FieldError("url", "required")]) }
        guard !settings.recipeSources.contains(where: { $0.url == url }) else { throw LiftError.invalidState("source \(url) is already added") }
        guard confirm else { return .confirmationRequired("Clones \(url) into recipes/ and lists its recipes. Recipes run code from that repo on this Mac.") }
        guard let git = tools.git else { throw LiftError.prerequisite("git is required; run system_install_prereqs") }
        let name = RecipeSources.name(for: url, taken: Set(settings.recipeSources.map(\.name) + ["bundled", "bundled-local"]))
        try await RecipeSources(runner: config.runner, root: recipesDir, git: git, environment: toolchain.environment).clone(url: url, name: name)
        var s = settings
        s.recipeSources.append(RecipeSourceRef(name: name, url: url))
        try saveSettings(s)
        rescan()
        tick()
        return .done(recipesListSources())
    }

    public func recipesRemoveSource(_ name: String, confirm: Bool = false) throws -> Gated<RecipeSourcesView> {
        guard settings.recipeSources.contains(where: { $0.name == name }) else { throw LiftError.notFound("source \(name)") }
        guard confirm else { return .confirmationRequired("Removes recipe source \(name) and its folder. Installed models stay installed.") }
        try? FileManager.default.removeItem(at: recipesDir.appending(path: name))
        var s = settings
        s.recipeSources.removeAll { $0.name == name }
        try saveSettings(s)
        staleSources.remove(name)
        rescan()
        tick()
        return .done(recipesListSources())
    }

    /// Pulls each git source (or just `name`). A failed pull marks the source stale and keeps its last good recipes.
    public func recipesRefresh(_ name: String? = nil) async throws -> RecipeSourcesView {
        guard let git = tools.git else { throw LiftError.prerequisite("git is required; run system_install_prereqs") }
        let sources = RecipeSources(runner: config.runner, root: recipesDir, git: git, environment: toolchain.environment)
        for ref in settings.recipeSources where name == nil || ref.name == name {
            if await sources.pull(name: ref.name) { staleSources.remove(ref.name) } else { staleSources.insert(ref.name) }
        }
        rescan()
        tick()
        return recipesListSources()
    }
}
```

`Sources/LiftCore/Commands/SystemCommands.swift`:
```swift
import Foundation
import GRDB

public struct WorkerView: Codable, Sendable, Equatable {
    public var id: String
    public var recipe: String
    public var pid: Int32
    public var ready: Bool
    public var jobs: [String]
    public var maxConcurrent: Int
    public var footprintBytes: Int
    public var reservedBytes: Int
}

public struct EstimateView: Codable, Sendable, Equatable {
    public var recipe: String
    public var task: String
    public var keyValues: String
    /// Learned peaks (max of the last 5); nil until sampled.
    public var loadBytes: Int?
    public var jobBytes: Int?
}

public struct ResourcesView: Codable, Sendable, Equatable {
    public var maxSlots: Int
    public var budgetBytes: Int
    public var reservedBytes: Int
    public var systemFreeBytes: Int
    public var workers: [WorkerView]
    public var estimates: [EstimateView]
}

extension Lift {
    // MARK: workers and resources

    public func workersList() -> [WorkerView] {
        workers.values.sorted { $0.id < $1.id }.map {
            WorkerView(id: $0.id, recipe: $0.recipe.id, pid: $0.pid, ready: $0.ready, jobs: $0.assigned.keys.sorted(),
                       maxConcurrent: $0.capacity, footprintBytes: $0.lastFootprint, reservedBytes: $0.reserved)
        }
    }

    /// Starts a worker ahead of time. The caller decides; no budget check. Weights are verified first.
    public func workersLoad(_ recipe: String) async throws -> WorkerView {
        guard let r = installed[recipe] else { throw LiftError.invalidState("\(recipe) is not installed") }
        if !r.weights.isEmpty {
            let report = try await modelsVerifyWeights(recipe)
            guard report.state == .ok else {
                throw LiftError.invalidState("\(recipe)'s weights are \(report.state.rawValue): " + report.problems.map(\.path).joined(separator: ", "))
            }
        }
        let need = try await store.db.read { try Estimates.need($0, recipe: r, task: r.tasks[0].id, settings: [:]) }
        let w = spawn(r, baseline: need.load)
        w.idleSince = .now
        return workersList().first { $0.id == w.id }!
    }

    /// Stops a worker. A busy one needs `confirm`; its running steps fail.
    public func workersUnload(_ id: String, confirm: Bool = false) throws -> Gated<[WorkerView]> {
        guard let w = workers[id] else { throw LiftError.notFound("worker \(id)") }
        if w.assigned.isEmpty {
            stop(w)
        } else {
            guard confirm else { return .confirmationRequired("Worker \(id) is running \(w.assigned.count) job(s); unloading fails them.") }
            w.process.kill()  // not `stopping`: its exit fails the running steps
        }
        return .done(workersList())
    }

    public func resourcesGet() throws -> ResourcesView {
        let estimates = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT recipe, task, keyValues FROM memorySample ORDER BY recipe, task, keyValues").map { row in
                let (recipe, task, keys): (String, String, String) = (row["recipe"], row["task"], row["keyValues"])
                return EstimateView(recipe: recipe, task: task, keyValues: keys,
                                    loadBytes: try Estimates.learned(db, recipe: recipe, task: task, keyValues: keys, kind: .load),
                                    jobBytes: try Estimates.learned(db, recipe: recipe, task: task, keyValues: keys, kind: .job))
            }
        }
        return ResourcesView(maxSlots: settings.maxSlots, budgetBytes: settings.memoryBudgetBytes,
                             reservedBytes: workers.values.reduce(0) { $0 + $1.reserved }, systemFreeBytes: config.systemFree(),
                             workers: workersList(), estimates: estimates)
    }

    public func resourcesSet(maxSlots: Int? = nil, memoryBudgetGB: Double? = nil, idleUnloadMinutes: Double? = nil) throws -> Settings {
        var s = settings
        if let maxSlots { s = try s.setting("max_slots", to: .int(maxSlots)) }
        if let memoryBudgetGB { s = try s.setting("memory_budget_gb", to: .float(memoryBudgetGB)) }
        if let idleUnloadMinutes { s = try s.setting("idle_unload_minutes", to: .float(idleUnloadMinutes)) }
        try saveSettings(s)
        tick()
        return s
    }

    // MARK: settings

    public func settingsGet() -> Settings { settings }

    public func settingsSet(_ key: String, _ value: SettingValue) throws -> Settings {
        let s = try settings.setting(key, to: value)
        try saveSettings(s)
        if key == "dev_recipes" { rescan() }
        tick()
        return s
    }

    // MARK: system

    public func systemPrereqs(checkMetal: Bool = false) async -> Prereqs {
        tools = await toolchain.detect()
        return Prereqs(tools: tools, metalToolchain: checkMetal ? await toolchain.metalToolchainInstalled() : nil)
    }

    /// Installs what's missing: native Homebrew (one administrator dialog, spec §6), then
    /// `brew install git uv` with it, and the Metal Toolchain when `metal` is set. Output streams to `onLine`.
    public func systemInstallPrereqs(metal: Bool = false, confirm: Bool = false,
                                     onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Gated<Prereqs> {
        let now = await systemPrereqs(checkMetal: metal)
        var plan: [String] = []
        if now.tools.brew == nil {
            var step = "install native Homebrew in \(toolchain.homebrewPrefix) (one administrator dialog)"
            if let rosetta = now.tools.rosettaBrew { step += "; the Intel Homebrew at \(rosetta) is left as it is" }
            plan.append(step)
        }
        let formulae = [("git", now.tools.git), ("uv", now.tools.uv)].filter { $0.1 == nil }.map(\.0)
        if !formulae.isEmpty { plan.append("brew install \(formulae.joined(separator: " "))") }
        if metal && now.metalToolchain == false { plan.append("xcodebuild -downloadComponent MetalToolchain") }
        guard !plan.isEmpty else { return .done(now) }
        guard confirm else { return .confirmationRequired("Will " + plan.joined(separator: ", then ") + ".") }
        if now.tools.brew == nil {
            guard let git = now.tools.git else {
                throw LiftError.prerequisite("installing Homebrew needs git: install the Xcode Command Line Tools (xcode-select --install)")
            }
            try await toolchain.installHomebrew(git: git, onLine: onLine)
        }
        if !formulae.isEmpty { try await toolchain.brewInstall(formulae, onLine: onLine) }
        if metal && now.metalToolchain == false { try await toolchain.installMetalToolchain(onLine: onLine) }
        return .done(await systemPrereqs(checkMetal: metal))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter CommandTests`
Expected: `✔ Test run with 6 tests in 1 suite passed`. `riskyCommandsChangeNothingWithoutConfirm` also checks that `FakeRunner` recorded no commands. In `jobsWaitForVerifiedWeights`, the job waits `weights_unverified` until the test writes the file into the temp HF cache and verifies.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Commands Tests/LiftCoreTests/CommandTests.swift
git commit -m "feat(core): model (incl. weights download/verify), recipe, worker, resource, settings and system commands

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 13: Test Cube integration (real install, real workers)

**Files:**
- Test: `Tests/LiftCoreTests/CubeIntegrationTests.swift`

**Interfaces:**
- Consumes: every public command (Tasks 11–12), `dev-recipes/test-cube` (Task 9), `python/lift_worker` (Task 2), `dev-recipes/shared/lift_shim` (Plan 0) and `FakeMetadata` (Task 8).
- Produces: nothing new. This task proves the pieces work together. If a test fails, fix the engine code, not the assertion, and say in the commit message what changed.

- [ ] **Step 1: Write the integration tests**

`Tests/LiftCoreTests/CubeIntegrationTests.swift`. One `Lift` per suite installs Test Cube for real: a uv venv, `trimesh` and `numpy`, and `lift_shim` with its `.pth`, all in a temp workdir. That's the product path for this recipe, with no Homebrew and no weights. The tests then run against live workers:
```swift
import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// One real Lift with Test Cube installed (uv venv + trimesh + lift_shim), shared by the suite.
actor CubeFixture {
    static let shared = CubeFixture()
    private var lift: Lift?

    func get() async throws -> Lift {
        if let lift { return lift }
        // Real uv, git and Python; no Homebrew, a temp Hugging Face cache and fake weights metadata
        // (the Test Cube has no weights, and nothing in the tests may download any).
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime, bundledRecipes: Fixtures.devRecipes,
                                                  homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                                  housekeepingInterval: .milliseconds(200), heartbeatSeconds: 0.2,
                                                  hfToken: { nil }, hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        let model = try await lift.modelsInstall("test-cube", confirm: true, wait: true).value
        guard case .installed = model?.status else {
            throw LiftError.invalidState("test-cube install failed: \(String(describing: model?.status))\n\((try? await lift.modelsInstallLog("test-cube")) ?? "")")
        }
        self.lift = lift
        return lift
    }
}

@Suite(.serialized, .timeLimit(.minutes(10))) struct CubeIntegrationTests {
    func cube(_ settings: [String: SettingValue] = [:]) throws -> StepRequest {
        // A space and non-ASCII in the name: paths travel through JSON, the shell is never involved.
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image(named: "my photo é.png")], settings: settings)
    }

    func run(_ lift: Lift, _ steps: [StepRequest]) async throws -> JobView {
        let id = try await lift.jobsSubmit(SubmitRequest(steps: steps)).job.id
        return try await lift.jobsWait(id, timeout: .seconds(120))
    }

    @Test func installsAndLists() async throws {
        let lift = try await CubeFixture.shared.get()
        let model = try await lift.modelsGet("test-cube")
        #expect(model.status == .installed(commit: nil))
        #expect((model.diskBytes ?? 0) > 0)
        #expect(try await lift.modelsInstallLog("test-cube").contains("installed test-cube"))
    }

    @Test func submitWaitSucceeds() async throws {
        let lift = try await CubeFixture.shared.get()
        let seen = Mutex<Set<JobState>>([])
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["size": .float(2)])])).job.id
        let v = try await lift.jobsWait(id, timeout: .seconds(120)) { v in _ = seen.withLock { $0.insert(v.job.state) } }
        #expect(v.job.state == .succeeded)
        let glb = try #require(v.outputs.first)
        #expect(glb.hasSuffix("/steps/0/cube.glb"))
        #expect(try Data(contentsOf: URL(filePath: glb)).prefix(4) == Data("glTF".utf8))
        #expect(v.steps[0].stage == "Generating" && v.steps[0].fraction == 1)
        #expect(seen.withLock { $0.contains(.running) })
        let log = try String(contentsOf: lift.config.workdir.appending(path: "jobs/\(id)/log.txt"), encoding: .utf8)
        #expect(log.contains("[Stage] Generating"))
        #expect(log.contains("shim env: on"))  // lift_shim + .pth + LIFT_SHIM reached the worker
    }

    @Test func chainedStepsPassOutputs() async throws {
        let lift = try await CubeFixture.shared.get()
        let v = try await run(lift, [try cube(), StepRequest(recipe: "test-cube", task: "fake_rig")])
        #expect(v.job.state == .succeeded)
        #expect(v.steps[1].inputs["mesh"] == v.steps[0].outputs.first)
        #expect(v.outputs.first?.hasSuffix("/steps/1/rigged.glb") == true)
    }

    @Test func failedJobKeepsTheWorker() async throws {
        let lift = try await CubeFixture.shared.get()
        let failed = try await run(lift, [try cube(["fail": .bool(true)])])
        #expect(failed.job.state == .failed && failed.job.error?.contains("failed on purpose") == true)
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func crashFailsTheStepAndTheNextJobStillRuns() async throws {
        let lift = try await CubeFixture.shared.get()
        let crashed = try await run(lift, [try cube(["crash": .bool(true)])])
        #expect(crashed.job.state == .failed)
        #expect(crashed.job.error?.contains("exited with code 3") == true)
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func cancelRunningStopsTheWorker() async throws {
        let lift = try await CubeFixture.shared.get()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["delay": .float(60)])])).job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .running })
        #expect(try await lift.jobsCancel(id).impact != nil)
        #expect(try await lift.jobsCancel(id, confirm: true).value?.job.state == .cancelled)
        #expect(try await eventually(5) { await lift.workersList().allSatisfy { !$0.jobs.contains(id) } })
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func learnsMemoryEstimates() async throws {
        let lift = try await CubeFixture.shared.get()
        _ = try await run(lift, [try cube()])
        let e = try await lift.resourcesGet().estimates.first { $0.recipe == "test-cube" && $0.task == "image_to_3d" }
        #expect((e?.loadBytes ?? 0) > 1_000_000)
        #expect(e?.jobBytes != nil)
    }

    @Test func idleWorkersAreUnloaded() async throws {
        let lift = try await CubeFixture.shared.get()
        _ = try await run(lift, [try cube()])
        _ = try await lift.resourcesSet(idleUnloadMinutes: 0.01)
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
        _ = try await lift.resourcesSet(idleUnloadMinutes: 10)
    }

    @Test func workersLoadAndUnload() async throws {
        let lift = try await CubeFixture.shared.get()
        for w in await lift.workersList() { _ = try await lift.workersUnload(w.id) }
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
        let w = try await lift.workersLoad("test-cube")
        #expect(try await eventually { await lift.workersList().first { $0.id == w.id }?.ready == true })
        #expect(try await lift.workersUnload(w.id).value != nil)
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter CubeIntegrationTests`
Expected: `✔ Test run with 9 tests in 1 suite passed`. The first run downloads `trimesh`, `numpy` and `hatchling` through uv (network needed; seconds when the uv cache is warm). If the install fails, the thrown error carries `install.log`, so read it first.

- [ ] **Step 3: Run everything**

Run: `swift test && (cd python/lift_worker && uv run --python 3.11 pytest -q) && (cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest -q)`
Expected: `✔ Test run with 107 tests in 17 suites passed`, `22 passed`, and all `lift_shim` tests passing.

- [ ] **Step 4: Commit**

```bash
git add Tests/LiftCoreTests/CubeIntegrationTests.swift
git commit -m "test(core): Test Cube integration — install, shim, run, chain, fail, crash, cancel, estimates, idle unload

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 14: Test CI workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: the commands from Tasks 1–13.
- Produces: a `test` workflow on push and pull request. It builds LiftCore, runs every Swift test (unit plus Test Cube integration, with no real models and no weights), runs pytest for `lift_shim` and `lift_worker`, and uploads `test-results/`. Plan 3 adds `xcodebuild build` of the app and `lift-mcp` (spec §14) once they exist.

- [ ] **Step 1: Write the workflow**

`.github/workflows/test.yml`. The runner label comes from the repository variable `MACOS_RUNNER` and falls back to `macos-26`. If GitHub doesn't offer `macos-26` to this repo, set the variable to `macos-latest`. GitHub Actions has no automatic fallback between runner labels: a job with an unknown label just waits in the queue.
```yaml
name: test

on:
  push:
  pull_request:

jobs:
  test:
    # Xcode 26 / Swift 6.2+ image. If macos-26 isn't available to this repo, set the repository
    # variable MACOS_RUNNER to macos-latest (Settings → Secrets and variables → Actions → Variables).
    runs-on: ${{ vars.MACOS_RUNNER || 'macos-26' }}
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: Toolchain versions
        run: |
          sw_vers
          xcodebuild -version
          swift --version

      - uses: astral-sh/setup-uv@v6
        with:
          enable-cache: true

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-

      - name: Resolve packages
        run: swift package resolve

      - name: Build
        run: swift build --build-tests

      - name: Swift tests (unit + Test Cube integration; no real models)
        run: |
          mkdir -p test-results
          swift test --skip-build --xunit-output test-results/swift.xml

      - name: lift_shim tests
        working-directory: dev-recipes/shared/lift_shim
        run: uv run --python 3.11 pytest -q --junitxml=../../../test-results/lift_shim.xml

      - name: lift_worker tests
        working-directory: python/lift_worker
        run: uv run --python 3.11 pytest -q --junitxml=../../test-results/lift_worker.xml

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: test-results/
```

- [ ] **Step 2: Lint it and run its commands locally**

Run: `actionlint .github/workflows/test.yml` if actionlint is already installed (don't install it: no manual prerequisite installs), then:
```bash
swift package resolve && swift build --build-tests \
  && mkdir -p test-results && swift test --skip-build --xunit-output test-results/swift.xml \
  && (cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest -q --junitxml=../../../test-results/lift_shim.xml) \
  && (cd python/lift_worker && uv run --python 3.11 pytest -q --junitxml=../../test-results/lift_worker.xml) \
  && ls test-results
```
Expected: actionlint, if run, prints nothing. The tests pass as in Task 13, and `test-results/` holds `swift-swift-testing.xml`, `lift_shim.xml` and `lift_worker.xml`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: test workflow — Swift build/tests, Test Cube integration, pytest for lift_shim and lift_worker

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

- [ ] **Step 4: Report**

Tell the user that the workflow runs on the next push (nothing is pushed by this plan) and how to set `MACOS_RUNNER`. Also list the "Schema and protocol decisions" at the top of this plan so they can be folded into the spec.
