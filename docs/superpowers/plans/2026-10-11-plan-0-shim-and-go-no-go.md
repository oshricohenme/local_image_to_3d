# Plan 0 — `lift_shim` + Go/No-Go Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared CUDA→MPS runtime shim (kept, tested), then find out which of the four v1 models run unmodified on this Mac. For each model, record whether it runs, wall time, peak memory, concurrency safety and the exact install steps, so Plans 1–5 are built on facts.

**Architecture:** `lift_shim` is a Python package installed into each model venv. A `.pth` file loads `lift_shim.autoload` at interpreter start. It does nothing unless `LIFT_SHIM` (JSON) is set; when it is, it sets env defaults, registers module aliases and stand-ins (via `sys.meta_path`), and once `torch` is imported, pushes a `TorchFunctionMode` that redirects `cuda` devices to `mps`. This reaches every Python process an upstream project starts (scripts, CLIs, subprocesses) without touching upstream files. The go/no-go test drivers are throwaway scripts under `spike/`.

**Tech Stack:** Python 3.11, uv 0.6+, PyTorch (PyPI macOS arm64 wheels, MPS), pytest; pedronaugusto Metal packages (mtlgemm→`flex_gemm`, mtlmesh→`cumesh`, mtldiffrast, mtlbvh, trellis2-apple/o-voxel→`o_voxel`).

**Spec:** `docs/superpowers/specs/2026-10-11-lift-design.md` (§5 shim and go/no-go, §4 v1 recipes, §8 concurrency).

## Global Constraints

- Never edit any file inside a cloned upstream repo. Install commands, env vars, `.pth` files and driver scripts outside the repo are allowed.
- Apple Silicon, macOS 26, Python 3.11 for every model venv.
- Pins: Pixal3D `f7cf38429b0bd264f1995f0f8743a88b1c728b94`; UniRig `6793c6640ff01c8fb389f3993434124bb43d2933`; trellis-mac `d58628f4f5b9c3de8274cb110074154f4b31cef2`; TRELLIS.2 `75fbf0183001ed9876c8dbb35de6b68552ee08bd`; mtlgemm `566c133781ce4992de3f77c3a97dd6feaae9d013`; mtldiffrast `c9499ba2e4ed6849e95ce5da7aae5bf61addb528`; mtlbvh `6b2a0f63b476ad8225695d092902104beafd7f58`; mtlmesh `7de3864f783407201486bf6c900a4bd76a4018a3`; trellis2-apple `17347247c91c36c8cdc1896234983e878a457bba`.
- **Ask the user before every model-weight download or long GPU run** (feedback rule). The download sizes are given at each checkpoint.
- Gated weights need a Hugging Face login and granted access: `briaai/RMBG-2.0` (Pixal3D, trellis-mac) and `facebook/dinov3-vitl16-pretrain-lvd1689m` (trellis-mac).
- Time box: each model gets at most 90 minutes of compatibility work. Then it's recorded as `unsupported` with the reason.
- Go/no-go code (`spike/`) is throwaway and labelled as such. `dev-recipes/shared/lift_shim/` is real code.
- Commit on branch `oshricohenme/7jtm2`; no push. End each commit message with `Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw`.

## Review Focus

1. **A thread created by upstream code** (Lightning, `ThreadPoolExecutor`) must still be redirected. Pinned by `test_new_thread_redirected`.
2. **A CPU tensor or explicit `"cpu"` / `"mps"` device must be left alone.** Pinned by `test_non_cuda_untouched`.
3. **A real installed package must win over a stand-in or alias.** Pinned by `test_real_module_wins`.
4. **`LIFT_SHIM` unset means the shim does nothing**, even though the `.pth` loads in every interpreter. Pinned by `test_autoload_inert_without_env`.
5. **Bad `LIFT_SHIM` JSON** must fail loudly at start-up, not silently run on CPU. Pinned by `test_autoload_bad_json_fails`.

---

## File Structure

```
dev-recipes/shared/lift_shim/
├─ pyproject.toml                 package + dev deps (pytest, torch)
├─ src/lift_shim/__init__.py      install(config) → target device; public API
├─ src/lift_shim/device.py        TorchFunctionMode redirect, torch.cuda helpers, autocast, Thread patch
├─ src/lift_shim/modules.py       meta-path finder: aliases (nvdiffrast→mtldiffrast) + stand-ins
├─ src/lift_shim/standins/flash_attn.py   SDPA-backed flash_attn functions
├─ src/lift_shim/autoload.py      entry from .pth: reads LIFT_SHIM, defers device redirect until torch import
├─ src/lift_shim/pth.py           write/remove the .pth in a venv (used by installers)
└─ tests/test_device.py · test_modules.py · test_flash_attn.py · test_autoload.py
spike/                            THROWAWAY go/no-go drivers (committed for the record)
├─ README.md
├─ setup_pixal3d.sh · run_pixal3d.py · run_pixal3d_mv.py
├─ setup_unirig.sh · run_unirig.sh
├─ setup_trellis2_mac.sh · run_trellis2_mac.sh
├─ run_concurrent.py · bench_shim_overhead.py
└─ work/                          gitignored clones, venvs, outputs
docs/superpowers/findings/2026-10-go-no-go.md   results table + exact install steps per model
```

---

### Task 1: `lift_shim` device redirection

**Files:**
- Create: `dev-recipes/shared/lift_shim/pyproject.toml`
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/__init__.py`
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/device.py`
- Test: `dev-recipes/shared/lift_shim/tests/test_device.py`
- Modify: `.gitignore` (add `spike/work/`, `**/.venv/`, `**/__pycache__/`, `.build/`)

