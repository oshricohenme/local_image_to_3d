"""flash_attn.modules.mha.MHA — cross-attention path only, on torch SDPA.

Parameter names (Wq, Wkv, out_proj) and the Wkv output layout (2, H, D) match upstream so
flash-attn checkpoints load with strict=True."""
from __future__ import annotations

import torch.nn as nn
import torch.nn.functional as F


def _unsupported(what: str):
    return NotImplementedError(f"lift_shim flash_attn stand-in: MHA {what} is not implemented")


class MHA(nn.Module):
    def __init__(self, embed_dim, num_heads, num_heads_kv=None, cross_attn=False, qkv_proj_bias=True,
                 out_proj_bias=True, dropout=0.0, softmax_scale=None, causal=False, layer_idx=None,
                 dwconv=False, rotary_emb_dim=0, use_alibi=False, window_size=(-1, -1),
                 return_residual=False, device=None, dtype=None, **_):
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

    def forward(self, x, x_kv=None, key_padding_mask=None, mixer_subset=None, **_):
        if key_padding_mask is not None or mixer_subset is not None:
            raise _unsupported("key_padding_mask/mixer_subset")
        h = self.num_heads
        q = self.Wq(x).unflatten(-1, (h, -1)).transpose(1, 2)                    # (B, H, Sq, D)
        k, v = self.Wkv(x if x_kv is None else x_kv).unflatten(-1, (2, h, -1)).unbind(2)
        out = F.scaled_dot_product_attention(q, k.transpose(1, 2), v.transpose(1, 2),
                                             dropout_p=self.dropout if self.training else 0.0,
                                             scale=self.softmax_scale)
        return self.out_proj(out.transpose(1, 2).flatten(-2))
