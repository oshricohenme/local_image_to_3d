"""Imported from a .pth at interpreter start. Inert unless LIFT_SHIM is set.

Sets env defaults and module finders immediately (before torch can be imported), then
defers the device redirect until the first `import torch` completes.
"""
from __future__ import annotations

import importlib.abc
import importlib.util
import json
import os
import sys


def _config() -> dict | None:
    raw = os.environ.get("LIFT_SHIM", "").strip()
    if not raw:
        return None
    try:
        cfg = json.loads(raw)
    except json.JSONDecodeError as e:
        raise SystemExit(f"lift_shim: LIFT_SHIM is not valid JSON: {e}") from e
    if not isinstance(cfg, dict):
        raise SystemExit("lift_shim: LIFT_SHIM must be a JSON object")
    return cfg


class _TorchHook(importlib.abc.MetaPathFinder):
    """Wraps torch's own loader so lift_shim.install runs right after torch finishes importing."""

    def __init__(self, cfg):
        self.cfg = cfg

    def find_spec(self, name, path=None, target=None):
        if name != "torch":
            return None
        sys.meta_path.remove(self)
        spec = importlib.util.find_spec("torch")
        original_exec = spec.loader.exec_module
        cfg = self.cfg

        def exec_module(module):
            original_exec(module)
            import lift_shim
            lift_shim.install(cfg)

        spec.loader.exec_module = exec_module
        return spec


def _boot() -> None:
    cfg = _config()
    if cfg is None:
        return
    import lift_shim
    from lift_shim.modules import install_module_finder
    lift_shim.apply_env(cfg.get("env"))
    install_module_finder(cfg.get("aliases", {}), cfg.get("standins", []))
    if "torch" in sys.modules:
        lift_shim.install(cfg)
    else:
        sys.meta_path.insert(0, _TorchHook(cfg))


_boot()