**Interfaces:**
- Produces: `lift_shim.install(config: dict | None = None) -> str` returns `"mps"`, `"cpu"`, or `"cuda"` (meaning real CUDA, nothing done). Idempotent. `config` keys: `aliases: dict[str,str]`, `standins: list[str]`, `env: dict[str,str]`.
- Produces: `lift_shim.device.install_device_redirect(target: str) -> None`, `lift_shim.device.target_device() -> str`.

- [ ] **Step 1: Create the package skeleton**

`dev-recipes/shared/lift_shim/pyproject.toml`:
```toml
[project]
name = "lift-shim"
version = "0.1.0"
description = "Runtime CUDA→MPS redirection so unmodified CUDA PyTorch projects run on Apple Silicon"
requires-python = ">=3.10"
dependencies = []          # torch comes from the host model venv

[dependency-groups]
dev = ["pytest>=8", "torch>=2.6"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/lift_shim"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

Append to `.gitignore`:
```
spike/work/
**/.venv/
**/__pycache__/
.build/
```

- [ ] **Step 2: Write the failing tests**

`dev-recipes/shared/lift_shim/tests/test_device.py`:
```python
import threading

import pytest
import torch

import lift_shim

pytestmark = pytest.mark.skipif(torch.cuda.is_available(), reason="real CUDA present; shim is a no-op")
TARGET = "mps" if torch.backends.mps.is_available() else "cpu"


@pytest.fixture(scope="module", autouse=True)
def shim():
    assert lift_shim.install() == TARGET


def test_install_is_idempotent():
    assert lift_shim.install() == TARGET


def test_tensor_cuda():
    assert torch.zeros(2).cuda().device.type == TARGET
    assert torch.zeros(2).cuda(0).device.type == TARGET


@pytest.mark.parametrize("dev", ["cuda", "cuda:0", torch.device("cuda"), torch.device("cuda", 0)])
def test_tensor_to(dev):
    assert torch.zeros(2).to(dev).device.type == TARGET


def test_tensor_to_kwargs_keep_dtype():
    t = torch.zeros(2).to(device="cuda", dtype=torch.float16)
    assert t.device.type == TARGET and t.dtype == torch.float16


@pytest.mark.parametrize("factory", [
    lambda: torch.ones(3, device="cuda"),
    lambda: torch.randn(2, device=torch.device("cuda", 0)),
    lambda: torch.tensor([1.0], device="cuda"),
    lambda: torch.arange(4, device="cuda:0"),
    lambda: torch.zeros_like(torch.zeros(2), device="cuda"),
])
def test_factories(factory):
    assert factory().device.type == TARGET


def test_module_cuda_and_to():
    assert all(p.device.type == TARGET for p in torch.nn.Linear(2, 2).cuda().parameters())
    assert all(p.device.type == TARGET for p in torch.nn.Linear(2, 2).to("cuda").parameters())


def test_non_cuda_untouched():
    assert torch.zeros(2).to("cpu").device.type == "cpu"
    assert torch.zeros(2, device="cpu").device.type == "cpu"


def test_cuda_helpers_do_not_raise():
    torch.cuda.empty_cache()
    torch.cuda.synchronize()
    torch.cuda.manual_seed(1)
    torch.cuda.manual_seed_all(1)
    assert torch.cuda.current_device() == 0


def test_autocast_cuda():
    with torch.autocast("cuda", dtype=torch.bfloat16):
        out = torch.ones(2, 2, device="cuda") @ torch.ones(2, 2, device="cuda")
    assert out.device.type == TARGET


def test_new_thread_redirected():
    result = {}

    def work():
        try:
            result["dev"] = torch.zeros(1).cuda().device.type
        except Exception as e:  # noqa: BLE001 - surface any failure to the assert
            result["err"] = repr(e)

    t = threading.Thread(target=work)
    t.start()
    t.join()
    assert result == {"dev": TARGET}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest tests/test_device.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'lift_shim'` (or `AttributeError: install`).

- [ ] **Step 4: Implement**

`dev-recipes/shared/lift_shim/src/lift_shim/device.py`:
```python
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
    c.manual_seed = lambda seed: torch.manual_seed(seed)
    c.manual_seed_all = lambda seed: torch.manual_seed(seed)
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
```

`dev-recipes/shared/lift_shim/src/lift_shim/__init__.py`:
```python
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

_lock = threading.Lock()
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
        import torch
        if torch.cuda.is_available():
            _result = "cuda"
            return _result
        from .device import install_device_redirect
        target = "mps" if torch.backends.mps.is_available() else "cpu"
        install_device_redirect(target)
        _result = target
        return _result
```

Create an empty `src/lift_shim/modules.py` stub so the import resolves until Task 2:
```python
def install_module_finder(aliases, standins):
    """Replaced in Task 2."""
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest tests/test_device.py -q`
Expected: all pass. If `test_new_thread_redirected` fails, the mode stack is not inherited and the `Thread.run` patch is the fix. If `test_autocast_cuda` fails on MPS bfloat16, try `torch.float16`, and record which dtype MPS autocast accepts.

- [ ] **Step 6: Commit**

```bash
git add .gitignore dev-recipes/shared/lift_shim
git commit -m "feat(shim): CUDA→MPS device redirection via TorchFunctionMode

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 2: Module aliases and the `flash_attn` stand-in

**Files:**
- Modify: `dev-recipes/shared/lift_shim/src/lift_shim/modules.py`
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/standins/__init__.py` (empty)
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/standins/flash_attn.py`
- Test: `dev-recipes/shared/lift_shim/tests/test_modules.py`, `tests/test_flash_attn.py`

