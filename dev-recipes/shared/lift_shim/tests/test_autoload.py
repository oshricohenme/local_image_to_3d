import json
import os
import subprocess
import sys

import pytest
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


def test_install_before_torch_with_autoload_does_not_deadlock():
    # Regression: install() held a non-reentrant lock across `import torch`, whose autoload
    # post-import hook calls install() again → hang.
    code = "import lift_shim.autoload, lift_shim; print(lift_shim.install())"
    env = {**os.environ, "LIFT_SHIM": "{}"}
    r = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60)
    assert r.stdout.strip() == TARGET, r.stderr[-2000:]


def _autoload_probe(prelude):
    code = f"import lift_shim.autoload\n{prelude}\nimport torch; print(torch.zeros(1).cuda().device.type)"
    env = {**os.environ, "LIFT_SHIM": "{}"}
    return subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=120)


def test_autoload_survives_find_spec_torch_before_import():
    r = _autoload_probe("import importlib.util; importlib.util.find_spec('torch')")
    assert r.stdout.strip() == TARGET, r.stderr[-2000:]


def test_autoload_survives_transformers_before_torch():
    r = _autoload_probe("import transformers")
    assert r.stdout.strip() == TARGET, r.stderr[-2000:]


def run_via_pth(tmp_path, env_value, body="import torch; print(torch.zeros(1).cuda().device.type)"):
    # site.addsitedir processes .pth files with the same addpackage() as interpreter startup, which
    # swallows every Exception from a .pth line — only SystemExit stops the process.
    from lift_shim.pth import write_pth
    write_pth(tmp_path)
    code = f"import site; site.addsitedir({str(tmp_path)!r}); {body}"
    env = {**{k: v for k, v in os.environ.items() if k != "LIFT_SHIM"}, "LIFT_SHIM": env_value}
    return subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=120)


def test_pth_redirects(tmp_path):
    r = run_via_pth(tmp_path, json.dumps({"standins": ["flash_attn"]}))
    assert r.returncode == 0 and r.stdout.strip() == TARGET, r.stderr[-2000:]


@pytest.mark.parametrize("cfg,msg", [
    ({"patches": ["nope"]}, "unknown patch"),
    ({"standins": ["nope"]}, "unknown stand-in"),
    ({"standin": ["flash_attn"]}, "unknown config key"),
    ({"env": {"X": 1}}, "env"),
    ({"aliases": {"nvdiffrast": 1}}, "aliases"),
    ({"standins": "flash_attn"}, "standins"),
    ({"patches": "transformers_fa2_to_sdpa"}, "patches"),
    ({"env": ["X"]}, "env"),
])
def test_pth_bad_config_stops_startup(tmp_path, cfg, msg):
    r = run_via_pth(tmp_path, json.dumps(cfg), body="print('RAN')")
    assert r.returncode != 0, (r.stdout, r.stderr)
    assert "RAN" not in r.stdout
    assert "lift_shim:" in r.stderr and msg in r.stderr, r.stderr[-2000:]


@pytest.mark.parametrize("cfg", [{"standin": ["flash_attn"]}, {"env": {"X": 1}}, {"aliases": {"a": 1}},
                                 {"standins": "flash_attn"}, {"patches": "x"}])
def test_install_rejects_bad_config(cfg):
    import lift_shim
    with pytest.raises(ValueError, match="lift_shim"):
        lift_shim.install(cfg)
