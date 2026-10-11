"""THROWAWAY: run unmodified Pixal3D inference under lift_shim. Usage: run_pixal3d.py IMAGE OUT.glb [--low_vram] [--resolution N]"""
import argparse
import json
import os
import sys
import time

import lift_shim  # noqa: E402
# The .pth autoload ran at interpreter start (LIFT_SHIM unset → inert), so install explicitly, before torch.
lift_shim.install({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("out")
ap.add_argument("--low_vram", action="store_true"); ap.add_argument("--resolution", type=int, default=-1)
a = ap.parse_args()

repo = os.path.join(os.path.dirname(__file__), "work", "pixal3d")
sys.path.insert(0, repo)
import inference  # noqa: E402  upstream module, unmodified

t = time.perf_counter()
inference.run_inference(image_path=os.path.abspath(a.image), output_path=os.path.abspath(a.out),
                        low_vram=a.low_vram, resolution=a.resolution)
print(json.dumps({"wall_s": round(time.perf_counter() - t, 1)}))