**Interfaces:**
- Consumes: `lift_shim.install(config)` from Task 1 (calls `install_module_finder`).
- Produces: `install_module_finder(aliases: dict[str, str], standins: list[str]) -> None`. Alias `"nvdiffrast": "mtldiffrast"` makes `import nvdiffrast.torch` return `mtldiffrast.torch`. Stand-in `"flash_attn"` provides `flash_attn_func`, `flash_attn_qkvpacked_func`, `flash_attn_kvpacked_func`, `flash_attn_varlen_func` and `flash_attn_varlen_qkvpacked_func`. The finder is appended to the end of `sys.meta_path`, so real installed modules always win.

- [ ] **Step 1: Write the failing tests**

`tests/test_modules.py`:
```python
import importlib
import sys
import types

from lift_shim.modules import install_module_finder


def test_alias_resolves_submodules(tmp_path, monkeypatch):
    pkg = tmp_path / "realpkg"
    (pkg / "torch").mkdir(parents=True)
    (pkg / "__init__.py").write_text("NAME = 'real'\n")
    (pkg / "torch" / "__init__.py").write_text("def RasterizeGLContext(): return 'ok'\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    install_module_finder({"fakealias": "realpkg"}, [])
    mod = importlib.import_module("fakealias.torch")
    assert mod.RasterizeGLContext() == "ok"
    assert importlib.import_module("fakealias").NAME == "real"


def test_real_module_wins(tmp_path, monkeypatch):
    (tmp_path / "flash_attn").mkdir()
    (tmp_path / "flash_attn" / "__init__.py").write_text("REAL = True\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    sys.modules.pop("flash_attn", None)
    install_module_finder({}, ["flash_attn"])
    assert importlib.import_module("flash_attn").REAL is True
    sys.modules.pop("flash_attn", None)


def test_standin_used_when_missing():
    sys.modules.pop("flash_attn", None)
    install_module_finder({}, ["flash_attn"])
    mod = importlib.import_module("flash_attn")
    assert isinstance(mod, types.ModuleType)
    assert callable(mod.flash_attn_func)
    sys.modules.pop("flash_attn", None)
```

`tests/test_flash_attn.py`:
```python
import torch

from lift_shim.standins import flash_attn as fa


def naive(q, k, v, causal=False):
    # q,k,v: (B, S, H, D)
    q, k, v = (x.transpose(1, 2).float() for x in (q, k, v))
    w = (q @ k.transpose(-1, -2)) / q.shape[-1] ** 0.5
    if causal:
        w = w.masked_fill(torch.ones_like(w, dtype=torch.bool).triu(1), float("-inf"))
    return (w.softmax(-1) @ v).transpose(1, 2)


def test_func_matches_naive():
    q, k, v = (torch.randn(2, 5, 3, 8) for _ in range(3))
    assert torch.allclose(fa.flash_attn_func(q, k, v), naive(q, k, v), atol=1e-5)
    assert torch.allclose(fa.flash_attn_func(q, k, v, causal=True), naive(q, k, v, causal=True), atol=1e-5)


def test_packed_variants():
    qkv = torch.randn(2, 5, 3, 3, 8)
    q, k, v = qkv.unbind(2)
    assert torch.allclose(fa.flash_attn_qkvpacked_func(qkv), naive(q, k, v), atol=1e-5)
    assert torch.allclose(fa.flash_attn_kvpacked_func(q, torch.stack([k, v], 2)), naive(q, k, v), atol=1e-5)


def test_varlen_matches_per_sequence():
    lens = [3, 5]
    cu = torch.tensor([0, 3, 8], dtype=torch.int32)
    q, k, v = (torch.randn(8, 2, 4) for _ in range(3))  # (total, H, D)
    out = fa.flash_attn_varlen_func(q, k, v, cu, cu, max(lens), max(lens))
    for i, (s, e) in enumerate([(0, 3), (3, 8)]):
        ref = naive(q[None, s:e], k[None, s:e], v[None, s:e])[0]
        assert torch.allclose(out[s:e], ref, atol=1e-5), i
    qkv = torch.stack([q, k, v], 1)  # (total, 3, H, D)
    out2 = fa.flash_attn_varlen_qkvpacked_func(qkv, cu, max(lens))
    assert torch.allclose(out, out2, atol=1e-6)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest tests/test_modules.py tests/test_flash_attn.py -q`
Expected: FAIL — `ImportError: cannot import name 'flash_attn' from 'lift_shim.standins'`, and the alias test fails with `ModuleNotFoundError: fakealias`.

- [ ] **Step 3: Implement**

`src/lift_shim/modules.py`:
```python
"""Meta-path finder for module aliases and stand-ins. Appended last: real modules win."""
from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
import importlib.util
import sys

_STANDINS = {"flash_attn": "lift_shim.standins.flash_attn"}


class _AliasLoader(importlib.abc.Loader):
    def __init__(self, target: str):
        self.target = target

    def create_module(self, spec):
        return importlib.import_module(self.target)

    def exec_module(self, module):
        pass  # already executed by import_module


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self):
        self.aliases: dict[str, str] = {}

    def find_spec(self, name, path=None, target=None):
        root, _, rest = name.partition(".")
        if root not in self.aliases:
            return None
        real = self.aliases[root] + ("." + rest if rest else "")
        if importlib.util.find_spec(real) is None:
            return None
        is_pkg = importlib.util.find_spec(real).submodule_search_locations is not None
        return importlib.machinery.ModuleSpec(name, _AliasLoader(real), is_package=is_pkg)


_finder = _Finder()


def install_module_finder(aliases: dict[str, str], standins: list[str]) -> None:
    for name in standins:
        if name not in _STANDINS:
            raise ValueError(f"lift_shim: unknown stand-in {name!r}; known: {sorted(_STANDINS)}")
        _finder.aliases.setdefault(name, _STANDINS[name])
    for name, target in aliases.items():
        _finder.aliases[name] = target
    if _finder not in sys.meta_path:
        sys.meta_path.append(_finder)
```

