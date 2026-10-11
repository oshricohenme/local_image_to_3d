"""Imported from a .pth at interpreter start. Inert unless LIFT_SHIM is set.

Sets env defaults and module finders immediately (before torch can be imported), then
defers the device redirect until the first `import torch` completes.
"""
from __future__ import annotations

import json
import os


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


def _boot() -> None:
    cfg = _config()
    if cfg is None:
        return
    import lift_shim
    from lift_shim.modules import after_import, install_module_finder
    from lift_shim.patches import install_patches
    lift_shim.apply_env(cfg.get("env"))
    install_module_finder(cfg.get("aliases", {}), cfg.get("standins", []))
    install_patches(cfg.get("patches", []))  # as early as possible; install() repeats it (deduped) for direct callers
    after_import("torch", lambda _: lift_shim.install(cfg))


_boot()
