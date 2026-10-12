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
        _stage(job, "Predicting the skeleton (UniRig step 1 of 3)", 0.0, "launch/inference/generate_skeleton.sh",
               ["--input", mesh, "--output", skeleton, "--skeleton_task", s["skeleton_task"],
                "--add_root", s["add_root"], "--force_override", s["skeleton_force_override"], *common], skeleton)
        source = skeleton
        if s["stages"] == "skeleton+skin":
            source = os.path.join(work, "skin.fbx")
            _stage(job, "Working out how the mesh bends with each bone (step 2 of 3)", 0.4, "launch/inference/generate_skin.sh",
                   ["--input", skeleton, "--output", source, "--skin_task", s["skin_task"],
                    "--force_override", s["skin_force_override"], "--data_name", s["data_name"], *common], source)
        rigged = os.path.join(work, f"rigged.{s['format']}")
        _stage(job, "Putting the rig on your mesh and saving it (step 3 of 3)", 0.8, "launch/inference/merge.sh",
               ["--source", source, "--target", mesh, "--output", rigged, "--require_suffix", s["require_suffix"]], rigged)
        outputs = []
        for path in (rigged, source if source != skeleton else None, skeleton):  # the rigged mesh first: chains use it
            if path:
                outputs.append(shutil.move(path, os.path.join(job.out_dir, os.path.basename(path))))
        return outputs
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _stage(job, name, fraction, script, args, expected):
    job.stage(name, fraction)
    cmd = ["bash", script] + [_arg(a) for a in args]
    print("$ " + " ".join(cmd), flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    said = None
    for line in proc.stdout:  # universal newlines: tqdm's \r updates arrive as lines
        sys.stdout.write(line)
        said = _message(line) or said
    code = proc.wait()
    why = f": UniRig said \"{said}\"" if said else "; see the job log"
    if code != 0:
        raise RuntimeError(f"UniRig {os.path.basename(script)} exited with code {code}{why}")
    if not os.path.isfile(expected):
        # Upstream catches some failures itself and prints only the message (e.g. its FBX writer), then goes on.
        raise RuntimeError(f"UniRig {os.path.basename(script)} finished without writing {os.path.basename(expected)}{why}")


def _message(line):
    """A line upstream said something with: not a progress bar, a warning (or its source line) or the closing "done"."""
    text = line.strip()
    if not text or text == "done" or text.startswith("$ ") or line.startswith((" ", "\t")):
        return None
    if "%|" in text or "it/s]" in text or "Warning" in text:
        return None
    return text[:300]


def _arg(value):
    return ("true" if value else "false") if isinstance(value, bool) else str(value)