`src/lift_shim/standins/flash_attn.py`:
```python
"""flash_attn API on top of torch SDPA. Layouts follow flash-attn: (B, S, H, D); varlen (total, H, D)."""
from __future__ import annotations

import torch
import torch.nn.functional as F

__version__ = "2.0.0+lift_shim"


def flash_attn_func(q, k, v, dropout_p=0.0, softmax_scale=None, causal=False, **_):
    out = F.scaled_dot_product_attention(
        q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2),
        dropout_p=dropout_p, is_causal=causal, scale=softmax_scale,
    )
    return out.transpose(1, 2)


def flash_attn_qkvpacked_func(qkv, dropout_p=0.0, softmax_scale=None, causal=False, **_):
    q, k, v = qkv.unbind(2)
    return flash_attn_func(q, k, v, dropout_p, softmax_scale, causal)


def flash_attn_kvpacked_func(q, kv, dropout_p=0.0, softmax_scale=None, causal=False, **_):
    k, v = kv.unbind(2)
    return flash_attn_func(q, k, v, dropout_p, softmax_scale, causal)


def flash_attn_varlen_func(q, k, v, cu_seqlens_q, cu_seqlens_k, max_seqlen_q=None, max_seqlen_k=None,
                           dropout_p=0.0, softmax_scale=None, causal=False, **_):
    # ponytail: per-sequence loop; pad-and-mask batching if this shows up in profiles
    out = torch.empty_like(q)
    cq, ck = cu_seqlens_q.tolist(), cu_seqlens_k.tolist()
    for i in range(len(cq) - 1):
        qs, qe, ks, ke = cq[i], cq[i + 1], ck[i], ck[i + 1]
        out[qs:qe] = flash_attn_func(q[None, qs:qe], k[None, ks:ke], v[None, ks:ke],
                                     dropout_p, softmax_scale, causal)[0]
    return out


def flash_attn_varlen_qkvpacked_func(qkv, cu_seqlens, max_seqlen=None, dropout_p=0.0,
                                     softmax_scale=None, causal=False, **_):
    q, k, v = qkv.unbind(1)
    return flash_attn_varlen_func(q, k, v, cu_seqlens, cu_seqlens, max_seqlen, max_seqlen,
                                  dropout_p, softmax_scale, causal)
```

- [ ] **Step 4: Run all shim tests**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add dev-recipes/shared/lift_shim
git commit -m "feat(shim): module aliases and SDPA-backed flash_attn stand-in

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 3: Autoload through `.pth`

**Files:**
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/autoload.py`
- Create: `dev-recipes/shared/lift_shim/src/lift_shim/pth.py`
- Test: `dev-recipes/shared/lift_shim/tests/test_autoload.py`

**Interfaces:**
- Consumes: `lift_shim.apply_env`, `lift_shim.install`, `install_module_finder`.
- Produces:
  - `lift_shim.pth.write_pth(site_packages: Path) -> Path`: writes `lift_shim_autoload.pth` containing `import lift_shim.autoload`.
  - `lift_shim.pth.remove_pth(site_packages: Path) -> None`.
  - **Contract for Plan 1's installer:** env var `LIFT_SHIM` holds JSON `{"aliases":{…},"standins":[…],"env":{…}}`. If it's unset or empty, nothing happens.

- [ ] **Step 1: Write the failing tests**

`tests/test_autoload.py`:
```python
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


def test_write_and_remove_pth(tmp_path):
    from lift_shim.pth import remove_pth, write_pth
    p = write_pth(tmp_path)
    assert p.read_text().strip() == "import lift_shim.autoload"
    remove_pth(tmp_path)
    assert not p.exists()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest tests/test_autoload.py -q`
Expected: FAIL — `No module named 'lift_shim.autoload'`.

- [ ] **Step 3: Implement**

`src/lift_shim/autoload.py`:
```python
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
```

`src/lift_shim/pth.py`:
```python
from pathlib import Path

PTH_NAME = "lift_shim_autoload.pth"


def write_pth(site_packages: Path) -> Path:
    p = Path(site_packages) / PTH_NAME
    p.write_text("import lift_shim.autoload\n")
    return p


def remove_pth(site_packages: Path) -> None:
    (Path(site_packages) / PTH_NAME).unlink(missing_ok=True)
```

- [ ] **Step 4: Run all shim tests**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 pytest -q`
Expected: all pass. If `test_autoload_redirects_after_torch_import` fails because torch's spec loader can't be wrapped (a frozen or namespace loader), fall back to a `sys.modules` poll from `sys.setprofile`. That's not expected with PyPI torch.

- [ ] **Step 5: Commit**

```bash
git add dev-recipes/shared/lift_shim
git commit -m "feat(shim): .pth autoload gated by LIFT_SHIM, deferred until torch import

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 4: Shim overhead benchmark (throwaway)

**Files:**
- Create: `spike/README.md`, `spike/bench_shim_overhead.py`

- [ ] **Step 1: Write `spike/README.md`**

```markdown
# spike/ — THROWAWAY go/no-go drivers (Plan 0)

