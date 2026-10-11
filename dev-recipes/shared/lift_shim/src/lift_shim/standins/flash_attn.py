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
