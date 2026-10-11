# Plan 4 — Real recipes, Exporter, Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three real v1 recipes (Pixal3D with its multi-view task, UniRig, TRELLIS.2 through trellis-mac), the Exporter (GLB, USDZ, OBJ, FBX, export folder, credits, cleanup), the release workflow, and the product acceptance checklist — all tested without downloading a single model weight.

**Architecture:** Model specifics live only in each recipe folder under `dev-recipes/` (`recipe.yaml` + `launcher.py`), consumed by Plan 1's catalog, installer and `lift_worker`. LiftCore gains a small schema extension (`metal_toolchain`, `weights[].files`, the required `attribution:` block), process-group workers (so upstream subprocesses die with their worker), and an `Exporter` that runs after a job's last step: GLB copied and stamped with credits, USDZ through SceneKit, OBJ through ModelIO (GLB read by GLTFKit2), FBX through Blender's `bpy` from the UniRig venv, every copy SHA-256-verified before `cleanup_after_export` removes the job's own folder. Launchers are tested against fake upstream modules and fake upstream scripts; installs are dry-run against `FakeRunner`, with an opt-in real install that downloads packages but never weights.

**Tech Stack:**
- Swift 6.2 tools / Swift 6.3.3, macOS 26, Swift Testing; GRDB, Yams, swift-subprocess (Plan 1); **GLTFKit2 0.5.15** (new; a binary xcframework, 36.7 MB, SHA-256 `9d0c338282acce4986494aa02a5f1495278f56c60d43f31453fefea6875b4928`); ModelIO, SceneKit, CryptoKit from the SDK
- Python 3.11 through uv; pytest, PyYAML and NumPy for the recipe tests (dev only)
- GitHub Actions: `softprops/action-gh-release@v2`, `actions/checkout@v4`, `astral-sh/setup-uv@v6`; `actionlint` locally

**Spec:** `docs/superpowers/specs/2026-10-11-lift-design.md` — §4 (recipes, v1 table, trellis2-mac, multi-view inputs), §4a (attribution), §5 (shim, substitutes), §6 (install, working copy, weights), §7 (export), §8 (one job per worker, process-group kill), §9 (exports), §14 (CI, release workflow), §15 milestones 4–5. Also the go/no-go findings `docs/superpowers/findings/2026-10-go-no-go.md` (install steps, pins, shim configs, entry points, weights) and Plan 1 `docs/superpowers/plans/2026-10-11-plan-1-liftcore.md` (schema, launcher contract, installer, weights).

**Base:** branch `oshricohenme/7jtm2` at `8a0be35` (Plan 1 implemented, fixes I1–I8). Diffs below are against that commit. The repo moves quickly; if a hunk no longer applies, make the same change by intent at the code it names, and keep the tests exactly as written.

**Prototype verification (done while writing this plan, 2026-10-11):** every file below was built and run on a copy of `8a0be35` in a temp folder.
- `swift build --build-tests` clean; `swift test`: **157 tests in 24 suites pass** (Plan 1's suites plus this plan's, including the real Test Cube install, run, export and cleanup).
- `python/lift_worker`: 25 passed. `python/recipe_tests`: 28 passed, 4 skipped; with `LIFT_MODELS_DIR` pointing at the go/no-go clones (read-only): 32 passed — every Pixal3D/UniRig/trellis-mac setting matches upstream's keyword arguments, script flags and argparse options with their defaults.
- **Real installs through Lift's own `Installer`, no weights** (`LIFT_REAL_INSTALL=pixal3d,trellis2-mac`, temp workdir, temp uv/HF/torch caches): pixal3d installed in 238 s and its smoke check imported upstream under `lift_shim` (`[SPARSE] Conv backend: flex_gemm; Attention backend: sdpa`, `lift_worker: launcher OK`); trellis2-mac installed in 226 s with setup.sh using the pre-placed pinned clones and Lift's venv, `torch==2.13.0`, and the smoke check asserting o_voxel's Metal backend. Both passed again with the final, converging clone steps (439 s for the pair). UniRig wasn't installed for real: it needs native Homebrew for `libusb`, which this Mac doesn't have, and installing it is outside the dev rules.
- FBX through the go/no-go UniRig venv's real `bpy` 4.2 (`LIFT_TEST_BPY_PYTHON`): plain, textured and rigged GLBs convert; re-importing the FBX shows the mesh, the packed texture, and the armature with its vertex groups. bpy 4.2 segfaults at interpreter exit (code 139) after writing, hence `os._exit(0)` in the script.
- USDZ/OBJ: ModelIO can't write USDZ (`canExportFileExtension("usdz") == false`) and its USDC drops texture references, so USDZ goes through SceneKit (`SCNScene(gltfAsset:)` → `write(to:)`); the package holds the USDC and the PNG. ModelIO's OBJ writes `.obj` + `.mtl` + textures named after materials.
- `actionlint` 1.7.12: both workflows clean. The release workflow's tag check, notes and tag push were exercised against a local bare remote.
- Hugging Face file lists (metadata API only) checked for every weights repo, to choose `files:` subsets: UniRig 5.8 of 11.5 GB, OPT-350m 1 file of 2 GB, TRELLIS-image-large 0.15 of 3.3 GB, RMBG-2.0 0.9 of 5.4 GB.
- Not verified here: SwiftPM resolving GLTFKit2's binary artifact from its URL. In this sandbox SwiftPM's artifact download hangs while `curl` fetches the same zip (checksum matches), so the prototype used the same xcframework from a local path. CI resolves it normally. Task 11 (HTTP/MCP wiring) is written against Plan 2's draft and couldn't be run before Plan 2 merges.

## Global Constraints

- Platform: macOS 26+, Apple Silicon; Swift 6 language mode; Swift Testing only (`import Testing`), never XCTest.
- New Swift package: exactly `https://github.com/warrenm/GLTFKit2` from `0.5.15` (spec §3 package table: GLB preview and import). Commit the updated `Package.resolved`. No other new packages.
- Python 3.11 for every venv, through uv. `lift_worker` stays stdlib-only. Recipe tests may use `pytest`, `pyyaml`, `numpy` (dev group only).
- **User rules (binding):** never download model weights; never install prerequisites outside the repo or temp dirs (no `brew install`, no Metal Toolchain install, no Blender add-ons in `~/Library`); never delete anything outside the repo or temp dirs; never edit upstream repos; the app makes no intelligent choices; prefer established packages.
- Tests never download weights. Real installs (`RealInstallTests`) are opt-in through `LIFT_REAL_INSTALL`, run in a temp workdir with `downloadWeights: false`, and may download Python packages and git clones only.
- **Never edit upstream code** (spec principle 1). Launchers import or run upstream as it is. trellis-mac's own `setup.sh` patching its TRELLIS.2 clone is trellis-mac's documented behaviour inside Lift's working copy (spec §6), not an edit by Lift.
- **Lift owns its working copy** (spec §6): every nested clone a recipe makes converges — clone when missing, else `fetch` and `checkout -qf <pin>`.
- **One job per worker process; cancel/kill is an immediate process-group SIGKILL** (spec §8). No recipe declares `max_concurrent_per_process`.
- **Credit the authors** (spec principle 5, §4a): every recipe carries a complete `attribution:` block; every export carries the credit.
- Deletion in product code is limited to Lift's own files: `models/<id>/deps/`, the job's own `jobs/<id>/` after a verified export, and temp folders Lift created.
- Branch `oshricohenme/7jtm2`, don't push. Commits name their paths: `git add <paths>` then `git commit -m "<subject>" -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- <paths>`.

## Decisions this plan makes (fold into the spec in Task 12)