Not product code. Kept only as a record of how each model was made to run.
Results live in docs/superpowers/findings/2026-10-go-no-go.md. `work/` is gitignored.
```

- [ ] **Step 2: Write the benchmark**

`spike/bench_shim_overhead.py`:
```python
"""Measure TorchFunctionMode overhead on MPS: transformer-ish forward, with vs. without the shim."""
import subprocess
import sys

CODE = r"""
import os, time, json
if os.environ.get("WITH_SHIM") == "1":
    import lift_shim; lift_shim.install()
import torch
dev = "mps"
layer = torch.nn.TransformerEncoder(torch.nn.TransformerEncoderLayer(512, 8, batch_first=True), 12).to(dev).eval()
x = torch.randn(4, 1024, 512, device=dev)
with torch.no_grad():
    for _ in range(3): layer(x)
    torch.mps.synchronize(); t = time.perf_counter()
    for _ in range(20): layer(x)
    torch.mps.synchronize()
print(json.dumps({"s": (time.perf_counter() - t) / 20}))
"""


def run(with_shim):
    env = {"WITH_SHIM": "1" if with_shim else "0", "PATH": "/usr/bin:/bin"}
    out = subprocess.run([sys.executable, "-c", CODE], env=env, capture_output=True, text=True, check=True)
    return float(out.stdout.split(":")[1].strip(" }\n"))


base, shim = run(False), run(True)
print(f"baseline {base*1000:.1f} ms  shim {shim*1000:.1f} ms  overhead {100*(shim/base-1):+.1f}%")
```

- [ ] **Step 3: Run it**

Run: `cd dev-recipes/shared/lift_shim && uv run --python 3.11 python ../../../spike/bench_shim_overhead.py`
Expected: prints the overhead. **Decision rule:** ≤ 10% → keep `TorchFunctionMode`. More than 10% → record it, and add a note for Plan 1 to replace the mode with targeted patches (`Tensor.cuda/to`, `Module.cuda/to` and the factory functions) behind the same tests.

- [ ] **Step 4: Commit**

```bash
git add spike/README.md spike/bench_shim_overhead.py
git commit -m "spike: shim overhead benchmark (throwaway)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 5: Go/no-go — Pixal3D single image

**Files:**
- Create: `spike/setup_pixal3d.sh`, `spike/run_pixal3d.py`

- [ ] **Step 1: Write the setup script**

`spike/setup_pixal3d.sh`:
```bash
#!/usr/bin/env bash
# THROWAWAY: Pixal3D on Apple Silicon with lift_shim. Never edits the cloned repo.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
ROOT=$(cd ../.. && pwd)

clone() { [ -d "$2" ] || git clone --filter=blob:none "$1" "$2"; git -C "$2" checkout -q "$3"; }
clone https://github.com/TencentARC/Pixal3D           pixal3d                 f7cf38429b0bd264f1995f0f8743a88b1c728b94
clone https://github.com/pedronaugusto/mtlgemm        deps/mtlgemm            566c133781ce4992de3f77c3a97dd6feaae9d013
clone https://github.com/pedronaugusto/mtldiffrast    deps/mtldiffrast        c9499ba2e4ed6849e95ce5da7aae5bf61addb528
clone https://github.com/pedronaugusto/mtlbvh         deps/mtlbvh             6b2a0f63b476ad8225695d092902104beafd7f58
clone https://github.com/pedronaugusto/mtlmesh        deps/mtlmesh            7de3864f783407201486bf6c900a4bd76a4018a3
clone https://github.com/pedronaugusto/trellis2-apple deps/trellis2-apple     17347247c91c36c8cdc1896234983e878a457bba

[ -d venv-pixal3d ] || uv venv venv-pixal3d --python 3.11
export VIRTUAL_ENV=$PWD/venv-pixal3d PATH=$PWD/venv-pixal3d/bin:$PATH
uv pip install torch torchvision
uv pip install -r pixal3d/requirements.txt
uv pip install https://github.com/LDYang694/Storages/releases/download/20260430/utils3d-0.0.2-py3-none-any.whl
uv pip install setuptools wheel pybind11 xatlas fast-simplification scipy
export MACOSX_DEPLOYMENT_TARGET=12.0
for d in mtlbvh mtldiffrast mtlmesh mtlgemm trellis2-apple/o-voxel; do uv pip install --no-build-isolation "deps/$d"; done
uv pip install -e "$ROOT/dev-recipes/shared/lift_shim"
python -c "import site, lift_shim.pth as p; print(p.write_pth(site.getsitepackages()[0]))"
python -c "import flex_gemm, cumesh, mtldiffrast, o_voxel; print('substitutes import OK')"
```

- [ ] **Step 2: Run setup (no model weights yet)**

Run: `bash spike/setup_pixal3d.sh 2>&1 | tee spike/work/setup_pixal3d.log`
Expected: ends with `substitutes import OK`. On a build failure, record the failing package and the end of the log. Fix only install commands (flags, versions, extra deps); never upstream files.

- [ ] **Step 3: Write the driver**

