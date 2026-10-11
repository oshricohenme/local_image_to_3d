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
