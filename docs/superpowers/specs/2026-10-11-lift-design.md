# Lift — design spec

Date: 2026-10-11 · Status: draft for review · UI mockups: https://claude.ai/artifact/XAQQaC4Q1affNUpYweUHWr

## 1. Purpose

Lift is a native macOS app that makes open-source generative-model projects easy to use locally. It
clones each upstream project at a pinned commit, builds its environment, runs the project's own Python
code unmodified, and gives you a queue, a UI, an HTTP API and an MCP server around it.

Version 1 ships 3D only (image → 3D, multi-view → 3D, rigging). The recipe format, UI, API and MCP are
built for any modality (image, video, audio) so later projects need only a recipe.

### Principles

1. **Never edit upstream code.** Lift clones, installs, invokes and observes. Any Mac compatibility work
   happens at runtime, outside the cloned repo.
2. **Lift executes; the caller decides.** The app never chooses a model, settings or ordering on its own.
   The UI user or the calling LLM (through MCP or HTTP) decides; Lift does exactly what it is told and
   reports facts (state, resources, warnings).
3. **One command layer.** UI, HTTP and MCP are three front ends over the same commands, with full parity.
4. **Use packages, don't reinvent.** An established package is preferred for every operation.

## 2. Scope

### v1

- Native SwiftUI app, macOS 26+, Apple Silicon only, personal build (Xcode-signed, not notarized, no App Sandbox).
- Recipes: **Pixal3D** (image→3D), **Pixal3D multi-view** (multi-view→3D), **UniRig** (mesh→rigged),
  **TRELLIS.2 via trellis-mac** (image→3D), **Test Cube** (fake, for tests).
- Persistent job queue (SQLite) with parallel slots, a memory budget, priorities and manual reordering.
- Multi-step jobs (e.g. Pixal3D → UniRig).
- Export formats: GLB always, plus USDZ, FBX and OBJ, chosen by the user per job.
- HTTP API with an OpenAPI spec and a `/docs` page; MCP over Streamable HTTP, plus a `lift-mcp` stdio bridge.
- Optional LAN access with a bearer token.
- macOS notifications.
- GitHub Actions: a test workflow, and a release workflow that tags and publishes a GitHub Release (§14).

### Not in v1

Image, video and audio recipes (their tabs and viewers are present and show empty states), webhooks,
input by URL, CORS, the server-sent events stream, sound on finish, and notarized distribution.

## 3. Architecture

```
Lift.app (Swift 6, SwiftUI)
├─ LiftCore            (Swift package, no UI)
│   ├─ Recipes         load/validate recipe manifests; recipe sources (bundled + git URLs)
│   ├─ Toolchain       Homebrew / git / uv detection + install
│   ├─ Installer       clone pinned commit → uv venv → install steps → shim → verify
│   ├─ Store           GRDB/SQLite: jobs, steps, events, workers, memory samples, settings
│   ├─ Scheduler       slots + memory budget + priority/FIFO/manual order → start decisions
│   ├─ Workers         spawn/talk to Python worker processes (JSON lines), idle unload
│   ├─ Resources       system memory, per-process footprint, learned estimates
│   ├─ Exporter        format conversion, export dir copy, post-export cleanup
│   └─ Commands        the single command layer (typed requests/responses)
├─ LiftServer          Hummingbird 2: /v1 (generated from openapi.yaml), /docs, /mcp
├─ LiftUI              SwiftUI screens (see the mockups)
└─ lift-mcp            stdio ↔ HTTP MCP bridge (command-line tool in the app bundle)

<workdir>/                                     (one folder chosen at first launch, see §11)
├─ lift.sqlite
├─ recipes/<source>/                           git clone of each recipe source
│   ├─ <recipe-id>/{recipe.yaml,launcher.py,files/}
│   └─ shared/{substitutes.yaml,lift_shim/}    shared Mac shim + substitute registry
├─ models/<recipe-id>/{repo,venv,install.log}
└─ jobs/<job-id>/{inputs/,steps/<n>/,outputs/,log.txt}
<export dir>/                                  chosen separately at first launch
```

The app bundle contains no recipes. It ships only `lift_worker`, the Python runtime for the worker
protocol (§8). That's versioned with the app because the protocol is the app's contract.

### Packages

