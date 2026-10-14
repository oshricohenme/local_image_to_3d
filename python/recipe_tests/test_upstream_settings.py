"""The recipes' settings against the real upstream code: every keyword argument / flag, with upstream's default.

Needs upstream checkouts, so it is skipped unless LIFT_MODELS_DIR points at a Lift `models/` folder with
pixal3d, unirig and trellis2-mac installed (each has repo/). Run it after changing any pin.
"""
import ast
import os
import re
from pathlib import Path

import pytest

from conftest import defaults

MODELS = os.environ.get("LIFT_MODELS_DIR")
pytestmark = pytest.mark.skipif(not MODELS, reason="set LIFT_MODELS_DIR to a models/ folder with the real recipes installed")


def repo(recipe):
    return Path(MODELS) / recipe / "repo"


def keyword_defaults(path, function, constants):
    tree = ast.parse(Path(path).read_text())
    fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == function)
    args = fn.args.args[len(fn.args.args) - len(fn.args.defaults):]
    return {a.arg: constants[d.id] if isinstance(d, ast.Name) else ast.literal_eval(d) for a, d in zip(args, fn.args.defaults)}


@pytest.mark.parametrize("module, task, lift_only", [
    ("inference", "image_to_3d", set()),
    ("inference_mv", "image_set_to_3d", {"views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance"}),
])
def test_pixal3d_settings_are_run_inference_keywords(module, task, lift_only):
    upstream = keyword_defaults(repo("pixal3d") / f"{module}.py", "run_inference",
                                {"MODEL_PATH": "TencentARC/Pixal3D", "CONFIG_FILE": "pipeline_mv.json"})
    if "num_views" in upstream:
        assert upstream["num_views"] is None
        upstream["num_views"] = 0  # Lift's 0 = upstream's None (all views)
    ours = {k: v for k, v in defaults("pixal3d", task).items() if k not in lift_only}
    assert ours == upstream


def test_unirig_settings_are_the_script_flags():
    ours = defaults("unirig", "rig")
    for script, renames in [("generate_skeleton", {"force_override": "skeleton_force_override"}),
                            ("generate_skin", {"force_override": "skin_force_override"}), ("merge", {})]:
        text = (repo("unirig") / f"launch/inference/{script}.sh").read_text()
        flags = re.findall(r"^\s+--(\w+)\) ", text, re.M)
        values = {k: a or b for k, a, b in re.findall(r'^(\w+)=(?:"([^"]*)"|(\S+))', text, re.M)}
        for flag in flags:
            if flag in {"input", "output", "input_dir", "output_dir", "source", "target"}:
                continue  # Lift passes the job's files
            value = ours[renames.get(flag, flag)]
            assert (str(value).lower() if isinstance(value, bool) else str(value)) == values[flag], (script, flag)


def test_trellis_settings_are_generate_py_options():
    text = (repo("trellis2-mac") / "generate.py").read_text()
    options = {o.replace("-", "_") for o in re.findall(r'add_argument\(\s*"--([\w-]+)"', text)} - {"output"}
    assert set(defaults("trellis2-mac", "image_to_3d")) == options
