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


# The ops CUDA autocast casts to its dtype (its lower-precision list); in a float32 region they get fp32 inputs.
_AUTOCAST_OPS = {
    "conv1d", "conv2d", "conv3d", "conv_transpose1d", "conv_transpose2d", "conv_transpose3d", "convolution",
    "prelu", "addmm", "addmv", "addr", "matmul", "__matmul__", "__rmatmul__", "einsum", "mm", "mv", "linear",
    "addbmm", "baddbmm", "bmm", "chain_matmul", "multi_dot", "scaled_dot_product_attention",
}


def _to_fp32(obj):
    if isinstance(obj, torch.Tensor) and obj.dtype in (torch.float16, torch.bfloat16):
        return obj.float()
    if isinstance(obj, (list, tuple)):
        return type(obj)(_to_fp32(o) for o in obj)
    return obj


class _CudaRedirect(TorchFunctionMode):
    def __torch_function__(self, func, types, args=(), kwargs=None):
        kwargs = dict(kwargs or {})
        if getattr(_tls, "fp32", 0) and getattr(func, "__name__", "") in _AUTOCAST_OPS:
            args, kwargs = _to_fp32(args), {k: _to_fp32(v) for k, v in kwargs.items()}
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

    original_init, original_enter, original_exit = torch.autocast.__init__, torch.autocast.__enter__, torch.autocast.__exit__

    # CUDA runs an enabled float32 autocast region in fp32 (MoGe-2 forces its output projection so, inside
    # an fp16 region). MPS and CPU reject float32 and turn autocast off, leaving half activations against
    # float weights. So: off, quietly, and _CudaRedirect gives the region's autocast ops fp32 inputs.
    def autocast_init(self, device_type, dtype=None, enabled=True, cache_enabled=None):
        if device_type == "cuda":
            device_type = _target
        self._lift_fp32 = enabled and dtype == torch.float32 and device_type != "cuda"
        if self._lift_fp32:
            dtype, enabled = None, False
        original_init(self, device_type, dtype=dtype, enabled=enabled, cache_enabled=cache_enabled)

    def autocast_enter(self):
        if getattr(self, "_lift_fp32", False):
            _tls.fp32 = getattr(_tls, "fp32", 0) + 1
        return original_enter(self)

    def autocast_exit(self, *exc):
        if getattr(self, "_lift_fp32", False):
            _tls.fp32 -= 1
        return original_exit(self, *exc)

    torch.autocast.__init__, torch.autocast.__enter__, torch.autocast.__exit__ = autocast_init, autocast_enter, autocast_exit

    # torch.load: every map_location form (None, str, device, dict, callable returning None) ends in
    # this module-global lookup, so CUDA-saved checkpoints land on the target. Patching torch.load
    # itself would break its safetensors/jit paths, which only accept str/device.
    original_restore = torch.serialization.default_restore_location

    def default_restore_location(storage, location):
        return original_restore(storage, _target if _is_cuda(location) else location)

    torch.serialization.default_restore_location = default_restore_location


def install_device_redirect(target: str) -> None:
    global _target
    _target = target
    _patch_cuda_module()
    _patch_threads()
    _activate_current_thread()