| Need | Package |
|---|---|
| HTTP server | hummingbird 2 |
| OpenAPI server stubs + `/openapi.json` | swift-openapi-generator + swift-openapi-runtime + swift-openapi-hummingbird |
| MCP server (Streamable HTTP, stdio) | modelcontextprotocol/swift-sdk |
| SQLite, migrations, observation | GRDB |
| Running processes (git, uv, brew, workers) | swiftlang/swift-subprocess |
| Keychain (LAN token, HF token) | KeychainAccess |
| Recipe manifests | Yams (YAML) |
| GLB preview | GLTFKit2 |
| CLI for `lift-mcp` | swift-argument-parser |
| Logging | swift-log |
| Launch at login | ServiceManagement (system) |
| Notifications | UserNotifications (system) |
| USDZ / OBJ export | ModelIO (system) and Blender's `bpy` from the UniRig venv for FBX (see §9) |
| API docs page | bundled Redoc standalone build |
| Python side | uv, pytest; trimesh for the Test Cube |

## 4. Recipes

A recipe is a folder: `recipe.yaml`, `launcher.py`, optional `files/`. Recipes are not part of the app.
They live in **recipe sources**: git repos cloned into `<workdir>/recipes/<source>/`.

- **Default source:** the public repo `oshricohenme/lift-recipes`, open to community contributions. It
  holds the v1 recipes plus `shared/` (the `lift_shim` package and `substitutes.yaml`, so contributors can
  extend Mac support without an app release). It's cloned at first launch.
- **More sources:** any git URL (`recipes_add_source`). If two sources define the same recipe id, the one
  added first wins, and the clash is shown as a warning.
- **Updates:** a source is pulled only when you click Refresh or call `recipes_refresh`. Installed models
  keep their pinned upstream commit; a refreshed recipe that changes the pin shows "update available"
  and reinstalls only when you say so.
- **Compatibility:** a recipe with `schema` newer than the app supports is listed as "needs a newer Lift" and can't be installed.
- **Test Cube** lives in the dev recipe source (`dev-recipes/test-cube`, see below), loaded only by the
  test suite and by a hidden developer setting. It is not in the public source.

### `recipe.yaml` (schema v1)

```yaml
schema: 1
id: pixal3d
name: Pixal3D
publisher: TencentARC
license: MIT
homepage: https://github.com/TencentARC/Pixal3D
repo: https://github.com/TencentARC/Pixal3D
commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94
python: "3.11"
platform:
  status: supported | unsupported      # set from the go/no-go test; unsupported carries a reason
  reason: ""
install:                               # run in models/<id>/ with venv active; each step logged
  - uv pip install torch torchvision
  - uv pip install -r repo/requirements.txt
  - uv pip install https://github.com/LDYang694/Storages/releases/download/20260430/utils3d-0.0.2-py3-none-any.whl
substitutes: [flex_gemm, nvdiffrast, o_voxel, cumesh, flash_attn]   # from the shared registry (§5)
weights:                               # shown to the user before install; downloaded lazily by upstream
  - { repo: TencentARC/Pixal3D, gated: false }
  - { repo: Ruicheng/moge-2-vitl, gated: false }
  - { repo: camenduru/dinov3-vitl16-pretrain-lvd1689m, gated: false }
resources:
  memory_gb: 18                        # starting estimate
  memory_keys: [low_vram, resolution]  # settings that change memory; learned per combination
  memory_overrides: [{ when: { low_vram: true }, memory_gb: 12 }]
  max_concurrent_per_process: 1        # >1 only once verified safe (see §8)
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: inference:run_inference     # module:function inside repo/
    settings:
      - { key: resolution, label: Resolution, type: enum, options: [1024, 1536], default: 1536, group: basic }
      - { key: low_vram, label: Low memory mode, type: bool, default: false, group: basic, help: "..." }
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: manual_fov, label: Camera FOV, type: float, default: -1.0, help: "radians; <0 = auto (MoGe-2)", group: basic }
      - { key: ss_sampling_steps, label: Sparse structure steps, type: int, min: 1, max: 50, default: 12, group: advanced }
      # … every keyword argument of run_inference, with upstream defaults
```

