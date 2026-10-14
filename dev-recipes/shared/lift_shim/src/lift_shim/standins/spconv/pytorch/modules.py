import torch.nn as nn


class SparseModule(nn.Module):
    """Marker base: PointSequential-style containers route SparseConvTensors to these."""


def is_spconv_module(module) -> bool:
    return isinstance(module, SparseModule)
