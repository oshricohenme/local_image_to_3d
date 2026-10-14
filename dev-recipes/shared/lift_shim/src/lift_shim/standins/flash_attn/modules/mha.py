"""flash_attn.modules.mha on torch SDPA: FlashSelfAttention, FlashCrossAttention, and MHA (cross-attention
path only).

MHA's parameter names (Wq, Wkv, out_proj) and the Wkv output layout (2, H, D) match upstream so
flash-attn checkpoints load with strict=True. Signatures match flash-attn v2.7.4."""
from __future__ import annotations

import torch.nn as nn
import torch.nn.functional as F

from .. import (flash_attn_kvpacked_func, flash_attn_qkvpacked_func, flash_attn_varlen_kvpacked_func,
                flash_attn_varlen_qkvpacked_func)


class FlashSelfAttention(nn.Module):
    # upstream asserts fp16/bf16 CUDA tensors; this runs any dtype on any device
    def __init__(self, causal=False, softmax_scale=None, attention_dropout=0.0, window_size=(-1, -1),
                 alibi_slopes=None, deterministic=False):
        super().__init__()
        self.causal, self.softmax_scale, self.drop = causal, softmax_scale, nn.Dropout(attention_dropout)
        self.register_buffer("alibi_slopes", alibi_slopes, persistent=False)
        self.window_size, self.deterministic = window_size, deterministic

    def forward(self, qkv, causal=None, cu_seqlens=None, max_seqlen=None):
        # qkv: (B, S, 3, H, D), or (total, 3, H, D) with cu_seqlens
        kw = dict(softmax_scale=self.softmax_scale, causal=self.causal if causal is None else causal,
                  alibi_slopes=self.alibi_slopes, window_size=self.window_size, deterministic=self.deterministic)
        p = self.drop.p if self.training else 0.0
        if cu_seqlens is not None:
            return flash_attn_varlen_qkvpacked_func(qkv, cu_seqlens, max_seqlen, p, **kw)
        return flash_attn_qkvpacked_func(qkv, p, **kw)


class FlashCrossAttention(nn.Module):
    # upstream asserts fp16/bf16 CUDA tensors; this runs any dtype on any device
    def __init__(self, causal=False, softmax_scale=None, attention_dropout=0.0, alibi_slopes=None,
                 window_size=(-1, -1), deterministic=False):
        super().__init__()
        self.causal, self.softmax_scale, self.drop = causal, softmax_scale, nn.Dropout(attention_dropout)
        self.register_buffer("alibi_slopes", alibi_slopes, persistent=False)
        self.window_size, self.deterministic = window_size, deterministic

    def forward(self, q, kv, causal=None, cu_seqlens=None, max_seqlen=None, cu_seqlens_k=None, max_seqlen_k=None):
        # q: (B, Sq, H, D), kv: (B, Sk, 2, H, D); or (total_q, H, D) and (total_k, 2, H, D) with cu_seqlens
        kw = dict(softmax_scale=self.softmax_scale, causal=self.causal if causal is None else causal,
                  alibi_slopes=self.alibi_slopes, window_size=self.window_size, deterministic=self.deterministic)
        p = self.drop.p if self.training else 0.0
        if cu_seqlens is not None:
            return flash_attn_varlen_kvpacked_func(q, kv, cu_seqlens, cu_seqlens_k, max_seqlen, max_seqlen_k, p, **kw)
        return flash_attn_kvpacked_func(q, kv, p, **kw)


def _unsupported(what: str):
    return NotImplementedError(f"lift_shim flash_attn stand-in: MHA {what} is not implemented")


class MHA(nn.Module):
    # Accepted and ignored, numerics-neutral: rotary_emb_* (unused while rotary_emb_dim=0),
    # fused_bias_fc (fused Linear kernel), use_flash_attn (backend choice; this is SDPA either way),
    # checkpointing (activation recomputation: memory only).
    def __init__(self, embed_dim, num_heads, num_heads_kv=None, cross_attn=False, qkv_proj_bias=True,
                 out_proj_bias=True, dropout=0.0, softmax_scale=None, causal=False, layer_idx=None,
                 dwconv=False, rotary_emb_dim=0, rotary_emb_base=10000.0, rotary_emb_scale_base=None,
                 rotary_emb_interleaved=False, use_alibi=False, window_size=(-1, -1), fused_bias_fc=False,
                 use_flash_attn=False, return_residual=False, checkpointing=False, device=None, dtype=None):
        super().__init__()
        # ponytail: only what UniRig uses; add the Wqkv self-attn path when a project needs it
        for bad, what in [(not cross_attn, "self-attention (cross_attn=False)"), (causal, "causal"),
                          (num_heads_kv not in (None, num_heads), "num_heads_kv (MQA/GQA)"),
                          (dwconv, "dwconv"), (rotary_emb_dim, "rotary embeddings"), (use_alibi, "ALiBi"),
                          (tuple(window_size) != (-1, -1), "window_size"), (return_residual, "return_residual")]:
            if bad:
                raise _unsupported(what)
        fk = {"device": device, "dtype": dtype}
        self.embed_dim, self.num_heads, self.layer_idx = embed_dim, num_heads, layer_idx
        self.dropout, self.softmax_scale = dropout, softmax_scale
        self.Wq = nn.Linear(embed_dim, embed_dim, bias=qkv_proj_bias, **fk)
        self.Wkv = nn.Linear(embed_dim, 2 * embed_dim, bias=qkv_proj_bias, **fk)
        self.out_proj = nn.Linear(embed_dim, embed_dim, bias=out_proj_bias, **fk)

    def forward(self, x, x_kv=None, key_padding_mask=None, cu_seqlens=None, max_seqlen=None,
                mixer_subset=None, inference_params=None, **kwargs):
        for name, val in [("key_padding_mask", key_padding_mask), ("cu_seqlens", cu_seqlens),
                          ("max_seqlen", max_seqlen), ("mixer_subset", mixer_subset),
                          ("inference_params", inference_params)]:
            if val is not None:
                raise _unsupported(name)
        if kwargs:  # upstream forwards these to its inner attention (causal, cu_seqlens_k, ...)
            raise _unsupported(f"forward kwargs {sorted(kwargs)}")
        h = self.num_heads
        q = self.Wq(x).unflatten(-1, (h, -1)).transpose(1, 2)                    # (B, H, Sq, D)
        k, v = self.Wkv(x if x_kv is None else x_kv).unflatten(-1, (2, h, -1)).unbind(2)
        out = F.scaled_dot_product_attention(q, k.transpose(1, 2), v.transpose(1, 2),
                                             dropout_p=self.dropout if self.training else 0.0,
                                             scale=self.softmax_scale)
        return self.out_proj(out.transpose(1, 2).flatten(-2))
