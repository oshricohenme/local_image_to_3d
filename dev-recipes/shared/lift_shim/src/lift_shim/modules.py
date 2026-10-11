"""Meta-path finder for module aliases and stand-ins.

Inserted first so submodules of an alias (alias.torch) resolve through it rather than being
re-loaded from the real package's __path__ under the alias name; a really-installed package
of the same name still wins (checked via PathFinder)."""
from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
import importlib.util
import sys

_STANDINS = {"flash_attn": "lift_shim.standins.flash_attn", "spconv": "lift_shim.standins.spconv"}


_IDENTITY = ("__name__", "__spec__", "__package__", "__loader__", "__file__", "__path__", "__cached__")


class _AliasLoader(importlib.abc.Loader):
    """Hands back the real module; restores its identity attrs, which the import system overwrites."""

    def __init__(self, target: str):
        self.target = target
        self._saved: dict = {}

    def create_module(self, spec):
        module = importlib.import_module(self.target)
        self._saved = {k: getattr(module, k) for k in _IDENTITY if hasattr(module, k)}
        return module

    def exec_module(self, module):
        for k, v in self._saved.items():  # already executed by import_module; undo the renaming
            setattr(module, k, v)


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self):
        self.aliases: dict[str, str] = {}

    def find_spec(self, name, path=None, target=None):
        root, _, rest = name.partition(".")
        if root not in self.aliases:
            return None
        if importlib.machinery.PathFinder.find_spec(root) is not None:
            return None  # a real package by this name is installed: it wins
        real = self.aliases[root] + ("." + rest if rest else "")
        real_spec = importlib.util.find_spec(real)
        if real_spec is None:
            return None
        is_pkg = real_spec.submodule_search_locations is not None
        return importlib.machinery.ModuleSpec(name, _AliasLoader(real), is_package=is_pkg)


_finder = _Finder()


class _PostImport(importlib.abc.MetaPathFinder):
    """Wraps a module's own loader so callbacks run right after the module finishes executing."""

    def __init__(self):
        self.pending: dict[str, list] = {}

    def find_spec(self, name, path=None, target=None):
        callbacks = self.pending.pop(name, None)
        if callbacks is None:
            return None
        spec = importlib.util.find_spec(name)  # re-enters this finder, but name is no longer pending
        if spec is None or spec.loader is None:
            return spec
        original_exec = spec.loader.exec_module

        def exec_module(module):
            original_exec(module)
            for fn in callbacks:
                fn(module)

        spec.loader.exec_module = exec_module
        return spec


_post_import = _PostImport()


def after_import(name: str, fn) -> None:
    """Run fn(module) once `name` has been imported (immediately if it already is)."""
    if name in sys.modules:
        fn(sys.modules[name])
        return
    _post_import.pending.setdefault(name, []).append(fn)
    if _post_import not in sys.meta_path:
        sys.meta_path.insert(0, _post_import)


def install_module_finder(aliases: dict[str, str], standins: list[str]) -> None:
    for name in standins:
        if name not in _STANDINS:
            raise ValueError(f"lift_shim: unknown stand-in {name!r}; known: {sorted(_STANDINS)}")
        _finder.aliases.setdefault(name, _STANDINS[name])
    for name, target in aliases.items():
        _finder.aliases[name] = target
    if _finder not in sys.meta_path:
        sys.meta_path.insert(0, _finder)