`spike/run_pixal3d.py`:
```python
"""THROWAWAY: run unmodified Pixal3D inference under lift_shim. Usage: run_pixal3d.py IMAGE OUT.glb [--low_vram] [--resolution N]"""
import argparse
import json
import os
import sys
import time

os.environ["LIFT_SHIM"] = json.dumps({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})
import lift_shim.autoload  # noqa: E402,F401  (already loaded via .pth; explicit for clarity)

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("out")
ap.add_argument("--low_vram", action="store_true"); ap.add_argument("--resolution", type=int, default=-1)
a = ap.parse_args()

repo = os.path.join(os.path.dirname(__file__), "work", "pixal3d")
sys.path.insert(0, repo)
import inference  # noqa: E402  upstream module, unmodified

t = time.perf_counter()
inference.run_inference(image_path=os.path.abspath(a.image), output_path=os.path.abspath(a.out),
                        low_vram=a.low_vram, resolution=a.resolution)
print(json.dumps({"wall_s": round(time.perf_counter() - t, 1)}))
```

- [ ] **Step 4: CHECKPOINT — ask the user before downloading**

Ask: "Pixal3D needs a Hugging Face login and access to the gated `briaai/RMBG-2.0`. Please request access at https://huggingface.co/briaai/RMBG-2.0 and run `! spike/work/venv-pixal3d/bin/hf auth login`. The first run downloads about 20 GB: the Pixal3D single-view checkpoints, MoGe-2 (1.3 GB), DINOv3 (1.2 GB), RMBG-2.0 and NAF. OK to go ahead?" Wait for a yes.

- [ ] **Step 5: Run it (low-memory mode first, then standard)**

Run:
```bash
cd spike/work && /usr/bin/time -l venv-pixal3d/bin/python ../run_pixal3d.py pixal3d/assets/images/0_img.png out/pixal3d_lowvram.glb --low_vram 2>&1 | tee run_pixal3d_lowvram.log
/usr/bin/time -l venv-pixal3d/bin/python ../run_pixal3d.py pixal3d/assets/images/0_img.png out/pixal3d_1536.glb 2>&1 | tee run_pixal3d_1536.log
```
Expected: a GLB that opens in Quick Look/Preview (`qlmanage -p out/pixal3d_lowvram.glb` won't render GLB, so check with `python -c "import trimesh; m=trimesh.load('out/pixal3d_lowvram.glb'); print(m)"`). Record `wall_s` and `peak memory footprint` from `time -l`.
On failure, work through these in order within the time box:
- (a) A missing Python dependency: add it to the setup script.
- (b) A CUDA call the shim misses: add a test reproducing it to `test_device.py`, fix it in the shim, rerun.
- (c) `natten` required by NAF: try `uv pip install natten` (CPU build). If unavailable, record it.
- (d) A `cumesh` or `o_voxel` API that's missing from the Apple fork: record the exact symbol.

- [ ] **Step 6: Commit**

```bash
git add spike/setup_pixal3d.sh spike/run_pixal3d.py dev-recipes/shared/lift_shim
git commit -m "spike: Pixal3D go/no-go driver (throwaway)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 6: Go/no-go — Pixal3D multi-view

**Files:**
- Create: `spike/run_pixal3d_mv.py`

- [ ] **Step 1: Write the driver**

`spike/run_pixal3d_mv.py`:
```python
"""THROWAWAY: unmodified Pixal3D multi-view via its own CLI entry, under lift_shim."""
import json
import os
import runpy
import sys
import time

os.environ["LIFT_SHIM"] = json.dumps({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})
import lift_shim.autoload  # noqa: E402,F401

repo = os.path.join(os.path.dirname(__file__), "work", "pixal3d")
sys.path.insert(0, repo)
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "out/pixal3d_mv.glb")
sys.argv = ["inference_mv.py", "--views_dir", os.path.join(repo, "assets/mv_images/example"),
            "--output", out, "--low_vram"]
t = time.perf_counter()
runpy.run_path(os.path.join(repo, "inference_mv.py"), run_name="__main__")
print(json.dumps({"wall_s": round(time.perf_counter() - t, 1)}))
```

- [ ] **Step 2: CHECKPOINT — ask the user**

Ask: "Pixal3D multi-view uses separate `_mv` checkpoints from the same repo, roughly another 20 GB. OK to download and run?" Wait for a yes.

- [ ] **Step 3: Run it**

Run: `cd spike/work && /usr/bin/time -l venv-pixal3d/bin/python ../run_pixal3d_mv.py out/pixal3d_mv.glb 2>&1 | tee run_pixal3d_mv.log`
Expected: a GLB; record time and peak memory. Use the same failure procedure as Task 5, step 5.

- [ ] **Step 4: Commit**

```bash
git add spike/run_pixal3d_mv.py
git commit -m "spike: Pixal3D multi-view go/no-go driver (throwaway)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 7: Go/no-go — UniRig

**Files:**
- Create: `spike/setup_unirig.sh`, `spike/run_unirig.sh`

- [ ] **Step 1: Write the setup script**

`spike/setup_unirig.sh`:
```bash
#!/usr/bin/env bash
# THROWAWAY: UniRig on Apple Silicon with lift_shim. Never edits the cloned repo.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
ROOT=$(cd ../.. && pwd)
[ -d unirig ] || git clone --filter=blob:none https://github.com/VAST-AI-Research/UniRig unirig
git -C unirig checkout -q 6793c6640ff01c8fb389f3993434124bb43d2933

[ -d venv-unirig ] || uv venv venv-unirig --python 3.11
export VIRTUAL_ENV=$PWD/venv-unirig PATH=$PWD/venv-unirig/bin:$PATH
uv pip install torch torchvision
grep -v -E '^(flash_attn|wandb)' unirig/requirements.txt > req-unirig.txt   # flash_attn → shim stand-in
uv pip install -r req-unirig.txt
uv pip install setuptools wheel
uv pip install --no-build-isolation torch_scatter torch_cluster
uv pip install spconv || echo "SPCONV: no macOS wheel — record"
uv pip install numpy==1.26.4
uv pip install -e "$ROOT/dev-recipes/shared/lift_shim"
python -c "import site, lift_shim.pth as p; print(p.write_pth(site.getsitepackages()[0]))"
(cd unirig && python -c "import bpy, os; bpy.ops.preferences.addon_install(filepath=os.path.abspath('blender/add-on-vrm-v2.20.77_modified.zip'))")
python -c "import bpy, torch_scatter, torch_cluster; print('unirig deps OK')"
```

