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
    # _bootstrap_inner, not run: subclasses (and threading.Timer) override run() without calling super
    original = threading.Thread._bootstrap_inner

    def _bootstrap_inner(self):
        _activate_current_thread()
        return original(self)

    threading.Thread._bootstrap_inner = _bootstrap_inner


def _patch_cuda_module() -> None:
    # Every replacement is a fresh function: reusing torch.mps.* objects (or one object for two
    # names) gives torch._dynamo duplicate trace rules and breaks `import torch._dynamo`.
    c = torch.cuda
    mps = _target == "mps"

    def empty_cache():
        if mps:
            torch.mps.empty_cache()

    def synchronize(device=None):
        if mps:
            torch.mps.synchronize()

    def memory_allocated(device=None):
        return torch.mps.current_allocated_memory() if mps else 0

    # torch.manual_seed() itself calls torch.cuda.manual_seed_all(), so these must seed only the
    # accelerator generator — never call back into torch.manual_seed.
    def manual_seed(seed):
        if mps:
            torch.mps.manual_seed(seed)

    def manual_seed_all(seed):
        if mps:
            torch.mps.manual_seed(seed)

    def current_device():
        return 0

    c.empty_cache, c.synchronize, c.memory_allocated = empty_cache, synchronize, memory_allocated
    c.manual_seed, c.manual_seed_all, c.current_device = manual_seed, manual_seed_all, current_device

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
