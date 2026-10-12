---
name: lift
description: Make 3D models on this Mac with the Lift app's MCP tools. Use when the user asks to turn a photo or several photos into a 3D model ("make a 3D model from this photo", "turn this picture into a GLB"), to rig or add a skeleton to a mesh ("rig this mesh", "make this character animatable"), to export or convert a result ("export as USDZ / FBX / OBJ / GLB"), or to install, check or choose a 3D model in Lift.
---

# Lift: 3D models from photos, on this Mac

Lift is a Mac app that runs open-source 3D models locally (photo → 3D, several photos → 3D, rigging).
You reach it through its MCP tools (server name `lift`). Lift does exactly what you ask and makes no
choices of its own: you choose the model and settings with the user, never on your own guesses.

## Golden rules

1. **Ask before anything big or risky.** A tool that answers `confirmation_required` returns an
   `impact`. Show that impact to the user in plain words and call again with `confirm: true` only
   after they say yes. Never send `confirm: true` on the first try.
2. **Never invent settings.** Use only keys from the task's settings schema (`models_get`), with
   values of the right type and within its options. Leave out what the user didn't ask for: the
   defaults apply.
3. **Credit the authors.** Every model is someone else's open-source project. Lift keeps answers
   short and doesn't repeat credits in them: an export that lists a `credits` file has the authors,
   license and any restrictions (e.g. non-commercial) next to the exported model, and the app shows
   them all under About Lift → Credits. Point the user there when you show a result. Never present
   the output as your work or Lift's.
4. **When it's ambiguous, ask.** Several models fit, a setting is unclear, or the input could be
   read two ways: ask the user one short question instead of picking.

## 1. Find the model

- `models_list`: every model with its `status` (`installed`, `not_installed`, `installing`,
  `update_available`, `weights_missing`, `unsupported`, …) and its recipe's tasks.
- `models_get` with the model's `id`: its tasks (`image_to_3d`, `image_set_to_3d`, `rig`, …), each
  task's inputs and settings schema, memory needs and status.
- Match the request to a task: one photo → `image_to_3d`; several photos of one object →
  `image_set_to_3d`; an existing mesh to animate → `rig`. If more than one installed model has the
  task, tell the user the options (name, what it's good at, memory) and let them choose.
- `models_readme` gives the model's own README when the user wants details.

## 2. Install only with the user's OK

- If the model isn't installed, say so and ask first: installing downloads its code and weights
  (often several GB) and takes a while. Then call `models_install` (confirm-gated: show the impact,
  then `confirm: true`). It runs in the background; check `models_get` until it's `installed`.
- `weights_missing` or `weights_corrupt`: ask, then `models_download_weights` (also confirm-gated).
- To stop an install the user no longer wants: `models_cancel_install`. If it failed,
  `models_install_log` shows why; summarize it in plain words.

## 3. Submit the job

Call `jobs_submit` with one step per model run:

```json
{
  "steps": [{
    "recipe": "<model id>",
    "task": "image_to_3d",
    "inputs": { "image_path": "/absolute/path/to/photo.jpg" },
    "settings": { }
  }]
}
```

- Inputs are absolute paths on this Mac: `<input name>_path` (the names come from the task's
  `inputs`). For a file you only have as data, use `<name>_base64` plus `<name>_filename`.
- Chain steps (e.g. photo → 3D, then rig) by listing them in order: a later step may leave its first
  input out and receives the previous step's output.
- Want other formats right away? Add `"export": { "formats": ["usdz", "fbx"] }`.
- Bad input answers with one error per field: fix those fields and resend.

**Memory warning.** If the answer is a `memory_warning` instead of a job, nothing was queued. Tell the
user its `message` (e.g. "This model usually needs about 18 GB; this Mac has 16 GB") and ask whether to
run it anyway. Only if they agree, send the same request again with `accept_memory_warning: true`.
A smaller setting from the schema (e.g. a low-memory option) may be a better offer.

## 4. Follow it and get the result

- `jobs_wait` with the job `id` waits up to `timeout_seconds` (default 30) and returns the job as it
  is then. Call it again while the state is `queued`, `waiting`, `loading` or `running`; tell the
  user briefly what it's doing (`waiting` means it waits for memory or a free slot).
- `succeeded`: `outputs` lists each file's absolute `path` (give the user that path) and a
  `lift://jobs/{id}/outputs/{file}` resource you can read.
- `failed`: say what failed in plain words from the job's error; offer `jobs_retry` (optionally with
  new settings from the schema) only if the user wants.
- Other formats later: `jobs_export` with `formats` from `glb`, `usdz`, `obj`, `fbx` (and an optional
  `dir`). It never deletes the job's files.
- Cancel with `jobs_cancel` (a running job is confirm-gated). `jobs_list` and `jobs_get` show
  earlier work; `queue_status` shows what's queued.

## When something goes wrong

- **Lift isn't reachable** (the tools fail with "Lift is not reachable" or don't answer): ask the user
  to open the Lift app, then try again. Lift's MCP server only runs while the app is open.
- **A gated model** (its weights need Hugging Face access): ask the user to open Lift → Settings →
  Hugging Face and follow the walkthrough (a free account, accept the model's terms, add a Read key),
  then try the install or download again.
- **`prerequisite` or `invalid_state` errors**: read the message to the user; Lift says what's missing
  and how to fix it. Don't work around it.
- **Not sure which port or address**: `server_status` shows them.
