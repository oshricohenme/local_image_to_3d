import importlib
import sys

import pytest
import torch
import torch.nn.functional as F

from lift_shim.modules import install_module_finder
from lift_shim.standins.spconv import pytorch as spconv

DEVICES = sorted({"cpu", "mps" if torch.backends.mps.is_available() else "cpu"})
SHAPE = (6, 5, 7)


def random_sparse(batch_size, c_in, device, density=0.4):
    occ = torch.rand(batch_size, *SHAPE) < density  # dense enough that grid edges are always hit
    indices = occ.nonzero().int()                   # (N, 4): batch, x, y, z
    return indices.to(device), torch.randn(len(indices), c_in, device=device)


def dense_reference(conv, indices, feats, batch_size):
    # Scatter to a dense grid, run conv3d (cross-correlation), read back at the active sites.
    c_in = feats.shape[1]
    grid = feats.new_zeros(batch_size, c_in, *SHAPE)
    b, x, y, z = indices.long().unbind(1)
    grid[b, :, x, y, z] = feats
    w = conv.weight.permute(0, 4, 1, 2, 3)          # (out, k0, k1, k2, in) -> (out, in, k0, k1, k2)
    d = conv.dilation[0]
    dense = F.conv3d(grid, w, conv.bias, padding=d * (w.shape[-1] // 2), dilation=d)
    return dense[b, :, x, y, z]


@pytest.mark.parametrize("device", DEVICES)
@pytest.mark.parametrize("k,dilation", [(3, 1), (5, 1), (3, 2)])
def test_subm_conv_matches_dense(device, k, dilation):
    torch.manual_seed(0)
    indices, feats = random_sparse(2, 4, device)
    conv = spconv.SubMConv3d(4, 6, kernel_size=k, padding=1, dilation=dilation, bias=True).to(device)
    torch.nn.init.normal_(conv.bias)
    x = spconv.SparseConvTensor(features=feats, indices=indices, spatial_shape=list(SHAPE), batch_size=2)
    with torch.no_grad():
        out = conv(x)
        ref = dense_reference(conv, indices, feats, 2)
    assert torch.equal(out.indices, indices)
    assert out.features.shape == (len(indices), 6)
    assert torch.allclose(out.features, ref, atol=1e-4)


def test_weight_layout_matches_spconv2_checkpoints():
    conv = spconv.SubMConv3d(9, 32, kernel_size=5, bias=False, indice_key="stem")
    assert conv.weight.shape == (32, 5, 5, 5, 9)  # spconv 2.x KRSC: (out, *kernel, in)
    assert conv.bias is None
    conv.load_state_dict({"weight": torch.randn(32, 5, 5, 5, 9)}, strict=True)


def test_replace_feature_shares_geometry():
    indices, feats = random_sparse(1, 3, "cpu")
    x = spconv.SparseConvTensor(features=feats, indices=indices, spatial_shape=list(SHAPE), batch_size=1)
    y = x.replace_feature(feats * 2)
    assert y is not x and y.indices is x.indices
    assert (y.spatial_shape, y.batch_size) == (x.spatial_shape, x.batch_size)
    assert torch.equal(y.features, feats * 2) and torch.equal(x.features, feats)


def test_standin_import_matches_upstream_usage():
    for k in [k for k in sys.modules if k == "spconv" or k.startswith("spconv.")]:
        sys.modules.pop(k)
    install_module_finder({}, ["spconv"])
    sp = importlib.import_module("spconv.pytorch")  # UniRig: `import spconv.pytorch as spconv`
    assert sp.modules.is_spconv_module(sp.SubMConv3d(2, 2, 3))
    assert not sp.modules.is_spconv_module(torch.nn.Linear(2, 2))
    for k in [k for k in sys.modules if k == "spconv" or k.startswith("spconv.")]:
        sys.modules.pop(k)
