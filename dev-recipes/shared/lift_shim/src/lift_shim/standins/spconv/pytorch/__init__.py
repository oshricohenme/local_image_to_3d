"""spconv.pytorch subset: SparseConvTensor + SubMConv3d, pure torch (cpu and mps).

Matches spconv 2.x (traveller59/spconv master, checked 2026-10):
- weight layout: constants.ALL_WEIGHT_IS_KRSC = True, so conv.py allocates
  `weight_shape = [out_channels, *kernel_size, in_channels]` — checkpoints load as-is.
- kernel offsets: csrc/sparse/indices.py ConvOutLocIter walks the kernel row-major (last spatial
  dim fastest) and pairs input `in = out - padding + r * dilation` with subm padding = (k // 2) * dilation,
  i.e. cross-correlation exactly like F.conv3d. Spatial dims follow the index columns (1, 2, 3).
"""
from __future__ import annotations

import math

import torch
import torch.nn as nn

from . import modules
from .modules import SparseModule

__all__ = ["SparseConvTensor", "SubMConv3d", "modules"]


class SparseConvTensor:
    def __init__(self, features, indices, spatial_shape, batch_size, **_):
        self.features, self.indices = features, indices  # (N, C); (N, 4) int: batch, d0, d1, d2
        self.spatial_shape, self.batch_size = list(spatial_shape), batch_size

    def replace_feature(self, feature):
        return SparseConvTensor(feature, self.indices, self.spatial_shape, self.batch_size)


def _triple(v):
    return tuple(v) if isinstance(v, (list, tuple)) else (v,) * 3


def _subm_neighbors(indices, spatial_shape, kernel_size, dilation):
    """(K, N) row of the active site at each kernel offset, -1 where the neighbor is inactive."""
    idx = indices.long()
    shape = torch.tensor(spatial_shape, device=idx.device)
    strides = torch.tensor([shape[0] * shape[1] * shape[2], shape[1] * shape[2], shape[2], 1], device=idx.device)
    keys = idx @ strides
    sorted_keys, order = keys.sort(stable=True)  # duplicate sites: searchsorted hits the first occurrence
    r = [torch.arange(k, device=idx.device) - k // 2 for k in kernel_size]
    offsets = torch.stack(torch.meshgrid(*r, indexing="ij"), -1).reshape(-1, 3)  # row-major, like spconv
    offsets = offsets * torch.tensor(dilation, device=idx.device)
    nb = idx[None, :, 1:] + offsets[:, None, :]                                  # (K, N, 3)
    inside = ((nb >= 0) & (nb < shape)).all(-1)  # out-of-grid coords would alias other keys
    nb_keys = idx[None, :, 0] * strides[0] + nb @ strides[1:]
    pos = torch.searchsorted(sorted_keys, nb_keys).clamp_(max=len(keys) - 1)
    hit = inside & (sorted_keys[pos] == nb_keys)
    return torch.where(hit, order[pos], -1)


class SubMConv3d(SparseModule):
    """Submanifold conv: output sites == input sites; padding/stride ignored, as in spconv's subm path."""

    def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0, dilation=1, groups=1,
                 bias=True, indice_key=None, algo=None, fp32_accum=None, large_kernel_fast_algo=False,
                 name=None):
        super().__init__()
        self.kernel_size, self.dilation = _triple(kernel_size), _triple(dilation)
        if any(k % 2 == 0 for k in self.kernel_size):
            raise ValueError("lift_shim spconv stand-in: subm only supports odd kernel sizes (as spconv)")
        if groups != 1:
            raise NotImplementedError("lift_shim spconv stand-in: groups != 1")
        self.in_channels, self.out_channels, self.indice_key = in_channels, out_channels, indice_key
        self.weight = nn.Parameter(torch.empty(out_channels, *self.kernel_size, in_channels))
        self.bias = nn.Parameter(torch.empty(out_channels)) if bias else None
        fan_in = in_channels * math.prod(self.kernel_size)
        nn.init.kaiming_uniform_(self.weight.data.view(out_channels, fan_in), a=math.sqrt(5))
        if self.bias is not None:
            nn.init.uniform_(self.bias, -1 / math.sqrt(fan_in), 1 / math.sqrt(fan_in))

    def forward(self, x: SparseConvTensor) -> SparseConvTensor:
        # ponytail: neighbor maps are rebuilt per call (spconv caches them per indice_key); cache on
        # the tensor if the sort/searchsorted shows up in profiles next to the matmuls
        nbr = _subm_neighbors(x.indices, x.spatial_shape, self.kernel_size, self.dilation)
        feats = x.features
        w = self.weight.reshape(self.out_channels, -1, self.in_channels)            # (out, K, in)
        out = feats.new_zeros(len(feats), self.out_channels)
        for k in range(nbr.shape[0]):
            hit = (nbr[k] >= 0).unsqueeze(1)
            out = out + (feats[nbr[k].clamp(min=0)] * hit) @ w[:, k].T
        if self.bias is not None:
            out = out + self.bias
        return x.replace_feature(out)