- **Input types:** `text`, `image`, `image_set` (multi-view), `mesh`, `video`, `audio`. **Output types:** `mesh`, `rigged_mesh`, `image`, `video`, `audio`.
- **Modality** groups tasks into the UI tabs (3D, Image, Video, Audio).
- **Settings** generate the UI form and validate HTTP/MCP input. Types: `int`, `float`, `bool`, `enum`,
  `string`, `path`, with `min`/`max`/`options`/`default`/`help`/`group`.
- A step can follow another when its first input type matches the previous step's output type
  (`mesh` and `rigged_mesh` are both accepted where `mesh` is required).

### v1 recipes

| Recipe | Pin | Tasks | Entry |
|---|---|---|---|
| pixal3d | TencentARC/Pixal3D `f7cf384` | image→mesh | `inference.run_inference` |
| pixal3d (same recipe) | same | image_set→mesh | `inference_mv` main path, `pipeline_mv.json` weights |
| unirig | VAST-AI-Research/UniRig `6793c66` | mesh→rigged_mesh | `launch/inference/generate_skeleton.sh` → `generate_skin.sh` → `merge.sh` (run as subprocesses from the worker) |
| trellis2-mac | shivampkumar/trellis-mac `d58628f` (MIT), which brings microsoft/TRELLIS.2 pinned at `75fbf01` | image→mesh | `generate.py <image> --seed --output --pipeline-type {512,1024,1024_cascade} --texture-size {512,1024,2048} [--no-texture]` |
| test-cube | dev-recipes/ in this repo | image→mesh | `cube.generate` (writes a cube GLB; options: size, delay, fail) |

**trellis2-mac** is an existing Mac port, so it uses no `lift_shim`. Its install steps are:
1. Clone trellis-mac at its pin.
2. Clone TRELLIS.2 at `75fbf01` into `repo/TRELLIS.2`. trellis-mac's `setup.sh` skips its own unpinned
   clone when that folder exists.
3. Run `setup.sh` unchanged. It needs the Metal Toolchain, and Hugging Face access to the gated
   `facebook/dinov3-vitl16-pretrain-lvd1689m` and `briaai/RMBG-2.0`.

Its launcher keeps the loaded pipeline between jobs by importing `generate.py`'s functions, not by running a new process per job.

**Dev recipe source:** `dev-recipes/` in this app repo holds `pixal3d`, `trellis2-mac` and `test-cube`. A
developer setting (`LIFT_DEV_RECIPES=1` or Settings → Developer) adds it as a local source, so
development and tests don't depend on the public `lift-recipes` repo. The public repo is created later
from the same folders.

Multi-view input (`image_set`) accepts any of: a 4-view preset (front/right/back/left slots; Lift writes the
upstream example `transforms.json` with your file names), a folder that already contains
`transforms.json`, or N images plus an orbit (count, elevation, FOV), for which Lift writes evenly spaced cameras.

## 5. Mac compatibility shim (`lift_shim`)

A Python package that Lift installs into every model venv. The launcher imports it before anything
upstream, and only when `torch.cuda.is_available()` is false:

- **Device redirection:** `torch.Tensor.cuda`, `nn.Module.cuda`, `.to("cuda"…)`, `torch.device("cuda")`,
  `device="cuda"` arguments of tensor factories, `torch.cuda.is_available/empty_cache/synchronize/
  manual_seed/current_device`, and `torch.autocast("cuda")` are all redirected to `mps`.
- **Environment:** `PYTORCH_ENABLE_MPS_FALLBACK=1`, `ATTN_BACKEND=sdpa`, `SPARSE_ATTN_BACKEND=sdpa`.
- **Substitute registry** (`substitutes.yaml` in Lift): maps each CUDA-only package to an Apple Silicon
  replacement, installed when a recipe lists it:

  | CUDA package | Substitute |
  |---|---|
  | flex_gemm | `mtlgemm` (pedronaugusto) |
  | nvdiffrast | `mtldiffrast` (pedronaugusto) |
  | o_voxel | o_voxel from `pedronaugusto/trellis2-apple` |
  | cumesh | stand-in that does nothing (hole filling skipped, as in trellis-mac) |
  | flash_attn / xformers | stand-in that calls `torch.nn.functional.scaled_dot_product_attention` |
  | spconv, torch_scatter, torch_cluster | CPU/MPS builds where they exist (go/no-go test decides) |

- The registry grows as recipes are added. Building the Metal substitutes needs `xcodebuild -downloadComponent MetalToolchain`.

