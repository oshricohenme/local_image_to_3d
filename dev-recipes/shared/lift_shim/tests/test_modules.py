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


def test_alias_keeps_real_module_identity(tmp_path, monkeypatch):
    # Regression: importing via an alias must not rename the real module (breaks its relative imports).
    pkg = tmp_path / "realpkg2"
    (pkg / "torch").mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    (pkg / "torch" / "__init__.py").write_text("")
    monkeypatch.syspath_prepend(str(tmp_path))
    install_module_finder({"alias2": "realpkg2"}, [])
    aliased = importlib.import_module("alias2.torch")
    real = importlib.import_module("realpkg2.torch")
    assert aliased is real
    assert (real.__name__, real.__spec__.name, real.__package__) == ("realpkg2.torch",) * 3


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


def test_standin_submodule_resolves():
    for k in [k for k in sys.modules if k == "flash_attn" or k.startswith("flash_attn.")]:
        sys.modules.pop(k)
    install_module_finder({}, ["flash_attn"])
    from flash_attn.modules.mha import MHA
    import flash_attn
    assert MHA.__module__ == "lift_shim.standins.flash_attn.modules.mha"
    assert flash_attn.__version__.endswith("+lift_shim")
    for k in [k for k in sys.modules if k == "flash_attn" or k.startswith("flash_attn.")]:
        sys.modules.pop(k)


def test_after_import_runs_once_module_has_executed(tmp_path, monkeypatch):
    from lift_shim.modules import after_import
    (tmp_path / "hookedmod.py").write_text("VALUE = 1\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    seen = []
    after_import("hookedmod", lambda m: seen.append(m.VALUE))
    assert seen == []  # lazy: nothing until the import
    import hookedmod  # noqa: F401
    assert seen == [1]
    after_import("hookedmod", lambda m: seen.append("now"))  # already imported → immediate
    assert seen == [1, "now"]
    sys.modules.pop("hookedmod")


def test_after_import_survives_find_spec_probe(tmp_path, monkeypatch):
    # Regression: importlib.util.find_spec(name) before the import (transformers probes torch this way)
    # consumed the callbacks onto a spec that never executed, so they never ran.
    from lift_shim.modules import after_import
    (tmp_path / "probedmod.py").write_text("VALUE = 2\n")
    monkeypatch.syspath_prepend(str(tmp_path))
    seen = []
    after_import("probedmod", lambda m: seen.append(m.VALUE))
    assert importlib.util.find_spec("probedmod") is not None
    assert seen == []
    import probedmod  # noqa: F401
    assert seen == [2]
    sys.modules.pop("probedmod")
    import probedmod  # noqa: F401,F811 - re-import must not fire again
    assert seen == [2]
    sys.modules.pop("probedmod")
