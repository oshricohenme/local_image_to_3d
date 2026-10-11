import json
import os
import subprocess
import sys

import torch

TARGET = "mps" if torch.backends.mps.is_available() else "cpu"
PROBE = "import lift_shim.autoload, torch; print(torch.zeros(1).cuda().device.type)"


def run(env_value):
    env = {k: v for k, v in os.environ.items() if k != "LIFT_SHIM"}
    if env_value is not None:
        env["LIFT_SHIM"] = env_value
    return subprocess.run([sys.executable, "-c", PROBE], env=env, capture_output=True, text=True)


def test_autoload_redirects_after_torch_import():
    r = run(json.dumps({"standins": ["flash_attn"]}))
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == TARGET


def test_autoload_inert_without_env():
    r = run(None)
    assert r.returncode != 0
    assert "CUDA" in r.stderr  # plain torch error: shim did nothing


def test_autoload_bad_json_fails():
    r = run("{not json")
    assert r.returncode != 0
    assert "LIFT_SHIM" in r.stderr


def test_autoload_sets_env_before_torch():
    code = "import lift_shim.autoload, os; print(os.environ['PYTORCH_ENABLE_MPS_FALLBACK'])"
    env = {**os.environ, "LIFT_SHIM": "{}"}
    r = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True)
    assert r.stdout.strip() == "1", r.stderr


def test_dynamo_imports_after_install():
    # Regression: assigning one function object to both cuda.manual_seed and manual_seed_all made
    # torch._dynamo's trace rules fail ("Duplicate torch object") — lightning/torchvision import it.
    code = "import lift_shim; lift_shim.install(); import torch._dynamo; print('ok')"
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert r.stdout.strip() == "ok", r.stderr[-2000:]


def test_write_and_remove_pth(tmp_path):
    from lift_shim.pth import remove_pth, write_pth
    p = write_pth(tmp_path)
    assert p.read_text().strip() == "import lift_shim.autoload"
    remove_pth(tmp_path)
    assert not p.exists()


FA2_PROBE = """
from transformers import AutoModelForCausalLM, OPTConfig
cfg = OPTConfig(hidden_size=16, num_hidden_layers=1, num_attention_heads=2, ffn_dim=32, vocab_size=50,
                max_position_embeddings=32, _attn_implementation="flash_attention_2")
print(AutoModelForCausalLM.from_config(cfg).config._attn_implementation)
"""


def test_autoload_applies_patches():
    env = {**os.environ, "LIFT_SHIM": json.dumps({"patches": ["transformers_fa2_to_sdpa"]})}
    r = subprocess.run([sys.executable, "-c", "import lift_shim.autoload\n" + FA2_PROBE],
                       env=env, capture_output=True, text=True)
    assert r.stdout.strip() == "sdpa", r.stderr[-2000:]


def test_install_applies_patches():
    code = "import lift_shim; lift_shim.install({'patches': ['transformers_fa2_to_sdpa']})\n" + FA2_PROBE
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert r.stdout.strip() == "sdpa", r.stderr[-2000:]


def test_autoload_unknown_patch_fails():
    r = run(json.dumps({"patches": ["nope"]}))
    assert r.returncode != 0
    assert "unknown patch" in r.stderr
