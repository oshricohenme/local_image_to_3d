"""Measure TorchFunctionMode overhead on MPS: transformer-ish forward, with vs. without the shim."""
import json
import subprocess
import sys

CODE = r"""
import os, time, json
if os.environ.get("WITH_SHIM") == "1":
    import lift_shim; lift_shim.install()
import torch
dev = "mps"
layer = torch.nn.TransformerEncoder(torch.nn.TransformerEncoderLayer(512, 8, batch_first=True), 12).to(dev).eval()
x = torch.randn(4, 1024, 512, device=dev)
with torch.no_grad():
    for _ in range(3): layer(x)
    torch.mps.synchronize(); t = time.perf_counter()
    for _ in range(20): layer(x)
    torch.mps.synchronize()
print(json.dumps({"s": (time.perf_counter() - t) / 20}))
"""


def run(with_shim):
    env = {"WITH_SHIM": "1" if with_shim else "0", "PATH": "/usr/bin:/bin"}
    out = subprocess.run([sys.executable, "-c", CODE], env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout.strip().splitlines()[-1])["s"]


base, shim = run(False), run(True)
print(f"baseline {base*1000:.1f} ms  shim {shim*1000:.1f} ms  overhead {100*(shim/base-1):+.1f}%")
