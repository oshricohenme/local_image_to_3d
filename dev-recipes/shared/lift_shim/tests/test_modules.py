import importlib
import sys
import types

from lift_shim.modules import install_module_finder


def test_alias_resolves_submodules(tmp_path, monkeypatch):
    pkg = tmp_path / "realpkg"
    (pkg / "torch").mkdir(parents=True)
    (pkg / "__init__.py").write_text("NAME = 'real'\n")
    (pkg / "torch" / "__init__.py").write_text("def RasterizeGLContext(): return 'ok'\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    install_module_finder({"fakealias": "realpkg"}, [])
    mod = importlib.import_module("fakealias.torch")
    assert mod.RasterizeGLContext() == "ok"
    assert importlib.import_module("fakealias").NAME == "real"


def test_real_module_wins(tmp_path, monkeypatch):
    (tmp_path / "flash_attn").mkdir()
    (tmp_path / "flash_attn" / "__init__.py").write_text("REAL = True\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    sys.modules.pop("flash_attn", None)
    install_module_finder({}, ["flash_attn"])
    assert importlib.import_module("flash_attn").REAL is True
    sys.modules.pop("flash_attn", None)


def test_standin_used_when_missing():
    sys.modules.pop("flash_attn", None)
    install_module_finder({}, ["flash_attn"])
    mod = importlib.import_module("flash_attn")
    assert isinstance(mod, types.ModuleType)
    assert callable(mod.flash_attn_func)
    sys.modules.pop("flash_attn", None)
