"""THROWAWAY: can one loaded Pixal3D serve two jobs at once? Compares sequential vs. 2 threads, same seeds."""
import functools
import hashlib
import json
import os
import sys
import threading
import time

import lift_shim

lift_shim.install({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})

repo = os.path.join(os.path.dirname(os.path.abspath(__file__)), "work", "pixal3d")
sys.path.insert(0, repo)
import inference  # noqa: E402  upstream module, unmodified

inference.init_pipeline = functools.cache(inference.init_pipeline)  # warm pipeline, upstream untouched
img = os.path.join(repo, "assets/images/0_img.png")


def job(out):
    inference.run_inference(image_path=img, output_path=os.path.abspath(out), low_vram=True, seed=42)


def digest(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]


errors = []


def guarded(o):
    try:
        job(o)
    except Exception as e:  # noqa: BLE001
        errors.append(repr(e))


job("out/warmup.glb")
t = time.perf_counter(); job("out/seq_a.glb"); job("out/seq_b.glb"); seq = time.perf_counter() - t
threads = [threading.Thread(target=guarded, args=(o,)) for o in ("out/con_a.glb", "out/con_b.glb")]
t = time.perf_counter(); [th.start() for th in threads]; [th.join() for th in threads]; con = time.perf_counter() - t
print(json.dumps({
    "sequential_s": round(seq, 1), "concurrent_s": round(con, 1), "errors": errors,
    "seq_same": digest("out/seq_a.glb") == digest("out/seq_b.glb"),
    "con_matches_seq": not errors and digest("out/con_a.glb") == digest("out/seq_a.glb"),
}))
