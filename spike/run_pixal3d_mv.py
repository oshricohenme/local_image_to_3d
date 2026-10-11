"""THROWAWAY: unmodified Pixal3D multi-view via its own CLI entry, under lift_shim."""
import json
import os
import runpy
import sys
import time

import lift_shim

lift_shim.install({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})

repo = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "pixal3d")
sys.path.insert(0, repo)
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "out/pixal3d_mv.glb")
sys.argv = ["inference_mv.py", "--views_dir", os.path.join(repo, "assets/mv_images/example"),
            "--output", out, "--low_vram"]
t = time.perf_counter()
runpy.run_path(os.path.join(repo, "inference_mv.py"), run_name="__main__")
print(json.dumps({"wall_s": round(time.perf_counter() - t, 1)}))
