"""Argument-vector launchers. Dependencies and downloads belong to prepare, never run."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def expand(value, values):
    return re.sub(r"\{([a-z][a-z0-9_]*)\}", lambda m: str(values[m[1]]), value)


def environment(spec, values, offline=False):
    env = dict(os.environ)
    env.update({k: expand(v, values) for k, v in spec.get("env", {}).items()})
    env["PYTHONUNBUFFERED"] = "1"
    env["HF_HUB_DISABLE_XET"] = "1"
    if offline:
        env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1")
    return env


def execute(commands, values, spec, offline=False):
    for command in commands:
        argv = [expand(arg, values) for arg in command]
        print(f"[Stage] Running {Path(argv[0]).name}", flush=True)
        # Feed subprocess diagnostics through the worker's tagged stream for live job progress.
        with subprocess.Popen(argv, cwd=expand(spec.get("cwd", "{repo}"), values),
                              env=environment(spec, values, offline), stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1) as process:
            for line in process.stdout:
                print(line.rstrip("\n"), flush=True)
            code = process.wait()
            if code:
                raise subprocess.CalledProcessError(code, argv)


def context(recipe_dir):
    recipe = Path(recipe_dir).resolve()
    root = recipe.parent
    return {"root": str(root), "repo": str(root / "repo"),
            "recipe": str(recipe), "python": sys.executable}


def load(ctx):
    values = context(ctx.recipe_dir)
    path = Path(ctx.recipe_dir) / "files/media.json"
    spec = json.loads(path.read_text())
    receipt = Path(values["root"]) / "media-prepared.json"
    if not receipt.exists():
        raise RuntimeError("Model preparation is missing. Reinstall this recipe from Models.")
    prepared = json.loads(receipt.read_text())
    if prepared["spec_sha256"] != digest(path):
        raise RuntimeError("Model setup changed. Reinstall this recipe from Models.")
    values.update(prepared["assets"])
    for required in spec.get("required", []):
        if not Path(expand(required, values)).exists():
            raise RuntimeError(f"Installed model file is missing: {required}. Reinstall this recipe.")
    return spec, values


def run(state, job):
    spec, base = state
    task = spec["tasks"][job.task]
    out = Path(job.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Inputs/settings never replace trusted installation or output paths.
    values = dict(job.settings) | dict(job.inputs) | base | {"out": str(out)}
    for name, filename in task.get("text_files", {}).items():
        path = out / filename
        path.write_text(str(values[name]))
        values[name + "_file"] = str(path)
    for folder in task.get("directories", []):
        (out / folder).mkdir(parents=True, exist_ok=True)
    before = {str(p): (p.stat().st_mtime_ns, p.stat().st_size)
              for pattern in task["outputs"] for p in out.glob(pattern) if p.is_file()}
    job.stage("Generating")
    execute(task["commands"], values, spec, offline=True)
    outputs = []
    for pattern in task["outputs"]:
        matched = False
        for path in sorted(out.glob(pattern)):
            if (path.is_file() and path.stat().st_size and path.resolve().is_relative_to(out)
                    and before.get(str(path)) != (path.stat().st_mtime_ns, path.stat().st_size)):
                matched = True
                resolved = str(path.resolve())
                if resolved not in outputs:
                    outputs.append(resolved)
        if not matched:
            raise RuntimeError(f"The upstream runtime did not produce a nonempty output matching {pattern}.")
    if not outputs:
        raise RuntimeError("The upstream runtime finished without producing a nonempty output file.")
    job.stage("Complete", 1.0)
    return outputs
