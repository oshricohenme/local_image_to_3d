"""Helpers: load a recipe's launcher.py with fake upstream modules, and a stand-in for lift_worker's Job."""
import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest
import yaml

RECIPES = Path(__file__).resolve().parent


class FakeJob:
    """The launcher contract's job: id, step, task, inputs, settings, out_dir, cancelled, stage()."""

    def __init__(self, task, inputs, settings, out_dir):
        self.id, self.step, self.task = "job-1", 0, task
        self.inputs, self.settings, self.out_dir = inputs, settings, str(out_dir)
        self.cancelled = False
        self.stages = []

    def stage(self, name, fraction=None):
        self.stages.append((name, fraction))


def defaults(recipe, task):
    """The task's settings as Lift sends them when the caller changes nothing."""
    data = yaml.safe_load((RECIPES / recipe / "recipe.yaml").read_text())
    task = next(t for t in data["tasks"] if t["id"] == task)
    return {s["key"]: s["default"] for s in task["settings"]}


def module(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    return m


@pytest.fixture
def launcher(monkeypatch):
    """launcher("pixal3d", {"inference": fake, ...}) imports dev-recipes/pixal3d/launcher.py against the fakes."""

    monkeypatch.setattr(sys, "path", list(sys.path))  # launchers may extend sys.path at import
    before = set(sys.modules)

    def load(recipe, fakes):
        for name, fake in fakes.items():
            monkeypatch.setitem(sys.modules, name, fake)
        spec = importlib.util.spec_from_file_location(f"launcher_{recipe.replace('-', '_')}", RECIPES / recipe / "launcher.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    yield load
    for name in set(sys.modules) - before:  # a recipe's files/ helpers bind to this test's fakes: reload them next time
        if str(getattr(sys.modules[name], "__file__", "") or "").startswith(str(RECIPES)):
            del sys.modules[name]


def upstream_repo(recipe):
    """Opt-in contracts against the installed upstream checkout, without importing models."""
    models = os.environ.get("LIFT_MODELS_DIR")
    if not models:
        pytest.skip("set LIFT_MODELS_DIR to check installed upstream settings")
    return Path(models) / recipe / "repo"
