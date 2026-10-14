import natten as real  # the real package (dev group); its CPU flex backend is the reference
import pytest
import torch

from lift_shim.standins import natten as nat


@pytest.mark.parametrize("shape,kernel,dilation", [
    ((2, 12, 12, 2, 8), 3, 1),
    ((1, 13, 10, 2, 8), (5, 3), (2, 3)),   # non-square, uneven dilation groups
    ((1, 16, 16, 4, 16), 4, 2),            # even kernel: window extends one less to the right
    ((1, 32, 32, 4, 16), 9, (3, 3)),       # NAF's kernel, borders everywhere
])
def test_matches_natten(shape, kernel, dilation):
    q, k, v = (torch.randn(shape) for _ in range(3))
    want = real.na2d(q, k, v, kernel_size=kernel, dilation=dilation, backend="flex-fna")
    got = nat.na2d(q, k, v, kernel_size=kernel, dilation=dilation, backend="cutlass-fna")
    assert torch.allclose(got, want, atol=1e-5)


def test_chunked_rows_match_unchunked(monkeypatch):
    q, k, v = (torch.randn(1, 20, 20, 2, 8) for _ in range(3))
    whole = nat.na2d(q, k, v, kernel_size=5, dilation=2)
    monkeypatch.setattr(nat, "_WORKING_SET", 1)  # one row per chunk
    assert torch.equal(nat.na2d(q, k, v, kernel_size=5, dilation=2), whole)


def test_rejects_what_it_does_not_implement():
    q = torch.randn(1, 8, 8, 1, 4)
    with pytest.raises(NotImplementedError, match="stride"):
        nat.na2d(q, q, q, kernel_size=3, stride=2)
    with pytest.raises(NotImplementedError, match="is_causal"):
        nat.na2d(q, q, q, kernel_size=3, is_causal=True)
    with pytest.raises(ValueError):
        nat.na2d(q, q, q, kernel_size=5, dilation=2)
