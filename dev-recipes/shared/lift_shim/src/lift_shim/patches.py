"""Named, opt-in patches to third-party modules, applied lazily right after the module imports."""
from __future__ import annotations

import functools

from .modules import after_import


def _fa2_to_sdpa(modeling_utils) -> None:
    # transformers 4.51: every model build (from_config/from_pretrained/__init__) routes the requested
    # attention through PreTrainedModel._autoset_attn_implementation; a requested FA2 raises without
    # flash_attn/CUDA, so rewrite it to sdpa (eager if the model has no sdpa path) before that check.
    cls = modeling_utils.PreTrainedModel
    original = cls.__dict__["_autoset_attn_implementation"].__func__

    def autoset(klass, config, use_flash_attention_2=False, *a, **kw):
        if use_flash_attention_2 or getattr(config, "_attn_implementation_internal", None) == "flash_attention_2":
            config._attn_implementation = "sdpa" if klass._supports_sdpa else "eager"
        return original(klass, config, False, *a, **kw)

    cls._autoset_attn_implementation = classmethod(autoset)


def _cpu_roundtrip(fn):
    """CPU-only compiled ops: move tensor args to CPU, call, move tensor results back."""
    import torch

    def to(x, dev):
        return x.to(dev) if isinstance(x, torch.Tensor) else x

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        dev = next((x.device for x in (*args, *kwargs.values()) if isinstance(x, torch.Tensor)), None)
        if dev is None or dev.type == "cpu":
            return fn(*args, **kwargs)
        out = fn(*(to(a, "cpu") for a in args), **{k: to(v, "cpu") for k, v in kwargs.items()})
        return tuple(to(o, dev) for o in out) if isinstance(out, tuple) else to(out, dev)

    return wrapper


def _wrap_cpu_only(*names):
    def apply(module):
        for n in names:
            setattr(module, n, _cpu_roundtrip(getattr(module, n)))
    return apply


# name -> (module to wait for, patch fn). The cpu_roundtrip lists are every function UniRig calls;
# torch_scatter.scatter is pure torch in 2.1.x and already runs on MPS.
_PATCHES = {
    "transformers_fa2_to_sdpa": ("transformers.modeling_utils", _fa2_to_sdpa),
    "torch_scatter_mps": ("torch_scatter", _wrap_cpu_only("segment_csr")),
    "torch_cluster_mps": ("torch_cluster", _wrap_cpu_only("fps")),
}
_installed: set[str] = set()


def install_patches(names: list[str]) -> None:
    for name in names:
        if name not in _PATCHES:
            raise ValueError(f"lift_shim: unknown patch {name!r}; known: {sorted(_PATCHES)}")
    for name in names:
        if name not in _installed:
            _installed.add(name)
            after_import(*_PATCHES[name])
