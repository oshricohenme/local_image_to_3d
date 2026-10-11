import sys

import pytest
import torch

from lift_shim.patches import install_patches

ACCEL = "mps" if torch.backends.mps.is_available() else "cpu"


def test_unknown_patch_raises():
    with pytest.raises(ValueError, match="unknown patch"):
        install_patches(["no_such_patch"])


def test_transformers_fa2_becomes_sdpa():
    install_patches(["transformers_fa2_to_sdpa"])
    from transformers import AutoModelForCausalLM, OPTConfig
    cfg = OPTConfig(hidden_size=16, num_hidden_layers=1, num_attention_heads=2, ffn_dim=32, vocab_size=50,
                    max_position_embeddings=32, _attn_implementation="flash_attention_2")
    model = AutoModelForCausalLM.from_config(cfg)
    assert model.config._attn_implementation == "sdpa"
    model(torch.tensor([[1, 2, 3]]))


def _fake_pkg(tmp_path, monkeypatch, name, fn_name):
    # Mimics the compiled CPU-only ops: they assert every tensor input is on CPU.
    (tmp_path / name).mkdir()
    (tmp_path / name / "__init__.py").write_text(
        f"def {fn_name}(*args, **kwargs):\n"
        "    ts = [a for a in (*args, *kwargs.values()) if hasattr(a, 'device')]\n"
        "    assert all(t.device.type == 'cpu' for t in ts), 'src must be CPU tensor'\n"
        "    return ts[0] * 2\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    sys.modules.pop(name, None)


@pytest.mark.parametrize("patch,pkg,fn", [("torch_scatter_mps", "torch_scatter", "segment_csr"),
                                          ("torch_cluster_mps", "torch_cluster", "fps")])
def test_cpu_roundtrip_patches(tmp_path, monkeypatch, patch, pkg, fn):
    _fake_pkg(tmp_path, monkeypatch, pkg, fn)
    install_patches([patch])
    mod = __import__(pkg)
    x = torch.ones(3, device=ACCEL)
    out = getattr(mod, fn)(x, ptr=torch.tensor([0, 3], device=ACCEL))
    assert out.device.type == ACCEL and out.tolist() == [2.0, 2.0, 2.0]
    from_import = __import__(pkg, fromlist=[fn]).__dict__[fn]  # `from torch_cluster import fps` sees the wrapper
    assert from_import is getattr(mod, fn)
    sys.modules.pop(pkg)