**Go/no-go test (first milestone):** run Pixal3D, Pixal3D-MV and UniRig through the shim, and trellis2-mac as is, on this
Mac. Record pass/fail, wall time, peak memory, and whether two jobs can run concurrently in one process.
A failure marks that recipe `platform.status: unsupported` with the reason. It ships disabled and
everything else is still built.

## 6. Toolchain and model lifecycle

**At launch (Toolchain):** detect `brew`, `git`, `uv` and the Metal Toolchain.
- **Native Homebrew only.** Lift uses `/opt/homebrew/bin/brew` (arm64). An Intel/Rosetta Homebrew in
  `/usr/local` is detected and never used for native libraries: its packages are x86_64 and can't be
  loaded by arm64 Python (found on the dev machine: `open3d` couldn't load an x86_64 `libusb`).
- If only the Rosetta Homebrew exists, the setup screen offers to install native Homebrew alongside it.
- Recipes can declare `brew: [libusb, …]`. These are installed with the native brew, and its `lib/` is
  added to the worker's `DYLD_FALLBACK_LIBRARY_PATH`.
- If `brew` is missing, a setup screen offers **Install Homebrew**. That runs the official install script
  with a live log; macOS asks for your admin password.
- If `git` or `uv` is missing, the app runs `brew install git uv` with a live log.
- The Metal Toolchain is checked only when a recipe needs it, and then offered as a one-click install.

**Install a model:** prerequisite checks (toolchain, free disk, gated weights → HF token present) →
`git clone --filter=blob:none` + `checkout <commit>` → `uv venv --python <python>` → `install` steps →
substitutes → `lift_shim` + `launcher.py` → a smoke import. Each step is logged to `install.log` and
streamed live. Any failure leaves the model `install_failed` with the log kept; a partial install never
counts as installed.

**Weights: you start the download; Lift verifies it.**
- Lift never downloads weights on its own. Each recipe's `weights:` list (repo and optional revision) is
  shown with its total size, and **Download** (UI) or `models_download_weights` (MCP/HTTP, confirm
  needed) starts it explicitly, using `hf download` from the model's venv into the shared HF cache.
- You can also download weights yourself outside Lift.
- **`models_verify_weights`** runs before every worker start, and on demand. For each repo it gets the
  file list with LFS SHA-256 hashes and sizes from the Hugging Face API, checks every file exists in the
  local cache at that revision, checks sizes, and hashes the LFS files. Hashes are cached per file
  (path, size, mtime), so later checks are fast.
- Missing or corrupt files mark the model `weights_missing` or `weights_corrupt`, listing each bad file,
  and block its jobs with waiting reason `weights_unverified`. If Lift is offline, it falls back to the
  last successful check (and says so).

**Re-clone** happens only on install, reinstall or a pin change. **Check upstream** runs `git ls-remote`
and reports how far upstream has moved past the pin. **Change pin** reinstalls at the new commit.
**Uninstall** removes `models/<id>/`; weights in the shared HF cache are kept unless you choose
"also delete weights", which lists the cached repos it will remove.

## 7. Jobs, steps and the queue

- A **job** is an ordered list of **steps**. A step is `{recipe, task, inputs, settings}`. The input of
  step 2 onward is the previous step's output, unless given explicitly.
- Job fields: id, title, priority (`low|normal|high`), position (manual order), source (`ui|http|mcp`),
  `export: {dir, formats[], cleanup_after_export}`, `force_start`, timestamps, state.
- **States** (job and step): `queued → waiting(reason) → loading → running → succeeded | failed | cancelled | interrupted`.
  `waiting` reasons are facts: `no_free_slot`, `memory {needed, free}`, `model_installing`, `model_not_installed`, `model_unsupported`, `weights_unverified`, `queue_paused`.
- **Ordering:** highest priority first, then manual position, then submission time (FIFO). Moving a job
  sets its position. No reordering by model warmth.
- **Persistence:** everything lives in SQLite (GRDB migrations). Inputs are copied into `jobs/<id>/inputs/` when the job is submitted.
- **Relaunch after a crash or quit:** jobs found in `loading/running` are set to `interrupted`. A sheet
  on launch lists them with **Re-queue all / Discard / Decide later**, and MCP/HTTP have `jobs.resolve_interrupted`.
  Restarts begin from the step that was interrupted; finished steps are kept.
- **Retention:** kept forever; deleted only by you (UI, HTTP, MCP).
- **Export:** after the final step succeeds, outputs are converted to the requested formats and copied to
  `export.dir` (default chosen at first launch) as `<title>.<ext>`. If `cleanup_after_export` is on, the job's
  files are deleted after a verified copy, and the job record stays with `cleaned_up: true`.

## 8. Scheduler, workers and resources

**Settings:** `max_slots` (default 1), `memory_budget_gb` (default 48), `idle_unload_minutes` (default 10).

**A slot** is one running step. The scheduler runs on every state change and starts the next eligible
step when all of these hold:
1. A slot is free.
2. The step's memory estimate fits: `estimate ≤ budget − reserved_by_running_and_loaded_workers`.
3. Actual system free memory is above the estimate (to catch other apps using memory).

Condition 3 uses `host_statistics64` free + inactive pages.

**Over budget:** the step goes to `waiting(memory, needed, free)`, which shows in the UI, `get_job` and
notifications. `jobs.force_start` (with confirm) skips conditions 2 and 3 but not 1.

**Workers:** each worker is one Python process for one recipe that keeps its model loaded.
- If an idle worker for the recipe exists and `max_concurrent_per_process` allows it, the step goes there
  and only its per-job working memory is added (learned).
- Otherwise a new worker (a new loaded copy) is started, if it fits in the budget.
- A worker with no jobs for `idle_unload_minutes` is stopped. MCP/HTTP/UI can also load a worker ahead
  of time (`workers.load`) or unload one.

**Memory estimates:**
1. The recipe value (and its overrides) is used first.
2. After each run, the worker's peak `phys_footprint` (from `proc_pid_rusage`, which includes
   unified/GPU memory) is recorded per `(recipe, task, memory_keys values)`. Load cost and per-job cost
   are recorded separately.
