"""flash_attn API on top of torch SDPA. Layouts follow flash-attn: (B, S, H, D); varlen (total, H, D).

Signatures match flash-attn v2.7.4. Arguments that change numerics (window_size, softcap,
alibi_slopes, return_attn_probs, block_table) raise unless left at their defaults; `deterministic`
only affects flash-attn's backward-pass reduction order, so it is accepted and ignored."""
from __future__ import annotations

import torch
import torch.nn.functional as F

__version__ = "2.0.0+lift_shim"


def _check(window_size=(-1, -1), softcap=0.0, alibi_slopes=None, return_attn_probs=False, block_table=None):
    for bad, what in [(tuple(window_size) != (-1, -1), "window_size"), (softcap > 0.0, "softcap"),
                      (alibi_slopes is not None, "alibi_slopes"), (return_attn_probs, "return_attn_probs"),
                      (block_table is not None, "block_table")]:
        if bad:
            raise NotImplementedError(f"lift_shim flash_attn stand-in: {what} is not implemented")


def _sdpa(q, k, v, dropout_p, softmax_scale, causal):
    # (B, S, H, D) in and out
    q, k, v = q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2)
    sq, sk = q.shape[-2], k.shape[-2]
    if not causal or sq == sk:
        out = F.scaled_dot_product_attention(q, k, v, dropout_p=dropout_p, is_causal=causal, scale=softmax_scale)
        return out.transpose(1, 2)
    # flash-attn >= 2.1 aligns the causal mask bottom-right (SDPA's is_causal is top-left); rows with
    # no visible key (sq > sk) output 0, as upstream documents
    keep = torch.ones(sq, sk, dtype=torch.bool, device=q.device).tril(sk - sq)
    out = F.scaled_dot_product_attention(q, k, v, attn_mask=keep, dropout_p=dropout_p, scale=softmax_scale)
    return out.masked_fill(~keep.any(-1)[:, None], 0.0).transpose(1, 2)


def flash_attn_func(q, k, v, dropout_p=0.0, softmax_scale=None, causal=False, window_size=(-1, -1),
                    softcap=0.0, alibi_slopes=None, deterministic=False, return_attn_probs=False):
    _check(window_size, softcap, alibi_slopes, return_attn_probs)
    return _sdpa(q, k, v, dropout_p, softmax_scale, causal)


def flash_attn_qkvpacked_func(qkv, dropout_p=0.0, softmax_scale=None, causal=False, window_size=(-1, -1),
                              softcap=0.0, alibi_slopes=None, deterministic=False, return_attn_probs=False):
    _check(window_size, softcap, alibi_slopes, return_attn_probs)
    q, k, v = qkv.unbind(2)
    return _sdpa(q, k, v, dropout_p, softmax_scale, causal)


def flash_attn_kvpacked_func(q, kv, dropout_p=0.0, softmax_scale=None, causal=False, window_size=(-1, -1),
                             softcap=0.0, alibi_slopes=None, deterministic=False, return_attn_probs=False):
    _check(window_size, softcap, alibi_slopes, return_attn_probs)
    k, v = kv.unbind(2)
    return _sdpa(q, k, v, dropout_p, softmax_scale, causal)


def flash_attn_varlen_func(q, k, v, cu_seqlens_q, cu_seqlens_k, max_seqlen_q=None, max_seqlen_k=None,
                           dropout_p=0.0, softmax_scale=None, causal=False, window_size=(-1, -1), softcap=0.0,
                           alibi_slopes=None, deterministic=False, return_attn_probs=False, block_table=None):
    _check(window_size, softcap, alibi_slopes, return_attn_probs, block_table)
    # ponytail: per-sequence loop; pad-and-mask batching if this shows up in profiles
    out = torch.empty_like(q)
    cq, ck = cu_seqlens_q.tolist(), cu_seqlens_k.tolist()
    for i in range(len(cq) - 1):
        qs, qe, ks, ke = cq[i], cq[i + 1], ck[i], ck[i + 1]
        out[qs:qe] = _sdpa(q[None, qs:qe], k[None, ks:ke], v[None, ks:ke], dropout_p, softmax_scale, causal)[0]
    return out


def flash_attn_varlen_kvpacked_func(q, kv, cu_seqlens_q, cu_seqlens_k, max_seqlen_q=None, max_seqlen_k=None,
                                    dropout_p=0.0, softmax_scale=None, causal=False, window_size=(-1, -1),
                                    softcap=0.0, alibi_slopes=None, deterministic=False, return_attn_probs=False):
    _check(window_size, softcap, alibi_slopes, return_attn_probs)
    k, v = kv.unbind(1)
    return flash_attn_varlen_func(q, k, v, cu_seqlens_q, cu_seqlens_k, max_seqlen_q, max_seqlen_k,
                                  dropout_p, softmax_scale, causal)


def flash_attn_varlen_qkvpacked_func(qkv, cu_seqlens, max_seqlen=None, dropout_p=0.0, softmax_scale=None,
                                     causal=False, window_size=(-1, -1), softcap=0.0, alibi_slopes=None,
                                     deterministic=False, return_attn_probs=False):
    _check(window_size, softcap, alibi_slopes, return_attn_probs)
    q, k, v = qkv.unbind(1)
    return flash_attn_varlen_func(q, k, v, cu_seqlens, cu_seqlens, max_seqlen, max_seqlen,
                                  dropout_p, softmax_scale, causal)
