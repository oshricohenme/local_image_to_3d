"""lift_shim — run unmodified CUDA PyTorch projects on Apple Silicon.

Import order matters: env defaults must be set before torch is first imported,
so callers use autoload (via .pth) or call install() before importing upstream code.
"""
from __future__ import annotations

import os
import threading

ENV_DEFAULTS = {
    "PYTORCH_ENABLE_MPS_FALLBACK": "1",
    "ATTN_BACKEND": "sdpa",
    "SPARSE_ATTN_BACKEND": "sdpa",
}

_lock = threading.RLock()  # reentrant: `import torch` below fires autoload's hook, which calls install()
_result: str | None = None


def apply_env(extra: dict[str, str] | None = None) -> None:
    for k, v in {**ENV_DEFAULTS, **(extra or {})}.items():
        os.environ.setdefault(k, v)


def install(config: dict | None = None) -> str:
    """Install once per process; returns 'mps', 'cpu', or 'cuda' (real CUDA: no-op)."""
    global _result
    config = config or {}
    with _lock:
        if _result is not None:
            return _result
        apply_env(config.get("env"))
        from .modules import install_module_finder
        install_module_finder(config.get("aliases", {}), config.get("standins", []))
        from .patches import install_patches
        install_patches(config.get("patches", []))
        import torch
        if _result is not None:  # the torch post-import hook already installed (re-entered under _lock)
            return _result
        if torch.cuda.is_available():
            _result = "cuda"
            return _result
        from .device import install_device_redirect
        target = "mps" if torch.backends.mps.is_available() else "cpu"
        install_device_redirect(target)
        _result = target
        return _result