3. Once a sample exists, the learned peak (max of the last 5) replaces the recipe value.

These are measurements, not decisions.

**Concurrency inside one process:** the launcher keeps a thread pool of size `max_concurrent_per_process`.
Upstream `torch.manual_seed` is process-global, so concurrent jobs in one process can't guarantee
seed reproducibility. The UI and API say so wherever concurrency is greater than 1. Every v1 recipe
defaults to 1 and is raised only if the go/no-go test shows it is safe.

### Worker protocol (JSON lines, version 1)

- At start-up the launcher duplicates its stdout to a private file descriptor for protocol messages and
  points fd 1 at stderr, so output from native code can't corrupt the protocol. `sys.stdout` and
  `sys.stderr` are replaced by a proxy that tags each line with the job running on the current thread.
- Messages from the app to the worker: `{"op":"run","job":…,"step":…,"task":…,"inputs":{…},"settings":{…},"out_dir":…}`, `{"op":"cancel","job":…}`, `{"op":"shutdown"}`.
- Messages from the worker to the app:
  - `{"ev":"ready","protocol":1,"load_seconds":…}`
  - `{"ev":"log","job":…,"line":…}`
  - `{"ev":"stage","job":…,"name":…,"fraction":…}`
  - `{"ev":"done","job":…,"outputs":[…]}`
  - `{"ev":"error","job":…,"message":…,"traceback":…}`
  - `{"ev":"heartbeat","mps_allocated":…}`
- Stages are parsed from upstream's own output (`[Stage]` tags and tqdm lines), using patterns declared in
  the recipe.
- Cancelling a running job in a worker with concurrency 1 stops the worker process. In a concurrent
  worker it marks the job cancelled and discards its result; upstream code cannot be interrupted safely.
- A worker crash fails its running steps with the end of the log. The worker is restarted on demand.

## 9. Exports

| Format | How |
|---|---|
| GLB | native output |
| USDZ | ModelIO (`MDLAsset` import of GLB via GLTFKit2, then export `.usdz`) |
| OBJ | ModelIO export |
| FBX | Blender `bpy` (already in the UniRig venv). For a rigged mesh, UniRig's `merge.sh --output x.fbx` is used directly. |

If a conversion fails, that format is reported as failed on the job; the other outputs are kept.

## 10. Command layer, HTTP and MCP