- [ ] **Step 2: Run setup**

Run: `bash spike/setup_unirig.sh 2>&1 | tee spike/work/setup_unirig.log`
Expected: `unirig deps OK`. Record whether `spconv` installed. If not, check whether the skeleton path imports `PTv3Object` (`grep -rn PTv3Object spike/work/unirig/src`) to know which tasks need it.

- [ ] **Step 3: Write the runner**

`spike/run_unirig.sh`:
```bash
#!/usr/bin/env bash
# THROWAWAY: upstream UniRig scripts, unmodified, with the shim injected through LIFT_SHIM + .pth.
set -euo pipefail
cd "$(dirname "$0")/work/unirig"
export PATH=$PWD/../venv-unirig/bin:$PATH
export LIFT_SHIM='{"standins":["flash_attn"]}'
mkdir -p ../out
bash launch/inference/generate_skeleton.sh --input examples/giraffe.glb --output ../out/giraffe_skeleton.fbx
bash launch/inference/generate_skin.sh --input ../out/giraffe_skeleton.fbx --output ../out/giraffe_skin.fbx
bash launch/inference/merge.sh --source ../out/giraffe_skin.fbx --target examples/giraffe.glb --output ../out/giraffe_rigged.glb
```

- [ ] **Step 4: CHECKPOINT — ask the user**

Ask: "UniRig downloads about 11.5 GB from `VAST-AI/UniRig` (not gated). OK to download and run?" Wait for a yes.

- [ ] **Step 5: Run it**

Run: `/usr/bin/time -l bash spike/run_unirig.sh 2>&1 | tee spike/work/run_unirig.log`
Expected: `giraffe_rigged.glb`. Record time and peak memory for each stage.
Known risk: UniRig imports `flash_attn.modules.mha.MHA`, a full module class. If the skin stage fails on it, time-box 45 minutes for a stand-in `flash_attn/modules/mha.py`, `MHA`, matching flash-attn's parameter names (`Wqkv`, `out_proj`; for cross-attention `Wq`, `Wkv`), so the checkpoint loads. Add it to the shim **with a test that loads a state_dict using those key names**. If it isn't done within the time box, record skeleton-only support (if the skeleton stage worked) or unsupported.

- [ ] **Step 6: Commit**

```bash
git add spike/setup_unirig.sh spike/run_unirig.sh dev-recipes/shared/lift_shim
git commit -m "spike: UniRig go/no-go (throwaway drivers)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 8: Go/no-go — trellis2-mac (no shim)

**Files:**
- Create: `spike/setup_trellis2_mac.sh`, `spike/run_trellis2_mac.sh`

- [ ] **Step 1: Write the scripts**

`spike/setup_trellis2_mac.sh`:
```bash
#!/usr/bin/env bash
# THROWAWAY: trellis-mac's own setup, unmodified. TRELLIS.2 is pre-placed at a pin so setup.sh skips its unpinned clone.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
[ -d trellis-mac ] || git clone --filter=blob:none https://github.com/shivampkumar/trellis-mac trellis-mac
git -C trellis-mac checkout -q d58628f4f5b9c3de8274cb110074154f4b31cef2
[ -d trellis-mac/TRELLIS.2 ] || git clone --filter=blob:none https://github.com/microsoft/TRELLIS.2 trellis-mac/TRELLIS.2
git -C trellis-mac/TRELLIS.2 checkout -q 75fbf0183001ed9876c8dbb35de6b68552ee08bd
(cd trellis-mac && bash setup.sh)
```

`spike/run_trellis2_mac.sh`:
```bash
#!/usr/bin/env bash
# THROWAWAY
set -euo pipefail
cd "$(dirname "$0")/work/trellis-mac"
source .venv/bin/activate
python generate.py assets/shoe_input.png --output ../out/trellis2_shoe --pipeline-type 512
```

- [ ] **Step 2: Run setup**

Run: `bash spike/setup_trellis2_mac.sh 2>&1 | tee spike/work/setup_trellis2_mac.log`
Expected: `=== Setup complete ===`. Note: trellis-mac's own patch script edits *its* TRELLIS.2 clone. That's trellis-mac's documented behaviour, not Lift editing upstream; record it in the findings so the user can confirm it's acceptable.

- [ ] **Step 3: CHECKPOINT — ask the user**

Ask: "trellis-mac downloads about 15 GB (`microsoft/TRELLIS.2-4B`, plus the gated `facebook/dinov3-vitl16-pretrain-lvd1689m` and `briaai/RMBG-2.0`). Please request access to DINOv3 at https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m and log in: `! spike/work/trellis-mac/.venv/bin/hf auth login`. OK to run?" Wait for a yes.

- [ ] **Step 4: Run it**

Run: `/usr/bin/time -l bash spike/run_trellis2_mac.sh 2>&1 | tee spike/work/run_trellis2_mac.log`
Expected: `out/trellis2_shoe.glb`; record time and peak memory.

- [ ] **Step 5: Commit**

```bash
git add spike/setup_trellis2_mac.sh spike/run_trellis2_mac.sh
git commit -m "spike: trellis2-mac go/no-go (throwaway drivers)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 9: Concurrency inside one process

