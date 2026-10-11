"""Test Cube launcher: writes a cube GLB with trimesh. Settings: size, delay, fail, crash, grandchild."""
import os
import shutil
import subprocess
import sys
import time

import trimesh
from cube_helpers import extents  # from this recipe's files/


def load(ctx):
    print("[Stage] Loading")
    time.sleep(float(os.environ.get("TEST_CUBE_LOAD_DELAY", "0")))  # tests set it through shim env
    return {}


def run(state, job):
    s = job.settings
    print(f"shim env: {os.environ.get('TEST_CUBE_SHIM')}")  # set only if lift_shim's autoload ran
    if s.get("grandchild"):  # a process upstream code might start; cancel must take it down too
        print(f"grandchild pid {subprocess.Popen(['/bin/sleep', '30']).pid}")
    print("[Stage] Generating")
    for i in range(1, 5):
        time.sleep(float(s.get("delay", 0)) / 4)  # not interruptible, like upstream code: cancel kills the worker
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
    trimesh.creation.box(extents=extents(s["size"])).export(out)
    return [out]
