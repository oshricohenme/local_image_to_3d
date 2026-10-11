"""Redirect CUDA device use to MPS (or CPU) without touching upstream source."""
from __future__ import annotations

import threading

import torch
from torch.overrides import TorchFunctionMode

_target = "cpu"


def target_device() -> str:
    return _target


def _is_cuda(obj) -> bool:
    if isinstance(obj, torch.device):
        return obj.type == "cuda"
    return isinstance(obj, str) and (obj == "cuda" or obj.startswith("cuda:"))


def _map(obj):
    return torch.device(_target) if _is_cuda(obj) else obj


class _CudaRedirect(TorchFunctionMode):
    def __torch_function__(self, func, types, args=(), kwargs=None):
        kwargs = dict(kwargs or {})
        if func is torch.device and args and _is_cuda(args[0]):
            # torch.device("cuda"[, index]) itself dispatches here; drop the CUDA ordinal
            return torch.device(_target)
        if func is torch.Tensor.cuda:
            # Tensor.cuda(device=None, non_blocking=False, ...): any CUDA ordinal → target
            return args[0].to(_target, non_blocking=kwargs.get("non_blocking", False))
        if "device" in kwargs:
            dev = kwargs["device"]
            kwargs["device"] = torch.device(_target) if isinstance(dev, int) or _is_cuda(dev) else dev
        args = tuple(_map(a) for a in args)
        return func(*args, **kwargs)


_tls = threading.local()


def _activate_current_thread() -> None:
    if not getattr(_tls, "active", False):
        _CudaRedirect().__enter__()  # never exited: lives for the thread's lifetime
        _tls.active = True


def _patch_threads() -> None:
    original_run = threading.Thread.run

    def run(self, *a, **kw):
        _activate_current_thread()
        return original_run(self, *a, **kw)

    threading.Thread.run = run


def _patch_cuda_module() -> None:
    c = torch.cuda
    if _target == "mps":
        c.empty_cache = torch.mps.empty_cache
        c.synchronize = lambda device=None: torch.mps.synchronize()
        c.memory_allocated = lambda device=None: torch.mps.current_allocated_memory()
    else:
        c.empty_cache = lambda: None
        c.synchronize = lambda device=None: None
    # torch.manual_seed() itself calls torch.cuda.manual_seed_all(), so these must seed
    # only the accelerator generator — never call back into torch.manual_seed.
    seed_accel = torch.mps.manual_seed if _target == "mps" else (lambda seed: None)
    c.manual_seed = seed_accel
    c.manual_seed_all = seed_accel
    c.current_device = lambda: 0

    original_init = torch.autocast.__init__

    def autocast_init(self, device_type, *a, **kw):
        if device_type == "cuda":
            device_type = _target
        original_init(self, device_type, *a, **kw)

    torch.autocast.__init__ = autocast_init


def install_device_redirect(target: str) -> None:
    global _target
    _target = target
    _patch_cuda_module()
    _patch_threads()
    _activate_current_thread()
