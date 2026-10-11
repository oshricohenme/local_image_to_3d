# Plan 4 — Real recipes, Exporter, Release (record)

Built directly on `oshricohenme/7jtm2` (user decision: build, don't polish the plan). The long prototype-verified
plan is in git history (`5cd5c97`). This file records what landed, what's waiting, and the decisions to fold into the spec.

## Landed

| Commit | What |
|---|---|
| `05ba965` | `Attribution` (spec §4a: project, authors, homepage, repo, paper, license, components with role and restrictions; `credit`, fixed `disclaimer`, `problems`) and `ReadmeLoader` (own clone → raw.githubusercontent at the pin → cache `models/<id>/readme/README.md`; injectable `ReadmeHTTP`). New files only. |
| `d73021d` | GLTFKit2 0.5.15 and `Exporter`: GLB stamped with credits in `asset.copyright`/`generator`, USDZ through SceneKit, OBJ through ModelIO as a `<title>/` folder, FBX through bpy (`os._exit(0)`: bpy 4.2 segfaults at exit), never overwrites, SHA-256-verified copies, `<title>.credits.txt` for non-GLB formats, each format fails alone. |
| `52bd1b0` | Test Cube attribution. |
| `76f0668` | Pinned Metal substitute registry (torch-range check, `MACOSX_DEPLOYMENT_TARGET=12.0`, `--no-build-isolation`, converging clones) and the Pixal3D recipe: photo and multi-view (`views`: four_view / orbit / transforms, writer in `files/pixal_views.py`), plain-language labels and help, 3–4 basic settings, `errors:` messages, full attribution. `python/recipe_tests` scaffold and the CI step. |
| `fc25087` | UniRig: upstream's three scripts as subprocesses from a temp folder (they `eval` their command lines), each stage judged by its output, plain copy, attribution with the TOG paper. |
| `bcb4309` | TRELLIS.2 via trellis-mac: nested clones (TRELLIS.2, five Metal deps) converge — clone, or fetch + `checkout -f` + `clean -fdx` inside that Lift-owned clone — then setup.sh re-applies its patches; `.venv` → Lift's venv; torch 2.13 constraint; the import asserts the Metal baker; bake block in `files/trellis_bake.py`. |
| `5ea77be` | Opt-in settings-vs-upstream check (`LIFT_MODELS_DIR`). |
| `c45c847` | `release.yml` (workflow_dispatch `version`; same tests via `workflow_call`; archive, ad-hoc sign, ditto zip + SHA-256, tag pushed after the build, notes from `git log` since the last tag, softprops/action-gh-release). actionlint clean. |
| `d4aead2` | `docs/superpowers/acceptance/v1.md`. |

Each commit ran the full `swift test` (197 tests at `d73021d`) and the recipe pytest (27 passed, 4 opt-in skipped;
32 passed against the go/no-go clones). Earlier, in the prototype: real installs of pixal3d and trellis2-mac
through Lift's Installer without weights passed (238 s / 226 s).

## Waiting (edits to existing LiftCore files, after plan1-writer's fix pass)

1. `Recipe`: `attribution: Attribution` (required; validation adds `Attribution.problems`), `metal_toolchain`,
   `weights[].files`, `description`, `errors: [{match, message}]`.
2. Installer: Metal Toolchain check before anything; `deps/` emptied; `hf download <repo> <files…>`; the verifier checks only listed files.
3. Export in jobs: `SubmitRequest.export`, `JobRecord.export/exports/exportPending/cleanedUp` (migration), settings
   `export_dir`/`export_formats`/`cleanup_after_export`, run after the last step, `jobs_wait` waits, resume at open,
   cleanup only after every format verified, `jobsExport`. Credits from each step's recipe.
4. Job view `attribution: Attribution?`; `Lift.modelsReadme(_:) -> Readme?` (with `LiftConfig.readmeHTTP`).
5. A failed step shows the recipe's plain `errors` message; the raw error stays in the log.
6. Swift tests: bundled-recipe dry-run installs/pins/credits, opt-in real installs, export flow and resume.
7. Plan 2 wiring: `export` on jobs_submit, `jobs_export` route/tool (+ `specTools`); Plan 3: export UI in its Generate/Setup/Settings/History files.

## Decisions to fold into the spec

- Schema: `metal_toolchain`, `weights[].files` (exact paths), `description`, `errors: [{match, message}]`, attribution components carry `role`.
- `cumesh` is a real Metal build (mtlmesh + mtlbvh), not a stand-in.
- `brew:` needs no `DYLD_FALLBACK_LIBRARY_PATH` for v1 (open3d links Homebrew's libusb by absolute path; SIP strips `DYLD_*` through bash).
- Pixal3D: `lru_cache(maxsize=1)` on `init_pipeline`; multi-view calls `inference_mv.run_inference`; orbit needs `orbit_distance`; `num_views: 0` = all.
- UniRig: no VRM add-on (writes to `~/Library`, `.vrm` only); temp-folder paths and plain-character string settings because upstream `eval`s.
- trellis2-mac: launcher mirrors `generate.py`'s `main()` (no importable functions) — re-check on a pin bump; all setup.sh deps pre-placed at pins.
- Weight subsets: UniRig 5.8 of 11.5 GB, OPT-350m `config.json` only, TRELLIS-image-large 0.15 of 3.3 GB, RMBG-2.0 0.9 of 5.4 GB.
- Exports: USDZ via SceneKit (ModelIO can't write it), OBJ as a folder, FBX via bpy for rigged meshes too, `<title> 2.<ext>` instead of overwriting.

## Facts not verified (TODO)

- OPT-350m's license: the Hugging Face card says only "other" (recipe: `NOASSERTION`).
- MoGe code license: GitHub reports `NOASSERTION`; the recipe links the LICENSE at the pin.
- DINOv3 restrictions are summarised from Meta's license page (no military/weapons use; "Built with DINOv3" when redistributing); a human should confirm.
- SwiftPM resolved GLTFKit2 here from its local cache; a clean CI runner downloads the 36.7 MB xcframework.
- UniRig was never installed for real (needs native Homebrew); `release.yml` assumes Plan 3's `Lift.xcodeproj` / scheme `Lift`.