Each command is a typed Swift request/response in `LiftCore.Commands`. HTTP (generated from
`openapi.yaml`) and MCP tools are thin adapters over the same commands. **Risky commands need `confirm: true`.**
Without it they return `confirmation_required` with a description of the impact and change nothing.

| Area | Commands (MCP tool = `area_action`; HTTP route) | Confirm |
|---|---|---|
| Jobs | `jobs_submit` (one or more steps, priority, export, title) · `jobs_list` (filter by state, modality, recipe, text) · `jobs_get` · `jobs_wait` (timeout, streams progress) · `jobs_cancel` · `jobs_retry` (optional new settings) · `jobs_move` (before/after/to position) · `jobs_set_priority` · `jobs_force_start` · `jobs_delete` · `jobs_export` (re-export, formats, dir) · `jobs_list_interrupted` · `jobs_resolve_interrupted` (requeue/discard) | force_start, delete, cancel-running |
| Queue | `queue_status` · `queue_pause` · `queue_resume` | — |
| Models | `models_list` · `models_get` (recipe, tasks, settings schema, status, pin, disk, memory) · `models_install` · `models_reinstall` · `models_set_pin` · `models_check_upstream` · `models_uninstall` (optional delete weights) · `models_install_log` · `models_download_weights` · `models_verify_weights` | install, reinstall, set_pin, uninstall, download_weights |
| Recipes | `recipes_list_sources` · `recipes_add_source` (git URL) · `recipes_remove_source` · `recipes_refresh` | add_source, remove_source |
| Workers & resources | `workers_list` · `workers_load` · `workers_unload` · `resources_get` (budget, reserved, system free, per-worker footprint, learned estimates) · `resources_set` (max_slots, memory_budget_gb, idle_unload_minutes) | unload-busy |
| Settings & server | `settings_get` · `settings_set` (any setting) · `server_status` (port, bind, URLs) · `server_set_lan` · `server_rotate_token` · `secrets_set_hf_token` | set_lan, rotate_token, settings that move folders |
| System | `system_prereqs` · `system_install_prereqs` (brew/git/uv/Metal Toolchain) | install_prereqs |

- **MCP resources:** `lift://jobs/{id}` (JSON), `lift://jobs/{id}/outputs/{file}` (binary),
  `lift://models/{id}/install-log`, `lift://resources`. Clients can subscribe to updates on jobs and resources.
- **MCP progress:** `jobs_wait` sends progress notifications (stage name and fraction).
- **Outputs** are returned both as absolute file paths and as resource URIs.
- **Transports:** Streamable HTTP at `/mcp`; the stdio bridge `lift-mcp` (inside the app bundle) forwards to it.
- **HTTP:** `/v1/*` mirrors the table above. File inputs use multipart upload or `*_path` / `*_base64`.
  `POST /v1/jobs` returns `202` with `Location`. `/openapi.json` and `/docs` (Redoc) are served too.
- **Port:** 7777 by default. If it's taken, the next free port is used, and the actual port is shown in
  the UI, `server_status` and the MCP config snippet.
- **Auth:** loopback requests need no token. With LAN mode on, the server binds `0.0.0.0` and any
  request not from this Mac needs `Authorization: Bearer <token>` (stored in the Keychain).

## 11. Settings and first launch

**First-launch wizard:**
1. Toolchain check/installs (§6).
2. Choose the **working directory** (holds recipes, models, jobs and the database) and the **export
   folder**, plus the default for `cleanup_after_export`.
3. Clone the default recipe source into `<workdir>/recipes/`, with a live log; on failure, Retry.
4. Optional Hugging Face token.
5. Show the MCP setup snippet.

All settings can be changed later in Settings, HTTP and MCP: working directory (moving it needs confirm
and moves the data), export folder, default export
formats, cleanup default, port, LAN mode, token, HF token, `max_slots`, `memory_budget_gb`,
`idle_unload_minutes`, notifications on/off, launch at login, keep running in the menu bar.

## 12. UI

As in the mockups (Generate, Queue, Models, Settings, History, Result viewers, Menu bar), with these additions:
- Queue shows the slot and memory meters (`reserved / budget`, system free), each worker with its
  footprint, and the reason a job is waiting, with **Force start**.
- Settings → Resources: slots, budget and idle unload, with the learned-estimates table (read-only, plus reset).
- Generate → export options (formats, export folder, cleanup after export) and priority.
- The interrupted-jobs sheet on launch.
- Unsupported recipes are shown greyed out with their reason.

