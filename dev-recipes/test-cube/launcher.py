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
        name = os.path.basename(next(iter(job.inputs.values()), ""))
        raise RuntimeError(f"failed on purpose (fail=true) for {name}")
    if job.task == "fake_rig":
        out = os.path.join(job.out_dir, "rigged.glb")
        shutil.copyfile(job.inputs["mesh"], out)
        return [out]
    out = os.path.join(job.out_dir, "cube.glb")
    trimesh.creation.box(extents=[float(s["size"])] * 3).export(out)
    return [out]
