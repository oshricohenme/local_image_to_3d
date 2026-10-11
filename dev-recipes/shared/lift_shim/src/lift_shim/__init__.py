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


_CONFIG_TYPES = {"aliases": dict, "standins": list, "patches": list, "env": dict}


def validate_config(config: dict) -> None:
    """ValueError for config the shim would otherwise ignore (typo'd keys) or choke on later.
    Unknown stand-in/patch names are rejected by install_module_finder/install_patches."""
    if not isinstance(config, dict):
        raise ValueError("lift_shim: config must be a JSON object")
    unknown = sorted(set(config) - set(_CONFIG_TYPES))
    if unknown:
        raise ValueError(f"lift_shim: unknown config key(s) {unknown}; allowed: {sorted(_CONFIG_TYPES)}")
    for key, typ in _CONFIG_TYPES.items():
        if key in config and not isinstance(config[key], typ):
            raise ValueError(f"lift_shim: config {key!r} must be a {'list' if typ is list else 'JSON object'}")
    for key in ("aliases", "env"):
        for k, v in config.get(key, {}).items():
            if not isinstance(v, str):
                raise ValueError(f"lift_shim: config {key}[{k!r}] must be a string, got {v!r}")


def install(config: dict | None = None) -> str:
    """Install once per process; returns 'mps', 'cpu', or 'cuda' (real CUDA: no-op)."""
    global _result
    config = config or {}
    validate_config(config)
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