## 13. Error handling

- **Bad input:** rejected before queueing, with errors per field (HTTP 422, MCP error result).
- **Toolchain/install failure:** the exact failing command and the end of its log are shown, with a retry.
- **Worker crash or out of memory:** the step fails with the end of its log, the worker is restarted on
  demand, and the queue keeps going.
- **Port taken:** the next free port is used and shown (§10). **Disk full:** checked before install and before export copies.
- **Interrupted jobs** go through the relaunch sheet. **A recipe source fails to pull:** the source is
  marked stale and its recipes keep their last good version.

## 14. Testing

- **Swift unit tests:** recipe parsing and validation; settings validation; scheduler (slots, budget,
  priority/position/FIFO, force start, waiting reasons); learned estimates; worker protocol
  encode/decode; the state machine and interrupted handling; auth (loopback vs token); confirm gates;
  command layer.
- **Integration tests:** the real app server with the Test Cube recipe, exercised over HTTP and MCP:
  submit → wait → outputs, chained steps, cancel, retry, reorder, priority, pause, interrupted resolve,
  install/uninstall Test Cube, settings round trip, stdio bridge.
- **Python (pytest):** shim device redirection, attention stand-in, launcher protocol (fd separation,
  per-thread log tagging, concurrency), stage parsing.
- **Manual acceptance:** one real run per v1 recipe (time and peak memory recorded). Every model download
  or long GPU run is approved by you first.

### CI (GitHub Actions, `macos-26` runner, Xcode 26)

- **`.github/workflows/test.yml`** runs on push and pull request:
  - Resolve packages (cached).
  - `xcodebuild build` of the app and `lift-mcp`.
  - Swift unit tests and integration tests (Test Cube only; no real models, no weights).
  - `uv run pytest` for the shim and launcher.
  - Test results are uploaded as artifacts.
- **`.github/workflows/release.yml`** is triggered manually (`workflow_dispatch`) with a `version` input (`X.Y.Z`):
  1. Run the same test job.
  2. Archive and export Lift.app (ad-hoc signed, Release build) and zip it with `ditto`.
  3. Create and push tag `vX.Y.Z` and a GitHub Release whose notes are generated from commits since the
     previous tag, with `Lift-X.Y.Z.zip` and its SHA-256 attached.

  It uses `softprops/action-gh-release` and `GITHUB_TOKEN` (`contents: write`). It fails if the tag already exists.
- No secrets are needed until notarization is added; Developer ID signing slots in at step 2 later.

## 15. Milestones

0. **Go/no-go test** for the four real recipes (§5). Throwaway code, and the findings feed the recipes.
   Then create the public `oshricohenme/lift-recipes` repo with the v1 recipes and `shared/` (only with your go-ahead).
1. LiftCore: Store, Recipes, Toolchain, Installer, Workers, Scheduler, Resources, Commands. Tested with
   Test Cube. The test CI workflow is added here, so every later milestone runs in CI.
2. LiftServer: OpenAPI HTTP, MCP (tools, resources, progress), auth, the `lift-mcp` bridge.
3. LiftUI: all screens, the first-launch wizard, the interrupted sheet, the menu bar, notifications.
4. Real recipes: Pixal3D, Pixal3D-MV, UniRig, TRELLIS.2, then exports (USDZ/OBJ/FBX).
5. Release workflow, and the first tagged release `v0.1.0` (run only when you say so).

## 16. Risks

- **The shim may not get a model running.** Mitigation: the go/no-go test first; the recipe ships as unsupported with a reason.
- **Concurrency inside one process may be unsafe or unreproducible** for upstream code. Mitigation: it
  defaults to 1 per recipe, is raised only when verified, and the seed caveat is shown.
- **`phys_footprint` may under-count MPS allocations.** Mitigation: worker heartbeats also report
  `torch.mps.driver_allocated_memory()`, and the estimate uses the larger of the two.
- **Gated weights (TRELLIS.2: RMBG-2.0, DINOv3)** need access granted on Hugging Face. Mitigation: a
  prerequisite check plus clear instructions.
- **Upstream entry points may print or exit in ways that break the worker.** Mitigation: fd separation, and `SystemExit` caught per job.