**Files:**
- Create: `spike/run_concurrent.py`

- [ ] **Step 1: Write the driver**

`spike/run_concurrent.py`:
```python
"""THROWAWAY: can one loaded Pixal3D serve two jobs at once? Compares sequential vs. 2 threads, same seeds."""
import functools
import hashlib
import json
import os
import sys
import threading
import time

os.environ["LIFT_SHIM"] = json.dumps({"aliases": {"nvdiffrast": "mtldiffrast"}, "standins": ["flash_attn"]})
import lift_shim.autoload  # noqa: E402,F401

repo = os.path.join(os.path.dirname(__file__), "work", "pixal3d")
sys.path.insert(0, repo)
import inference  # noqa: E402

inference.init_pipeline = functools.cache(inference.init_pipeline)  # warm pipeline, upstream untouched
img = os.path.join(repo, "assets/images/0_img.png")


def job(out):
    inference.run_inference(image_path=img, output_path=out, low_vram=True, seed=42)


def digest(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]


job("out/warmup.glb")
t = time.perf_counter(); job("out/seq_a.glb"); job("out/seq_b.glb"); seq = time.perf_counter() - t
errors = []


def guarded(o):
    try:
        job(o)
    except Exception as e:  # noqa: BLE001
        errors.append(repr(e))


threads = [threading.Thread(target=guarded, args=(o,)) for o in ("out/con_a.glb", "out/con_b.glb")]
t = time.perf_counter(); [th.start() for th in threads]; [th.join() for th in threads]; con = time.perf_counter() - t
print(json.dumps({
    "sequential_s": round(seq, 1), "concurrent_s": round(con, 1), "errors": errors,
    "seq_same": digest("out/seq_a.glb") == digest("out/seq_b.glb"),
    "con_matches_seq": not errors and digest("out/con_a.glb") == digest("out/seq_a.glb"),
}))
```

- [ ] **Step 2: CHECKPOINT — ask the user**

Ask: "The concurrency test runs Pixal3D 5 times in a row (about 25+ minutes of GPU). The weights are already downloaded. OK?" Wait for a yes.

- [ ] **Step 3: Run it**

Run: `cd spike/work && /usr/bin/time -l venv-pixal3d/bin/python ../run_concurrent.py 2>&1 | tee run_concurrent.log`
**Decision rule:** if `errors` is empty and `con_matches_seq` is true, set Pixal3D `max_concurrent_per_process: 2`. If it runs without errors but outputs differ, set it to 1 and note that seeds aren't reproducible under concurrency. If there are errors, set it to 1. Repeat for UniRig (via subprocess scripts: concurrency equals separate processes, so per-process concurrency is 1 by construction) and trellis2-mac (only if time allows; otherwise 1).

- [ ] **Step 4: Commit**

```bash
git add spike/run_concurrent.py
git commit -m "spike: in-process concurrency check (throwaway)

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

---

### Task 10: Findings and draft dev recipes

**Files:**
- Create: `docs/superpowers/findings/2026-10-go-no-go.md`
- Create: `dev-recipes/pixal3d/recipe.yaml`, `dev-recipes/unirig/recipe.yaml`, `dev-recipes/trellis2-mac/recipe.yaml` (drafts in the spec §4 schema; validated by Plan 1)
- Modify: `docs/superpowers/specs/2026-10-11-lift-design.md` (only where the findings change a fact: install steps, substitutes, concurrency, memory)

- [ ] **Step 1: Write the findings**

Use this exact table plus one section per model:

```markdown
# Go/no-go findings (Plan 0)

| Model | Status | Wall time | Peak memory | Concurrency/process | Blockers / notes |
|---|---|---|---|---|---|
| Pixal3D (1024 low-memory) | supported/unsupported | … s | … GB | 1 or 2 | … |
| Pixal3D (1536) | … | … | … | … | … |
| Pixal3D multi-view | … | … | … | … | … |
| UniRig skeleton / skin / merge | … | … | … | 1 (separate processes) | … |
| trellis2-mac (512) | … | … | … | … | … |

Shim overhead (TorchFunctionMode, MPS): …% → keep mode / switch to targeted patches.

## <model>
- Exact install commands (copied from the working setup script, in order)
- Substitutes and shim config (`LIFT_SHIM` JSON)
- Entry point used, and how to keep the pipeline loaded between jobs
- Stage markers seen in the output (for progress parsing)
- Every failure hit and how it was resolved, or why the model is unsupported
```

- [ ] **Step 2: Write the draft recipes**

Each `recipe.yaml` follows spec §4, with `platform.status` and `reason` set from the findings, `install:` copied from the working setup script, `resources.memory_gb` from the measured peak, and `max_concurrent_per_process` from Task 9. `settings:` list every upstream keyword argument with its upstream default: for Pixal3D, the `run_inference` signature; for trellis2-mac, the `generate.py` flags; for UniRig, `--seed`, the stages and the output format.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/findings dev-recipes docs/superpowers/specs/2026-10-11-lift-design.md
git commit -m "docs: go/no-go findings and draft dev recipes

Claude-Session: https://claude.ai/code/session_01YQaNtMcUoMHe2knND64orw"
```

- [ ] **Step 4: Report to the user**

Show them the findings table, and list every spec fact that changed. Then write Plan 1 (LiftCore) using the confirmed recipe format, shim config contract and worker entry points.