1. **Schema additions:** `metal_toolchain: bool` (default false; the installer runs `xcrun metal --version` before touching anything); `weights[].files: [path]` (exact repo paths; `hf download <repo> <files…> --revision <rev>`, and the verifier checks only those, reporting a listed path the repo doesn't have as missing); `attribution:` as spec §4a, validated at load.
2. **`cumesh` is a real Metal build**, not a do-nothing stand-in: pedronaugusto's `mtlmesh` provides the `cumesh` module (it imports `mtlbvh`, built first). The spec §5 table's "stand-in that does nothing" is wrong for v1.
3. **Substitutes check their torch range first** (`>=2.11,<2.14`: mtlgemm needs `at::mps::dispatch_sync_with_rethrow`, the forks hardcode `-std=c++17`, torch 2.14 headers need C++20) and build with `MACOSX_DEPLOYMENT_TARGET=12.0` and `--no-build-isolation`. `models/<id>/deps/` is emptied before every install.
4. **`brew:` needs no `DYLD_FALLBACK_LIBRARY_PATH` for v1:** open3d links `/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib` by absolute path, and SIP strips `DYLD_*` when UniRig's scripts go through `/bin/bash` anyway. Plan 1's env var stays (harmless); installing libusb with native brew is what matters.
5. **Pixal3D:** `inference.init_pipeline` and `inference_mv.init_pipeline` are wrapped in `functools.lru_cache(maxsize=1)` (not `functools.cache`): toggling `low_vram` or `model_path` replaces the loaded pipeline instead of keeping two. Multi-view calls the importable `inference_mv.run_inference(**kwargs)` rather than its CLI through `runpy`, so every keyword argument is a setting.
6. **Multi-view inputs (spec §4)** are a launcher setting `views`: `transforms` (the folder has transforms.json), `four_view` (files named front, right, back, left get the upstream example's cameras), `orbit` (every image in name order, evenly spaced). Orbit needs a distance as well as count/elevation/FOV: `orbit_distance` defaults to the upstream example's 3.1192 for its 20° FOV. Lift writes `out_dir/views/transforms.json` with absolute `file_path`s and never copies images.
7. **Sentinels where upstream's default is `None`:** Pixal3D `num_views: 0` and trellis-mac `steps: 0` mean upstream's default (generate.py itself treats 0 that way). Enum `resolution` includes upstream's `-1`.
8. **UniRig:** no VRM add-on install (it writes to `~/Library/Application Support/Blender` and is only for `.vrm` output); `format` is `glb|fbx`. The launcher hands upstream's `eval`-built scripts only fixed names in a fresh temp folder (the input is a symlink) and limits string settings to plain path characters, because the scripts `eval` their command lines. Each stage is judged by the file it writes, since the scripts end with `echo done` and exit 0 on failure. `pip` and `psutil` go into the venv so `extract.sh`'s `pip install psutil` stays inside it.
9. **trellis2-mac:** generate.py keeps its flow in `main()`, so the launcher mirrors it (load once; per job `pipeline.run` + the bake block, KDTree fallback included) and must be re-checked when the pin moves. All of setup.sh's dependency clones are pre-placed at the go/no-go commits (the spec named only TRELLIS.2), and `repo/.venv` is a symlink to Lift's venv. Importing the launcher asserts `o_voxel.postprocess._BACKEND == "metal"`, so the smoke check fails instead of shipping the silent KDTree fallback.
10. **Weights subsets** (`files:`): UniRig's two checkpoints, OPT-350m's `config.json`, TRELLIS.2-4B's pipeline files, TRELLIS-image-large's sparse-structure decoder, RMBG-2.0's BiRefNet files. If a subset misses a file, upstream downloads it at run time (online) — the acceptance checklist checks the first-run logs for that.
11. **Exports:** USDZ through SceneKit (ModelIO can't write it); OBJ is a folder `<title>/` with `<title>.obj`, `.mtl` and textures (ModelIO names textures after materials, so loose files would collide); FBX through bpy for every mesh, rigged ones included (armature and weights verified), and an output already in the format (UniRig's `format: fbx`) is copied as is. Names are `<title>.<ext>`, never overwriting (`<title> 2.<ext>`). Credits: GLB `asset.copyright`/`asset.generator` = "<Project> by <authors> (<license>)[; …], run with Lift"; USDZ/OBJ/FBX get one `<title>.credits.txt` with the credit line, disclaimer and component licenses.
12. **Export defaults and lifecycle:** a request's missing `export` fields take the `export_dir`, `export_formats` (default `[glb]`) and `cleanup_after_export` settings; no export folder yet means no export; `formats: []` opts out. The job is `succeeded` with `exportPending` until the export ends; `jobs_wait` waits for it, and an open after a crash resumes it. `cleanup_after_export` deletes `jobs/<id>/` only when every format was copied and verified (SHA-256); a re-export never cleans up; retry and re-export refuse a cleaned-up job. `settings_set("export_formats", "glb,usdz")` takes a comma list because setting values are scalars.
13. **Release:** the tag is pushed only after the archive and zip succeed; notes are `git log --no-merges` since the previous `vX.Y.Z` tag (GitHub's generated notes list PRs, not commits); the ad-hoc-signed app is taken from the archive (`-exportArchive` has no ad-hoc method); `test.yml` gains `workflow_call` so the release runs the same test job.
14. **Not owned here (flagged):** `models_readme`, the README fetch and the About/Credits UI (§4a) go to Plans 2/3; the UI's export options (Generate, History re-export) are Plan 3's, binding to this plan's `SubmitRequest.export`, `jobsExport` and the three settings.

## Review Focus

1. **A user file name or folder with spaces, quotes or `$(…)` reaches UniRig's `eval`'d launch scripts** — it must neither split nor execute. Pinned by `test_paths_with_spaces_and_shell_characters_never_reach_the_scripts` and `test_string_settings_with_shell_characters_are_refused` (Task 4).
2. **Cancel, unload or quit while UniRig's bash → python stage holds the GPU** — the grandchildren must die with the worker, not linger holding memory. Pinned by `killAlsoStopsWhatUpstreamStarted` (Task 2, Swift) and `test_exit_takes_upstream_children_along[eof|shutdown]` (Task 2, Python).
3. **Lift quits or crashes between a job's last step and the end of its export** — the job must not report done with files missing, and must not stay "exporting" forever. Pinned by `anExportCutShortByAQuitRunsAtTheNextOpen` and the `exportPending` check in `exportsEveryFormatAndAFailedFormatKeepsTheJobFiles` (Task 8).
4. **One format fails (no UniRig for FBX, disk full) while `cleanup_after_export` is on** — the other formats are kept, and the job's files are not deleted. Pinned by `exportsEveryFormatAndAFailedFormatKeepsTheJobFiles` (Task 8) and `eachFormatFailsAlone` (Task 7).
5. **Exporting into a folder that already has `<title>.glb`** — the user's existing file is never overwritten. Pinned by `existingFilesAreNeverOverwritten` (Task 7).

Also pinned: the KDTree fallback refused at install (`test_import_refuses_the_kdtree_fallback`, Task 5), UniRig stages that exit 0 without output (`test_a_stage_that_writes_nothing_fails_the_job_and_stops`, Task 4), and recipe settings drifting from upstream on a pin bump (`test_upstream_settings.py`, Task 6).

---

## File Structure

```
dev-recipes/
├─ shared/substitutes.yaml            Metal substitutes (pinned), spconv/torch_scatter/torch_cluster entries (Task 3)
├─ pixal3d/recipe.yaml · launcher.py  image_to_3d + image_set_to_3d, view layouts (Task 3)
├─ unirig/recipe.yaml · launcher.py   mesh → rigged mesh via upstream's scripts (Task 4)
├─ trellis2-mac/recipe.yaml · launcher.py   setup.sh with pinned clones; generate.py mirrored (Task 5)
└─ test-cube/recipe.yaml              + attribution (Task 1)
python/recipe_tests/                  weight-free launcher tests (pytest; outside the bundled recipes on purpose)
├─ pyproject.toml · conftest.py       FakeJob, defaults(), fake-module loader (Task 3)
├─ test_pixal3d.py (3) · test_unirig.py (4) · test_trellis2_mac.py (5) · test_upstream_settings.py (6, opt-in)
python/lift_worker/                   exit takes the process group along (Task 2)
Sources/LiftCore/
├─ Recipes/Recipe.swift · Validation.swift      metal_toolchain, weights.files, Attribution (Task 1)
├─ Installer/Installer.swift                    Metal check, empty deps/, file-scoped downloads (Task 1)
├─ Weights/Weights.swift                        verify only listed files (Task 1)
├─ Workers/WorkerProcess.swift                  process-group leader + group kill (Task 2)
├─ Exporter/Exporter.swift                      formats, credits, verified copy (Task 7)
├─ Engine/Export.swift · Engine/Lift.swift      export after the last step; resume at open (Task 8)
├─ Store/Records.swift · Store.swift · Settings.swift   job export fields + migration; export settings (Task 8)
└─ Commands/JobCommands.swift                   SubmitRequest.export, jobsWait, jobsRetry guard, jobsExport (Task 8)
Tests/LiftCoreTests/
├─ RecipeTests · InstallerTests · WeightsTests (1) · WorkerProcessTests (2) · CommandTests (3)
├─ BundledRecipeTests.swift · RealInstallTests.swift (6)
├─ CubeGLB.swift · ExporterTests.swift (7) · ExportFlowTests.swift (8)
.github/workflows/release.yml (9) · test.yml (3, 9)
docs/superpowers/acceptance/v1.md (10)
Sources/LiftServer/{Inputs.swift, API.swift, Tools.swift, openapi.yaml}, Tests/LiftServerTests (11, after Plan 2)
docs/superpowers/specs/2026-10-11-lift-design.md (12)
```

## Dependency graph and parallel execution

```
Task 1 schema/installer ─┬─> Task 3 pixal3d + registry + test scaffold ─┬─> Task 4 unirig ───┐
                         │                                               └─> Task 5 trellis ──┼─> Task 6 bundled-recipe checks
                         └─> Task 7 exporter ─> Task 8 export in jobs ─> Task 11 HTTP/MCP (needs Plan 2 merged)
Task 2 process groups ──────> (Task 4 relies on it at run time)
Task 9 release workflow · Task 10 acceptance doc — independent
Task 12 spec — last
```

| Wave | Tasks at the same time | Needs |
|---|---|---|
| A | **1**, **2**, **9**, **10** | none |
| B | **3**, **7** | 1 |
| C | **4** (2, 3), **5** (3), **8** (7) | as listed |
| D | **6** | 1, 3, 4, 5 |
| E | **11** (8 + Plan 2 merged), **12** (all) | as listed |

Swift tasks in the same wave each run in their own git worktree and merge in task-number order (all Swift tests share one target, so a half-written file breaks everyone's build). Task 1 and Task 8 both touch Plan 1 files but different ones; Task 3 and Task 9 each add one hunk to `test.yml`. Python-only steps (most of Tasks 3–5) can share a tree.

---
### Task 1: Recipe schema for real recipes — Metal Toolchain, weight subsets, attribution

**Files:**
- Modify: `Sources/LiftCore/Recipes/Recipe.swift` (Weight.files, Attribution, metalToolchain, CodingKeys)
- Modify: `Sources/LiftCore/Recipes/Validation.swift` (attribution required and complete)
- Modify: `Sources/LiftCore/Installer/Installer.swift` (Metal check, `deps/` emptied, `hf download` with files)
- Modify: `Sources/LiftCore/Weights/Weights.swift` (`RepoSnapshot.only`, listed files only)
- Modify: `dev-recipes/test-cube/recipe.yaml` (attribution)
- Test: `Tests/LiftCoreTests/RecipeTests.swift`, `Tests/LiftCoreTests/InstallerTests.swift`, `Tests/LiftCoreTests/WeightsTests.swift`

**Interfaces:**
- Consumes (Plan 1): `Recipe`, `Recipe.Weight(repo:revision:gated:)`, `RecipeLoad.read(directory:)`, `Installer.install(_:pin:onLine:)`, `Installer.downloadWeights(_:onLine:)`, `WeightsVerifier.verify(_:)`/`totalBytes(_:)`, `RepoSnapshot`, `WeightProblem`, test helpers `pixalYAML`, `writeRecipe`, `FakeRunner`, `writeHFCache`, `FakeMetadata`.
- Produces:
  - `Recipe.metalToolchain: Bool` (YAML `metal_toolchain`, default false).
  - `Recipe.Weight.files: [String]?` and `Recipe.Weight(repo:revision:gated:files:)`.
  - `Recipe.attribution: Recipe.Attribution?` with `Attribution { project: String, authors: [String], homepage: String, repo: String?, paper: Paper?, license: License, components: [Component] }`, `License { spdx, url }`, `Paper { title, url, bibtex? }`, `Component { name, url, license, restrictions: [String]? }`, computed `credit: String` ("<Project> by <authors> (<spdx>)") and `disclaimer: String` (spec §4a wording).
  - Validation problems: `"attribution is required: who made it, where it comes from and its license"`, `"attribution.<field> is required"`, `"attribution.components[<i>] needs name, url and license"`.
  - `Installer.install` throws `LiftError.prerequisite("<name> needs the Metal Toolchain; run system_install_prereqs with metal")` after `/usr/bin/xcrun metal --version` fails, before anything else runs; it empties `models/<id>/deps/` with `repo`, `venv`, ….
  - `downloadWeights` runs `hf download <repo> [<files>…] --revision <rev>`.
  - `extension RepoSnapshot { func only(_ paths: [String]?) -> RepoSnapshot }` (internal).

- [ ] **Step 1: Write the failing tests**

Add an attribution block to the shared `pixalYAML` fixture and three tests in `RecipeTests.swift`:

```diff
--- a/Tests/LiftCoreTests/RecipeTests.swift
+++ b/Tests/LiftCoreTests/RecipeTests.swift
@@ -27,6 +27,13 @@ install:
 substitutes: [flash_attn]
 shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }
 brew: [libusb]
+attribution:
+  project: Pixal3D
+  authors: [TencentARC]
+  homepage: https://github.com/TencentARC/Pixal3D
+  license: { spdx: MIT, url: https://github.com/TencentARC/Pixal3D/blob/master/LICENSE }
+  components:
+    - { name: RMBG-2.0, url: https://huggingface.co/briaai/RMBG-2.0, license: { spdx: CC-BY-NC-4.0, url: https://creativecommons.org/licenses/by-nc/4.0/ }, restrictions: [non-commercial] }
 weights:
   - { repo: TencentARC/Pixal3D, gated: false }
   - { repo: briaai/RMBG-2.0, revision: 1f3e2a7c, gated: true }
@@ -95,6 +102,31 @@ tasks:
         #expect(problems.contains(message))
     }
 
+    @Test func metalToolchainAndWeightFiles() throws {
+        let yaml = pixalYAML.replacingOccurrences(of: "  - { repo: TencentARC/Pixal3D, gated: false }",
+                                                  with: "  - { repo: TencentARC/Pixal3D, gated: false, files: [pipeline.json, ckpts/a.safetensors] }")
+            + "\nmetal_toolchain: true\n"
+        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected ok"); return }
+        #expect(r.metalToolchain && r.weights[0].files == ["pipeline.json", "ckpts/a.safetensors"] && r.weights[1].files == nil)
+        guard case .ok(let plain) = RecipeLoad.read(directory: try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())) else { return }
+        #expect(!plain.metalToolchain)  // default
+    }
+
+    @Test func attributionIsRequiredAndComplete() throws {
+        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected ok"); return }
+        let a = try #require(r.attribution)
+        #expect(a.credit == "Pixal3D by TencentARC (MIT)")
+        #expect(a.disclaimer == "Pixal3D was created by TencentARC. Lift is an independent app that runs open-source projects on your Mac. Lift did not create Pixal3D and is not affiliated with or endorsed by its authors.")
+        #expect(a.components.first?.restrictions == ["non-commercial"])
+        let start = pixalYAML.range(of: "attribution:")!.lowerBound, end = pixalYAML.range(of: "weights:")!.lowerBound
+        let without = pixalYAML.replacingCharacters(in: start..<end, with: "")
+        guard case .invalid(let missing) = RecipeLoad.read(directory: try writeRecipe(without, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected invalid"); return }
+        #expect(missing.contains("attribution is required"))
+        let blank = pixalYAML.replacingOccurrences(of: "  authors: [TencentARC]", with: "  authors: [\"\"]")
+        guard case .invalid(let problems) = RecipeLoad.read(directory: try writeRecipe(blank, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected invalid"); return }
+        #expect(problems.contains("attribution.authors is required"))
+    }
+
     @Test func noShimMeansNone() throws {
         let yaml = pixalYAML.replacingOccurrences(of: "shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }\n", with: "")
         guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected ok"); return }
```

In `InstallerTests.swift`, before `downloadWeightsRunsHFFromTheVenv`:

```diff
--- a/Tests/LiftCoreTests/InstallerTests.swift
+++ b/Tests/LiftCoreTests/InstallerTests.swift
@@ -121,6 +121,42 @@ import Testing
         #expect(try await inst.checkUpstream(entry.recipe, pin: nil) == UpstreamStatus(pin: entry.recipe.commit, head: head, commitsAhead: 7))
     }
 
+    @Test func aRecipeNeedingTheMetalToolchainChecksItBeforeTouchingAnything() async throws {
+        let runner = FakeRunner()
+        runner.on("xcrun metal", code: 1)
+        let inst = try installer(runner)
+        let entry = try source(pixalYAML + "\nmetal_toolchain: true\n")
+        await #expect(throws: LiftError.prerequisite("Pixal3D needs the Metal Toolchain; run system_install_prereqs with metal")) {
+            try await inst.install(entry, pin: nil, onLine: { _ in })
+        }
+        #expect(runner.displays == ["/usr/bin/xcrun metal --version"])
+        let ok = FakeRunner()
+        try await self.installer(ok).install(entry, pin: nil, onLine: { _ in })
+        #expect(ok.displays.first == "/usr/bin/xcrun metal --version")
+    }
+
+    @Test func depsStartsEmptyOnEveryInstall() async throws {
+        let inst = try installer(FakeRunner())
+        let stale = inst.dir("pixal3d").appending(path: "deps/mtlgemm/build")
+        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
+        try await inst.install(try source(), pin: nil, onLine: { _ in })
+        #expect(!FileManager.default.fileExists(atPath: inst.dir("pixal3d").appending(path: "deps").path))
+    }
+
+    @Test func weightDownloadsNameOnlyTheListedFiles() async throws {
+        let runner = FakeRunner()
+        let yaml = pixalYAML.replacingOccurrences(of: "  - { repo: TencentARC/Pixal3D, gated: false }",
+                                                  with: "  - { repo: TencentARC/Pixal3D, gated: false, files: [pipeline.json, ckpts/a.safetensors] }")
+        let entry = try source(yaml)
+        let inst = try installer(runner)
+        let bin = inst.dir("pixal3d").appending(path: "venv/bin")
+        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
+        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
+        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
+        try await inst.downloadWeights(entry.recipe, onLine: { _ in })
+        #expect(runner.displays.first == "\(bin.path)/hf download TencentARC/Pixal3D pipeline.json ckpts/a.safetensors --revision main")
+    }
+
     @Test func downloadWeightsRunsHFFromTheVenv() async throws {
         let runner = FakeRunner()
         let entry = try source()
```

In `WeightsTests.swift`, before `revisionNotDownloadedMeansAllMissing`:

```diff
--- a/Tests/LiftCoreTests/WeightsTests.swift
+++ b/Tests/LiftCoreTests/WeightsTests.swift
@@ -97,6 +97,18 @@ func writeHFCache(hub: URL, repo: String, commit: String, files: [String: Data],
         #expect(r.problems == [WeightProblem(repo: "org/model", path: "sub/b.bin", issue: .missing)])
     }
 
+    @Test func onlyTheListedFilesAreCheckedAndCounted() async throws {
+        let (meta, hub, v) = try setup()
+        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["config.json": Data("{}".utf8)], lfs: [])
+        snap.files.append(RemoteFile(path: "pytorch_model.bin", size: 9_000, sha256: String(repeating: "0", count: 64)))  // not downloaded, not needed
+        meta.set("org/model", .success(snap))
+        let r = try await v.verify(try recipe([Recipe.Weight(repo: "org/model", files: ["config.json"])]))
+        #expect(r.state == .ok && r.problems.isEmpty)
+        #expect(await v.totalBytes(try recipe([Recipe.Weight(repo: "org/model", files: ["config.json"])])) == 2)
+        let typo = try await v.verify(try recipe([Recipe.Weight(repo: "org/model", files: ["config.json", "confg.json"])]))
+        #expect(typo.state == .missing && typo.problems == [WeightProblem(repo: "org/model", path: "confg.json", issue: .missing, detail: "not in org/model@main")])
+    }
+
     @Test func revisionNotDownloadedMeansAllMissing() async throws {
         let (meta, _, v) = try setup()
         meta.set("org/model", .success(RepoSnapshot(repo: "org/model", revision: "main", commit: commit, files: [RemoteFile(path: "a", size: 1), RemoteFile(path: "b", size: 2)])))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: compile errors such as `value of type 'Recipe' has no member 'metalToolchain'`, `has no member 'attribution'`, `extra argument 'files' in call`.

- [ ] **Step 3: Implement the schema**

```diff
--- a/Sources/LiftCore/Recipes/Recipe.swift
+++ b/Sources/LiftCore/Recipes/Recipe.swift
@@ -69,11 +69,14 @@ public struct Recipe: Codable, Sendable, Equatable {
         public var repo: String
         public var revision: String
         public var gated: Bool
+        /// Only these files of the repo (exact paths), when upstream uses a few of many; nil means the whole repo.
+        public var files: [String]?
 
-        public init(repo: String, revision: String = "main", gated: Bool = false) {
+        public init(repo: String, revision: String = "main", gated: Bool = false, files: [String]? = nil) {
             self.repo = repo
             self.revision = revision
             self.gated = gated
+            self.files = files
         }
 
         public init(from decoder: any Decoder) throws {
@@ -81,6 +84,7 @@ public struct Recipe: Codable, Sendable, Equatable {
             repo = try c.decode(String.self, forKey: .repo)
             revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? "main"
             gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
+            files = try c.decodeIfPresent([String].self, forKey: .files)
         }
     }
 
@@ -101,6 +105,59 @@ public struct Recipe: Codable, Sendable, Equatable {
         }
     }
 
+    /// `attribution:` (spec §4a): who made the model, where it comes from and under which licenses. Required.
+    public struct Attribution: Codable, Sendable, Equatable {
+        public struct License: Codable, Sendable, Equatable {
+            /// SPDX id (`MIT`), or `LicenseRef-…` / `NOASSERTION` for custom licenses.
+            public var spdx: String
+            public var url: String
+        }
+
+        public struct Paper: Codable, Sendable, Equatable {
+            public var title: String
+            public var url: String
+            public var bibtex: String?
+        }
+
+        /// Everything else the model pulls in: weights repos, helper models, Mac ports.
+        public struct Component: Codable, Sendable, Equatable {
+            public var name: String
+            public var url: String
+            public var license: License
+            /// Shown prominently, e.g. `non-commercial`.
+            public var restrictions: [String]?
+        }
+
+        public var project: String
+        public var authors: [String]
+        public var homepage: String
+        public var repo: String?
+        public var paper: Paper?
+        public var license: License
+        public var components: [Component]
+
+        public init(from decoder: any Decoder) throws {
+            let c = try decoder.container(keyedBy: CodingKeys.self)
+            project = try c.decode(String.self, forKey: .project)
+            authors = try c.decode([String].self, forKey: .authors)
+            homepage = try c.decode(String.self, forKey: .homepage)
+            repo = try c.decodeIfPresent(String.self, forKey: .repo)
+            paper = try c.decodeIfPresent(Paper.self, forKey: .paper)
+            license = try c.decode(License.self, forKey: .license)
+            components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
+        }
+
+        /// "<Project> by <authors> (<license>)".
+        public var credit: String { "\(project) by \(authors.joined(separator: ", ")) (\(license.spdx))" }
+
+        /// The fixed wording of spec §4a.
+        public var disclaimer: String {
+            let by = authors.joined(separator: ", ")
+            return "\(project) was created by \(by). Lift is an independent app that runs open-source projects on your Mac. "
+                + "Lift did not create \(project) and is not affiliated with or endorsed by its authors."
+        }
+    }
+
     public struct MemoryOverride: Codable, Sendable, Equatable {
         public var when: [String: SettingValue]
         public var memoryGB: Double
@@ -150,7 +207,11 @@ public struct Recipe: Codable, Sendable, Equatable {
     public var shim: Shim?
     /// Native Homebrew packages (e.g. `libusb`); their `lib/` goes on the worker's `DYLD_FALLBACK_LIBRARY_PATH`.
     public var brew: [String]
+    /// The install builds Metal shaders, so it needs the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
+    public var metalToolchain: Bool
     public var weights: [Weight]
+    /// Required; a recipe without it fails validation (spec §4a). Optional here so the problem can be reported.
+    public var attribution: Attribution?
     /// Developer-only (the Test Cube): hidden unless the `dev_recipes` setting or `LIFT_DEV_RECIPES=1` is on.
     public var developer: Bool
     public var resources: Resources
@@ -173,13 +234,20 @@ public struct Recipe: Codable, Sendable, Equatable {
         substitutes = try c.decodeIfPresent([String].self, forKey: .substitutes) ?? []
         shim = try c.decodeIfPresent(Shim.self, forKey: .shim)
         brew = try c.decodeIfPresent([String].self, forKey: .brew) ?? []
+        metalToolchain = try c.decodeIfPresent(Bool.self, forKey: .metalToolchain) ?? false
         weights = try c.decodeIfPresent([Weight].self, forKey: .weights) ?? []
+        attribution = try c.decodeIfPresent(Attribution.self, forKey: .attribution)
         developer = try c.decodeIfPresent(Bool.self, forKey: .developer) ?? false
         resources = try c.decode(Resources.self, forKey: .resources)
         stages = try c.decodeIfPresent([StagePattern].self, forKey: .stages) ?? []
         tasks = try c.decode([RecipeTask].self, forKey: .tasks)
     }
 
+    enum CodingKeys: String, CodingKey {
+        case schema, id, name, publisher, license, homepage, repo, commit, python, platform, install, substitutes, shim, brew
+        case metalToolchain = "metal_toolchain", weights, attribution, developer, resources, stages, tasks
+    }
+
     public func task(_ id: String) -> RecipeTask? { tasks.first { $0.id == id } }
 }
 
```

```diff
--- a/Sources/LiftCore/Recipes/Validation.swift
+++ b/Sources/LiftCore/Recipes/Validation.swift
@@ -12,6 +12,16 @@ extension Recipe {
         if let commit, commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) == nil {
             out.append("commit must be a full 40-character sha")
         }
+        if let a = attribution {
+            let blank: [(String, String)] = [("project", a.project), ("homepage", a.homepage), ("license.spdx", a.license.spdx), ("license.url", a.license.url)]
+            for (field, value) in blank where value.trimmingCharacters(in: .whitespaces).isEmpty { out.append("attribution.\(field) is required") }
+            if a.authors.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { out.append("attribution.authors is required") }
+            for (i, c) in a.components.enumerated() where c.name.isEmpty || c.url.isEmpty || c.license.spdx.isEmpty || c.license.url.isEmpty {
+                out.append("attribution.components[\(i)] needs name, url and license")
+            }
+        } else {
+            out.append("attribution is required: who made it, where it comes from and its license")
+        }
         if platform.status == .unsupported && (platform.reason ?? "").isEmpty {
             out.append("platform.reason is required when unsupported")
         }
```

- [ ] **Step 4: Implement the installer and verifier changes**

```diff
--- a/Sources/LiftCore/Installer/Installer.swift
+++ b/Sources/LiftCore/Installer/Installer.swift
@@ -141,11 +141,14 @@ public struct Installer: Sendable {
     public func install(_ entry: CatalogEntry, pin: String?, onLine: @escaping @Sendable (String) -> Void) async throws {
         let (registry, shimConfig) = try preflight(entry)
         let recipe = entry.recipe
+        if recipe.metalToolchain, try await runner.run(ShellCommand("/usr/bin/xcrun", ["metal", "--version"]), onLine: { _ in }) != 0 {
+            throw LiftError.prerequisite("\(recipe.name) needs the Metal Toolchain; run system_install_prereqs with metal")
+        }
         let commit = pin ?? recipe.commit
         let git = tools.git!, uv = tools.uv!
         let fm = FileManager.default
         let root = dir(recipe.id)
-        for name in ["repo", "venv", "recipe", "state.json", "shim.json", "install.log"] {
+        for name in ["repo", "venv", "deps", "recipe", "state.json", "shim.json", "install.log"] {
             try? fm.removeItem(at: root.appending(path: name))
         }
         try fm.createDirectory(at: root, withIntermediateDirectories: true)
@@ -242,7 +245,7 @@ public struct Installer: Sendable {
         return env
     }
 
-    /// `hf download <repo> --revision <rev>` for each weight, from the model's venv into the shared cache.
+    /// `hf download <repo> [<files>…] --revision <rev>` for each weight, from the model's venv into the shared cache.
     /// Appends to `install.log`. Only ever started by an explicit user action (spec §6).
     public func downloadWeights(_ recipe: Recipe, onLine: @escaping @Sendable (String) -> Void) async throws {
         let hf = dir(recipe.id).appending(path: "venv/bin/hf").path
@@ -258,7 +261,7 @@ public struct Installer: Sendable {
             onLine(line)
         }
         for w in recipe.weights {
-            let command = ShellCommand(hf, ["download", w.repo, "--revision", w.revision], environment: workerEnvironment(recipe))
+            let command = ShellCommand(hf, ["download", w.repo] + (w.files ?? []) + ["--revision", w.revision], environment: workerEnvironment(recipe))
             lines("$ \(command.display)")
             try await runner.check(command, onLine: lines)
         }
```

```diff
--- a/Sources/LiftCore/Weights/Weights.swift
+++ b/Sources/LiftCore/Weights/Weights.swift
@@ -31,6 +31,16 @@ public struct RepoSnapshot: Codable, Sendable, Equatable {
     }
 }
 
+extension RepoSnapshot {
+    /// Just these files (a recipe's `weights[].files`); nil keeps the whole repo.
+    func only(_ paths: [String]?) -> RepoSnapshot {
+        guard let paths else { return self }
+        var s = self
+        s.files = files.filter { paths.contains($0.path) }
+        return s
+    }
+}
+
 public enum WeightsMetadataError: Error, Sendable, Equatable {
     /// No network (or Hugging Face unreachable): verification may fall back to the last good check.
     case offline
@@ -188,7 +198,7 @@ public struct WeightsVerifier: Sendable {
     public func totalBytes(_ recipe: Recipe) async -> Int? {
         var total = 0
         for w in recipe.weights {
-            guard let s = try? await metadata.snapshot(repo: w.repo, revision: w.revision) else { return nil }
+            guard let s = try? await metadata.snapshot(repo: w.repo, revision: w.revision).only(w.files) else { return nil }
             total += s.files.reduce(0) { $0 + $1.size }
         }
         return total
@@ -200,7 +210,13 @@ public struct WeightsVerifier: Sendable {
         guard !recipe.weights.isEmpty else { return report }
         var snapshots: [RepoSnapshot] = []
         do {
-            for w in recipe.weights { snapshots.append(try await snapshot(for: w, report: &report)) }
+            for w in recipe.weights {
+                let s = try await snapshot(for: w, report: &report)
+                for path in w.files ?? [] where !s.files.contains(where: { $0.path == path }) {
+                    report.problems.append(WeightProblem(repo: w.repo, path: path, issue: .missing, detail: "not in \(w.repo)@\(w.revision)"))
+                }
+                snapshots.append(s.only(w.files))
+            }
         } catch let error as WeightsMetadataError {
             // Offline, an outage (5xx) or a rate limit (429): fall back to the last good check's file lists.
             // A refusal (401/403/404) is an answer, not an outage: unknown.
```

Every recipe now needs an attribution block, including the Test Cube:

```diff
--- a/dev-recipes/test-cube/recipe.yaml
+++ b/dev-recipes/test-cube/recipe.yaml
@@ -7,6 +7,13 @@ publisher: Lift
 license: MIT
 python: "3.11"
 platform: { status: supported }
+attribution:
+  project: Test Cube
+  authors: [Lift]
+  homepage: https://github.com/oshricohenme/local_image_to_3d
+  license: { spdx: MIT, url: https://github.com/oshricohenme/local_image_to_3d }
+  components:
+    - { name: trimesh, url: https://github.com/mikedh/trimesh, license: { spdx: MIT, url: https://github.com/mikedh/trimesh/blob/main/LICENSE.md } }
 install:
   - uv pip install "trimesh>=4,<5" numpy
 shim: { env: { TEST_CUBE_SHIM: "on" } }   # exercises lift_shim + .pth + LIFT_SHIM end to end
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "RecipeTests|InstallerTests|WeightsTests|CatalogTests|BundledTests|CommandTests|CubeIntegrationTests"`
Expected: all pass (the new `metalToolchainAndWeightFiles`, `attributionIsRequiredAndComplete`, `aRecipeNeedingTheMetalToolchainChecksItBeforeTouchingAnything`, `depsStartsEmptyOnEveryInstall`, `weightDownloadsNameOnlyTheListedFiles`, `onlyTheListedFilesAreCheckedAndCounted` among them). Then `swift test` — every suite passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiftCore/Recipes/Recipe.swift Sources/LiftCore/Recipes/Validation.swift Sources/LiftCore/Installer/Installer.swift \
        Sources/LiftCore/Weights/Weights.swift dev-recipes/test-cube/recipe.yaml \
        Tests/LiftCoreTests/RecipeTests.swift Tests/LiftCoreTests/InstallerTests.swift Tests/LiftCoreTests/WeightsTests.swift
git commit -m "feat(core): recipe metal_toolchain, weights[].files subsets and the required attribution block" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Sources/LiftCore/Recipes/Recipe.swift Sources/LiftCore/Recipes/Validation.swift Sources/LiftCore/Installer/Installer.swift \
        Sources/LiftCore/Weights/Weights.swift dev-recipes/test-cube/recipe.yaml \
        Tests/LiftCoreTests/RecipeTests.swift Tests/LiftCoreTests/InstallerTests.swift Tests/LiftCoreTests/WeightsTests.swift
```

---
### Task 2: Workers lead their own process group — kill and exit take upstream's children along

Spec §8: "Cancel/Kill … sends SIGKILL to that job's worker and its whole process group, so grandchildren and any GPU memory they hold go too." UniRig runs `bash` → `python run.py` children; without this, killing the worker orphans them. If the repo's `WorkerProcess.kill()` already signals `-pid` by the time this runs, keep the tests and skip the Swift hunk.

**Files:**
- Modify: `Sources/LiftCore/Workers/WorkerProcess.swift`
- Modify: `python/lift_worker/src/lift_worker/worker.py`
- Modify: `python/lift_worker/tests/conftest.py`, `python/lift_worker/tests/fixtures/launcher.py`
- Test: `python/lift_worker/tests/test_worker.py`, `Tests/LiftCoreTests/WorkerProcessTests.swift`

**Interfaces:**
- Consumes (Plan 1): `WorkerProcess(executable:arguments:environment:workingDirectory:)`, `kill()`, the fixture launcher's settings protocol, `EventRecorder`, `eventually`.
- Produces: workers start with `PlatformOptions.processGroupID = 0` (their own group); `kill()` sends `SIGKILL` to `-pid`. `lift_worker` exits through `_exit_group(code)`: when it is its group's leader it `SIGTERM`s the group (ignoring the signal itself) before `os._exit`. Fixture launcher setting `spawn: true` starts `sleep 300` and writes its pid to `<out_dir>/child.pid`.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/python/lift_worker/tests/fixtures/launcher.py
+++ b/python/lift_worker/tests/fixtures/launcher.py
@@ -1,5 +1,6 @@
 """Test launcher: behaviour is driven by job settings."""
 import os
+import subprocess
 import sys
 import threading
 import time
@@ -29,6 +30,10 @@ def run(state, job):
         t = threading.Thread(target=lambda: print("from upstream thread"))
         t.start()
         t.join()
+    if s.get("spawn"):  # like UniRig: upstream work in a child process, its pid left for the test
+        child = subprocess.Popen(["sleep", "300"])
+        with open(os.path.join(job.out_dir, "child.pid"), "w") as f:
+            f.write(str(child.pid))
     end = time.monotonic() + float(s.get("sleep", 0))
     while time.monotonic() < end:
         if job.cancelled:
```

```diff
--- a/python/lift_worker/tests/conftest.py
+++ b/python/lift_worker/tests/conftest.py
@@ -24,6 +24,7 @@ class WorkerProc:
             [sys.executable, "-m", "lift_worker", json.dumps(config)],
             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
             env={**os.environ, "PYTHONPATH": str(SRC), **(env or {})},
+            process_group=0,  # as Lift starts workers: a process-group leader
         )
         self.events: queue.Queue = queue.Queue()
         self.raw_stdout: list[str] = []
```

```diff
--- a/python/lift_worker/tests/test_worker.py
+++ b/python/lift_worker/tests/test_worker.py
@@ -4,6 +4,8 @@ import subprocess
 import sys
 import time
 
+import pytest
+
 from conftest import FIXTURE, SRC
 
 TAG = {"pattern": r"^\[Stage\] (?P<name>.+)$"}
@@ -148,3 +150,33 @@ def test_unicode_line_separators_stay_inside_one_protocol_line(worker):
     assert {"ev": "log", "job": "j1", "line": "a\u2028b\u2029c\u0085d"} in evs
     # Swift's line splitting treats U+2028/U+2029/U+0085 as line breaks: they must be escaped on the wire.
     assert not any(ch in line for line in w.raw_stdout for ch in "\u2028\u2029\u0085")
+
+def _alive(pid):
+    try:
+        os.kill(pid, 0)
+        return True
+    except ProcessLookupError:
+        return False
+
+
+@pytest.mark.parametrize("stop", ["eof", "shutdown"])
+def test_exit_takes_upstream_children_along(worker, tmp_path, stop):
+    w = worker()
+    w.until(is_ev("ready"))
+    w.run("j1", spawn=True, sleep=30)
+    pid_file = tmp_path / "j1" / "child.pid"
+    end = time.monotonic() + 5
+    while not pid_file.exists() and time.monotonic() < end:
+        time.sleep(0.02)
+    child = int(pid_file.read_text())
+    assert _alive(child)
+    if stop == "eof":
+        w.p.stdin.close()
+    else:
+        w.send(op="shutdown")
+    assert w.p.wait(5) == 0
+    end = time.monotonic() + 5
+    while _alive(child) and time.monotonic() < end:
+        time.sleep(0.05)
+    assert not _alive(child)
+
```

```diff
--- a/Tests/LiftCoreTests/WorkerProcessTests.swift
+++ b/Tests/LiftCoreTests/WorkerProcessTests.swift
@@ -69,6 +69,21 @@ func isExited(_ e: WorkerEvent) -> Bool { if case .exited = e { true } else { fa
         #expect(ContinuousClock.now - t0 < .seconds(5))
     }
 
+    @Test func killAlsoStopsWhatUpstreamStarted() async throws {
+        let dir = try Fixtures.tempDir()
+        let w = try await launch(dir)
+        let r = EventRecorder(w)
+        _ = try await r.wait(for: isReady)
+        w.send(.run(job: "j1", step: 0, task: "t", inputs: [:], settings: ["spawn": .bool(true), "sleep": .int(60)], outDir: dir.path))
+        let pidFile = dir.appending(path: "child.pid")
+        #expect(try await eventually(5) { FileManager.default.fileExists(atPath: pidFile.path) })
+        let child = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))
+        #expect(Darwin.kill(child, 0) == 0)
+        w.kill()
+        _ = try await r.wait(for: isExited)
+        #expect(try await eventually(5) { Darwin.kill(child, 0) != 0 })
+    }
+
     @Test func crashReportsExitCode() async throws {
         let dir = try Fixtures.tempDir()
         let w = try await launch(dir)
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd python/lift_worker && uv run --python 3.11 pytest -q -k children`
Expected: `2 failed` — the `sleep` child outlives the worker (`assert not _alive(child)`).
Run: `swift test --filter killAlsoStopsWhatUpstreamStarted`
Expected: FAIL at `eventually(5) { Darwin.kill(child, 0) != 0 }` after 5 s.
Then stop the orphaned test children: `pkill -f "sleep 300"` (they are the tests' own processes).

- [ ] **Step 3: Implement**

```diff
--- a/Sources/LiftCore/Workers/WorkerProcess.swift
+++ b/Sources/LiftCore/Workers/WorkerProcess.swift
@@ -23,6 +23,9 @@ public final class WorkerProcess: Sendable {
         var overrides: [Environment.Key: String?] = [:]
         for (k, v) in environment { overrides[Environment.Key(rawValue: k)!] = v }
         let env = Environment.inherit.updating(overrides)
+        // Its own process group, so kill() also stops what upstream started (UniRig's bash → python stages).
+        var options = PlatformOptions()
+        options.processGroupID = 0
         let pid = self.pid
         task = Task {
             var code: Int32
@@ -32,6 +35,7 @@ public final class WorkerProcess: Sendable {
                     arguments: Arguments(arguments),
                     environment: env,
                     workingDirectory: workingDirectory.map { FilePath($0) },
+                    platformOptions: options,
                     input: .inputWriter,
                     output: .sequence,
                     error: .sequence
@@ -70,9 +74,9 @@ public final class WorkerProcess: Sendable {
         ops.yield(op.line)
     }
 
-    /// Stops the process now with SIGKILL, even if it is stuck in native code.
+    /// Stops the process and everything it started (its process group) now with SIGKILL, even if stuck in native code.
     public func kill() {
         let p = pid.value.withLock { $0 }
-        if p > 0 { Darwin.kill(p, SIGKILL) } else { task.cancel() }
+        if p > 0 { Darwin.kill(-p, SIGKILL) } else { task.cancel() }
     }
 }
```

```diff
--- a/python/lift_worker/src/lift_worker/worker.py
+++ b/python/lift_worker/src/lift_worker/worker.py
@@ -4,6 +4,7 @@ from __future__ import annotations
 import importlib.util
 import json
 import os
+import signal
 import sys
 import threading
 import time
@@ -29,6 +30,14 @@ def load_launcher(cfg: dict):
     return module
 
 
+def _exit_group(code: int) -> None:
+    """Exit now, taking down processes upstream started: Lift starts each worker as a process-group leader."""
+    if os.getpgrp() == os.getpid():
+        signal.signal(signal.SIGTERM, signal.SIG_IGN)
+        os.killpg(os.getpid(), signal.SIGTERM)
+    os._exit(code)
+
+
 def _mps_allocated() -> int:
     torch = sys.modules.get("torch")  # never import torch here: it is the launcher's choice
     try:
@@ -117,7 +126,7 @@ class Worker:
             for s in self.streams:
                 s.drain()
             self.ch.send(ev="error", job=None, message=f"{type(e).__name__}: {e}", traceback=traceback.format_exc())
-            os._exit(1)
+            _exit_group(1)
         for s in self.streams:
             s.drain()
         self.ch.send(ev="ready", protocol=PROTOCOL, load_seconds=round(time.perf_counter() - t0, 3))
@@ -148,7 +157,7 @@ class Worker:
                     job._cancel.set()
             elif op == "shutdown":
                 break
-        os._exit(0)
+        _exit_group(0)
 
     def _run(self, job: Job) -> None:
         self.local.job = job.id
```

- [ ] **Step 4: Run the tests**

Run: `cd python/lift_worker && uv run --python 3.11 pytest -q`
Expected: `25 passed`.
Run: `swift test --filter "WorkerProcessTests|CubeIntegrationTests|EngineTests"`
Expected: all pass, `killAlsoStopsWhatUpstreamStarted` and `cancelRunningStopsTheWorker` included.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiftCore/Workers/WorkerProcess.swift python/lift_worker/src/lift_worker/worker.py \
        python/lift_worker/tests/conftest.py python/lift_worker/tests/fixtures/launcher.py python/lift_worker/tests/test_worker.py \
        Tests/LiftCoreTests/WorkerProcessTests.swift
git commit -m "feat(worker): workers lead their process group; kill and exit take upstream's children along" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Sources/LiftCore/Workers/WorkerProcess.swift python/lift_worker/src/lift_worker/worker.py \
        python/lift_worker/tests/conftest.py python/lift_worker/tests/fixtures/launcher.py python/lift_worker/tests/test_worker.py \
        Tests/LiftCoreTests/WorkerProcessTests.swift
```

---
### Task 3: Substitute registry, the Pixal3D recipe, and the recipe-test scaffold

**Files:**
- Modify (whole file): `dev-recipes/shared/substitutes.yaml`
- Create: `dev-recipes/pixal3d/recipe.yaml`, `dev-recipes/pixal3d/launcher.py`
- Create: `python/recipe_tests/pyproject.toml`, `python/recipe_tests/conftest.py`, `python/recipe_tests/test_pixal3d.py` (and the `uv.lock` uv writes)
- Modify: `.github/workflows/test.yml` (one step), `Tests/LiftCoreTests/CommandTests.swift` (robust to more bundled recipes)

**Interfaces:**
- Consumes: Task 1's `metal_toolchain`, `weights[].files`, `attribution`; Plan 1's launcher contract (`run(state, job)`, `job.task/inputs/settings/out_dir/cancelled/stage`), worker cwd = `models/<id>/repo` with `repo/` on `sys.path`; Plan 1's `ImageSet` (png/jpg/jpeg/webp + `transforms.json`).
- Produces:
  - Registry entries `flex_gemm`, `nvdiffrast` (alias `mtldiffrast`), `cumesh`, `o_voxel`, `flash_attn`, `spconv`, `torch_scatter` (patch `torch_scatter_mps`), `torch_cluster` (patch `torch_cluster_mps`).
  - Recipe `pixal3d` with tasks `image_to_3d` (input `image`) and `image_set_to_3d` (input `views`), output `mesh.glb` in `out_dir`.
  - `launcher.views_folder(folder, layout, out_dir) -> str` and `launcher.orbit(paths, elevation_deg, fov_deg, distance) -> dict` (transforms.json content).
  - Test helpers in `python/recipe_tests/conftest.py`: `FakeJob(task, inputs, settings, out_dir)` (records `stages`), `defaults(recipe, task) -> dict`, `module(name, **attrs)`, fixture `launcher(recipe, fakes) -> module`. Tasks 4–6 use them.

The recipe tests live in `python/recipe_tests/`, not `dev-recipes/`, because everything in `dev-recipes/` is bundled into the app and copied into every workdir.

- [ ] **Step 1: Write the test scaffold and the failing Pixal3D tests**

`python/recipe_tests/pyproject.toml`:

```toml
[project]
name = "lift-recipe-tests"
version = "0.1.0"
description = "Weight-free tests for the bundled recipes' launchers: upstream entry points are faked"
requires-python = ">=3.10"
dependencies = []

[dependency-groups]
dev = ["pytest>=8", "pyyaml>=6", "numpy"]

[tool.uv]
package = false

[tool.pytest.ini_options]
testpaths = ["."]
```

`python/recipe_tests/conftest.py`:

```python
"""Helpers: load a recipe's launcher.py with fake upstream modules, and a stand-in for lift_worker's Job."""
import importlib.util
import sys
import types
from pathlib import Path

import pytest
import yaml

RECIPES = Path(__file__).resolve().parents[2] / "dev-recipes"


class FakeJob:
    """The launcher contract's job: id, step, task, inputs, settings, out_dir, cancelled, stage()."""

    def __init__(self, task, inputs, settings, out_dir):
        self.id, self.step, self.task = "job-1", 0, task
        self.inputs, self.settings, self.out_dir = inputs, settings, str(out_dir)
        self.cancelled = False
        self.stages = []

    def stage(self, name, fraction=None):
        self.stages.append((name, fraction))


def defaults(recipe, task):
    """The task's settings as Lift sends them when the caller changes nothing."""
    data = yaml.safe_load((RECIPES / recipe / "recipe.yaml").read_text())
    task = next(t for t in data["tasks"] if t["id"] == task)
    return {s["key"]: s["default"] for s in task["settings"]}


def module(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    return m


@pytest.fixture
def launcher(monkeypatch):
    """launcher("pixal3d", {"inference": fake, ...}) imports dev-recipes/pixal3d/launcher.py against the fakes."""

    monkeypatch.setattr(sys, "path", list(sys.path))  # launchers may extend sys.path at import

    def load(recipe, fakes):
        for name, fake in fakes.items():
            monkeypatch.setitem(sys.modules, name, fake)
        spec = importlib.util.spec_from_file_location(f"launcher_{recipe.replace('-', '_')}", RECIPES / recipe / "launcher.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    return load
```

`python/recipe_tests/test_pixal3d.py` (the `EXAMPLE` constant is upstream's `assets/mv_images/example/transforms.json` at the pin):

```python
import json
import math
from pathlib import Path

import pytest

from conftest import FakeJob, defaults, module

# Upstream's assets/mv_images/example/transforms.json at f7cf384 (the four_view preset copies it).
D = 3.1192049980163574
EXAMPLE = {
    "camera_angle_x": 0.3490658503988659, "mesh_scale": 1.0,
    "frames": [
        {"file_path": "view00_azim000.png", "name": "azim000", "transform_matrix": [[1.0, 0.0, 0.0, 0.0], [0.0, 0.0, -1.0, -D], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view01_azim090.png", "name": "azim090", "transform_matrix": [[0.0, 0.0, 1.0, D], [1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view02_azim180.png", "name": "azim180", "transform_matrix": [[-1.0, 0.0, 0.0, 0.0], [0.0, 0.0, 1.0, D], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view03_azim270.png", "name": "azim270", "transform_matrix": [[0.0, 0.0, -1.0, -D], [-1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
    ],
}


def fake_upstream(name, repo, write=True):
    """inference / inference_mv: run_inference calls the module-level init_pipeline the way upstream does."""
    m = module(name, __file__=str(repo / f"{name}.py"), init_calls=[], runs=[])

    def init_pipeline(model_path, *args, low_vram=False):
        m.init_calls.append((model_path, low_vram))
        return object()

    def run_inference(output_path, **kw):
        m.init_pipeline(kw["model_path"], low_vram=kw["low_vram"])
        m.runs.append(kw)
        if write:
            Path(output_path).write_bytes(b"glTF")

    m.init_pipeline, m.run_inference = init_pipeline, run_inference
    return m


@pytest.fixture
def pixal(launcher, tmp_path):
    repo = tmp_path / "repo"
    (repo / "assets/mv_images/example").mkdir(parents=True)
    (repo / "assets/mv_images/example/transforms.json").write_text(json.dumps(EXAMPLE))
    fakes = {"inference": fake_upstream("inference", repo), "inference_mv": fake_upstream("inference_mv", repo)}
    return launcher("pixal3d", fakes), fakes


def job(task, inputs, tmp_path, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob(task, inputs, {**defaults("pixal3d", task), **changes}, out)


def images(folder, *names):
    folder.mkdir()
    for n in names:
        (folder / n).write_bytes(b"png")
    return str(folder)


def test_image_to_3d_passes_every_setting_as_a_keyword(pixal, tmp_path):
    mod, fakes = pixal
    j = job("image_to_3d", {"image": "/in/photo.png"}, tmp_path)
    assert mod.run(None, j) == [f"{j.out_dir}/mesh.glb"]
    (kw,) = fakes["inference"].runs
    assert kw == {"image_path": "/in/photo.png", **defaults("pixal3d", "image_to_3d")}


def test_pipeline_stays_loaded_until_model_path_or_low_vram_change(pixal, tmp_path):
    mod, fakes = pixal
    for low in (False, False, True, False):
        mod.run(None, job("image_to_3d", {"image": "/in/a.png"}, tmp_path, low_vram=low))
    assert fakes["inference"].init_calls == [("TencentARC/Pixal3D", False), ("TencentARC/Pixal3D", True), ("TencentARC/Pixal3D", False)]


def test_missing_output_is_an_error(launcher, tmp_path):
    repo = tmp_path / "repo"
    mod = launcher("pixal3d", {"inference": fake_upstream("inference", repo, write=False), "inference_mv": fake_upstream("inference_mv", repo)})
    with pytest.raises(RuntimeError, match="without writing"):
        mod.run(None, job("image_to_3d", {"image": "/in/a.png"}, tmp_path))


def test_transforms_folder_is_used_as_is_and_layout_settings_stay_in_lift(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "views", "a.png", "transforms.json")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, num_views=3))
    (kw,) = fakes["inference_mv"].runs
    assert kw["views_dir"] == folder and kw["num_views"] == 3
    assert not {"views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance"} & kw.keys()
    expected = {k: v for k, v in defaults("pixal3d", "image_set_to_3d").items() if not k.startswith("orbit_") and k != "views"}
    assert kw == {"views_dir": folder, **expected, "num_views": 3}


def test_num_views_zero_means_all(pixal, tmp_path):
    mod, fakes = pixal
    mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "transforms.json")}, tmp_path))
    assert fakes["inference_mv"].runs[0]["num_views"] is None


def test_transforms_layout_without_transforms_json_is_rejected(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="transforms.json"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "a.png")}, tmp_path))


def test_four_view_writes_upstream_example_cameras_with_your_files(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "v", "left.jpg", "FRONT.png", "back.PNG", "right.webp")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, views="four_view"))
    views_dir = fakes["inference_mv"].runs[0]["views_dir"]
    assert views_dir == f"{tmp_path}/out/views"
    meta = json.loads(Path(views_dir, "transforms.json").read_text())
    assert [f["file_path"] for f in meta["frames"]] == [f"{folder}/{n}" for n in ("FRONT.png", "right.webp", "back.PNG", "left.jpg")]
    assert [f["transform_matrix"] for f in meta["frames"]] == [f["transform_matrix"] for f in EXAMPLE["frames"]]
    assert meta["camera_angle_x"] == EXAMPLE["camera_angle_x"]


def test_four_view_names_the_missing_slots(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="missing: back, left"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "front.png", "right.png")}, tmp_path, views="four_view"))


def test_orbit_of_four_matches_the_upstream_example(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "v", "1.png", "2.png", "3.png", "4.png", "notes.txt")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, views="orbit"))
    meta = json.loads(Path(fakes["inference_mv"].runs[0]["views_dir"], "transforms.json").read_text())
    assert [f["file_path"] for f in meta["frames"]] == [f"{folder}/{n}.png" for n in "1234"]
    assert [f["name"] for f in meta["frames"]] == ["azim000", "azim090", "azim180", "azim270"]
    assert meta["camera_angle_x"] == pytest.approx(EXAMPLE["camera_angle_x"])
    for got, want in zip(meta["frames"], EXAMPLE["frames"]):
        for got_row, want_row in zip(got["transform_matrix"], want["transform_matrix"]):
            assert got_row == pytest.approx(want_row)


def test_orbit_elevation_raises_the_cameras_and_keeps_rotations_orthonormal(pixal, tmp_path):
    mod, _ = pixal
    meta = mod.orbit(["a", "b", "c"], elevation_deg=30.0, fov_deg=40.0, distance=2.0)
    assert meta["camera_angle_x"] == pytest.approx(math.radians(40))
    for frame in meta["frames"]:
        m = frame["transform_matrix"]
        assert m[2][3] == pytest.approx(2.0 * math.sin(math.radians(30)))  # camera height
        assert math.dist((0, 0, 0), [m[r][3] for r in range(3)]) == pytest.approx(2.0)
        cols = [[m[r][c] for r in range(3)] for c in range(3)]
        for i in range(3):
            for k in range(3):
                assert sum(a * b for a, b in zip(cols[i], cols[k])) == pytest.approx(1.0 if i == k else 0.0, abs=1e-9)


def test_orbit_needs_images(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="no images"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "notes.txt")}, tmp_path, views="orbit"))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q test_pixal3d.py`
Expected: every test errors with `FileNotFoundError: … dev-recipes/pixal3d/recipe.yaml` (or `launcher.py`).

- [ ] **Step 3: Write the substitute registry**

Replace `dev-recipes/shared/substitutes.yaml` with:

```yaml
# Substitute registry (spec §5): CUDA-only package → how to provide it on Apple Silicon.
# Keys are the names recipes list under `substitutes:`. Fields:
#   install: commands run in models/<id>/ with the venv active, after the recipe's own install steps
#   alias:   `import <key>` resolves to this installed module (lift_shim alias)
#   standin: a lift_shim built-in stand-in
#   patches: named lift_shim runtime patches the substitute needs
# Recipes using alias/standin/patches must have `shim:`.
#
# Metal builds: pedronaugusto's forks, pinned to the commits verified in the go/no-go test
# (docs/superpowers/findings/2026-10-go-no-go.md). They compile against the venv's torch
# (--no-build-isolation) with a hardcoded -std=c++17, so they need torch >=2.11 (at::mps::dispatch_sync_with_rethrow)
# and <2.14 (its headers need C++20); each checks that first. MACOSX_DEPLOYMENT_TARGET=12.0 because PyTorch's MPS
# headers reject uv Python's default 11.0. They need the Metal Toolchain: recipes using them set `metal_toolchain: true`.
# deps/ is Lift's own folder in models/<id>/; the installer empties it before every install, and each clone
# step converges anyway (clones when missing, else fetches and force-checks-out the pin).

flex_gemm:
  install:
    - python -c "import torch; v = torch.__version__; assert '2.11' <= v < '2.14', f'mtlgemm needs torch >=2.11,<2.14; found {v}'"
    - '{ [ -d deps/mtlgemm/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlgemm deps/mtlgemm; } && git -C deps/mtlgemm fetch -q origin && git -C deps/mtlgemm checkout -qf 566c133781ce4992de3f77c3a97dd6feaae9d013'
    - MACOSX_DEPLOYMENT_TARGET=12.0 uv pip install --no-build-isolation deps/mtlgemm

nvdiffrast:
  alias: mtldiffrast
  install:
    - python -c "import torch; v = torch.__version__; assert '2.11' <= v < '2.14', f'mtldiffrast needs torch >=2.11,<2.14; found {v}'"
    - '{ [ -d deps/mtldiffrast/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtldiffrast deps/mtldiffrast; } && git -C deps/mtldiffrast fetch -q origin && git -C deps/mtldiffrast checkout -qf c9499ba2e4ed6849e95ce5da7aae5bf61addb528'
    - MACOSX_DEPLOYMENT_TARGET=12.0 uv pip install --no-build-isolation deps/mtldiffrast

# mtlmesh provides the `cumesh` module and imports mtlbvh, so mtlbvh is built first.
cumesh:
  install:
    - python -c "import torch; v = torch.__version__; assert '2.11' <= v < '2.14', f'mtlmesh needs torch >=2.11,<2.14; found {v}'"
    - '{ [ -d deps/mtlbvh/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlbvh deps/mtlbvh; } && git -C deps/mtlbvh fetch -q origin && git -C deps/mtlbvh checkout -qf 6b2a0f63b476ad8225695d092902104beafd7f58'
    - '{ [ -d deps/mtlmesh/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlmesh deps/mtlmesh; } && git -C deps/mtlmesh fetch -q origin && git -C deps/mtlmesh checkout -qf 7de3864f783407201486bf6c900a4bd76a4018a3'
    - MACOSX_DEPLOYMENT_TARGET=12.0 uv pip install --no-build-isolation deps/mtlbvh
    - MACOSX_DEPLOYMENT_TARGET=12.0 uv pip install --no-build-isolation deps/mtlmesh

# o_voxel from the Apple fork. Without its Eigen submodule it silently builds without the Metal baker.
o_voxel:
  install:
    - python -c "import torch; v = torch.__version__; assert '2.11' <= v < '2.14', f'o_voxel needs torch >=2.11,<2.14; found {v}'"
    - '{ [ -d deps/trellis2-apple/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/trellis2-apple deps/trellis2-apple; } && git -C deps/trellis2-apple fetch -q origin && git -C deps/trellis2-apple checkout -qf 17347247c91c36c8cdc1896234983e878a457bba'
    - git -C deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen
    - MACOSX_DEPLOYMENT_TARGET=12.0 uv pip install --no-build-isolation deps/trellis2-apple/o-voxel

flash_attn: { standin: flash_attn }

# spconv has no macOS wheel or sdist: lift_shim's pure-torch SubMConv3d / SparseConvTensor.
spconv: { standin: spconv }

# The recipe installs CPU builds of torch_scatter / torch_cluster; these patches move their CPU-only
# compiled ops (segment_csr, fps) through the CPU when called with MPS tensors.
torch_scatter: { patches: [torch_scatter_mps] }
torch_cluster: { patches: [torch_cluster_mps] }
```

- [ ] **Step 4: Write the Pixal3D recipe and launcher**

`dev-recipes/pixal3d/recipe.yaml` (install steps from `spike/setup_pixal3d.sh`; every setting is a keyword argument of upstream's `run_inference` with its default — Task 6's `test_upstream_settings.py` checks that against the real code):

```yaml
# Pixal3D (TencentARC) through lift_shim. Install steps and pins: docs/superpowers/findings/2026-10-go-no-go.md.
schema: 1
id: pixal3d
name: Pixal3D
publisher: TencentARC
license: MIT
homepage: https://github.com/TencentARC/Pixal3D
repo: https://github.com/TencentARC/Pixal3D
commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94
python: "3.11"
platform: { status: supported }
shim: {}          # on; the substitutes below add the nvdiffrast alias and the flash_attn stand-in
metal_toolchain: true
install:
  # torch 2.11: the mtl* substitutes need >=2.11 and build with C++17, which 2.14 headers reject.
  - uv pip install "torch==2.11.*" torchvision
  # MoGe (unpinned in requirements.txt) is installed below at a pin and without its CUDA-only deps;
  # MoGe needs trimesh>=4.11 while requirements.txt pins 4.10.1.
  - grep -v MoGe repo/requirements.txt > requirements-mac.txt && echo "trimesh>=4.11" > overrides-mac.txt
  - uv pip install -r requirements-mac.txt --override overrides-mac.txt
  - uv pip install --no-deps "moge @ git+https://github.com/microsoft/MoGe.git@74fbce054ebed49800de42d0ad0e83495065719a"
  - uv pip install "click>=8.3.1" matplotlib requests huggingface-hub starlette "utils3d_moge @ git+https://github.com/EasternJournalist/utils3d-moge.git@62f09d58509485564e24d5d9f6aac9ee9ebc0c37" "pipeline @ git+https://github.com/EasternJournalist/pipeline.git@1c511390d90226c00c101f34b84df26a0f8789b4"
  - uv pip install https://github.com/LDYang694/Storages/releases/download/20260430/utils3d-0.0.2-py3-none-any.whl
  - uv pip install setuptools wheel pybind11 xatlas fast-simplification scipy
substitutes: [flex_gemm, nvdiffrast, cumesh, o_voxel, flash_attn]
attribution:   # spec §4a
  project: Pixal3D
  authors: [TencentARC]
  homepage: https://github.com/TencentARC/Pixal3D
  repo: https://github.com/TencentARC/Pixal3D
  license: { spdx: MIT, url: https://github.com/TencentARC/Pixal3D/blob/f7cf38429b0bd264f1995f0f8743a88b1c728b94/LICENSE }
  components:
    - { name: Pixal3D weights, url: https://huggingface.co/TencentARC/Pixal3D, license: { spdx: MIT, url: https://huggingface.co/TencentARC/Pixal3D/blob/main/LICENSE } }
    - { name: MoGe-2 ViT-L (camera estimation), url: https://huggingface.co/Ruicheng/moge-2-vitl, license: { spdx: MIT, url: https://huggingface.co/Ruicheng/moge-2-vitl } }
    - { name: MoGe code, url: https://github.com/microsoft/MoGe, license: { spdx: NOASSERTION, url: https://github.com/microsoft/MoGe/blob/74fbce054ebed49800de42d0ad0e83495065719a/LICENSE } }
    - { name: DINOv3 ViT-L/16 (image features), url: https://huggingface.co/camenduru/dinov3-vitl16-pretrain-lvd1689m, license: { spdx: LicenseRef-DINOv3, url: https://ai.meta.com/resources/models-and-libraries/dinov3-license } }
    - { name: RMBG-2.0 (background removal), url: https://huggingface.co/briaai/RMBG-2.0, license: { spdx: CC-BY-NC-4.0, url: https://creativecommons.org/licenses/by-nc/4.0/ }, restrictions: [non-commercial] }
    - { name: NAF upsampler (torch.hub), url: https://github.com/valeoai/NAF, license: { spdx: Apache-2.0, url: https://github.com/valeoai/NAF/blob/main/LICENSE } }
    - { name: utils3d-moge and pipeline (EasternJournalist), url: https://github.com/EasternJournalist/utils3d-moge, license: { spdx: MIT, url: https://github.com/EasternJournalist/utils3d-moge/blob/62f09d58509485564e24d5d9f6aac9ee9ebc0c37/LICENSE } }
    - { name: utils3d 0.0.2 wheel (LDYang694), url: https://github.com/LDYang694/Storages, license: { spdx: MIT, url: https://github.com/LDYang694/Storages/blob/master/LICENSE } }
    - { name: mtlgemm (FlexGEMM on Metal), url: https://github.com/pedronaugusto/mtlgemm, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlgemm/blob/566c133781ce4992de3f77c3a97dd6feaae9d013/LICENSE } }
    - { name: mtldiffrast (rasterizer on Metal), url: https://github.com/pedronaugusto/mtldiffrast, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtldiffrast/blob/c9499ba2e4ed6849e95ce5da7aae5bf61addb528/LICENSE.txt } }
    - { name: mtlbvh (BVH on Metal), url: https://github.com/pedronaugusto/mtlbvh, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlbvh/blob/6b2a0f63b476ad8225695d092902104beafd7f58/LICENSE.txt } }
    - { name: mtlmesh (CuMesh on Metal), url: https://github.com/pedronaugusto/mtlmesh, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlmesh/blob/7de3864f783407201486bf6c900a4bd76a4018a3/LICENSE } }
    - { name: trellis2-apple (o-voxel for Apple Silicon), url: https://github.com/pedronaugusto/trellis2-apple, license: { spdx: MIT, url: https://github.com/pedronaugusto/trellis2-apple/blob/17347247c91c36c8cdc1896234983e878a457bba/LICENSE } }
weights:
  - { repo: TencentARC/Pixal3D }
  - { repo: Ruicheng/moge-2-vitl }
  - { repo: camenduru/dinov3-vitl16-pretrain-lvd1689m }
  - { repo: briaai/RMBG-2.0, gated: true, files: [config.json, BiRefNet_config.py, birefnet.py, model.safetensors] }   # BiRefNet; not the ONNX exports
  # Also fetched by upstream at first run, outside Hugging Face: the NAF upsampler via torch.hub (github.com/valeoai/NAF).
resources:
  memory_gb: 18
  memory_keys: [low_vram, resolution]
  memory_overrides: [{ when: { low_vram: true }, memory_gb: 12 }]
  disk_gb: 3
stages:
  - { pattern: '^\[(?:Pipeline|ImageCond|NAF|MoGe-2|Views|Camera|Inference|Done)\] (?P<name>.+)$' }
  - { pattern: '^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|' }
  - { pattern: '^\s*(?P<pct>\d+)%\|' }
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: inference:run_inference
    settings:   # every keyword argument of inference.run_inference except image_path/output_path, with its defaults
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: low_vram, label: Low memory mode, type: bool, default: false, group: basic, help: "Models stay on the CPU and move to the GPU per stage: ~10-12 GB instead of ~18 GB, slower." }
      - { key: resolution, label: Resolution, type: enum, options: [-1, 1024, 1536], default: -1, group: basic, help: "-1 = 1024 in low memory mode, else 1536." }
      - { key: manual_fov, label: Camera FOV, type: float, default: -1.0, group: basic, help: "Radians, e.g. 0.2. Below 0 = estimated by MoGe-2." }
      - { key: ss_guidance_strength, label: Sparse structure guidance, type: float, default: 7.5, group: advanced }
      - { key: ss_guidance_rescale, label: Sparse structure guidance rescale, type: float, default: 0.7, group: advanced }
      - { key: ss_sampling_steps, label: Sparse structure steps, type: int, default: 12, min: 1, group: advanced }
      - { key: ss_rescale_t, label: Sparse structure rescale t, type: float, default: 5.0, group: advanced }
      - { key: shape_slat_guidance_strength, label: Shape guidance, type: float, default: 7.5, group: advanced }
      - { key: shape_slat_guidance_rescale, label: Shape guidance rescale, type: float, default: 0.5, group: advanced }
      - { key: shape_slat_sampling_steps, label: Shape steps, type: int, default: 12, min: 1, group: advanced }
      - { key: shape_slat_rescale_t, label: Shape rescale t, type: float, default: 3.0, group: advanced }
      - { key: tex_slat_guidance_strength, label: Texture guidance, type: float, default: 1.0, group: advanced }
      - { key: tex_slat_guidance_rescale, label: Texture guidance rescale, type: float, default: 0.0, group: advanced }
      - { key: tex_slat_sampling_steps, label: Texture steps, type: int, default: 12, min: 1, group: advanced }
      - { key: tex_slat_rescale_t, label: Texture rescale t, type: float, default: 3.0, group: advanced }
      - { key: mesh_scale, label: Mesh scale, type: float, default: 1.0, group: advanced }
      - { key: extend_pixel, label: Extend pixels, type: int, default: 0, group: advanced }
      - { key: image_resolution, label: Image resolution, type: int, default: 512, min: 1, group: advanced }
      - { key: max_num_tokens, label: Max tokens, type: int, default: 49152, min: 1, group: advanced }
      - { key: model_path, label: Model path, type: string, default: TencentARC/Pixal3D, group: advanced, help: "Hugging Face repo or local folder." }
  - id: image_set_to_3d
    modality: 3d
    label: Multi-view → 3D
    inputs: [{ name: views, type: image_set }]
    output: mesh
    entry: inference_mv:run_inference
    settings:   # Lift's view layouts (spec §4), then every keyword argument of inference_mv.run_inference except views_dir/output_path
      - { key: views, label: Views, type: enum, options: [transforms, four_view, orbit], default: transforms, group: basic, help: "transforms: the folder has transforms.json. four_view: files named front, right, back, left (upstream example cameras). orbit: every image in name order, evenly spaced around the object." }
      - { key: orbit_elevation_deg, label: Orbit elevation (degrees), type: float, default: 0.0, min: -89, max: 89, group: basic, help: "orbit only." }
      - { key: orbit_fov_deg, label: Orbit FOV (degrees), type: float, default: 20.0, min: 1, max: 179, group: basic, help: "orbit only; horizontal. The upstream example uses 20°." }
      - { key: orbit_distance, label: Orbit camera distance, type: float, default: 3.1192049980163574, min: 0.01, group: basic, help: "orbit only. The upstream example's distance for a 20° FOV." }
      - { key: num_views, label: Views used, type: int, default: 0, min: 0, group: basic, help: "Use only the first N views; 0 = all." }
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: low_vram, label: Low memory mode, type: bool, default: false, group: basic }
      - { key: resolution, label: Resolution, type: enum, options: [-1, 1024, 1536], default: -1, group: basic, help: "-1 = 1024 in low memory mode, else 1536." }
      - { key: ss_guidance_strength, label: Sparse structure guidance, type: float, default: 7.5, group: advanced }
      - { key: ss_guidance_rescale, label: Sparse structure guidance rescale, type: float, default: 0.7, group: advanced }
      - { key: ss_sampling_steps, label: Sparse structure steps, type: int, default: 12, min: 1, group: advanced }
      - { key: ss_rescale_t, label: Sparse structure rescale t, type: float, default: 5.0, group: advanced }
      - { key: shape_slat_guidance_strength, label: Shape guidance, type: float, default: 7.5, group: advanced }
      - { key: shape_slat_guidance_rescale, label: Shape guidance rescale, type: float, default: 0.5, group: advanced }
      - { key: shape_slat_sampling_steps, label: Shape steps, type: int, default: 12, min: 1, group: advanced }
      - { key: shape_slat_rescale_t, label: Shape rescale t, type: float, default: 3.0, group: advanced }
      - { key: tex_slat_guidance_strength, label: Texture guidance, type: float, default: 1.0, group: advanced }
      - { key: tex_slat_guidance_rescale, label: Texture guidance rescale, type: float, default: 0.0, group: advanced }
      - { key: tex_slat_sampling_steps, label: Texture steps, type: int, default: 12, min: 1, group: advanced }
      - { key: tex_slat_rescale_t, label: Texture rescale t, type: float, default: 3.0, group: advanced }
      - { key: max_num_tokens, label: Max tokens, type: int, default: 49152, min: 1, group: advanced }
      - { key: model_path, label: Model path, type: string, default: TencentARC/Pixal3D, group: advanced }
      - { key: config_file, label: Pipeline config, type: string, default: pipeline_mv.json, group: advanced, help: "Inside model_path; points the pipeline at the multi-view checkpoints." }
```

`dev-recipes/pixal3d/launcher.py`:

```python
"""Pixal3D launcher (TencentARC/Pixal3D @ f7cf384, through lift_shim).

image_to_3d calls upstream's inference.run_inference and image_set_to_3d calls inference_mv.run_inference, with
every setting passed as a keyword argument. Each module's init_pipeline is wrapped in lru_cache(maxsize=1), so a
loaded pipeline is reused by the next job and only rebuilt when model_path / low_vram change. Upstream is
imported here rather than in load(), so the installer's smoke check (`lift_worker --check`) imports it too.
"""
import functools
import json
import math
import os

import inference  # upstream, unmodified: repo/ is on sys.path
import inference_mv

for _module in (inference, inference_mv):
    _module.init_pipeline = functools.lru_cache(maxsize=1)(_module.init_pipeline)

LAYOUT_SETTINGS = ("views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance")
FOUR_VIEW = ("front", "right", "back", "left")  # the frame order of upstream's assets/mv_images/example
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}  # what Lift accepts in an image_set (ImageSet.extensions)


def run(state, job):
    settings = dict(job.settings)
    out = os.path.join(job.out_dir, "mesh.glb")
    if job.task == "image_to_3d":
        inference.run_inference(image_path=job.inputs["image"], output_path=out, **settings)
    else:
        layout = {key: settings.pop(key) for key in LAYOUT_SETTINGS}
        settings["num_views"] = settings["num_views"] or None  # 0 → upstream's default, all views
        views_dir = views_folder(job.inputs["views"], layout, job.out_dir)
        inference_mv.run_inference(views_dir=views_dir, output_path=out, **settings)
    if not os.path.isfile(out):
        raise RuntimeError(f"Pixal3D finished without writing {out}")
    return [out]


def views_folder(folder, layout, out_dir):
    """The folder inference_mv reads: the input itself, or out_dir/views/ with a transforms.json Lift writes."""
    if layout["views"] == "transforms":
        if not os.path.isfile(os.path.join(folder, "transforms.json")):
            raise ValueError(f"views=transforms needs {folder}/transforms.json")
        return folder
    images = sorted(f for f in os.listdir(folder) if os.path.splitext(f)[1].lower() in IMAGE_EXTENSIONS)
    if layout["views"] == "four_view":
        by_stem = {os.path.splitext(f)[0].lower(): f for f in images}
        missing = [slot for slot in FOUR_VIEW if slot not in by_stem]
        if missing:
            raise ValueError(f"views=four_view needs images named {', '.join(FOUR_VIEW)}; missing: {', '.join(missing)}")
        example = os.path.join(os.path.dirname(os.path.abspath(inference_mv.__file__)), "assets/mv_images/example/transforms.json")
        with open(example) as f:
            meta = json.load(f)
        for frame, slot in zip(meta["frames"], FOUR_VIEW):
            frame["file_path"] = os.path.join(folder, by_stem[slot])
    else:
        if not images:
            raise ValueError(f"views=orbit found no images in {folder}")
        meta = orbit([os.path.join(folder, f) for f in images], layout["orbit_elevation_deg"],
                     layout["orbit_fov_deg"], layout["orbit_distance"])
    views = os.path.join(out_dir, "views")
    os.makedirs(views, exist_ok=True)
    with open(os.path.join(views, "transforms.json"), "w") as f:
        json.dump(meta, f, indent=2)
    return views  # file_path entries are absolute; upstream's os.path.join(views_dir, …) keeps them


def orbit(paths, elevation_deg, fov_deg, distance):
    """Cameras evenly spaced in azimuth with frame 0 in front, camera at (0, -d, 0), in upstream's convention
    (transforms.json, Blender/NeRF): Z-up world, camera-to-world matrices, camera looking down its -Z, +Y up."""
    e = math.radians(elevation_deg)
    frames = []
    for i, path in enumerate(paths):
        a = 2 * math.pi * i / len(paths)
        back = (math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e))  # camera +Z, away from the object
        right = (math.cos(a), math.sin(a), 0.0)
        up = (back[1] * right[2] - back[2] * right[1], back[2] * right[0] - back[0] * right[2], back[0] * right[1] - back[1] * right[0])
        matrix = [[_clean(v) for v in (right[r], up[r], back[r], distance * back[r])] for r in range(3)] + [[0.0, 0.0, 0.0, 1.0]]
        frames.append({"file_path": path, "name": f"azim{round(math.degrees(a)):03d}", "transform_matrix": matrix})
    return {"camera_angle_x": math.radians(fov_deg), "mesh_scale": 1.0, "frames": frames}


def _clean(v):
    return round(v, 12) + 0.0  # cos(90°) is 6e-17, and -0.0 reads badly
```

- [ ] **Step 5: Keep Plan 1's listing tests independent of the bundled set, and run recipe tests in CI**

```diff
--- a/Tests/LiftCoreTests/CommandTests.swift
+++ b/Tests/LiftCoreTests/CommandTests.swift
@@ -88,9 +88,9 @@ func weightedBundle() throws -> URL {
     @Test func developerRecipesNeedTheSetting() async throws {
         let lift = try await Fixtures.lift()
         _ = try await lift.settingsSet("dev_recipes", .bool(false))
-        #expect(try await lift.modelsList().isEmpty)  // the Test Cube is the only bundled recipe so far, and it's hidden
+        #expect(try await !lift.modelsList().map(\.id).contains("test-cube"))  // hidden; the full list: BundledRecipeTests
         _ = try await lift.settingsSet("dev_recipes", .bool(true))
-        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
+        #expect(try await lift.modelsList().map(\.id).contains("test-cube"))
     }
 
     @Test func failedRefreshMarksTheSourceStaleAndKeepsItsRecipes() async throws {
@@ -109,9 +109,9 @@ func weightedBundle() throws -> URL {
 
     @Test func modelsAndRecipesAreListed() async throws {
         let lift = try await Fixtures.lift()
-        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
+        #expect(try await lift.modelsList().map(\.id).contains("test-cube"))  // the full bundled list: BundledRecipeTests
         let sources = await lift.recipesListSources()
-        #expect(sources.sources.first?.recipes == ["test-cube"])
+        #expect(sources.sources.first { $0.name == "bundled" }?.recipes.contains("test-cube") == true)
         #expect(sources.problems.isEmpty)
     }
 }
```

```diff
--- a/.github/workflows/test.yml
+++ b/.github/workflows/test.yml
@@ -49,6 +50,10 @@ jobs:
         working-directory: python/lift_worker
         run: uv run --python 3.11 pytest -q --junitxml=../../test-results/lift_worker.xml
 
+      - name: Recipe launcher tests (fake upstream, no weights)
+        working-directory: python/recipe_tests
+        run: uv run --python 3.11 pytest -q --junitxml=../../test-results/recipes.xml
+
       - name: Upload test results
         if: always()
         uses: actions/upload-artifact@v4
```

- [ ] **Step 6: Run the tests**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q test_pixal3d.py`
Expected: `11 passed` (among them `test_orbit_of_four_matches_the_upstream_example`, which proves the orbit formula reproduces upstream's cameras).
Run: `swift test --filter "CommandTests|CatalogTests|BundledTests"`
Expected: all pass; the catalog reports no problems with `pixal3d` in it.

- [ ] **Step 7: Commit**

```bash
git add dev-recipes/shared/substitutes.yaml \
        dev-recipes/pixal3d/recipe.yaml \
        dev-recipes/pixal3d/launcher.py \
        python/recipe_tests/pyproject.toml \
        python/recipe_tests/uv.lock \
        python/recipe_tests/conftest.py \
        python/recipe_tests/test_pixal3d.py \
        .github/workflows/test.yml \
        Tests/LiftCoreTests/CommandTests.swift
git commit -m "feat(recipes): Metal substitute registry and the Pixal3D recipe (single and multi-view)" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        dev-recipes/shared/substitutes.yaml \
        dev-recipes/pixal3d/recipe.yaml \
        dev-recipes/pixal3d/launcher.py \
        python/recipe_tests/pyproject.toml \
        python/recipe_tests/uv.lock \
        python/recipe_tests/conftest.py \
        python/recipe_tests/test_pixal3d.py \
        .github/workflows/test.yml \
        Tests/LiftCoreTests/CommandTests.swift
```

---
### Task 4: The UniRig recipe

**Files:**
- Create: `dev-recipes/unirig/recipe.yaml`, `dev-recipes/unirig/launcher.py`
- Test: `python/recipe_tests/test_unirig.py`

**Interfaces:**
- Consumes: Task 3's registry entries `flash_attn`, `spconv`, `torch_scatter`, `torch_cluster` and test helpers; Task 1's `brew`/`files`/`attribution`; Task 2's process groups (a cancel kills the bash → python stage too).
- Produces: recipe `unirig`, task `rig` (input `mesh`, output `rigged_mesh`). `run` returns `[<out_dir>/rigged.<format>, <out_dir>/skin.fbx (skeleton+skin only), <out_dir>/skeleton.fbx]` — the rigged mesh first, because a chained step takes the first output. Stage names `skeleton`, `skin`, `merge` at fractions 0, 0.4, 0.8.

- [ ] **Step 1: Write the failing tests**

They run upstream's script interface with stand-in scripts that log their arguments and write `--output` (and, like upstream, always exit 0):

```python
import os
from pathlib import Path

import pytest

from conftest import FakeJob, defaults

# Stands in for upstream's launch/inference/*.sh: logs its arguments (and where --input points), then writes
# --output unless FAIL_<script> is set. Like upstream, it always exits 0.
FAKE_SCRIPT = """#!/bin/bash
name=$(basename "$0" .sh)
echo "$name" >> "$UNIRIG_LOG"
while [[ $# -gt 0 ]]; do
  echo "  $1" >> "$UNIRIG_LOG"
  case $1 in
    --input|--target) echo "  $2" >> "$UNIRIG_LOG"; [ -L "$2" ] && echo "  -> $(readlink "$2")" >> "$UNIRIG_LOG"; shift ;;
    --output) echo "  $2" >> "$UNIRIG_LOG"; out="$2"; shift ;;
  esac
  shift
done
fail="FAIL_$name"
[ -n "$out" ] && [ -z "${!fail}" ] && echo "$name" > "$out"
echo "Predicting DataLoader 0: 100%|##########| 1/1"
echo done
"""


@pytest.fixture
def unirig(launcher, tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    (repo / "launch/inference").mkdir(parents=True)
    for name in ("generate_skeleton", "generate_skin", "merge"):
        (repo / f"launch/inference/{name}.sh").write_text(FAKE_SCRIPT)
    monkeypatch.chdir(repo)  # lift_worker runs launchers in models/<id>/repo
    monkeypatch.setenv("UNIRIG_LOG", str(tmp_path / "calls.log"))
    return launcher("unirig", {})


def calls(tmp_path):
    out, current = [], None
    for line in (tmp_path / "calls.log").read_text().splitlines():
        if line.startswith("  "):
            current[1].append(line[2:])
        else:
            current = (line, [])
            out.append(current)
    return out


def job(tmp_path, mesh, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob("rig", {"mesh": str(mesh)}, {**defaults("unirig", "rig"), **changes}, out)


def mesh(tmp_path, name="giraffe.glb"):
    folder = tmp_path / "inputs"
    folder.mkdir(exist_ok=True)
    p = folder / name
    p.write_bytes(b"glTF")
    return p


def test_default_runs_skeleton_skin_merge_with_upstream_defaults(unirig, tmp_path):
    m = mesh(tmp_path)
    j = job(tmp_path, m)
    assert unirig.run(None, j) == [f"{j.out_dir}/rigged.glb", f"{j.out_dir}/skin.fbx", f"{j.out_dir}/skeleton.fbx"]
    (skel, skel_args), (skin, skin_args), (merge, merge_args) = calls(tmp_path)
    assert (skel, skin, merge) == ("generate_skeleton", "generate_skin", "merge")
    work = os.path.dirname(skel_args[1])
    assert skel_args == ["--input", f"{work}/input.glb", f"-> {m}", "--output", f"{work}/skeleton.fbx",
                         "--skeleton_task", "configs/task/quick_inference_skeleton_articulationxl_ar_256.yaml",
                         "--add_root", "false", "--force_override", "false",
                         "--config", "configs/data/quick_inference.yaml", "--require_suffix", "obj,fbx,FBX,dae,glb,gltf,vrm",
                         "--num_runs", "1", "--faces_target_count", "50000", "--seed", "12345"]
    assert skin_args[:6] == ["--input", f"{work}/skeleton.fbx", "--output", f"{work}/skin.fbx", "--skin_task", "configs/task/quick_inference_unirig_skin.yaml"]
    assert skin_args[6:10] == ["--force_override", "true", "--data_name", "raw_data.npz"]
    assert merge_args == ["--source", f"{work}/skin.fbx", "--target", f"{work}/input.glb", f"-> {m}",
                          "--output", f"{work}/rigged.glb", "--require_suffix", "obj,fbx,FBX,dae,glb,gltf,vrm"]
    assert [s[0] for s in j.stages] == ["skeleton", "skin", "merge"]
    assert not os.path.exists(work)  # the temp folder is gone


def test_skeleton_only_merges_the_skeleton_and_fbx_format(unirig, tmp_path):
    j = job(tmp_path, mesh(tmp_path), stages="skeleton", format="fbx")
    assert unirig.run(None, j) == [f"{j.out_dir}/rigged.fbx", f"{j.out_dir}/skeleton.fbx"]
    names = [c[0] for c in calls(tmp_path)]
    assert names == ["generate_skeleton", "merge"]
    merge_args = calls(tmp_path)[1][1]
    assert merge_args[1].endswith("/skeleton.fbx") and merge_args[merge_args.index("--output") + 1].endswith("/rigged.fbx")


def test_paths_with_spaces_and_shell_characters_never_reach_the_scripts(unirig, tmp_path):
    m = mesh(tmp_path, "my $(touch pwned); model.GLB")
    unirig.run(None, job(tmp_path, m))
    args = [x for _, xs in calls(tmp_path) for x in xs if not x.startswith("-> ")]
    assert all(" " not in a and "$" not in a and ";" not in a for a in args)
    assert f"-> {m}" in calls(tmp_path)[0][1]
    assert args[1].endswith("/input.glb")


def test_string_settings_with_shell_characters_are_refused(unirig, tmp_path):
    with pytest.raises(ValueError, match="config"):
        unirig.run(None, job(tmp_path, mesh(tmp_path), config="configs/data/x.yaml; rm -rf ~"))
    assert not (tmp_path / "calls.log").exists()


def test_a_stage_that_writes_nothing_fails_the_job_and_stops(unirig, tmp_path, monkeypatch):
    monkeypatch.setenv("FAIL_generate_skin", "1")
    with pytest.raises(RuntimeError, match="generate_skin.sh finished without writing skin.fbx"):
        unirig.run(None, job(tmp_path, mesh(tmp_path)))
    assert [c[0] for c in calls(tmp_path)] == ["generate_skeleton", "generate_skin"]


def test_cancelled_before_a_stage_stops(unirig, tmp_path):
    j = job(tmp_path, mesh(tmp_path))
    j.cancelled = True
    with pytest.raises(RuntimeError, match="cancelled"):
        unirig.run(None, j)
    assert not (tmp_path / "calls.log").exists()


def test_upstream_output_reaches_the_job_log(unirig, tmp_path, capsys):
    unirig.run(None, job(tmp_path, mesh(tmp_path)))
    out = capsys.readouterr().out
    assert "$ bash launch/inference/generate_skeleton.sh" in out
    assert "Predicting DataLoader 0: 100%|" in out
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q test_unirig.py`
Expected: errors with `FileNotFoundError: … dev-recipes/unirig/…`.

- [ ] **Step 3: Write the recipe and launcher**

`dev-recipes/unirig/recipe.yaml` (install steps from `spike/setup_unirig.sh`, with the versions the go/no-go venv resolved pinned; settings are every flag of the three upstream scripts with their defaults):

```yaml
# UniRig (VAST-AI-Research) through lift_shim. Install steps: docs/superpowers/findings/2026-10-go-no-go.md.
schema: 1
id: unirig
name: UniRig
publisher: VAST-AI-Research
license: MIT
homepage: https://github.com/VAST-AI-Research/UniRig
repo: https://github.com/VAST-AI-Research/UniRig
commit: 6793c6640ff01c8fb389f3993434124bb43d2933
python: "3.11"
platform: { status: supported }
shim: { patches: [transformers_fa2_to_sdpa] }   # transformers 4.51 raises on flash_attention_2 without CUDA
brew: [libusb]   # open3d (merge step) links /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
install:
  - uv pip install torch==2.14.1 torchvision==0.29.1
  # flash_attn → lift_shim stand-in; wandb is training-only.
  - grep -v -E '^(flash_attn|wandb)' repo/requirements.txt > requirements-mac.txt && uv pip install -r requirements-mac.txt
  # pip: upstream's extract.sh runs `pip install psutil`, which must find this venv's pip (not another Python's).
  # huggingface_hub (also in requirements.txt) provides `hf` for Lift's weight download.
  - uv pip install setuptools wheel pip psutil huggingface_hub
  - uv pip install --no-build-isolation torch_scatter==2.1.2 torch_cluster==1.6.3
  - uv pip install numpy==1.26.4
  - python -c "import bpy, open3d, torch_scatter, torch_cluster"
substitutes: [flash_attn, spconv, torch_scatter, torch_cluster]
attribution:   # spec §4a
  project: UniRig
  authors: [VAST-AI-Research]
  homepage: https://github.com/VAST-AI-Research/UniRig
  repo: https://github.com/VAST-AI-Research/UniRig
  license: { spdx: MIT, url: https://github.com/VAST-AI-Research/UniRig/blob/6793c6640ff01c8fb389f3993434124bb43d2933/LICENSE }
  components:
    - { name: UniRig weights, url: https://huggingface.co/VAST-AI/UniRig, license: { spdx: MIT, url: https://huggingface.co/VAST-AI/UniRig } }
    - { name: OPT-350m (architecture config only), url: https://huggingface.co/facebook/opt-350m, license: { spdx: LicenseRef-OPT, url: https://huggingface.co/facebook/opt-350m } }
    - { name: Blender (bpy), url: https://www.blender.org, license: { spdx: GPL-2.0-or-later, url: https://www.blender.org/about/license/ } }
    - { name: Open3D, url: https://github.com/isl-org/Open3D, license: { spdx: MIT, url: https://github.com/isl-org/Open3D/blob/main/LICENSE } }
    - { name: PyTorch Scatter and PyTorch Cluster, url: https://github.com/rusty1s/pytorch_scatter, license: { spdx: MIT, url: https://github.com/rusty1s/pytorch_scatter/blob/master/LICENSE } }
    - { name: libusb (Homebrew), url: https://libusb.info, license: { spdx: LGPL-2.1-or-later, url: https://github.com/libusb/libusb/blob/master/COPYING } }
weights:
  - { repo: VAST-AI/UniRig, files: [skeleton/articulation-xl_quantization_256/model.ckpt, skin/articulation-xl/model.ckpt] }   # what src/inference/download.py fetches for these task configs (5.8 of 11.5 GB)
  - { repo: facebook/opt-350m, files: [config.json] }   # the skeleton model's architecture config, not its 2 GB of weights
resources:
  memory_gb: 8
  disk_gb: 4
stages:
  - { pattern: '^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|' }
  - { pattern: '^\s*(?P<pct>\d+)%\|' }
tasks:
  - id: rig
    modality: 3d
    label: Mesh → rigged mesh
    inputs: [{ name: mesh, type: mesh }]
    output: rigged_mesh
    entry: launch/inference/generate_skeleton.sh → generate_skin.sh → merge.sh
    settings:   # Lift's stage choice and output format, then every flag of the three upstream scripts with their defaults
      - { key: stages, label: Stages, type: enum, options: [skeleton, skeleton+skin], default: skeleton+skin, group: basic, help: "skeleton: bones only. skeleton+skin: bones and skinning weights. Both end with merge.sh onto your mesh." }
      - { key: format, label: Output format, type: enum, options: [glb, fbx], default: glb, group: basic, help: "merge.sh --output extension." }
      - { key: seed, label: Seed, type: int, default: 12345, group: basic, help: "--seed of both generate scripts." }
      - { key: faces_target_count, label: Target face count, type: int, default: 50000, min: 1, group: advanced, help: "--faces_target_count of both generate scripts." }
      - { key: skeleton_task, label: Skeleton task config, type: enum, options: [configs/task/quick_inference_skeleton_articulationxl_ar_256.yaml], default: configs/task/quick_inference_skeleton_articulationxl_ar_256.yaml, group: advanced }
      - { key: skin_task, label: Skin task config, type: enum, options: [configs/task/quick_inference_unirig_skin.yaml], default: configs/task/quick_inference_unirig_skin.yaml, group: advanced }
      - { key: add_root, label: Add root bone, type: bool, default: false, group: advanced, help: "generate_skeleton.sh --add_root." }
      - { key: config, label: Data config, type: string, default: configs/data/quick_inference.yaml, group: advanced }
      - { key: require_suffix, label: Accepted suffixes, type: string, default: "obj,fbx,FBX,dae,glb,gltf,vrm", group: advanced }
      - { key: num_runs, label: Extract runs, type: int, default: 1, min: 1, group: advanced }
      - { key: skeleton_force_override, label: Re-extract mesh (skeleton), type: bool, default: false, group: advanced, help: "generate_skeleton.sh --force_override." }
      - { key: skin_force_override, label: Re-extract mesh (skin), type: bool, default: true, group: advanced, help: "generate_skin.sh --force_override." }
      - { key: data_name, label: Skin data file, type: string, default: raw_data.npz, group: advanced, help: "generate_skin.sh --data_name." }
```

`dev-recipes/unirig/launcher.py`:

```python
"""UniRig launcher (VAST-AI-Research/UniRig @ 6793c66, through lift_shim).

Runs upstream's own launch scripts as subprocesses, in repo/ as they expect: generate_skeleton.sh, then
generate_skin.sh (stages=skeleton+skin), then merge.sh onto the input mesh. The children inherit LIFT_SHIM, so the
shim's .pth applies in every upstream `python` they start.

Two upstream traits shape this file:
- The scripts build their command lines as strings and `eval` them, so a path with a space or a shell character
  would split or run. Every path handed to them is a fixed name in a fresh temp folder (the input is a symlink),
  and string settings are limited to plain path characters.
- They end with `echo done`, so they exit 0 even when a stage failed: each stage is judged by the file it writes.
Upstream's intermediate npz files land in that temp folder too, so jobs never share them.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

PLAIN = re.compile(r"^[A-Za-z0-9._/,-]+$")


def run(state, job):
    s = job.settings
    for key in ("config", "require_suffix", "data_name", "skeleton_task", "skin_task"):
        if not PLAIN.match(str(s[key])):
            raise ValueError(f"{key} may only contain letters, digits and . _ / , - (upstream evals it in a shell)")
    work = tempfile.mkdtemp(prefix="lift-unirig-")
    try:
        mesh = os.path.join(work, "input" + os.path.splitext(job.inputs["mesh"])[1].lower())
        os.symlink(os.path.abspath(job.inputs["mesh"]), mesh)
        skeleton = os.path.join(work, "skeleton.fbx")
        common = ["--config", s["config"], "--require_suffix", s["require_suffix"], "--num_runs", s["num_runs"],
                  "--faces_target_count", s["faces_target_count"], "--seed", s["seed"]]
        _stage(job, "skeleton", 0.0, "launch/inference/generate_skeleton.sh",
               ["--input", mesh, "--output", skeleton, "--skeleton_task", s["skeleton_task"],
                "--add_root", s["add_root"], "--force_override", s["skeleton_force_override"], *common], skeleton)
        source = skeleton
        if s["stages"] == "skeleton+skin":
            source = os.path.join(work, "skin.fbx")
            _stage(job, "skin", 0.4, "launch/inference/generate_skin.sh",
                   ["--input", skeleton, "--output", source, "--skin_task", s["skin_task"],
                    "--force_override", s["skin_force_override"], "--data_name", s["data_name"], *common], source)
        rigged = os.path.join(work, f"rigged.{s['format']}")
        _stage(job, "merge", 0.8, "launch/inference/merge.sh",
               ["--source", source, "--target", mesh, "--output", rigged, "--require_suffix", s["require_suffix"]], rigged)
        outputs = []
        for path in (rigged, source if source != skeleton else None, skeleton):  # the rigged mesh first: chains use it
            if path:
                outputs.append(shutil.move(path, os.path.join(job.out_dir, os.path.basename(path))))
        return outputs
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _stage(job, name, fraction, script, args, expected):
    if job.cancelled:
        raise RuntimeError("cancelled")
    job.stage(name, fraction)
    cmd = ["bash", script] + [_arg(a) for a in args]
    print("$ " + " ".join(cmd), flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    for line in proc.stdout:  # universal newlines: tqdm's \r updates arrive as lines
        sys.stdout.write(line)
    code = proc.wait()
    if code != 0:
        raise RuntimeError(f"UniRig {os.path.basename(script)} exited with code {code}")
    if not os.path.isfile(expected):
        raise RuntimeError(f"UniRig {os.path.basename(script)} finished without writing {os.path.basename(expected)}; see the job log")


def _arg(value):
    return ("true" if value else "false") if isinstance(value, bool) else str(value)
```

- [ ] **Step 4: Run the tests**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q test_unirig.py`
Expected: `7 passed`.

- [ ] **Step 5: Commit**

```bash
git add dev-recipes/unirig/recipe.yaml \
        dev-recipes/unirig/launcher.py \
        python/recipe_tests/test_unirig.py
git commit -m "feat(recipes): UniRig — skeleton, skin and merge through upstream's own scripts" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        dev-recipes/unirig/recipe.yaml \
        dev-recipes/unirig/launcher.py \
        python/recipe_tests/test_unirig.py
```

---
### Task 5: The TRELLIS.2 (trellis-mac) recipe

**Files:**
- Create: `dev-recipes/trellis2-mac/recipe.yaml`, `dev-recipes/trellis2-mac/launcher.py`
- Test: `python/recipe_tests/test_trellis2_mac.py`

**Interfaces:**
- Consumes: Task 1's `metal_toolchain`/`files`/`attribution`; Task 3's test helpers. No `shim:` — trellis-mac is a Mac port.
- Produces: recipe `trellis2-mac`, task `image_to_3d` (input `image`). `load(ctx)` returns the pipeline (`Trellis2ImageTo3DPipeline.from_pretrained("microsoft/TRELLIS.2-4B")` on `mps`); `run` returns `[<out_dir>/mesh.glb, <out_dir>/mesh.obj]` (generate.py also writes the bare OBJ). Importing the launcher raises `RuntimeError(… KDTree …)` unless `o_voxel.postprocess._BACKEND == "metal"` and `_HAS_DR`. GPU-watchdog failures become `RuntimeError(WATCHDOG_HELP)` (trellis-mac's own advice text).

- [ ] **Step 1: Write the failing tests**

```python
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from conftest import FakeJob, defaults, module


class Tensor:
    """Just enough of a torch tensor for the launcher: .cpu(), .numpy(), .float(), .device."""

    def __init__(self, a):
        self.a, self.device = np.asarray(a), "mps"

    def cpu(self):
        return self

    def float(self):
        return self

    def numpy(self):
        return self.a


def mesh_out(verts=8, faces=12, attrs=True):
    return SimpleNamespace(vertices=Tensor(np.zeros((verts, 3))), faces=Tensor(np.zeros((faces, 3), dtype=int)),
                           attrs=Tensor(np.zeros((4, 6))) if attrs else None, coords=Tensor(np.zeros((4, 4))),
                           origin=Tensor(np.zeros(3)), layout={"base_color": slice(0, 3)}, voxel_size=1 / 64)


class Pipeline:
    def __init__(self):
        self.device, self.runs, self.result = None, [], mesh_out()

    def to(self, device):
        self.device = device

    def run(self, img, **kw):
        self.runs.append((img, kw))
        if isinstance(self.result, Exception):
            raise self.result
        return [self.result]


class Glb:
    def export(self, path):
        Path(path).write_bytes(b"glTF")


def fakes(backend="metal"):
    pipeline = Pipeline()
    to_glb_calls = []

    def to_glb(**kw):
        to_glb_calls.append(kw)
        if isinstance(fakes.to_glb_error, Exception):
            raise fakes.to_glb_error
        return Glb()

    fakes.to_glb_error = None
    postprocess = module("o_voxel.postprocess", _BACKEND=backend, _HAS_DR=backend == "metal", _HAS_FLEX_GEMM=True, to_glb=to_glb)
    pil_image = module("PIL.Image", open=lambda p: ("image", p), fromarray=lambda a: SimpleNamespace(save=lambda p: Path(p).write_bytes(b"png")))
    baker = module("backends.texture_baker",
                   uv_unwrap=lambda v, f: (v, f, np.zeros((len(v), 2)), None),
                   bake_texture=lambda *a, **k: (np.zeros((2, 2, 3)), np.zeros((2, 2, 3)), None),
                   export_glb_with_texture=lambda v, f, uv, bc, mr, path: Path(path).write_bytes(b"kdtree"))
    return {
        "flex_gemm": module("flex_gemm"),
        "torch": module("torch", device=lambda name: ("device", name)),
        "o_voxel": module("o_voxel", postprocess=postprocess), "o_voxel.postprocess": postprocess,
        "PIL": module("PIL", Image=pil_image), "PIL.Image": pil_image,
        "trimesh": module("trimesh", Trimesh=lambda vertices, faces: Glb()),
        "fast_simplification": module("fast_simplification"),
        "backends": module("backends"), "backends.texture_baker": baker,
        "trellis2": module("trellis2"), "trellis2.pipelines": module("trellis2.pipelines"),
        "trellis2.pipelines.trellis2_image_to_3d": module(
            "trellis2.pipelines.trellis2_image_to_3d",
            Trellis2ImageTo3DPipeline=SimpleNamespace(from_pretrained=lambda name: (pipeline.__setattr__("name", name), pipeline)[1])),
    }, pipeline, to_glb_calls


@pytest.fixture
def trellis(launcher, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    f, pipeline, to_glb_calls = fakes()
    mod = launcher("trellis2-mac", f)
    return mod, mod.load(SimpleNamespace(repo_dir=str(tmp_path))), to_glb_calls


def job(tmp_path, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob("image_to_3d", {"image": "/in/shoe.png"}, {**defaults("trellis2-mac", "image_to_3d"), **changes}, out)


def test_import_refuses_the_kdtree_fallback(launcher, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    with pytest.raises(RuntimeError, match="KDTree"):
        launcher("trellis2-mac", fakes(backend=None)[0])


def test_load_puts_the_pinned_pipeline_on_mps(trellis):
    _, pipeline, _ = trellis
    assert pipeline.name == "microsoft/TRELLIS.2-4B" and pipeline.device == ("device", "mps")


def test_defaults_map_to_generate_py_and_bake_on_metal(trellis, tmp_path):
    mod, pipeline, to_glb_calls = trellis
    j = job(tmp_path)
    assert mod.run(pipeline, j) == [f"{j.out_dir}/mesh.glb", f"{j.out_dir}/mesh.obj"]
    ((img, kw),) = pipeline.runs
    assert img == ("image", "/in/shoe.png")
    assert kw == {"seed": 42, "pipeline_type": "512", "sparse_structure_sampler_params": {},
                  "shape_slat_sampler_params": {}, "tex_slat_sampler_params": {}}
    ((bake,),) = [tuple(to_glb_calls)]
    assert bake["texture_size"] == 1024 and bake["decimation_target"] == 12
    assert bake["aabb"] == [[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]]
    obj = Path(j.out_dir, "mesh.obj").read_text().splitlines()
    assert sum(l.startswith("v ") for l in obj) == 8 and sum(l.startswith("f ") for l in obj) == 12


def test_steps_override_all_three_phases(trellis, tmp_path):
    mod, pipeline, _ = trellis
    mod.run(pipeline, job(tmp_path, steps=8, pipeline_type="1024_cascade", seed=7))
    kw = pipeline.runs[0][1]
    assert kw["seed"] == 7 and kw["pipeline_type"] == "1024_cascade"
    assert kw["sparse_structure_sampler_params"] == kw["shape_slat_sampler_params"] == kw["tex_slat_sampler_params"] == {"steps": 8}


def test_no_texture_exports_geometry_without_baking(trellis, tmp_path):
    mod, pipeline, to_glb_calls = trellis
    j = job(tmp_path, no_texture=True)
    mod.run(pipeline, j)
    assert to_glb_calls == [] and Path(j.out_dir, "mesh.glb").read_bytes() == b"glTF"


def test_metal_bake_failure_falls_back_to_kdtree_like_generate_py(trellis, tmp_path):
    mod, pipeline, _ = trellis
    fakes.to_glb_error = RuntimeError("command buffer failed")
    j = job(tmp_path)
    mod.run(pipeline, j)
    assert Path(j.out_dir, "mesh.glb").read_bytes() == b"kdtree" and Path(j.out_dir, "mesh_basecolor.png").exists()


@pytest.mark.parametrize("error", [IndexError("max(): Expected reduction dim 0 to have non-zero size"),
                                   AssertionError("BVH needs at least 8 triangles, got 0")])
def test_watchdog_signatures_become_trellis_mac_advice(trellis, tmp_path, error):
    mod, pipeline, _ = trellis
    pipeline.result = error
    with pytest.raises(RuntimeError, match="GPU watchdog"):
        mod.run(pipeline, job(tmp_path))


def test_empty_mesh_is_the_watchdog_too(trellis, tmp_path):
    mod, pipeline, _ = trellis
    pipeline.result = mesh_out(verts=0, faces=0)
    with pytest.raises(RuntimeError, match="GPU watchdog"):
        mod.run(pipeline, job(tmp_path))


def test_other_errors_pass_through(trellis, tmp_path):
    mod, pipeline, _ = trellis
    pipeline.result = IndexError("list index out of range")
    with pytest.raises(IndexError, match="list index"):
        mod.run(pipeline, job(tmp_path))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q test_trellis2_mac.py`
Expected: errors with `FileNotFoundError: … dev-recipes/trellis2-mac/…`.

- [ ] **Step 3: Write the recipe and launcher**

`dev-recipes/trellis2-mac/recipe.yaml` (install steps from `spike/setup_trellis2_mac.sh`; settings are generate.py's options with their defaults):

```yaml
# TRELLIS.2 through trellis-mac, an existing Mac port: no lift_shim. Its setup.sh runs unchanged; Lift only
# pre-places pinned clones so setup.sh skips its own unpinned ones, and points its .venv at Lift's venv.
# Each clone step converges: it clones when missing, else fetches and force-checks-out the pin (spec §6).
# Install steps and pins: docs/superpowers/findings/2026-10-go-no-go.md. Note: trellis-mac's own
# patches/mps_compat.py (run by setup.sh) edits files in its TRELLIS.2 clone; that is trellis-mac's documented behaviour.
schema: 1
id: trellis2-mac
name: TRELLIS.2 (trellis-mac)
publisher: shivampkumar (Mac port of microsoft/TRELLIS.2)
license: MIT
homepage: https://github.com/shivampkumar/trellis-mac
repo: https://github.com/shivampkumar/trellis-mac
commit: d58628f4f5b9c3de8274cb110074154f4b31cef2
python: "3.11"
platform: { status: supported }
metal_toolchain: true
install:
  - '{ [ -d repo/TRELLIS.2/.git ] || git clone --filter=blob:none https://github.com/microsoft/TRELLIS.2 repo/TRELLIS.2; } && git -C repo/TRELLIS.2 fetch -q origin && git -C repo/TRELLIS.2 checkout -qf 75fbf0183001ed9876c8dbb35de6b68552ee08bd'
  # setup.sh clones these at HEAD unless they exist; these are the commits verified in the go/no-go test.
  - '{ [ -d repo/deps/mtlbvh/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlbvh repo/deps/mtlbvh; } && git -C repo/deps/mtlbvh fetch -q origin && git -C repo/deps/mtlbvh checkout -qf 6b2a0f63b476ad8225695d092902104beafd7f58'
  - '{ [ -d repo/deps/mtldiffrast/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtldiffrast repo/deps/mtldiffrast; } && git -C repo/deps/mtldiffrast fetch -q origin && git -C repo/deps/mtldiffrast checkout -qf c9499ba2e4ed6849e95ce5da7aae5bf61addb528'
  - '{ [ -d repo/deps/mtlmesh/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlmesh repo/deps/mtlmesh; } && git -C repo/deps/mtlmesh fetch -q origin && git -C repo/deps/mtlmesh checkout -qf 7de3864f783407201486bf6c900a4bd76a4018a3'
  - '{ [ -d repo/deps/mtlgemm/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/mtlgemm repo/deps/mtlgemm; } && git -C repo/deps/mtlgemm fetch -q origin && git -C repo/deps/mtlgemm checkout -qf 566c133781ce4992de3f77c3a97dd6feaae9d013'
  - '{ [ -d repo/deps/trellis2-apple/.git ] || git clone --filter=blob:none https://github.com/pedronaugusto/trellis2-apple repo/deps/trellis2-apple; } && git -C repo/deps/trellis2-apple fetch -q origin && git -C repo/deps/trellis2-apple checkout -qf 17347247c91c36c8cdc1896234983e878a457bba'
  # setup.sh's clone has no submodules; without Eigen, o_voxel silently falls back to the KDTree baker.
  - git -C repo/deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen
  # setup.sh creates .venv only if it is missing, then activates it: make it Lift's venv.
  - ln -sfn ../venv repo/.venv
  # Build products an earlier install left in Lift's copy break the Metal builds against a fresh venv.
  - rm -rf repo/deps/*/build repo/deps/trellis2-apple/o-voxel/build
  # setup.sh installs unpinned torch. 2.14 headers need C++20 (the mtl* builds use C++17), 2.9 lacks
  # at::mps::dispatch_sync_with_rethrow, mtlgemm needs >=2.11: 2.13 fits. UV_NO_CACHE avoids stale local builds.
  - printf 'torch==2.13.0\n' > torch-constraint.txt
  - cd repo && UV_CONSTRAINT="$PWD/../torch-constraint.txt" UV_NO_CACHE=1 bash setup.sh
attribution:   # spec §4a; trellis-mac is the Mac port Lift installs
  project: TRELLIS.2
  authors: [Microsoft]
  homepage: https://github.com/microsoft/TRELLIS.2
  repo: https://github.com/microsoft/TRELLIS.2
  license: { spdx: MIT, url: https://github.com/microsoft/TRELLIS.2/blob/75fbf0183001ed9876c8dbb35de6b68552ee08bd/LICENSE }
  components:
    - { name: trellis-mac (Mac port, by shivampkumar), url: https://github.com/shivampkumar/trellis-mac, license: { spdx: MIT, url: https://github.com/shivampkumar/trellis-mac/blob/d58628f4f5b9c3de8274cb110074154f4b31cef2/LICENSE } }
    - { name: TRELLIS.2-4B weights, url: https://huggingface.co/microsoft/TRELLIS.2-4B, license: { spdx: MIT, url: https://huggingface.co/microsoft/TRELLIS.2-4B } }
    - { name: TRELLIS-image-large (sparse-structure decoder), url: https://huggingface.co/microsoft/TRELLIS-image-large, license: { spdx: MIT, url: https://huggingface.co/microsoft/TRELLIS-image-large } }
    - { name: DINOv3 ViT-L/16 (image features), url: https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m, license: { spdx: LicenseRef-DINOv3, url: https://ai.meta.com/resources/models-and-libraries/dinov3-license } }
    - { name: RMBG-2.0 (background removal), url: https://huggingface.co/briaai/RMBG-2.0, license: { spdx: CC-BY-NC-4.0, url: https://creativecommons.org/licenses/by-nc/4.0/ }, restrictions: [non-commercial] }
    - { name: mtlgemm (FlexGEMM on Metal), url: https://github.com/pedronaugusto/mtlgemm, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlgemm/blob/566c133781ce4992de3f77c3a97dd6feaae9d013/LICENSE } }
    - { name: mtldiffrast (rasterizer on Metal), url: https://github.com/pedronaugusto/mtldiffrast, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtldiffrast/blob/c9499ba2e4ed6849e95ce5da7aae5bf61addb528/LICENSE.txt } }
    - { name: mtlbvh (BVH on Metal), url: https://github.com/pedronaugusto/mtlbvh, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlbvh/blob/6b2a0f63b476ad8225695d092902104beafd7f58/LICENSE.txt } }
    - { name: mtlmesh (CuMesh on Metal), url: https://github.com/pedronaugusto/mtlmesh, license: { spdx: MIT, url: https://github.com/pedronaugusto/mtlmesh/blob/7de3864f783407201486bf6c900a4bd76a4018a3/LICENSE } }
    - { name: trellis2-apple (o-voxel for Apple Silicon), url: https://github.com/pedronaugusto/trellis2-apple, license: { spdx: MIT, url: https://github.com/pedronaugusto/trellis2-apple/blob/17347247c91c36c8cdc1896234983e878a457bba/LICENSE } }
    - { name: utils3d (EasternJournalist), url: https://github.com/EasternJournalist/utils3d, license: { spdx: MIT, url: https://github.com/EasternJournalist/utils3d/blob/9a4eb15e4021b67b12c460c7057d642626897ec8/LICENSE } }
weights:
  # The files TRELLIS.2-4B's pipeline.json (image to 3D) names; the shape/texture encoders are training-only.
  - repo: microsoft/TRELLIS.2-4B
    files: [pipeline.json, ckpts/ss_flow_img_dit_1_3B_64_bf16.json, ckpts/ss_flow_img_dit_1_3B_64_bf16.safetensors,
            ckpts/shape_dec_next_dc_f16c32_fp16.json, ckpts/shape_dec_next_dc_f16c32_fp16.safetensors,
            ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.json, ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.safetensors,
            ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.json, ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.safetensors,
            ckpts/tex_dec_next_dc_f16c32_fp16.json, ckpts/tex_dec_next_dc_f16c32_fp16.safetensors,
            ckpts/slat_flow_imgshape2tex_dit_1_3B_512_bf16.json, ckpts/slat_flow_imgshape2tex_dit_1_3B_512_bf16.safetensors,
            ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.json, ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.safetensors]
  - { repo: microsoft/TRELLIS-image-large, files: [ckpts/ss_dec_conv3d_16l8_fp16.json, ckpts/ss_dec_conv3d_16l8_fp16.safetensors] }   # pipeline.json's sparse_structure_decoder
  - { repo: facebook/dinov3-vitl16-pretrain-lvd1689m, gated: true }
  - { repo: briaai/RMBG-2.0, gated: true, files: [config.json, BiRefNet_config.py, birefnet.py, model.safetensors] }
resources:
  memory_gb: 18
  memory_keys: [pipeline_type]
  disk_gb: 3
stages:
  - { pattern: '^(?P<name>Loading pipeline|Generating 3D model|Baking PBR textures[^.]*|Exporting with vertex colors)' }
  - { pattern: '^(?P<name>[^:|]+):\s*(?P<pct>\d+)%\|' }
  - { pattern: '^\s*(?P<pct>\d+)%\|' }
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: generate.py (main, mirrored by launcher.py)
    settings:   # every generate.py option except image/--output, with its defaults
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: pipeline_type, label: Pipeline, type: enum, options: ["512", "1024", "1024_cascade"], default: "512", group: basic }
      - { key: texture_size, label: Texture size, type: enum, options: [512, 1024, 2048], default: 1024, group: basic }
      - { key: no_texture, label: Geometry only, type: bool, default: false, group: basic, help: "Skip texture baking." }
      - { key: steps, label: Sampler steps, type: int, default: 0, min: 0, group: advanced, help: "All three flow phases; 0 = the pipeline's own (usually 12)." }
```

`dev-recipes/trellis2-mac/launcher.py` (mirrors `generate.py` `main()` at `d58628f`; compare with `repo/generate.py` whenever the pin moves):

```python
"""trellis2-mac launcher (shivampkumar/trellis-mac @ d58628f with microsoft/TRELLIS.2 @ 75fbf01). No lift_shim.

trellis-mac's generate.py keeps its whole flow inside main(), so it can't be imported piecewise. This file
mirrors it: the environment and sys.path set-up at import, the pipeline load once in load(), and per job
pipeline.run plus generate.py's bake block. Re-check it against generate.py whenever the trellis-mac pin moves.

Importing o_voxel here makes the installer's smoke check fail when setup.sh quietly fell back to the KDTree
baker (it still prints "Setup complete" when the Metal build failed).
"""
import os
import sys
import time

# As generate.py: before torch is imported anywhere (flex_gemm imports it).
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("ATTN_BACKEND", "sdpa")
os.environ.setdefault("SPARSE_ATTN_BACKEND", "sdpa")
try:
    import flex_gemm  # noqa: F401
    os.environ.setdefault("SPARSE_CONV_BACKEND", "flex_gemm")
except (ImportError, RuntimeError):
    os.environ.setdefault("SPARSE_CONV_BACKEND", "none")

REPO = os.getcwd()  # lift_worker runs in models/<id>/repo, which is trellis-mac's checkout
sys.path.insert(0, os.path.join(REPO, "TRELLIS.2"))
sys.path.append(os.path.join(REPO, "stubs"))

import o_voxel.postprocess  # noqa: E402

if o_voxel.postprocess._BACKEND != "metal" or not o_voxel.postprocess._HAS_DR:
    raise RuntimeError(f"o_voxel is not on its Metal backend (_BACKEND={o_voxel.postprocess._BACKEND!r}); "
                       "trellis-mac's setup.sh fell back to the KDTree baker. Reinstall after checking the Metal Toolchain.")

# generate.py's text for the macOS GPU watchdog failures, which surface as these errors or an empty mesh.
WATCHDOG_SIGNATURES = ("non-zero size", "BVH needs at least 8 triangles")
WATCHDOG_HELP = (
    "The decoder produced an empty mesh. On Apple Silicon this is almost always the macOS GPU watchdog "
    "killing a long-running Metal kernel in the SLat decoder (look for "
    "'kIOGPUCommandBufferCallbackErrorImpactingInteractivity' in the log). Workarounds, cheapest first: "
    "1. run headless (close the lid / unplug external displays); "
    "2. MTL_CAPTURE_ENABLED=1 (extends the watchdog timeout); "
    "3. SPARSE_CONV_BACKEND=none (slower path). "
    "See https://github.com/shivampkumar/trellis-mac/issues"
)


def load(ctx):
    import torch
    from trellis2.pipelines.trellis2_image_to_3d import Trellis2ImageTo3DPipeline

    print("Loading pipeline...")
    pipeline = Trellis2ImageTo3DPipeline.from_pretrained("microsoft/TRELLIS.2-4B")
    pipeline.to(torch.device("mps"))
    return pipeline


def run(pipeline, job):
    import torch
    from PIL import Image

    s = job.settings
    img = Image.open(job.inputs["image"])
    base = os.path.join(job.out_dir, "mesh")
    overrides = {"steps": s["steps"]} if s["steps"] else {}
    print(f"Generating 3D model (pipeline={s['pipeline_type']}, seed={s['seed']})...")
    t0 = time.time()
    try:
        outputs = pipeline.run(img, seed=s["seed"], pipeline_type=s["pipeline_type"],
                               sparse_structure_sampler_params=overrides, shape_slat_sampler_params=overrides,
                               tex_slat_sampler_params=overrides)
    except (IndexError, AssertionError) as e:
        if any(sig in str(e) for sig in WATCHDOG_SIGNATURES):
            raise RuntimeError(WATCHDOG_HELP) from e
        raise
    mesh_out = outputs[0] if isinstance(outputs, list) else outputs
    verts = mesh_out.vertices.cpu().numpy()
    faces = mesh_out.faces.cpu().numpy()
    if verts.shape[0] == 0 or faces.shape[0] == 0:
        raise RuntimeError(WATCHDOG_HELP)
    print(f"Mesh: {verts.shape[0]:,} vertices, {faces.shape[0]:,} triangles; generation {time.time() - t0:.1f}s")

    glb_path = f"{base}.glb"
    tex_size = int(s["texture_size"])
    if hasattr(mesh_out, "attrs") and mesh_out.attrs is not None and not s["no_texture"]:
        _bake(mesh_out, verts, faces, tex_size, base, glb_path, torch)
    else:
        import trimesh

        print("Exporting with vertex colors...")
        trimesh.Trimesh(vertices=verts, faces=faces).export(glb_path)
    obj_path = f"{base}.obj"  # generate.py also writes the raw geometry as OBJ
    with open(obj_path, "w") as f:
        for v in verts:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        for face in faces:
            f.write(f"f {face[0] + 1} {face[1] + 1} {face[2] + 1}\n")
    return [glb_path, obj_path]


def _bake(mesh_out, verts, faces, tex_size, base, glb_path, torch):
    """generate.py's bake block: Metal (o_voxel.postprocess.to_glb) when available, else its KDTree baker."""
    pp = o_voxel.postprocess
    use_metal = pp._BACKEND == "metal" and pp._HAS_DR
    if use_metal and not getattr(pp, "_HAS_FLEX_GEMM", False):
        pp._grid_sample_3d = _grid_sample_3d_fix  # generate.py's fix for o_voxel's fallback layout
    if use_metal:
        try:
            print(f"Baking PBR textures via Metal ({tex_size}x{tex_size})...")
            import fast_simplification

            target_faces = min(200000, len(faces))
            if len(faces) > target_faces:
                print(f"  Simplifying mesh: {len(faces):,} -> ~{target_faces:,} faces")
                sv, sf = fast_simplification.simplify(verts, faces, 1.0 - target_faces / len(faces))
                sv_t = torch.from_numpy(sv).float().to(mesh_out.vertices.device)
                sf_t = torch.from_numpy(sf.astype("int32")).to(mesh_out.faces.device)
            else:
                sv_t, sf_t = mesh_out.vertices, mesh_out.faces
            glb = pp.to_glb(vertices=sv_t.cpu(), faces=sf_t.cpu(), attr_volume=mesh_out.attrs.cpu(),
                            coords=mesh_out.coords.cpu(), attr_layout=mesh_out.layout, voxel_size=mesh_out.voxel_size,
                            aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]], decimation_target=target_faces,
                            texture_size=tex_size, verbose=True)
            glb.export(glb_path)
            return
        except RuntimeError as e:
            print(f"  Metal bake failed: {e}\n  Falling back to KDTree texture baker...")
    from PIL import Image
    from backends.texture_baker import bake_texture, export_glb_with_texture, uv_unwrap

    print(f"Baking PBR textures via KDTree ({tex_size}x{tex_size})...")
    bv, bf = verts, faces
    target_faces = min(200000, len(faces))
    if len(faces) > target_faces:
        import fast_simplification

        bv, bf = fast_simplification.simplify(verts, faces, 1.0 - target_faces / len(faces))
    new_verts, new_faces, uvs, _ = uv_unwrap(bv, bf)
    base_color, mr, _ = bake_texture(new_verts, new_faces, uvs, mesh_out.coords.cpu().float().numpy(),
                                     mesh_out.attrs.cpu().float().numpy(), mesh_out.origin.cpu().float().numpy(),
                                     mesh_out.voxel_size, texture_size=tex_size)
    Image.fromarray(base_color).save(f"{base}_basecolor.png")
    export_glb_with_texture(new_verts, new_faces, uvs, base_color, mr, glb_path)


def _grid_sample_3d_fix(feats, coords, shape, grid, mode="trilinear"):
    import torch
    import torch.nn.functional as F

    B, C, D, H, W = shape[0], shape[1], shape[2], shape[3], shape[4]
    dense = torch.zeros(B, C, D, H, W, dtype=feats.dtype, device=feats.device)
    b, x, y, z = coords[:, 0].long(), coords[:, 1].long(), coords[:, 2].long(), coords[:, 3].long()
    dense[b, :, x, y, z] = feats
    g = torch.stack([grid[..., 2] / (W - 1) * 2 - 1, grid[..., 1] / (H - 1) * 2 - 1, grid[..., 0] / (D - 1) * 2 - 1],
                    dim=-1).reshape(B, 1, 1, -1, 3)
    sampled = F.grid_sample(dense, g, mode="bilinear", align_corners=True, padding_mode="border")
    return sampled.reshape(B, C, grid.shape[1]).permute(0, 2, 1).reshape(B * grid.shape[1], C)
```

- [ ] **Step 4: Run the tests**

Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q`
Expected: `28 passed` (`test_trellis2_mac.py` alone: `10 passed`).

- [ ] **Step 5: Commit**

```bash
git add dev-recipes/trellis2-mac/recipe.yaml \
        dev-recipes/trellis2-mac/launcher.py \
        python/recipe_tests/test_trellis2_mac.py
git commit -m "feat(recipes): TRELLIS.2 through trellis-mac — pinned setup, warm pipeline, Metal bake" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        dev-recipes/trellis2-mac/recipe.yaml \
        dev-recipes/trellis2-mac/launcher.py \
        python/recipe_tests/test_trellis2_mac.py
```

---
### Task 6: The bundled recipes, checked end to end without weights

This task pins existing behaviour: the three recipes parse and validate, install in the go/no-go order (dry run through `FakeRunner`), pin every upstream source, credit what they use, and download only their weight subsets. It also adds two opt-in checks for pin bumps: a real install into a temp workdir, and the recipe settings against the upstream code.

**Files:**
- Create: `Tests/LiftCoreTests/BundledRecipeTests.swift`, `Tests/LiftCoreTests/RealInstallTests.swift`, `python/recipe_tests/test_upstream_settings.py`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5; Plan 1's `Catalog.scan(_:includeDeveloper:)`, `RecipeSourceDir`, `ShimConfig.build(_:registry:)`, `Installer(runner:models:workerRuntime:tools:toolEnvironment:hfToken:hfHub:)`, `Lift.modelsInstall(_:confirm:wait:downloadWeights:)`, `FakeMetadata`, `Fixtures.devRecipes`/`workerRuntime`/`tempDir()`.
- Produces: env switches `LIFT_REAL_INSTALL=<id,id>` (Swift, real install, ~4 min per recipe, no weights) and `LIFT_MODELS_DIR=<models folder>` (Python, compares settings with `<models>/<id>/repo`).

- [ ] **Step 1: Write the checks**

`Tests/LiftCoreTests/BundledRecipeTests.swift`:

```swift
import Foundation
import Testing
@testable import LiftCore

/// The real recipes in dev-recipes/: they parse, validate, and install (dry run) exactly as the go/no-go found.
@Suite struct BundledRecipeTests {
    static let catalog = Catalog.scan([RecipeSourceDir(name: "bundled", dir: Fixtures.devRecipes)], includeDeveloper: true)

    func entry(_ id: String) throws -> CatalogEntry { try #require(Self.catalog.entries[id]) }

    func installer(_ runner: FakeRunner, brew: String? = "/opt/homebrew/bin/brew") throws -> Installer {
        Installer(runner: runner, models: try Fixtures.tempDir(), workerRuntime: URL(filePath: "/lift/runtime"),
                  tools: ToolPaths(brew: brew, git: "/bin/git", uv: "/bin/uv"), toolEnvironment: ["PATH": "/bin"],
                  hfToken: { "hf_x" }, hfHub: URL(filePath: "/hf/hub"))
    }

    @Test func everyRecipeParsesAndValidates() throws {
        #expect(Self.catalog.problems.isEmpty, "\(Self.catalog.problems)")
        #expect(Self.catalog.entries.keys.sorted() == ["pixal3d", "test-cube", "trellis2-mac", "unirig"])
        for id in ["pixal3d", "unirig", "trellis2-mac"] {
            let r = try entry(id).recipe
            #expect(r.platform.status == .supported)
            #expect(r.commit?.count == 40)
        }
    }

    @Test func shimConfigsMatchTheGoNoGoFindings() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        func shim(_ id: String) throws -> String? { try ShimConfig.build(entry(id).recipe, registry: registry)?.json }
        #expect(try shim("pixal3d") == #"{"aliases":{"nvdiffrast":"mtldiffrast"},"env":{},"patches":[],"standins":["flash_attn"]}"#)
        #expect(try shim("unirig") == #"{"aliases":{},"env":{},"patches":["transformers_fa2_to_sdpa","torch_scatter_mps","torch_cluster_mps"],"standins":["flash_attn","spconv"]}"#)
        #expect(try shim("trellis2-mac") == nil)
    }

    /// Every git clone is followed by a checkout of a full sha, and every git+https requirement names one.
    @Test func everyUpstreamSourceIsPinned() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        let commands = Self.catalog.entries.values.flatMap(\.recipe.install) + registry.values.flatMap(\.install)
        for c in commands where c.contains("git clone") {
            #expect(c.range(of: #"\{ \[ -d (\S+)/\.git \] \|\| git clone --filter=blob:none \S+ \1; \} && git -C \1 fetch -q origin && git -C \1 checkout -qf [0-9a-f]{40}$"#,
                            options: .regularExpression) != nil, "\(c)")
        }
        for c in commands where c.contains("git+https") {
            #expect(c.range(of: #"git\+https://[^"@ ]+@[0-9a-f]{40}"#, options: .regularExpression) != nil, "\(c)")
        }
    }

    @Test func pixal3dInstallsInTheFindingsOrder() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let e = try entry("pixal3d")
        let m = inst.dir("pixal3d").path
        let stale = inst.dir("pixal3d").appending(path: "deps/mtlgemm/build")  // a previous install's build products
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try await inst.install(e, pin: nil, onLine: { _ in })
        #expect(!FileManager.default.fileExists(atPath: stale.path))  // deps/ starts empty, so substitutes rebuild cleanly
        let d = runner.displays
        #expect(Array(d.prefix(4)) == ["/usr/bin/xcrun metal --version",
                                       "/bin/git clone --filter=blob:none https://github.com/TencentARC/Pixal3D \(m)/repo",
                                       "/bin/git -C \(m)/repo checkout --quiet f7cf38429b0bd264f1995f0f8743a88b1c728b94",
                                       "/bin/uv venv --python 3.11 \(m)/venv"])
        #expect(d[4] == #"uv pip install "torch==2.11.*" torchvision"#)
        #expect(d.filter { $0.contains("--no-build-isolation deps/") }.map { String($0.split(separator: " ").last!) }
                == ["deps/mtlgemm", "deps/mtldiffrast", "deps/mtlbvh", "deps/mtlmesh", "deps/trellis2-apple/o-voxel"])
        #expect(d.contains("git -C deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen"))
        let lastBuild = try #require(d.lastIndex { $0.contains("--no-build-isolation deps/") })
        #expect(d[lastBuild + 1] == "/bin/uv pip install \(e.shared.path)/lift_shim")
        #expect(d.last!.hasPrefix("\(m)/venv/bin/python -m lift_worker --check "))
        #expect(runner.commands.last!.environment["LIFT_SHIM"]?.contains(#""nvdiffrast":"mtldiffrast""#) == true)
        #expect(runner.commands[4].workingDirectory == m && runner.commands[4].environment["VIRTUAL_ENV"] == "\(m)/venv")
    }

    @Test func unirigInstallsLibusbWithNativeBrewFirst() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        try await inst.install(try entry("unirig"), pin: nil, onLine: { _ in })
        #expect(runner.displays.first == "/opt/homebrew/bin/brew install libusb")
        #expect(runner.displays.contains(#"python -c "import bpy, open3d, torch_scatter, torch_cluster""#))
        #expect(!runner.displays.contains { $0.contains("xcrun metal") })
    }

    @Test func unirigNeedsNativeBrew() async throws {
        let runner = FakeRunner()
        await #expect(throws: LiftError.prerequisite("UniRig needs native Homebrew for libusb; run system_install_prereqs")) {
            try await installer(runner, brew: nil).install(try entry("unirig"), pin: nil, onLine: { _ in })
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func trellisRunsSetupShWithPinsPrePlacedAndNoShim() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let m = inst.dir("trellis2-mac").path
        try await inst.install(try entry("trellis2-mac"), pin: nil, onLine: { _ in })
        let d = runner.displays
        let setup = try #require(d.firstIndex(of: #"cd repo && UV_CONSTRAINT="$PWD/../torch-constraint.txt" UV_NO_CACHE=1 bash setup.sh"#))
        for dep in ["TRELLIS.2", "deps/mtlbvh", "deps/mtldiffrast", "deps/mtlmesh", "deps/mtlgemm", "deps/trellis2-apple"] {
            let clone = try #require(d.firstIndex { $0.contains("git clone --filter=blob:none") && $0.contains(" repo/\(dep); }") }, "\(dep)")
            #expect(clone < setup)
        }
        #expect(d.firstIndex(of: "ln -sfn ../venv repo/.venv")! < setup)
        #expect(d.firstIndex(of: "printf 'torch==2.13.0\\n' > torch-constraint.txt")! < setup)
        #expect(!d.contains { $0.contains("lift_shim") })
        #expect(runner.commands.last!.environment["LIFT_SHIM"] == nil)
        #expect(d.last!.hasPrefix("\(m)/venv/bin/python -m lift_worker --check "))
    }

    @Test func aMissingMetalToolchainStopsBeforeAnythingIsTouched() async throws {
        let runner = FakeRunner()
        runner.on("xcrun metal", code: 1)
        await #expect(throws: LiftError.prerequisite("TRELLIS.2 (trellis-mac) needs the Metal Toolchain; run system_install_prereqs with metal")) {
            try await installer(runner).install(try entry("trellis2-mac"), pin: nil, onLine: { _ in })
        }
        #expect(runner.displays == ["/usr/bin/xcrun metal --version"])
    }

    @Test func weightDownloadsFetchOnlyTheListedFiles() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let bin = inst.dir("unirig").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try await inst.downloadWeights(try entry("unirig").recipe, onLine: { _ in })
        #expect(runner.displays == [
            "\(bin.path)/hf download VAST-AI/UniRig skeleton/articulation-xl_quantization_256/model.ckpt skin/articulation-xl/model.ckpt --revision main",
            "\(bin.path)/hf download facebook/opt-350m config.json --revision main",
        ])
    }

    /// Spec §4a: every weights repo is credited, and RMBG-2.0's non-commercial license is flagged wherever it's used.
    @Test func everyRecipeCreditsWhatItUses() throws {
        for id in ["pixal3d", "unirig", "trellis2-mac"] {
            let r = try entry(id).recipe
            let a = try #require(r.attribution, "\(id)")
            for w in r.weights {
                #expect(a.components.contains { $0.url == "https://huggingface.co/\(w.repo)" }, "\(id): \(w.repo) is not credited")
            }
            for c in a.components where c.name.hasPrefix("RMBG-2.0") { #expect(c.restrictions == ["non-commercial"], "\(id)") }
        }
        #expect(try entry("trellis2-mac").recipe.attribution?.components.contains { $0.url == "https://github.com/shivampkumar/trellis-mac" } == true)
    }

    @Test func gatedWeightsAreMarked() throws {
        func gated(_ id: String) throws -> [String] { try entry(id).recipe.weights.filter(\.gated).map(\.repo) }
        #expect(try gated("pixal3d") == ["briaai/RMBG-2.0"])
        #expect(try gated("trellis2-mac") == ["facebook/dinov3-vitl16-pretrain-lvd1689m", "briaai/RMBG-2.0"])
        #expect(try gated("unirig").isEmpty)
        #expect(try entry("unirig").recipe.weights.first { $0.repo == "facebook/opt-350m" }?.files == ["config.json"])

    }
}
```

`Tests/LiftCoreTests/RealInstallTests.swift`:

```swift
import Foundation
import Testing
@testable import LiftCore

/// Slow and opt-in: a real install of bundled recipes into a temp workdir: clone at the pins, build the venv and
/// the Metal substitutes, and pass the smoke check (which imports upstream under lift_shim). No weights are
/// downloaded. LIFT_REAL_INSTALL is a comma-separated list of recipe ids, e.g. `pixal3d,trellis2-mac`.
@Suite(.serialized, .timeLimit(.minutes(60))) struct RealInstallTests {
    static let ids = (ProcessInfo.processInfo.environment["LIFT_REAL_INSTALL"] ?? "").split(separator: ",").map(String.init)

    @Test(.enabled(if: !ids.isEmpty), arguments: ids)
    func installsAndPassesTheSmokeCheck(id: String) async throws {
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime,
                                                  bundledRecipes: Fixtures.devRecipes, hfToken: { "hf_not_used_without_weights" },
                                                  hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        let model = try await lift.modelsInstall(id, confirm: true, wait: true, downloadWeights: false).value
        let log = (try? await lift.modelsInstallLog(id)) ?? ""
        #expect(model?.status == .installed(commit: model?.recipe.commit), "\(log.suffix(4000))")
        #expect(log.contains("lift_worker: launcher OK"))
        #expect(FileManager.default.isExecutableFile(atPath: lift.config.workdir.appending(path: "models/\(id)/venv/bin/hf").path))  // for weight downloads
    }
}
```

`python/recipe_tests/test_upstream_settings.py`:

```python
"""The recipes' settings against the real upstream code: every keyword argument / flag, with upstream's default.

Needs upstream checkouts, so it is skipped unless LIFT_MODELS_DIR points at a Lift `models/` folder with
pixal3d, unirig and trellis2-mac installed (each has repo/). Run it after changing any pin.
"""
import ast
import os
import re
from pathlib import Path

import pytest

from conftest import defaults

MODELS = os.environ.get("LIFT_MODELS_DIR")
pytestmark = pytest.mark.skipif(not MODELS, reason="set LIFT_MODELS_DIR to a models/ folder with the real recipes installed")


def repo(recipe):
    return Path(MODELS) / recipe / "repo"


def keyword_defaults(path, function, constants):
    tree = ast.parse(Path(path).read_text())
    fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == function)
    args = fn.args.args[len(fn.args.args) - len(fn.args.defaults):]
    return {a.arg: constants[d.id] if isinstance(d, ast.Name) else ast.literal_eval(d) for a, d in zip(args, fn.args.defaults)}


@pytest.mark.parametrize("module, task, lift_only", [
    ("inference", "image_to_3d", set()),
    ("inference_mv", "image_set_to_3d", {"views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance"}),
])
def test_pixal3d_settings_are_run_inference_keywords(module, task, lift_only):
    upstream = keyword_defaults(repo("pixal3d") / f"{module}.py", "run_inference",
                                {"MODEL_PATH": "TencentARC/Pixal3D", "CONFIG_FILE": "pipeline_mv.json"})
    if "num_views" in upstream:
        assert upstream["num_views"] is None
        upstream["num_views"] = 0  # Lift's 0 = upstream's None (all views)
    ours = {k: v for k, v in defaults("pixal3d", task).items() if k not in lift_only}
    assert ours == upstream


def test_unirig_settings_are_the_script_flags():
    ours = defaults("unirig", "rig")
    for script, renames in [("generate_skeleton", {"force_override": "skeleton_force_override"}),
                            ("generate_skin", {"force_override": "skin_force_override"}), ("merge", {})]:
        text = (repo("unirig") / f"launch/inference/{script}.sh").read_text()
        flags = re.findall(r"^\s+--(\w+)\) ", text, re.M)
        values = {k: a or b for k, a, b in re.findall(r'^(\w+)=(?:"([^"]*)"|(\S+))', text, re.M)}
        for flag in flags:
            if flag in {"input", "output", "input_dir", "output_dir", "source", "target"}:
                continue  # Lift passes the job's files
            value = ours[renames.get(flag, flag)]
            assert (str(value).lower() if isinstance(value, bool) else str(value)) == values[flag], (script, flag)


def test_trellis_settings_are_generate_py_options():
    text = (repo("trellis2-mac") / "generate.py").read_text()
    options = {o.replace("-", "_") for o in re.findall(r'add_argument\(\s*"--([\w-]+)"', text)} - {"output"}
    assert set(defaults("trellis2-mac", "image_to_3d")) == options
```

- [ ] **Step 2: Run them**

Run: `swift test --filter "BundledRecipeTests|RealInstallTests"`
Expected: `BundledRecipeTests` — 11 tests pass; `installsAndPassesTheSmokeCheck` is skipped (no `LIFT_REAL_INSTALL`).
Run: `cd python/recipe_tests && uv run --python 3.11 pytest -q`
Expected: `28 passed, 4 skipped`.

If a `BundledRecipeTests` expectation fails, the recipe is wrong, not the test: compare with the findings and `spike/setup_*.sh`.

- [ ] **Step 3 (optional, slow, needs network for packages only): real installs**

Only on a Mac with the Metal Toolchain (`xcrun metal --version`). It clones at the pins, builds the venv and the Metal substitutes in a temp workdir, and imports upstream in the smoke check. It downloads no weights (`downloadWeights: false`) and installs nothing outside temp folders, so it leaves out `unirig` (its `brew install libusb` would write to `/opt/homebrew`):

```bash
mkdir -p "$TMPDIR/lift-real/uv" "$TMPDIR/lift-real/hf"
UV_CACHE_DIR="$TMPDIR/lift-real/uv" HF_HOME="$TMPDIR/lift-real/hf" TORCH_HOME="$TMPDIR/lift-real/torch" \
  LIFT_REAL_INSTALL=pixal3d,trellis2-mac swift test --filter RealInstallTests
```

Expected: `installsAndPassesTheSmokeCheck(id:) with 2 test cases passed` in about 7–8 minutes; each install log ends with `lift_worker: launcher OK` and `installed <id>`.

To check the settings against upstream after a pin change, point `LIFT_MODELS_DIR` at a `models/` folder with the three recipes installed (or one with `<id>/repo` symlinks to clones at the pins):

```bash
cd python/recipe_tests && LIFT_MODELS_DIR=/path/to/workdir/models uv run --python 3.11 pytest -q test_upstream_settings.py
```

Expected: `4 passed`.

- [ ] **Step 4: Commit**

```bash
git add Tests/LiftCoreTests/BundledRecipeTests.swift \
        Tests/LiftCoreTests/RealInstallTests.swift \
        python/recipe_tests/test_upstream_settings.py
git commit -m "test(recipes): bundled recipes install in the findings order, pinned and credited; opt-in real installs" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Tests/LiftCoreTests/BundledRecipeTests.swift \
        Tests/LiftCoreTests/RealInstallTests.swift \
        python/recipe_tests/test_upstream_settings.py
```

---
### Task 7: The Exporter — GLB, USDZ, OBJ, FBX, credits, verified copies

**Files:**
- Modify: `Package.swift`, `Package.resolved` (GLTFKit2)
- Create: `Sources/LiftCore/Exporter/Exporter.swift`
- Create: `Tests/LiftCoreTests/CubeGLB.swift` (a generated cube GLB, optionally textured), `Tests/LiftCoreTests/ExporterTests.swift`

**Interfaces:**
- Consumes: Task 1's `Recipe.Attribution` (`credit`, `disclaimer`, components); Plan 1's `CommandRunner`, `ShellCommand`, `SubprocessRunner`, `LiftError`, `Fixtures.tempDir()`/`fakeBin(_:)`.
- Produces:
  - `public enum ExportFormat: String, Codable, Sendable, CaseIterable { case glb, usdz, obj, fbx }`
  - `public struct ExportSpec: Codable, Sendable, Equatable { dir: String?, formats: [ExportFormat]?, cleanupAfterExport: Bool? }` with `init(dir:formats:cleanupAfterExport:)` (all default nil).
  - `public struct ExportResult: Codable, Sendable, Equatable { format, path: String?, error: String?, credits: String? }`
  - `public struct Exporter { init(runner:blenderPython:); func export(_ outputs: [String], title: String, formats: [ExportFormat], credits: [Recipe.Attribution], to dir: URL, work: URL) async -> [ExportResult] }`
  - Internal statics used by tests: `fbxScript`, `fileName(_:)`, `copy(_:into:)`, `creditLine(_:)`, `creditsText(_:)`, `stamped(glb:credit:)`.
  - Test helpers: `Fixtures.cubeGLB(textured: Bool = false, in: URL? = nil, name: String = "cube.glb") throws -> URL`, `cubeCredits`, `RecordingRunner`.

- [ ] **Step 1: Add GLTFKit2**

```diff
--- a/Package.swift
+++ b/Package.swift
@@ -11,10 +11,12 @@ let package = Package(
         .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
         .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
         .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.1"),
+        .package(url: "https://github.com/warrenm/GLTFKit2", from: "0.5.15"),
     ],
     targets: [
         .target(name: "LiftCore", dependencies: [
+            .product(name: "GLTFKit2", package: "GLTFKit2"),
             .product(name: "GRDB", package: "GRDB.swift"),
             .product(name: "Yams", package: "Yams"),
             .product(name: "Subprocess", package: "swift-subprocess"),
```

Run: `swift package resolve` — it downloads GLTFKit2's xcframework zip (checksum `9d0c3382…`), then `git diff --stat Package.resolved` shows the new pin `0.5.15` (`e69e354c4f31ea07b7816b8cbe2ddb28e897d073`).

- [ ] **Step 2: Write the cube fixture and the failing tests**

`Tests/LiftCoreTests/CubeGLB.swift` (a valid binary glTF 2.0 written by hand: 8 vertices, 12 triangles, optional UVs and an embedded 2×2 PNG):

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Fixtures {
    /// Writes a 1-unit cube as binary glTF 2.0 (8 vertices, 12 triangles). With `textured`, it also has
    /// UVs and an embedded 2×2 PNG base-color texture, so exporters have a material to carry over.
    static func cubeGLB(textured: Bool = false, in dir: URL? = nil, name: String = "cube.glb") throws -> URL {
        let p: [Float] = [-0.5, -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, -0.5, -0.5, 0.5, -0.5,
                          -0.5, -0.5, 0.5, 0.5, -0.5, 0.5, 0.5, 0.5, 0.5, -0.5, 0.5, 0.5]
        let idx: [UInt16] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                             2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 3, 0, 4, 3, 4, 7]
        let uv: [Float] = [0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1]
        var bin = Data()
        func append<T>(_ values: [T]) -> (offset: Int, length: Int) {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            values.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, bin.count - offset)
        }
        let pv = append(p), iv = append(idx)
        var views: [[String: Any]] = [["buffer": 0, "byteOffset": pv.offset, "byteLength": pv.length, "target": 34962],
                                      ["buffer": 0, "byteOffset": iv.offset, "byteLength": iv.length, "target": 34963]]
        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [-0.5, -0.5, -0.5], "max": [0.5, 0.5, 0.5]],
            ["bufferView": 1, "componentType": 5123, "count": 36, "type": "SCALAR"],
        ]
        var attributes: [String: Any] = ["POSITION": 0]
        var json: [String: Any] = ["asset": ["version": "2.0", "generator": "Lift tests"], "scene": 0,
                                   "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": "Cube"]]]
        var primitive: [String: Any] = ["indices": 1]
        if textured {
            let tv = append(uv)
            views.append(["buffer": 0, "byteOffset": tv.offset, "byteLength": tv.length, "target": 34962])
            accessors.append(["bufferView": 2, "componentType": 5126, "count": 8, "type": "VEC2"])
            attributes["TEXCOORD_0"] = 2
            let png = try Self.png2x2()
            let imgv = append([UInt8](png))
            views.append(["buffer": 0, "byteOffset": imgv.offset, "byteLength": imgv.length])
            json["images"] = [["bufferView": 3, "mimeType": "image/png"]]
            json["textures"] = [["source": 0]]
            json["materials"] = [["name": "Checker", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "metallicFactor": 0.0]]]
            primitive["material"] = 0
        }
        while bin.count % 4 != 0 { bin.append(0) }
        primitive["attributes"] = attributes
        json["meshes"] = [["primitives": [primitive]]]
        json["accessors"] = accessors
        json["bufferViews"] = views
        json["buffers"] = [["byteLength": bin.count]]
        var text = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        while text.count % 4 != 0 { text.append(0x20) }
        var glb = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { glb.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); glb.append(text)
        u32(bin.count); u32(0x004E_4942); glb.append(bin)
        let url = (try dir ?? tempDir()).appending(path: name)
        try glb.write(to: url)
        return url
    }

    private static func png2x2() throws -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}
```

`Tests/LiftCoreTests/ExporterTests.swift`:

```swift
import Foundation
import ModelIO
import Testing
@testable import LiftCore

/// A recipe's attribution as Lift reads it, with one restricted component.
let cubeCredits = [try! JSONDecoder().decode(Recipe.Attribution.self, from: Data(#"""
{"project": "Test Cube", "authors": ["Lift"], "homepage": "https://example.org/cube",
 "license": {"spdx": "MIT", "url": "https://example.org/cube/LICENSE"},
 "components": [{"name": "RMBG-2.0", "url": "https://huggingface.co/briaai/RMBG-2.0",
                 "license": {"spdx": "CC-BY-NC-4.0", "url": "https://creativecommons.org/licenses/by-nc/4.0/"},
                 "restrictions": ["non-commercial"]}]}
"""#.utf8))]

@Suite struct ExporterTests {
    /// A stand-in for the UniRig venv's python: writes its last argument (the FBX path) like Blender would.
    func fakeBlender() throws -> String {
        let bin = try Fixtures.fakeBin(["python"]).appending(path: "python")
        try "#!/bin/sh\nfor a; do last=\"$a\"; done\necho fbx > \"$last\"\n".write(to: bin, atomically: true, encoding: .utf8)
        return bin.path
    }

    func export(_ outputs: [URL], _ formats: [ExportFormat], title: String = "My cube", blender: String? = nil,
                runner: any CommandRunner = SubprocessRunner(), into dir: URL? = nil,
                credits: [Recipe.Attribution] = cubeCredits) async throws -> (URL, [ExportResult]) {
        let dir = try dir ?? Fixtures.tempDir()
        let results = await Exporter(runner: runner, blenderPython: blender)
            .export(outputs.map(\.path), title: title, formats: formats, credits: credits, to: dir, work: try Fixtures.tempDir())
        return (dir, results)
    }

    /// The GLB's JSON chunk as a dictionary, and everything after it (the binary chunk).
    func glbParts(_ url: URL) throws -> (json: [String: Any], rest: Data) {
        let b = [UInt8](try Data(contentsOf: url))
        let end = 20 + (Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24)
        return (try JSONSerialization.jsonObject(with: Data(b[20..<end])) as! [String: Any], Data(b[end...]))
    }

    @Test func glbKeepsItsGeometryAndCarriesTheCredit() async throws {
        let glb = try Fixtures.cubeGLB(textured: true)
        let (dir, results) = try await export([glb], [.glb])
        let out = dir.appending(path: "My cube.glb")
        #expect(results == [ExportResult(format: .glb, path: out.path)])
        let asset = try #require(try glbParts(out).json["asset"] as? [String: Any])
        #expect(asset["copyright"] as? String == "Test Cube by Lift (MIT), run with Lift" && asset["generator"] as? String == asset["copyright"] as? String)
        #expect(asset["version"] as? String == "2.0")
        #expect(try Data(contentsOf: out).count % 4 == 0)
        #expect(try glbParts(out).rest == glbParts(glb).rest)  // the binary chunk is untouched
        #expect((try glbParts(out).json["meshes"] as? [Any])?.count == 1)  // the rest of the JSON is intact
    }

    @Test func otherFormatsGetACreditsSidecar() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB()], [.glb, .obj, .usdz])
        let sidecar = dir.appending(path: "My cube.credits.txt")
        #expect(results[0].credits == nil && results[1].credits == sidecar.path && results[2].credits == sidecar.path)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(text.hasPrefix("Test Cube by Lift (MIT), run with Lift\n"))
        #expect(text.contains("Lift did not create Test Cube and is not affiliated with or endorsed by its authors."))
        #expect(text.contains("RMBG-2.0: https://huggingface.co/briaai/RMBG-2.0 — CC-BY-NC-4.0") && text.contains("NON-COMMERCIAL"))
        let (glbOnly, _) = try await export([try Fixtures.cubeGLB()], [.glb])
        #expect(!FileManager.default.fileExists(atPath: glbOnly.appending(path: "My cube.credits.txt").path))  // the GLB credits itself
    }

    @Test func usdzEmbedsTheTexture() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.usdz])
        let usdz = dir.appending(path: "My cube.usdz")
        #expect(results.first?.error == nil && results.first?.path == usdz.path)
        let bytes = try Data(contentsOf: usdz)
        #expect(bytes.prefix(2) == Data("PK".utf8))  // a zip package
        #expect(bytes.range(of: Data(".png".utf8)) != nil)  // the base-color texture travels inside
        #expect(MDLAsset(url: usdz).count == 1)
    }

    @Test func objIsAFolderWithItsMaterialAndTexture() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.obj])
        let folder = dir.appending(path: "My cube")
        #expect(results.first?.path == folder.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.contains("My cube.obj") && files.contains("My cube.mtl") && files.contains { $0.hasSuffix(".png") })
        let obj = MDLAsset(url: folder.appending(path: "My cube.obj"))
        #expect((obj.object(at: 0) as? MDLMesh)?.vertexCount ?? 0 >= 8)
    }

    @Test func fbxRunsBlendersImporterAndExporter() async throws {
        let blender = try fakeBlender()
        let glb = try Fixtures.cubeGLB()
        let runner = RecordingRunner()
        let (dir, results) = try await export([glb], [.fbx], blender: blender, runner: runner)
        #expect(results.first?.path == dir.appending(path: "My cube.fbx").path)
        let command = try #require(runner.commands.first)
        #expect(command.executable == blender && command.arguments[0] == "-c" && command.arguments[1] == Exporter.fbxScript)
        #expect(command.arguments[2] == glb.path && command.arguments[3].hasSuffix("/fbx/My cube.fbx"))
        #expect(command.environment["BLENDER_USER_RESOURCES"]?.hasSuffix("/fbx/blender") == true)
    }

    @Test func eachFormatFailsAlone() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB()], [.glb, .fbx, .obj])
        #expect(results.map(\.format) == [.glb, .fbx, .obj])
        #expect(results[1].path == nil && results[1].error?.contains("install UniRig") == true)
        #expect(results[0].error == nil && results[2].error == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "My cube.glb").path))
    }

    @Test func anOutputAlreadyInTheFormatIsUsedAsIs() async throws {
        let fbx = try Fixtures.tempDir().appending(path: "rigged.fbx")
        try Data("unirig fbx".utf8).write(to: fbx)
        let runner = RecordingRunner()
        let (dir, results) = try await export([fbx], [.fbx, .usdz], runner: runner)
        #expect(results[0].path == dir.appending(path: "My cube.fbx").path && runner.commands.isEmpty)
        #expect(results[1].error == "no GLB output to make usdz from")
    }

    @Test func existingFilesAreNeverOverwritten() async throws {
        let glb = try Fixtures.cubeGLB()
        let (dir, _) = try await export([glb], [.glb, .obj])
        let (_, again) = try await export([glb], [.glb, .obj], into: dir)
        #expect(again.map(\.path) == [dir.appending(path: "My cube 2.glb").path, dir.appending(path: "My cube 2").path])
    }

    @Test func titlesBecomeSafeFileNames() {
        #expect(Exporter.fileName("chair/v2: final") == "chair-v2- final")
        #expect(Exporter.fileName("  ..hidden ") == "hidden")
        #expect(Exporter.fileName("/") == "-")
        #expect(Exporter.fileName("") == "export")
    }

    /// Real Blender: set LIFT_TEST_BPY_PYTHON to a Python with bpy 4.2 (e.g. an installed UniRig's venv/bin/python).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFT_TEST_BPY_PYTHON"] != nil))
    func realBlenderWritesAnFBX() async throws {
        let python = ProcessInfo.processInfo.environment["LIFT_TEST_BPY_PYTHON"]!
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.fbx], blender: python)
        #expect(results.first?.error == nil)
        let fbx = try Data(contentsOf: dir.appending(path: "My cube.fbx"))
        #expect(fbx.prefix(18) == Data("Kaydara FBX Binary".utf8))
    }
}

/// Records commands and runs them for real (so the fake Blender writes its file).
final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ShellCommand] = []
    var commands: [ShellCommand] { lock.withLock { recorded } }

    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        lock.withLock { recorded.append(command) }
        return try await SubprocessRunner().run(command, onLine: onLine)
    }
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'Exporter' in scope`, `cannot find type 'ExportFormat' in scope`.

- [ ] **Step 4: Implement the Exporter**

`Sources/LiftCore/Exporter/Exporter.swift`:

```swift
import CryptoKit
import Foundation
import GLTFKit2
import ModelIO
import SceneKit

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case glb, usdz, obj, fbx
}

/// A job's `export` (spec §7). In a request, nil fields take the `export_dir`, `export_formats` and
/// `cleanup_after_export` settings; the stored job has all three filled.
public struct ExportSpec: Codable, Sendable, Equatable {
    public var dir: String?
    public var formats: [ExportFormat]?
    public var cleanupAfterExport: Bool?

    public init(dir: String? = nil, formats: [ExportFormat]? = nil, cleanupAfterExport: Bool? = nil) {
        self.dir = dir
        self.formats = formats
        self.cleanupAfterExport = cleanupAfterExport
    }
}

/// One format's outcome. A failed format never affects the others (spec §9).
public struct ExportResult: Codable, Sendable, Equatable {
    public var format: ExportFormat
    /// What landed in the export folder: a file, or for OBJ a folder with the .obj, its .mtl and textures.
    public var path: String?
    public var error: String?
    /// The `<title>.credits.txt` next to it (USDZ, OBJ and FBX carry no attribution of their own).
    public var credits: String?
}

/// Converts a job's final output and copies it into the export folder as `<title>.<ext>` (spec §9):
/// GLB as is, USDZ through SceneKit, OBJ through ModelIO (GLB read by GLTFKit2), FBX through Blender's `bpy`.
/// Every export credits the models that made it (spec §4a): in the GLB's `asset` fields, and in a
/// `<title>.credits.txt` sidecar for the other formats.
public struct Exporter: Sendable {
    let runner: any CommandRunner
    /// A Python with Blender's `bpy` (the UniRig venv); nil when there is none.
    let blenderPython: String?

    public init(runner: any CommandRunner, blenderPython: String?) {
        self.runner = runner
        self.blenderPython = blenderPython
    }

    /// `work` is scratch space inside the job folder; `outputs` are the final step's files; `credits` are the
    /// attributions of the recipes that made them, in step order.
    public func export(_ outputs: [String], title: String, formats: [ExportFormat], credits: [Recipe.Attribution],
                       to dir: URL, work: URL) async -> [ExportResult] {
        var results: [ExportResult] = []
        let name = Self.fileName(title)
        for format in formats where !results.contains(where: { $0.format == format }) {
            do {
                var made = try await convert(outputs, to: format, name: name, in: work.appending(path: format.rawValue))
                if format == .glb, !credits.isEmpty {
                    let stamped = work.appending(path: "glb-credited/\(made.lastPathComponent)")
                    try FileManager.default.createDirectory(at: stamped.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.stamped(glb: Data(contentsOf: made), credit: Self.creditLine(credits)).write(to: stamped)
                    made = stamped
                }
                results.append(ExportResult(format: format, path: try Self.copy(made, into: dir).path))
            } catch {
                results.append(ExportResult(format: format, error: "\(error)"))
            }
        }
        if !credits.isEmpty, results.contains(where: { $0.format != .glb && $0.path != nil }) {
            let sidecar = work.appending(path: "\(name).credits.txt")
            do {
                try Self.creditsText(credits).write(to: sidecar, atomically: true, encoding: .utf8)
                let copied = try Self.copy(sidecar, into: dir).path
                for i in results.indices where results[i].format != .glb && results[i].path != nil { results[i].credits = copied }
            } catch {
                for i in results.indices where results[i].format != .glb && results[i].path != nil { results[i].error = "credits file: \(error)" }
            }
        }
        return results
    }

    /// "<Project> by <authors> (<license>); …, run with Lift" (spec §4a).
    static func creditLine(_ credits: [Recipe.Attribution]) -> String {
        credits.map(\.credit).joined(separator: "; ") + ", run with Lift"
    }

    /// The sidecar: the credit line, each project's disclaimer and its components with their licenses.
    static func creditsText(_ credits: [Recipe.Attribution]) -> String {
        var lines = [creditLine(credits), ""]
        for a in credits {
            lines += [a.disclaimer, "\(a.project): \(a.homepage) — \(a.license.spdx) (\(a.license.url))"]
            for c in a.components {
                let restricted = (c.restrictions ?? []).isEmpty ? "" : " — \((c.restrictions ?? []).joined(separator: ", ").uppercased())"
                lines.append("  - \(c.name): \(c.url) — \(c.license.spdx) (\(c.license.url))\(restricted)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The GLB with `asset.copyright` and `asset.generator` set to `credit`; its binary chunk is untouched.
    static func stamped(glb data: Data, credit: String) throws -> Data {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        guard b.count >= 20, u32(0) == 0x4654_6C67, u32(16) == 0x4E4F_534A, 20 + u32(12) <= b.count else {
            throw LiftError.invalidState("not a binary glTF file")
        }
        let jsonEnd = 20 + u32(12)
        guard var json = try JSONSerialization.jsonObject(with: Data(b[20..<jsonEnd])) as? [String: Any] else {
            throw LiftError.invalidState("the GLB's JSON is not an object")
        }
        var asset = json["asset"] as? [String: Any] ?? ["version": "2.0"]
        asset["copyright"] = credit
        asset["generator"] = credit
        json["asset"] = asset
        var text = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data()
        func put(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        put(0x4654_6C67); put(2); put(12 + 8 + text.count + (b.count - jsonEnd))
        put(text.count); put(0x4E4F_534A)
        out.append(text)
        out.append(contentsOf: b[jsonEnd...])
        return out
    }

    func convert(_ outputs: [String], to format: ExportFormat, name: String, in work: URL) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let files = outputs.map { URL(filePath: $0) }
        // An output already in this format (e.g. UniRig's own FBX) is used as is. OBJ is always made from the
        // GLB: an upstream OBJ (trellis-mac's) is bare geometry.
        if format != .obj, let same = files.first(where: { $0.pathExtension.lowercased() == format.rawValue }) {
            let dest = work.appending(path: "\(name).\(format.rawValue)")
            try fm.copyItem(at: same, to: dest)
            return dest
        }
        guard let glb = files.first(where: { $0.pathExtension.lowercased() == "glb" }) else {
            throw LiftError.invalidState("no GLB output to make \(format.rawValue) from")
        }
        switch format {
        case .glb:
            preconditionFailure("a GLB output is always used as is")
        case .usdz:
            // ModelIO can't write USDZ, and its USDC loses texture references; SceneKit embeds them.
            let dest = work.appending(path: "\(name).usdz")
            guard SCNScene(gltfAsset: try GLTFAsset(url: glb)).write(to: dest, options: nil, delegate: nil, progressHandler: nil) else {
                throw LiftError.invalidState("SceneKit could not write \(dest.lastPathComponent)")
            }
            return dest
        case .obj:
            // ModelIO writes the .mtl and textures next to the .obj and names textures after materials,
            // so the three travel as one folder and two exports never overwrite each other's textures.
            let folder = work.appending(path: name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try MDLAsset(gltfAsset: try GLTFAsset(url: glb)).export(to: folder.appending(path: "\(name).obj"))
            return folder
        case .fbx:
            guard let blenderPython else {
                throw LiftError.prerequisite("FBX export uses Blender's bpy from the UniRig model; install UniRig to export FBX")
            }
            let dest = work.appending(path: "\(name).fbx")
            try await runner.check(ShellCommand(blenderPython, ["-c", Self.fbxScript, glb.path, dest.path],
                                                environment: ["BLENDER_USER_RESOURCES": work.appending(path: "blender").path]))
            guard fm.fileExists(atPath: dest.path) else { throw LiftError.invalidState("Blender wrote no \(dest.lastPathComponent)") }
            return dest
        }
    }

    /// Blender's own glTF importer and FBX exporter; armatures and skin weights carry over, textures are embedded.
    /// bpy 4.2 as a Python module segfaults at interpreter exit (code 139), hence `os._exit(0)` once written.
    static let fbxScript = """
    import os, sys
    import bpy
    source, target = sys.argv[-2], sys.argv[-1]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)
    bpy.ops.export_scene.fbx(filepath=target, path_mode="COPY", embed_textures=True, add_leaf_bones=False)
    sys.stdout.flush()
    os._exit(0)
    """

    /// A title made safe for a file name: no `/` or `:`, no leading dot.
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "export" : cleaned
    }

    /// Copies a file or folder into `dir` without overwriting (`name 2.ext`, `name 3.ext`, …) and checks
    /// the copy's SHA-256 against the source.
    static func copy(_ item: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let needed = try size(item)
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw LiftError.prerequisite("not enough disk space in \(dir.path): \(needed) bytes needed, \(free) free")
        }
        let ext = item.pathExtension, stem = item.deletingPathExtension().lastPathComponent
        var dest = dir.appending(path: item.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: item, to: dest)
        guard try digest(item) == digest(dest) else {
            try? fm.removeItem(at: dest)
            throw LiftError.invalidState("the copy at \(dest.path) does not match its source")
        }
        return dest
    }

    /// Files in `item` (or `item` itself), as sorted relative paths.
    static func files(_ item: URL) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { return [""] }
        return (FileManager.default.subpaths(atPath: item.path) ?? []).filter { path in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: item.appending(path: path).path, isDirectory: &d) && !d.boolValue
        }.sorted()
    }

    static func size(_ item: URL) throws -> Int {
        try files(item).reduce(0) { total, path in
            let url = path.isEmpty ? item : item.appending(path: path)
            return total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    static func digest(_ item: URL) throws -> String {
        var hash = SHA256()
        for path in files(item) {
            hash.update(data: Data(path.utf8))
            hash.update(data: try Data(contentsOf: path.isEmpty ? item : item.appending(path: path), options: .mappedIfSafe))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ExporterTests`
Expected: 9 pass, `realBlenderWritesAnFBX` skipped.

Optional, with a Python that has `bpy` 4.2 (an installed UniRig's venv, or the go/no-go one):
`PYTHONDONTWRITEBYTECODE=1 LIFT_TEST_BPY_PYTHON=spike/work/venv-unirig/bin/python swift test --filter realBlenderWritesAnFBX` → passes; the FBX starts with `Kaydara FBX Binary`. (`BLENDER_USER_RESOURCES` points into the test's temp folder, so nothing is written to `~/Library`.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift \
        Package.resolved \
        Sources/LiftCore/Exporter/Exporter.swift \
        Tests/LiftCoreTests/CubeGLB.swift \
        Tests/LiftCoreTests/ExporterTests.swift
git commit -m "feat(core): Exporter — GLB, USDZ (SceneKit), OBJ (ModelIO via GLTFKit2), FBX (bpy), credits, verified copies" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Package.swift \
        Package.resolved \
        Sources/LiftCore/Exporter/Exporter.swift \
        Tests/LiftCoreTests/CubeGLB.swift \
        Tests/LiftCoreTests/ExporterTests.swift
```

---
### Task 8: Export after a job's last step, re-export, cleanup, resume

**Files:**
- Modify: `Sources/LiftCore/Store/Records.swift` (job fields), `Sources/LiftCore/Store/Store.swift` (migration `export`), `Sources/LiftCore/Store/Settings.swift` (three settings)
- Modify: `Sources/LiftCore/Commands/JobCommands.swift` (`SubmitRequest.export`, `jobsWait`, `jobsRetry` guard, `jobsExport`)
- Modify: `Sources/LiftCore/Engine/Lift.swift` (start export after the last step; resume at open)
- Create: `Sources/LiftCore/Engine/Export.swift`
- Test: `Tests/LiftCoreTests/ExportFlowTests.swift`

**Interfaces:**
- Consumes: Task 7's `Exporter`, `ExportSpec`, `ExportResult`, `ExportFormat`; Task 1's `Recipe.attribution`; Plan 1's `Lift` actor (`finish`, `start`, `view`, `recipe(_:)`, `installer.venvPython(_:)`, `installed`), `CubeFixture`, `CubeIntegrationTests.cube(_:)`, `Fixtures.lift(workdir:)`, `fieldErrors`.
- Produces:
  - `JobRecord.export: ExportSpec?` (all three fields filled), `exports: [ExportResult]`, `exportPending: Bool`, `cleanedUp: Bool` — GRDB migration `"export"` adds the columns.
  - Settings `export_dir: String?`, `export_formats: [ExportFormat]` (default `[glb]`; `settings_set` takes `"glb,usdz"`), `cleanup_after_export: Bool` (default false); `settings_set("export_dir", "")` clears it.
  - `SubmitRequest(steps:title:priority:source:export:)`; field error `export.dir` when formats are given and no folder is known.
  - `Lift.jobsExport(_ id: String, formats: [ExportFormat]? = nil, dir: String? = nil) async throws -> JobView` (never cleans up).
  - `jobsWait` returns only when the job is terminal **and** `!exportPending`. `jobsRetry` refuses a cleaned-up job.
  - Internal `Lift.export(_ id: String, _ spec: ExportSpec) async throws`; FBX uses `models/unirig/venv/bin/python` when UniRig is installed.

- [ ] **Step 1: Write the failing tests**

`Tests/LiftCoreTests/ExportFlowTests.swift` — real Test Cube runs in the serialized `CubeIntegrationTests` suite, plus a relaunch test:

```swift
import Foundation
import Testing
@testable import LiftCore

/// Export after a real Test Cube run (same serialized suite and shared install as CubeIntegrationTests).
extension CubeIntegrationTests {
    func submit(_ lift: Lift, export: ExportSpec?, title: String = "Cube export") async throws -> JobView {
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()], title: title, export: export)).job.id
        return try await lift.jobsWait(id, timeout: .seconds(120))
    }

    @Test func exportsEveryFormatAndAFailedFormatKeepsTheJobFiles() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        let v = try await submit(lift, export: ExportSpec(dir: dir.path, formats: [.glb, .usdz, .obj, .fbx], cleanupAfterExport: true))
        #expect(v.job.state == .succeeded && !v.job.exportPending)  // jobs_wait waited for the export
        #expect(v.job.exports.map(\.format) == [.glb, .usdz, .obj, .fbx])
        #expect(v.job.exports.prefix(3).allSatisfy { $0.error == nil })
        #expect(v.job.exports[3].error?.contains("install UniRig") == true)  // no UniRig in this workdir
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["Cube export", "Cube export.credits.txt", "Cube export.glb", "Cube export.usdz"])
        #expect(v.job.exports[1].credits == dir.appending(path: "Cube export.credits.txt").path)
        #expect(try String(contentsOf: dir.appending(path: "Cube export.credits.txt"), encoding: .utf8).hasPrefix("Test Cube by Lift (MIT), run with Lift"))
        let glb = try #require(v.outputs.first)
        #expect(!v.job.cleanedUp && FileManager.default.fileExists(atPath: glb))
    }

    @Test func cleanupDeletesOnlyTheJobFolderAfterAVerifiedCopy() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        let v = try await submit(lift, export: ExportSpec(dir: dir.path, formats: [.glb], cleanupAfterExport: true))
        #expect(v.job.cleanedUp && v.job.exports.first?.error == nil)
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(v.job.id)").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Cube export.glb").path))
        #expect(try await lift.jobsGet(v.job.id).job.state == .succeeded)  // the record stays
        await #expect(throws: LiftError.self) { _ = try await lift.jobsRetry(v.job.id) }
        await #expect(throws: LiftError.self) { _ = try await lift.jobsExport(v.job.id, formats: [.obj]) }
    }

    @Test func settingsAreTheDefaultsAndReExportAddsFormats() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        _ = try await lift.settingsSet("export_dir", .string(dir.path))
        _ = try await lift.settingsSet("export_formats", .string("glb, obj"))
        let v = try await submit(lift, export: nil, title: "Defaults")
        #expect(v.job.export == ExportSpec(dir: dir.path, formats: [.glb, .obj], cleanupAfterExport: false))
        #expect(v.job.exports.map(\.path) == [dir.appending(path: "Defaults.glb").path, dir.appending(path: "Defaults").path])
        let again = try await lift.jobsExport(v.job.id, formats: [.usdz])
        #expect(again.job.exports.map(\.path) == [dir.appending(path: "Defaults.usdz").path])
        _ = try await lift.settingsSet("export_dir", .string(""))
        #expect(await lift.settingsGet().exportDir == nil)
        let none = try await submit(lift, export: nil, title: "No folder")
        #expect(none.job.export == nil && none.job.exports.isEmpty)  // no export folder chosen: nothing exported
    }

    @Test func formatsWithoutAnyFolderAreRejectedAtSubmit() async throws {
        let lift = try await CubeFixture.shared.get()
        let errors = await fieldErrors {
            _ = try await lift.jobsSubmit(SubmitRequest(steps: [try self.cube()], export: ExportSpec(formats: [.glb])))
        }
        #expect(errors == ["export.dir"])
    }
}

@Suite struct ExportResumeTests {
    /// A quit or crash between "succeeded" and the end of its export leaves exportPending; the next open finishes it.
    @Test func anExportCutShortByAQuitRunsAtTheNextOpen() async throws {
        let workdir = try Fixtures.tempDir()
        let exportDir = try Fixtures.tempDir()
        let glb = try Fixtures.cubeGLB(in: try Fixtures.tempDir())
        let store = try Store(path: workdir.appending(path: "lift.sqlite").path)
        let now = Date()
        try await store.db.write { db in
            try JobRecord(id: "j1", title: "Resumed", priority: .normal, position: 1, source: .ui, state: .succeeded, forceStart: false,
                          currentStep: 0, createdAt: now, updatedAt: now, finishedAt: now,
                          export: ExportSpec(dir: exportDir.path, formats: [.glb], cleanupAfterExport: false), exportPending: true).insert(db)
            try StepRecord(jobId: "j1", idx: 0, recipe: "test-cube", task: "image_to_3d", inputs: [:], settings: [:],
                           state: .succeeded, outputs: [glb.path]).insert(db)
        }
        let lift = try await Fixtures.lift(workdir: workdir)
        let v = try await lift.jobsWait("j1", timeout: .seconds(20))
        #expect(!v.job.exportPending && v.job.exports == [ExportResult(format: .glb, path: exportDir.appending(path: "Resumed.glb").path)])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `extra argument 'export' in call` (SubmitRequest), `value of type 'JobRecord' has no member 'exports'`.

- [ ] **Step 3: Store the export on the job, and the export settings**

```diff
--- a/Sources/LiftCore/Store/Records.swift
+++ b/Sources/LiftCore/Store/Records.swift
@@ -85,6 +85,14 @@ public struct JobRecord: Codable, Sendable, Equatable, FetchableRecord, Persista
     public var createdAt: Date
     public var updatedAt: Date
     public var finishedAt: Date?
+    /// Where and how the final output is exported (dir, formats, cleanup all filled at submit); nil: no export.
+    public var export: ExportSpec? = nil
+    /// One result per exported format, from the latest export.
+    public var exports: [ExportResult] = []
+    /// The job succeeded and its export hasn't finished yet. `jobs_wait` waits for it; open resumes it.
+    public var exportPending = false
+    /// The job folder was deleted after a verified export (`cleanup_after_export`). The record stays.
+    public var cleanedUp = false
 }
 
 public struct StepRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
```

```diff
--- a/Sources/LiftCore/Store/Store.swift
+++ b/Sources/LiftCore/Store/Store.swift
@@ -94,6 +94,14 @@ public final class Store: Sendable {
                 t.column("value", .text).notNull()
             }
         }
+        m.registerMigration("export") { db in
+            try db.alter(table: "job") { t in
+                t.add(column: "export", .text)
+                t.add(column: "exports", .text).notNull().defaults(to: "[]")
+                t.add(column: "exportPending", .boolean).notNull().defaults(to: false)
+                t.add(column: "cleanedUp", .boolean).notNull().defaults(to: false)
+            }
+        }
         return m
     }
 }
```

```diff
--- a/Sources/LiftCore/Store/Settings.swift
+++ b/Sources/LiftCore/Store/Settings.swift
@@ -17,15 +17,21 @@ public struct Settings: Codable, Sendable, Equatable {
     public var recipeSources: [RecipeSourceRef] = []
     /// Recipe id → commit set by `models_set_pin`.
     public var pinOverrides: [String: String] = [:]
+    /// The export folder chosen at first launch; jobs export there unless their `export.dir` says otherwise.
+    public var exportDir: String?
+    public var exportFormats: [ExportFormat] = [.glb]
+    public var cleanupAfterExport = false
 
     enum CodingKeys: String, CodingKey, CaseIterable {
         case maxSlots = "max_slots", memoryBudgetGB = "memory_budget_gb", idleUnloadMinutes = "idle_unload_minutes"
         case devRecipes = "dev_recipes", queuePaused = "queue_paused"
         case recipeSources = "recipe_sources", pinOverrides = "pin_overrides"
+        case exportDir = "export_dir", exportFormats = "export_formats", cleanupAfterExport = "cleanup_after_export"
     }
 
     /// Keys `settings_set` accepts. The rest have their own commands (queue_pause, recipes_*, models_set_pin).
-    public static let userKeys: Set<String> = ["max_slots", "memory_budget_gb", "idle_unload_minutes", "dev_recipes"]
+    public static let userKeys: Set<String> = ["max_slots", "memory_budget_gb", "idle_unload_minutes", "dev_recipes",
+                                               "export_dir", "export_formats", "cleanup_after_export"]
 
     public init() {}
 
@@ -39,6 +45,9 @@ public struct Settings: Codable, Sendable, Equatable {
         queuePaused = try c.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? d.queuePaused
         recipeSources = try c.decodeIfPresent([RecipeSourceRef].self, forKey: .recipeSources) ?? d.recipeSources
         pinOverrides = try c.decodeIfPresent([String: String].self, forKey: .pinOverrides) ?? d.pinOverrides
+        exportDir = try c.decodeIfPresent(String.self, forKey: .exportDir)
+        exportFormats = try c.decodeIfPresent([ExportFormat].self, forKey: .exportFormats) ?? d.exportFormats
+        cleanupAfterExport = try c.decodeIfPresent(Bool.self, forKey: .cleanupAfterExport) ?? d.cleanupAfterExport
     }
 
     /// Upper bounds keep every value convertible to bytes / a Duration without trapping:
@@ -101,6 +110,9 @@ public struct Settings: Codable, Sendable, Equatable {
             let json = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
             try SettingRecord(key: key, value: String(decoding: json, as: UTF8.self)).save(db)
         }
+        for key in CodingKeys.allCases.map(\.rawValue) where object[key] == nil {  // a cleared optional (export_dir)
+            _ = try SettingRecord.deleteOne(db, key: key)
+        }
     }
 
     /// Returns a copy with one user key changed; type errors and range errors throw `invalidInput`.
@@ -112,6 +124,11 @@ public struct Settings: Codable, Sendable, Equatable {
         do {
             var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
             object[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
+            // A setting value is a scalar: export_formats is given as "glb,usdz", and "" clears export_dir.
+            if key == "export_formats", case .string(let list) = value {
+                object[key] = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
+            }
+            if key == "export_dir", case .string("") = value { object[key] = nil }
             updated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
         } catch {
             throw .invalidInput([FieldError(key, "wrong type: \(value)")])
```

- [ ] **Step 4: Submit, wait, retry and re-export**

```diff
--- a/Sources/LiftCore/Commands/JobCommands.swift
+++ b/Sources/LiftCore/Commands/JobCommands.swift
@@ -21,12 +21,15 @@ public struct SubmitRequest: Codable, Sendable, Equatable {
     public var title: String?
     public var priority: Priority
     public var source: JobSource
+    /// nil fields (or a nil `export`) take the export settings; `formats: []` means no export.
+    public var export: ExportSpec?
 
-    public init(steps: [StepRequest], title: String? = nil, priority: Priority = .normal, source: JobSource = .ui) {
+    public init(steps: [StepRequest], title: String? = nil, priority: Priority = .normal, source: JobSource = .ui, export: ExportSpec? = nil) {
         self.steps = steps
         self.title = title
         self.priority = priority
         self.source = source
+        self.export = export
     }
 }
 
@@ -94,6 +97,13 @@ extension Lift {
             do { step.inputs = try task.validated(inputs: s.inputs, chained: i > 0, prefix: "\(prefix).inputs", workdir: config.workdir) } catch { if case .invalidInput(let e) = error { errors += e } }
             checked.append((step, task))
         }
+        let wanted = ExportSpec(dir: request.export?.dir ?? settings.exportDir,
+                                formats: request.export?.formats ?? settings.exportFormats,
+                                cleanupAfterExport: request.export?.cleanupAfterExport ?? settings.cleanupAfterExport)
+        if wanted.dir == nil && request.export?.formats?.isEmpty == false {
+            errors.append(FieldError("export.dir", "no export folder: give export.dir or set export_dir"))
+        }
+        let export = wanted.dir == nil || wanted.formats?.isEmpty != false ? nil : wanted  // no folder chosen yet, or formats: []
         if !errors.isEmpty { throw LiftError.invalidInput(errors) }
 
         let id = UUID().uuidString.lowercased()
@@ -109,7 +119,7 @@ extension Lift {
             let position = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM job") ?? 0) + 1
             let job = JobRecord(id: id, title: request.title ?? firstInput ?? request.steps[0].recipe, priority: request.priority,
                                 position: position, source: request.source, state: .queued, forceStart: false, currentStep: 0,
-                                createdAt: now, updatedAt: now)
+                                createdAt: now, updatedAt: now, export: export)
             try job.insert(db)
             for step in steps { try step.insert(db) }
             var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "queued")
@@ -170,7 +180,7 @@ extension Lift {
                 for try await v in ValueObservation.tracking({ try JobView.fetch($0, id) }).values(in: store.db) {
                     guard let v else { throw LiftError.notFound("job \(id)") }
                     onProgress(v)
-                    if v.job.state.isTerminal { return v }
+                    if v.job.state.isTerminal && !v.job.exportPending { return v }
                 }
                 return nil
             }
@@ -220,6 +230,7 @@ extension Lift {
     public func jobsRetry(_ id: String, settings: [String: SettingValue]? = nil) throws -> JobView {
         let v = try view(id)
         guard v.job.state.isTerminal || v.job.state == .interrupted else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue); only finished jobs can be retried") }
+        guard !v.job.cleanedUp else { throw LiftError.invalidState("job \(id)'s files were deleted after export (cleanup_after_export)") }
         let from = v.steps.firstIndex { $0.state != .succeeded } ?? 0
         var newSettings: [String: SettingValue]?
         if let settings {
@@ -379,3 +390,23 @@ public struct QueueStatus: Codable, Sendable, Equatable {
     /// Unfinished jobs in scheduling order.
     public var jobs: [JobView]
 }
+
+// MARK: jobs_export
+
+extension Lift {
+    /// Exports a succeeded job again (spec §9): `formats`/`dir` default to the job's own export, then the settings.
+    /// Returns when every format has finished; failed formats carry their error.
+    public func jobsExport(_ id: String, formats: [ExportFormat]? = nil, dir: String? = nil) async throws -> JobView {
+        let v = try view(id)
+        guard v.job.state == .succeeded else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue); only succeeded jobs can be exported") }
+        guard !v.job.cleanedUp else { throw LiftError.invalidState("job \(id)'s files were deleted after its export") }
+        guard !v.job.exportPending else { throw LiftError.invalidState("job \(id) is exporting") }
+        let spec = ExportSpec(dir: dir ?? v.job.export?.dir ?? settings.exportDir,
+                              formats: formats ?? v.job.export?.formats ?? settings.exportFormats,
+                              cleanupAfterExport: false)  // a re-export never deletes the job's files
+        guard spec.dir != nil else { throw LiftError.invalidInput([FieldError("dir", "no export folder: give dir or set export_dir")]) }
+        guard spec.formats?.isEmpty == false else { throw LiftError.invalidInput([FieldError("formats", "at least one format is required")]) }
+        try await export(id, spec)
+        return try view(id)
+    }
+}
```

- [ ] **Step 5: Run the export after the last step, and resume one cut short**

```diff
--- a/Sources/LiftCore/Engine/Lift.swift
+++ b/Sources/LiftCore/Engine/Lift.swift
@@ -160,6 +160,10 @@ public actor Lift {
     func start() async {
         tools = await toolchain.detect()
         rescan()
+        // Exports cut short by a quit or crash run again (their steps already succeeded).
+        for job in (try? await store.db.read { try JobRecord.filter(Column("exportPending") == true).fetchAll($0) }) ?? [] {
+            if let spec = job.export { Task { try? await self.export(job.id, spec) } }
+        }
         let interval = config.housekeepingInterval
         housekeeping = Task { [weak self] in
             while !Task.isCancelled {
@@ -521,10 +525,13 @@ public actor Lift {
                 job.currentStep = step.idx + 1
                 try self.setState(db, job: job, step: nil, .queued)
             } else {
+                job.exportPending = job.export != nil  // in the same write, so jobs_wait never sees "done" before the export
                 try self.setState(db, job: job, step: step, .succeeded)
             }
         }
-        if try store.db.read({ try JobRecord.fetchOne($0, key: id)?.state.isTerminal }) == true { logs[id] = nil }
+        let after = try store.db.read { try JobRecord.fetchOne($0, key: id) }
+        if after?.state.isTerminal == true { logs[id] = nil }
+        if let after, after.exportPending, let spec = after.export { Task { try? await self.export(id, spec) } }
         tick()
     }
 
```

`Sources/LiftCore/Engine/Export.swift`:

```swift
import Foundation
import GRDB

extension Lift {
    /// Exports a succeeded job's final output (spec §7, §9) and records one result per format. With
    /// `cleanupAfterExport`, the job's own folder (`jobs/<id>/`) is deleted once every format is copied and
    /// verified; a failed format keeps it, so nothing is lost and the job can be exported again.
    func export(_ id: String, _ spec: ExportSpec) async throws {
        let v = try view(id)
        guard let dir = spec.dir, let formats = spec.formats, let outputs = v.steps.last?.outputs else { return }
        try await store.db.write { db in
            try db.execute(sql: "UPDATE job SET exportPending = 1, updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
        let jobDir = jobsDir.appending(path: id)
        // ponytail: FBX needs a Python with bpy and UniRig's venv is the one v1 has; a recipe-declared provider if a second appears.
        let exporter = Exporter(runner: config.runner, blenderPython: installed["unirig"] != nil ? installer.venvPython("unirig") : nil)
        let title = v.job.title
        var credits: [Recipe.Attribution] = []
        for step in v.steps { if let a = recipe(step.recipe)?.attribution, !credits.contains(a) { credits.append(a) } }
        let results = await Task.detached { [credits] in
            await exporter.export(outputs, title: title, formats: formats, credits: credits, to: URL(filePath: dir), work: jobDir.appending(path: "export"))
        }.value
        let clean = spec.cleanupAfterExport == true && results.allSatisfy { $0.error == nil }
        if clean { try? FileManager.default.removeItem(at: jobDir) }
        try await store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else { return }
            job.exports = results
            job.exportPending = false
            job.cleanedUp = job.cleanedUp || clean
            job.updatedAt = Date()
            try job.update(db)
            let detail = results.map { "\($0.format.rawValue): \($0.error ?? $0.path ?? "")" }.joined(separator: "; ")
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: Date(), kind: "export", detail: detail)
            try e.insert(db)
        }
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "CubeIntegrationTests|ExportResumeTests|EngineTests|StoreTests|CommandTests"`
Expected: all pass, including `exportsEveryFormatAndAFailedFormatKeepsTheJobFiles`, `cleanupDeletesOnlyTheJobFolderAfterAVerifiedCopy`, `settingsAreTheDefaultsAndReExportAddsFormats`, `formatsWithoutAnyFolderAreRejectedAtSubmit`, `anExportCutShortByAQuitRunsAtTheNextOpen`. Then `swift test`: every suite passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiftCore/Store/Records.swift \
        Sources/LiftCore/Store/Store.swift \
        Sources/LiftCore/Store/Settings.swift \
        Sources/LiftCore/Commands/JobCommands.swift \
        Sources/LiftCore/Engine/Lift.swift \
        Sources/LiftCore/Engine/Export.swift \
        Tests/LiftCoreTests/ExportFlowTests.swift
git commit -m "feat(core): export after the last step; jobs_export; cleanup after a verified copy; resume at open" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Sources/LiftCore/Store/Records.swift \
        Sources/LiftCore/Store/Store.swift \
        Sources/LiftCore/Store/Settings.swift \
        Sources/LiftCore/Commands/JobCommands.swift \
        Sources/LiftCore/Engine/Lift.swift \
        Sources/LiftCore/Engine/Export.swift \
        Tests/LiftCoreTests/ExportFlowTests.swift
```

---
### Task 9: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `.github/workflows/test.yml` (`workflow_call`, so the release runs the same test job)

**Interfaces:**
- Consumes: Plan 1's `test` job (and whatever Plans 2/3 added to it); Plan 3's app project. `PROJECT` and `SCHEME` at the top of `release.yml` name it (`Lift.xcodeproj`, `Lift`) — change those two lines if Plan 3 chose other names.
- Produces: Actions → **release** → *Run workflow* with `version: X.Y.Z` → tag `vX.Y.Z`, GitHub Release "Lift X.Y.Z" with `Lift-X.Y.Z.zip` and `Lift-X.Y.Z.zip.sha256`, notes = commits since the previous `v*.*.*` tag. Fails before building if the version isn't `X.Y.Z` or the tag exists; the tag is pushed only after the zip is built.

- [ ] **Step 1: Make the test workflow callable**

```diff
--- a/.github/workflows/test.yml
+++ b/.github/workflows/test.yml
@@ -3,6 +3,7 @@ name: test
 on:
   push:
   pull_request:
+  workflow_call:   # release.yml runs this same job first
 
 jobs:
   test:
```

- [ ] **Step 2: Write the release workflow**

```yaml
name: release

# Manual: Actions → release → Run workflow, with the version (X.Y.Z). Tags vX.Y.Z and publishes a GitHub
# Release with Lift-X.Y.Z.zip (ad-hoc signed Lift.app) and its SHA-256. Fails if the tag already exists.
# Developer ID signing and notarization slot into "Archive" later; until then no secrets are needed.
on:
  workflow_dispatch:
    inputs:
      version:
        description: Version to release, X.Y.Z (tagged vX.Y.Z)
        required: true
        type: string

permissions:
  contents: read

concurrency:
  group: release
  cancel-in-progress: false

env:
  VERSION: ${{ inputs.version }}
  PROJECT: Lift.xcodeproj   # Plan 3's app project and scheme
  SCHEME: Lift

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Version is X.Y.Z and its tag is unused
        run: |
          if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "::error::version must be X.Y.Z, got '$VERSION'"
            exit 1
          fi
          if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null; then
            echo "::error::tag v$VERSION already exists"
            exit 1
          fi

  test:
    needs: check
    uses: ./.github/workflows/test.yml

  release:
    needs: test
    runs-on: ${{ vars.MACOS_RUNNER || 'macos-26' }}
    timeout-minutes: 45
    permissions:
      contents: write   # push the tag, create the release
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # every tag and commit, for the notes

      - name: Archive Lift.app (Release, ad-hoc signed)
        run: |
          xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            -destination 'generic/platform=macOS' -archivePath build/Lift.xcarchive \
            MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
            CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
          # Ad-hoc signing has no export method, so the app is taken from the archive as built.
          ditto build/Lift.xcarchive/Products/Applications/Lift.app build/Lift.app
          codesign --force --deep --sign - build/Lift.app
          codesign --verify --deep --strict --verbose=2 build/Lift.app

      - name: Zip and SHA-256
        working-directory: build
        run: |
          ditto -c -k --sequesterRsrc --keepParent Lift.app "Lift-$VERSION.zip"
          shasum -a 256 "Lift-$VERSION.zip" > "Lift-$VERSION.zip.sha256"
          cat "Lift-$VERSION.zip.sha256"

      - name: Notes from the commits since the previous tag
        run: |
          prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2> /dev/null || true)
          {
            echo "## Changes${prev:+ since $prev}"
            echo
            git log --no-merges --pretty='- %s (%h)' "${prev:+$prev..}HEAD"
          } > build/notes.md
          cat build/notes.md

      - name: Tag v${{ inputs.version }}
        run: |
          git tag "v$VERSION" "$GITHUB_SHA"
          git push origin "refs/tags/v$VERSION"   # refused if the tag appeared since the check

      - uses: softprops/action-gh-release@v2
        with:
          tag_name: v${{ inputs.version }}
          name: Lift ${{ inputs.version }}
          body_path: build/notes.md
          files: |
            build/Lift-${{ inputs.version }}.zip
            build/Lift-${{ inputs.version }}.zip.sha256
          fail_on_unmatched_files: true
```

- [ ] **Step 3: Lint**

Run: `actionlint .github/workflows/release.yml .github/workflows/test.yml` (if missing, ask the user to `brew install actionlint`; don't install it yourself)
Expected: no output, exit 0.

- [ ] **Step 4: Check the shell logic locally, in a temp folder**

```bash
d=$(mktemp -d) && cd "$d" && git init -q --bare origin.git && git clone -q origin.git work && cd work
git commit -q --allow-empty -m first && git tag v0.1.0 && git commit -q --allow-empty -m "feat: second"
git push -q origin HEAD:main refs/tags/v0.1.0
VERSION=0.1.0; git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null && echo "v$VERSION exists → the check fails the run"
VERSION=0.2.0; git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null || echo "v$VERSION free"
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*'); git log --no-merges --pretty='- %s (%h)' "${prev:+$prev..}HEAD"
for V in 1.2.3 1.2 v1.2.3 "1.2.3; rm"; do [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "accept $V" || echo "reject $V"; done
```

Expected: `v0.1.0 exists …`, `v0.2.0 free`, one note line `- feat: second (…)`, `accept 1.2.3` and three rejects. (The temp folder is yours to remove afterwards.)

The workflow's first real run is the user's call (spec §15: `v0.1.0` only when they say so).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml \
        .github/workflows/test.yml
git commit -m "ci: release workflow — tests, ad-hoc signed Lift.app, zip + SHA-256, tag and GitHub Release" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        .github/workflows/release.yml \
        .github/workflows/test.yml
```

---
### Task 10: Product acceptance checklist

The go/no-go test verified environments without weights; everything that needs weights or a long GPU run is checked through Lift once the user runs it.

**Files:**
- Create: `docs/superpowers/acceptance/v1.md`

- [ ] **Step 1: Write the checklist**

```markdown
# Lift v1 — product acceptance checklist

The go/no-go test (docs/superpowers/findings/2026-10-go-no-go.md) verified that every v1 environment builds
and imports without weights. What it couldn't measure is checked here, **through Lift itself**, once you run
it. Nothing on this list happens on its own: every download and every long GPU run starts only when you click
or call it, and the sizes are shown first.

Fill in each `…` and tick the box. When a run changes a recipe value (memory or platform status), edit that
recipe in `dev-recipes/` in the same commit as the filled-in checklist, so the numbers and the recipes agree.

## 0. Before you start

- [ ] Lift.app (`v0.1.0` or a local build) launched, first-launch wizard done: working directory `…`, export folder `…`.
- [ ] Toolchain: native Homebrew at `/opt/homebrew` (`brew config` shows `HOMEBREW_PREFIX: /opt/homebrew`), git, uv, Metal Toolchain (`xcrun metal --version`).
- [ ] Hugging Face token saved (Settings → Hugging Face), with access granted on huggingface.co to the gated repos:
      `briaai/RMBG-2.0` (Pixal3D, TRELLIS.2) and `facebook/dinov3-vitl16-pretrain-lvd1689m` (TRELLIS.2).
- [ ] Settings → Resources: `max_slots` 1, `memory_budget_gb` 48 for the single-job runs below.
- [ ] Nothing else heavy running (the memory numbers are this machine's).

Machine: `…` (chip, memory, macOS). Lift commit: `…`. Date: `…`.

## 1. Installs

For each model: Models → Install (or `models_install`, confirm). Record the time and the size it reports.

| Model | Install OK | Wall time | `models/<id>/` size | Notes |
|---|---|---|---|---|
| pixal3d | [ ] | … | … | smoke check imports `inference` under lift_shim |
| unirig | [ ] | … | … | installs `libusb` with native brew first |
| trellis2-mac | [ ] | … | … | smoke check fails if o_voxel isn't on its Metal backend |

- [ ] trellis2-mac's log shows `HuggingFace auth: OK` and no `falling back to KDTree` line.
- [ ] A second install of one model (Reinstall) succeeds too (deps/ and repo/ are rebuilt from scratch).

## 2. Weights: download and verify

Download each model's weights explicitly (Models → Download weights, or `models_download_weights`, confirm),
then verify (`models_verify_weights`). Record the size Lift showed before the download.

| Model | Repos | Shown size | Download OK | Verify OK | Notes |
|---|---|---|---|---|---|
| pixal3d | TencentARC/Pixal3D, Ruicheng/moge-2-vitl, camenduru/dinov3-vitl16-pretrain-lvd1689m, briaai/RMBG-2.0 | … | [ ] | [ ] | NAF comes from torch.hub (github.com/valeoai/NAF) at the first run, not from Hugging Face |
| unirig | VAST-AI/UniRig (2 checkpoints), facebook/opt-350m (config.json only) | … | [ ] | [ ] | |
| trellis2-mac | microsoft/TRELLIS.2-4B, microsoft/TRELLIS-image-large, facebook/dinov3-vitl16-pretrain-lvd1689m, briaai/RMBG-2.0 | … | [ ] | [ ] | |

- [ ] Corrupt one cached file on purpose (append a byte to a small LFS file), verify again: the model shows
      `weights_corrupt` naming that file and its jobs wait with `weights_unverified`. Re-download, verify: clean.
- [ ] Offline (Wi-Fi off), verify again: Lift falls back to the last good check and says so.

## 3. One real run per task

Run each with default settings unless noted, one at a time. Wall time = submit → succeeded (from the job's
events). Peak memory = the learned estimate Lift recorded (Settings → Resources → learned estimates, or
`resources_get`), which is the larger of `phys_footprint` and `torch.mps.driver_allocated_memory()`.

| Recipe / task | Input | Settings | Succeeded | Wall time | Load (GB) | Job (GB) | Output looks right |
|---|---|---|---|---|---|---|---|
| pixal3d image_to_3d | a photo of an object on a plain background | defaults (1536) | [ ] | … | … | … | [ ] |
| pixal3d image_to_3d | same | `low_vram: true` (1024) | [ ] | … | … | … | [ ] |
| pixal3d image_set_to_3d | upstream `assets/mv_images/example` folder | `views: transforms` | [ ] | … | … | … | [ ] |
| pixal3d image_set_to_3d | the same 4 images renamed front/right/back/left | `views: four_view` | [ ] | … | … | … | [ ] matches the previous row |
| pixal3d image_set_to_3d | the same 4 images, any names in front, right, back, left order | `views: orbit` | [ ] | … | … | … | [ ] matches the previous row |
| unirig rig | the Pixal3D result above | defaults (skeleton+skin, glb) | [ ] | … | … | … | [ ] bones follow the shape |
| unirig rig | same | `stages: skeleton`, `format: fbx` | [ ] | … | … | … | [ ] |
| trellis2-mac image_to_3d | the photo above | defaults (512) | [ ] | … | … | … | [ ] textured |
| trellis2-mac image_to_3d | same | `pipeline_type: 1024_cascade` | [ ] | … | … | … | [ ] |
| chained: pixal3d → unirig | the photo | defaults | [ ] | … | — | — | [ ] |

- [ ] The UniRig merge step ran with native `libusb` (no `x86_64` / `incompatible architecture` in the job log).
- [ ] trellis2-mac: if a run fails with the GPU watchdog text, note the conditions (external display? lid open?) here: `…`.
- [ ] Pixal3D: `[Pipeline]`, `[Inference] …` and sampler progress show as stages while it runs.
- [ ] Update each recipe's `resources.memory_gb` (and the low_vram override) to the measured load + job, rounded up.

## 4. Two loaded copies at once

Each worker process runs one job at a time (spec §8); parallel jobs mean more loaded copies of the model.
For pixal3d and trellis2-mac: Settings → Resources → `max_slots` 2 and a budget that fits two loaded copies,
then submit the same input twice.

| Recipe | Two workers started | Both succeed | Wall time for both vs 2× one | Peak system memory | Notes |
|---|---|---|---|---|---|
| pixal3d | [ ] | [ ] | … | … | |
| trellis2-mac | [ ] | [ ] | … | … | |

Nothing in the recipe changes from this; it tells you whether `max_slots` 2 is worth it on this Mac.

## 5. Cancel, crash and unload with a real model

- [ ] Cancel a running UniRig job during the skeleton stage: within seconds `ps -ax | grep -E 'run.py|src.inference'`
      shows no UniRig process left (the worker's whole process group is killed).
- [ ] Cancel a running Pixal3D job: the worker exits and the next queued job starts.
- [ ] Quit Lift during a run: on relaunch the job is `interrupted` and no Python process from it is left running.
- [ ] Idle unload: after `idle_unload_minutes` with no jobs, the loaded worker exits and its memory is freed.

## 6. Exports

For one Pixal3D result and one UniRig result, export all four formats (Generate → export options, or
`jobs_export`), then open each:

| Source | GLB (Quick Look) | USDZ (Quick Look, textured) | OBJ folder (Blender or Preview, textured) | FBX (Blender: mesh, textures; rig for UniRig) |
|---|---|---|---|---|
| pixal3d | [ ] | [ ] | [ ] | [ ] |
| unirig | [ ] | [ ] | [ ] | [ ] armature and weights |

- [ ] `cleanup_after_export` on: after a successful export the job's folder is gone, the job stays in History
      marked cleaned up, and the exported files are complete.
- [ ] Exporting twice into the same folder adds `… 2.glb` and never replaces the first file.

## 7. Results

- [ ] Every recipe whose runs above failed for platform reasons is set to `platform: { status: unsupported, reason: "…" }`.
- [ ] The measured numbers above are copied into `docs/superpowers/findings/2026-10-go-no-go.md` (wall time, peak memory, two copies).
- [ ] Recipes updated: `memory_gb`, `memory_overrides`, `platform.status`.
```

- [ ] **Step 2: Check it against the recipes**

Every recipe id, task, setting and weights repo the checklist names must exist in `dev-recipes/*/recipe.yaml` (after Tasks 3–5): `grep -o 'views: [a-z_]*\|stages: [a-z+]*\|pipeline_type: [0-9_a-z]*' docs/superpowers/acceptance/v1.md` and compare with the recipes' `options`.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/acceptance/v1.md
git commit -m "docs: v1 product acceptance checklist (real runs, weights, memory, exports)" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        docs/superpowers/acceptance/v1.md
```

---
### Task 11: Export over HTTP and MCP (after Plan 2 merges)

Plan 2's server is generated from `Sources/LiftServer/openapi.yaml`; its MCP tool list is built from the same document, and each tool has a handler in `Tools.swift`. This task adds `export` to `jobs_submit` and the new `jobs_export` command to both, in Plan 2's snake_case wire style. **The names below are from Plan 2's draft** (`SubmitWire` and `Inputs.resolve` in `Inputs.swift`, `JobOut`/`Wire.convert` in `Wire.swift`, handlers in `API.swift` and `Tools.swift`); if Plan 2 renamed them, follow its pattern for `jobs_retry`, which has the same shape (path id + optional JSON body → `JobView`).

**Files:**
- Modify: `Sources/LiftServer/openapi.yaml`, `Sources/LiftServer/Inputs.swift`, `Sources/LiftServer/API.swift`, `Sources/LiftServer/Tools.swift`
- Test: `Tests/LiftServerTests/HTTPTests.swift`, `Tests/LiftServerTests/MCPTests.swift`, `Tests/LiftServerTests/ServerUnitTests.swift` (`specTools`)

**Interfaces:**
- Consumes: Task 8's `SubmitRequest.export`, `JobRecord.export/exports/exportPending/cleanedUp`, `Lift.jobsExport(_:formats:dir:)`.
- Produces: `POST /v1/jobs` and MCP `jobs_submit` accept `export: {dir?, formats?, cleanup_after_export?}`; `POST /v1/jobs/{id}/export` and MCP `jobs_export` (`{id, formats?, dir?}`) return the `JobView` with `job.exports`.

- [ ] **Step 1: Write the failing tests**

In `Tests/LiftServerTests/HTTPTests.swift`, next to `submitWaitAndDownloadTheOutput` (same fixture and helpers):

```swift
    @Test func exportOnSubmitAndAgainLater() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let dir = try Fixtures.tempDir()
        let submit = try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": try Fixtures.image()])], "title": "exported",
                                                                     "export": ["dir": dir.path, "formats": ["glb"]]])
        let id = try #require((submit.json["job"] as? [String: Any])?["id"] as? String)
        let done = try await wait(http, id)
        let exports = try #require((done["job"] as? [String: Any])?["exports"] as? [[String: Any]])
        #expect(exports.first?["path"] as? String == dir.appending(path: "exported.glb").path)
        let again = try await http.call("POST", "/v1/jobs/\(id)/export", json: ["formats": ["obj"]])
        #expect(again.status == 200)
        #expect(((again.json["job"] as? [String: Any])?["exports"] as? [[String: Any]])?.first?["format"] as? String == "obj")
    }
```

In `Tests/LiftServerTests/ServerUnitTests.swift`, `ToolCatalogTests.specTools` says "Spec §10's table, minus jobs_export (Plan 4: exports)": add `"jobs_export"` to the set and drop "minus jobs_export" from its comment. `MCPTests.toolsAreTheSpecTable` then fails until the tool exists.

In `Tests/LiftServerTests/MCPTests.swift` (uses that file's `connect`, `json` and `submit` helpers):

```swift
    @Test func jobsExportReExportsASucceededJob() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        let id = try await submit(client)
        _ = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120])
        let dir = try Fixtures.tempDir()
        let (content, isError) = try await client.callTool(name: "jobs_export", arguments: ["id": .string(id), "formats": ["glb"], "dir": .string(dir.path)])
        #expect(isError != true)
        let exports = try #require((try json(content)["job"] as? [String: Any])?["exports"] as? [[String: Any]])
        #expect((exports.first?["path"] as? String)?.hasPrefix(dir.path) == true)
    }

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "exportOnSubmitAndAgainLater|jobsExportReExportsASucceededJob|toolsAreTheSpecTable"`
Expected: FAIL — the submit ignores `export` (no `exports`), `/v1/jobs/{id}/export` is 404, there is no `jobs_export` tool.

- [ ] **Step 3: Describe it in the OpenAPI document**

Under `paths:`, after `/v1/jobs/{id}/retry`:

```yaml
  /v1/jobs/{id}/export:
    parameters: [{ $ref: '#/components/parameters/JobId' }]
    post:
      operationId: jobs_export
      summary: Export a succeeded job again. Formats and folder default to the job's own export, then the export settings. Never deletes the job's files.
      requestBody:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/ExportJob' }
      responses:
        '200':
          description: The job, with one export result per format.
          content:
            application/json:
              schema: { $ref: '#/components/schemas/JobView' }
        default: { $ref: '#/components/responses/Problem' }
```

Under `components.schemas`: add to `SubmitJob.properties`:

```yaml
        export: { $ref: '#/components/schemas/ExportSpec' }
```

add to `Job.properties`:

```yaml
        export: { $ref: '#/components/schemas/ExportSpec' }
        exports: { type: array, items: { $ref: '#/components/schemas/ExportResult' }, description: One result per format from the latest export. }
        export_pending: { type: boolean, description: Succeeded; its export hasn't finished yet. }
        cleaned_up: { type: boolean, description: The job's files were deleted after a verified export. }
```

and the new schemas:

```yaml
    ExportFormat: { type: string, enum: [glb, usdz, obj, fbx] }
    ExportSpec:
      type: object
      description: Missing fields take the export_dir, export_formats and cleanup_after_export settings. formats [] means no export.
      properties:
        dir: { type: string, description: A folder on this Mac. }
        formats: { type: array, items: { $ref: '#/components/schemas/ExportFormat' } }
        cleanup_after_export: { type: boolean, description: Delete the job's own files once every format is copied and verified. }
    ExportResult:
      type: object
      required: [format]
      properties:
        format: { $ref: '#/components/schemas/ExportFormat' }
        path: { type: string, description: The exported file (a folder for OBJ). }
        error: { type: string }
        credits: { type: string, description: The <title>.credits.txt next to it (USDZ, OBJ, FBX). }
    ExportJob:
      type: object
      properties:
        formats: { type: array, items: { $ref: '#/components/schemas/ExportFormat' } }
        dir: { type: string }
```

- [ ] **Step 4: Pass `export` through, and add the handlers**

`Sources/LiftServer/Inputs.swift`:

```diff
     var steps: [Step]
     var title: String?
     var priority: Priority?
+    var export: ExportSpec?
 }
```

```diff
-        return SubmitRequest(steps: steps, title: wire.title, priority: wire.priority ?? .normal, source: source)
+        return SubmitRequest(steps: steps, title: wire.title, priority: wire.priority ?? .normal, source: source, export: wire.export)
```

(`ExportSpec`'s `cleanupAfterExport` arrives as `cleanup_after_export` through the server's snake_case decoder; if `SubmitWire` is decoded without one, give `ExportSpec` a `CodingKeys` with `cleanupAfterExport = "cleanup_after_export"` instead.)

`Sources/LiftServer/API.swift`, after `jobsRetry`:

```swift
    func jobsExport(_ input: Operations.JobsExport.Input) async throws -> Operations.JobsExport.Output {
        var formats: [ExportFormat]?
        var dir: String?
        if case .json(let body) = input.body {
            formats = try body.formats.map { try Wire.convert($0) }
            dir = body.dir
        }
        return .ok(.init(body: .json(try Wire.convert(JobOut(try await lift.jobsExport(input.path.id, formats: formats, dir: dir))))))
    }
```

`Sources/LiftServer/Tools.swift`, in `handlers` after `"jobs_retry"`:

```swift
        "jobs_export": { a, c in .job(try await c.lift.jobsExport(a.required("id"), formats: a.decode("formats"), dir: a.decode("dir"))) },
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter LiftServerTests`
Expected: all pass, including Plan 2's schema-conformance and tool-parity tests with the new operation.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiftServer/openapi.yaml \
        Sources/LiftServer/Inputs.swift \
        Sources/LiftServer/API.swift \
        Sources/LiftServer/Tools.swift \
        Tests/LiftServerTests/HTTPTests.swift \
        Tests/LiftServerTests/MCPTests.swift \
        Tests/LiftServerTests/ServerUnitTests.swift
git commit -m "feat(server): export on jobs_submit and the jobs_export route and tool" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        Sources/LiftServer/openapi.yaml \
        Sources/LiftServer/Inputs.swift \
        Sources/LiftServer/API.swift \
        Sources/LiftServer/Tools.swift \
        Tests/LiftServerTests/HTTPTests.swift \
        Tests/LiftServerTests/MCPTests.swift \
        Tests/LiftServerTests/ServerUnitTests.swift
```

---
### Task 12: Fold this plan's decisions into the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-10-11-lift-design.md`

- [ ] **Step 1: Edit the spec**

Make each change in plain language (the spec's style), one paragraph or table row each:

1. §4 "Plan 1 schema additions": add `metal_toolchain: bool` and `weights[].files: [path]` (exact repo paths; download and verify only those).
2. §4 v1 recipes table: UniRig's entry adds "settings `stages` (skeleton | skeleton+skin), `format` (glb | fbx); temp-folder paths because upstream `eval`s its command lines; each stage judged by its output file". trellis2-mac's install list becomes: clone trellis-mac; pre-place TRELLIS.2 **and setup.sh's five Metal dependencies** at the go/no-go commits; init o-voxel's Eigen submodule; point `.venv` at Lift's venv; `UV_CONSTRAINT torch==2.13.0`, `UV_NO_CACHE=1`; run `setup.sh`. Replace "importing `generate.py`'s functions" with "mirroring `generate.py`'s `main()` (it has no importable functions); re-check on a pin bump".
3. §4 multi-view paragraph: the three layouts are the `views` setting (`transforms`, `four_view`, `orbit`); four_view reads files named front/right/back/left; orbit also takes `orbit_distance` (default from the upstream example).
4. §5 substitute table: `cumesh` → "pedronaugusto `mtlmesh` (Metal; needs `mtlbvh`)"; add "Metal substitutes need torch ≥2.11 and <2.14 and build with `MACOSX_DEPLOYMENT_TARGET=12.0` and `--no-build-isolation`; `torch_scatter`/`torch_cluster` are CPU builds with lift_shim's MPS patches".
5. §6 `brew:` sentence: "installed with native brew before anything else" — drop "its `lib/` is added to the worker's `DYLD_FALLBACK_LIBRARY_PATH`" or mark it as belt-and-braces (open3d links the Homebrew path directly, and SIP strips `DYLD_*` through `/bin/bash`).
6. §7 Export bullet: defaults come from `export_dir`/`export_formats`/`cleanup_after_export`; no export folder → no export; the job stays `succeeded` with `export_pending` until done (`jobs_wait` waits; an interrupted export resumes at launch); cleanup only when every format copied and verified; retry and re-export refuse a cleaned-up job; names never overwrite (`<title> 2.<ext>`).
7. §9 table: USDZ → "SceneKit (`SCNScene` from the GLB via GLTFKit2, `write(to:)`) — ModelIO can't write USDZ"; OBJ → "ModelIO (`MDLAsset` via GLTFKit2), as a folder with `.mtl` and textures"; FBX → "Blender `bpy` from the UniRig venv for every mesh, rigged ones included; an output already in the format is copied"; add the credits row (GLB `asset` fields; `<title>.credits.txt` for the rest).
8. §14 release: "the tag is pushed after the build; notes from `git log` since the previous tag; the ad-hoc app comes from the archive; `test.yml` is called with `workflow_call`".

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-11-lift-design.md
git commit -m "docs(spec): fold Plan 4 decisions — metal_toolchain, weight subsets, view layouts, exporter paths, release" \
           -m "Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw" -- \
        docs/superpowers/specs/2026-10-11-lift-design.md
```
