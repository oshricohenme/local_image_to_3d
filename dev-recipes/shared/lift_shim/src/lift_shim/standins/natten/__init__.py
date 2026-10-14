"""natten.na2d (NATTEN 0.21 API) in plain torch, so neighborhood attention runs on MPS.

Layout (B, H, W, heads, D). Each query attends to a kernel_size window of keys in its own dilation group,
centred on it and shifted inward at the borders so it always holds kernel_size keys, as natten does.
No `natten.functional`: callers that try the legacy na2d_qk/na2d_av API first fall back to na2d."""
from __future__ import annotations

import torch

__version__ = "0.21.0+lift_shim"

_WORKING_SET = 256 << 20  # ponytail: fixed per-chunk budget for gathered keys/values; tune if MPS memory is tight


def _pair(x):
    return tuple(x) if isinstance(x, (tuple, list)) else (x, x)


def _windows(length: int, k: int, d: int, device) -> torch.Tensor:
    """(length, k) key indices along one axis for each query index."""
    i = torch.arange(length, device=device)
    g, j = i % d, i // d
    group_len = (length - g + d - 1) // d
    start = torch.minimum((j - k // 2).clamp(min=0), group_len - k)
    return g[:, None] + d * (start[:, None] + torch.arange(k, device=device))


def na2d(query, key, value, kernel_size, stride=1, dilation=1, is_causal=False, scale=None,
         additional_keys=None, additional_values=None, attention_kwargs=None, backend=None,
         return_lse=False, **_kernel_choice):
    # backend and the tile / schedule / torch_compile arguments only pick natten's kernel; ignored
    causal = is_causal if isinstance(is_causal, (tuple, list)) else (bool(is_causal),)
    for bad, what in [(_pair(stride) != (1, 1), "stride"), (any(causal), "is_causal"),
                      (additional_keys is not None or additional_values is not None, "additional_keys/values"),
                      (bool(attention_kwargs), "attention_kwargs"), (return_lse, "return_lse")]:
        if bad:
            raise NotImplementedError(f"lift_shim natten stand-in: na2d {what} is not implemented")
    (kh, kw), (dh, dw) = _pair(kernel_size), _pair(dilation)
    b, h, w, heads, dim = query.shape
    if kh * dh > h or kw * dw > w:
        raise ValueError(f"natten: kernel_size * dilation ({kh * dh}, {kw * dw}) exceeds the input ({h}, {w})")
    scale = scale or dim ** -0.5
    rows_idx, cols_idx = _windows(h, kh, dh, query.device), _windows(w, kw, dw, query.device)
    out = torch.empty(*query.shape[:-1], value.shape[-1], dtype=value.dtype, device=query.device)
    per_row = b * w * kh * kw * heads * (dim + value.shape[-1]) * query.element_size()
    step = max(1, _WORKING_SET // per_row)
    for r0 in range(0, h, step):
        r = rows_idx[r0:r0 + step]
        k = key[:, r][:, :, :, cols_idx]      # (B, rows, kh, W, kw, heads, D)
        v = value[:, r][:, :, :, cols_idx]
        logits = torch.einsum("bnwhd,bnawchd->bnwhac", query[:, r0:r0 + step] * scale, k)
        attn = logits.flatten(-2).softmax(-1, dtype=torch.float32).to(v.dtype).view_as(logits)
        out[:, r0:r0 + step] = torch.einsum("bnwhac,bnawchd->bnwhd", attn, v)
    return out
