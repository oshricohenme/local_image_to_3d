"""Meta-path finder for module aliases and stand-ins. Appended last: real modules win."""
from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
import importlib.util
import sys

_STANDINS = {"flash_attn": "lift_shim.standins.flash_attn"}


class _AliasLoader(importlib.abc.Loader):
    def __init__(self, target: str):
        self.target = target

    def create_module(self, spec):
        return importlib.import_module(self.target)

    def exec_module(self, module):
        pass  # already executed by import_module


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self):
        self.aliases: dict[str, str] = {}

    def find_spec(self, name, path=None, target=None):
        root, _, rest = name.partition(".")
        if root not in self.aliases:
            return None
        real = self.aliases[root] + ("." + rest if rest else "")
        real_spec = importlib.util.find_spec(real)
        if real_spec is None:
            return None
        is_pkg = real_spec.submodule_search_locations is not None
        return importlib.machinery.ModuleSpec(name, _AliasLoader(real), is_package=is_pkg)


_finder = _Finder()


def install_module_finder(aliases: dict[str, str], standins: list[str]) -> None:
    for name in standins:
        if name not in _STANDINS:
            raise ValueError(f"lift_shim: unknown stand-in {name!r}; known: {sorted(_STANDINS)}")
        _finder.aliases.setdefault(name, _STANDINS[name])
    for name, target in aliases.items():
        _finder.aliases[name] = target
    if _finder not in sys.meta_path:
        sys.meta_path.append(_finder)
