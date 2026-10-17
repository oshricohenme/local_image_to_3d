import ast
import json
import math
from pathlib import Path

import pytest

from conftest import upstream_repo, RECIPES, FakeJob, defaults, module

# Upstream's assets/mv_images/example/transforms.json at f7cf384 (the four_view preset copies it).
D = 3.1192049980163574
EXAMPLE = {
    "camera_angle_x": 0.3490658503988659, "mesh_scale": 1.0,
    "frames": [
        {"file_path": "view00_azim000.png", "name": "azim000", "transform_matrix": [[1.0, 0.0, 0.0, 0.0], [0.0, 0.0, -1.0, -D], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view01_azim090.png", "name": "azim090", "transform_matrix": [[0.0, 0.0, 1.0, D], [1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view02_azim180.png", "name": "azim180", "transform_matrix": [[-1.0, 0.0, 0.0, 0.0], [0.0, 0.0, 1.0, D], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
        {"file_path": "view03_azim270.png", "name": "azim270", "transform_matrix": [[0.0, 0.0, -1.0, -D], [-1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]},
    ],
}


@pytest.fixture(autouse=True)
def stage_imports(monkeypatch):
    """Stage announcements must not require the real models in launcher contract tests."""
    import sys

    postprocess = module("o_voxel.postprocess")
    pipelines = module("pixal3d.pipelines")
    fakes = {
        "o_voxel": module("o_voxel", postprocess=postprocess), "o_voxel.postprocess": postprocess,
        "trimesh": module("trimesh", Trimesh=type("Trimesh", (), {})),
        "pixal3d": module("pixal3d", pipelines=pipelines), "pixal3d.pipelines": pipelines,
        "pixal3d.pipelines.pixal3d_image_to_3d": module("pixal3d.pipelines.pixal3d_image_to_3d", Pixal3DImageTo3DPipeline=type("Pipeline", (), {})),
    }
    for name, fake in fakes.items():
        monkeypatch.setitem(sys.modules, name, fake)


def fake_upstream(name, repo, write=True):
    """inference / inference_mv: run_inference calls the module-level init_pipeline the way upstream does."""
    m = module(name, __file__=str(repo / f"{name}.py"), init_calls=[], runs=[])

    def init_pipeline(model_path, *args, low_vram=False):
        m.init_calls.append((model_path, low_vram))
        return object()

    def run_inference(output_path, **kw):
        m.init_pipeline(kw["model_path"], low_vram=kw["low_vram"])
        m.runs.append(kw)
        if write:
            Path(output_path).write_bytes(b"glTF")

    m.init_pipeline, m.run_inference = init_pipeline, run_inference
    return m


@pytest.fixture
def pixal(launcher, tmp_path):
    repo = tmp_path / "repo"
    (repo / "assets/mv_images/example").mkdir(parents=True)
    (repo / "assets/mv_images/example/transforms.json").write_text(json.dumps(EXAMPLE))
    fakes = {"inference": fake_upstream("inference", repo), "inference_mv": fake_upstream("inference_mv", repo)}
    return launcher("pixal3d", fakes), fakes


def job(task, inputs, tmp_path, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob(task, inputs, {**defaults("pixal3d", task), **changes}, out)


def images(folder, *names):
    folder.mkdir()
    for n in names:
        (folder / n).write_bytes(b"png")
    return str(folder)


def test_image_to_3d_passes_every_setting_as_a_keyword(pixal, tmp_path):
    mod, fakes = pixal
    j = job("image_to_3d", {"image": "/in/photo.png"}, tmp_path)
    assert mod.run(None, j) == [f"{j.out_dir}/mesh.glb"]
    (kw,) = fakes["inference"].runs
    assert kw == {"image_path": "/in/photo.png", **defaults("pixal3d", "image_to_3d")}


def test_recipe_only_advertises_a_resolution_below_the_mps_mesh_limit():
    import yaml

    recipe = yaml.safe_load((RECIPES / "pixal3d/recipe.yaml").read_text())
    for task in recipe["tasks"]:
        resolution = next(s for s in task["settings"] if s["key"] == "resolution")
        assert resolution["default"] == 1024
        assert resolution["options"] == [1024]
        assert all(n ** 3 <= 2 ** 31 - 1 for n in resolution["options"])


@pytest.mark.parametrize("task", ["image_to_3d", "image_set_to_3d"])
@pytest.mark.parametrize("resolution", [-1, 1536, None])
@pytest.mark.parametrize("low_vram", [False, True])
def test_unsafe_or_missing_resolution_stops_before_inference(pixal, tmp_path, task, resolution, low_vram):
    mod, fakes = pixal
    inputs = {"image": "/in/photo.png"} if task == "image_to_3d" else {"views": images(tmp_path / "v", "transforms.json")}
    j = job(task, inputs, tmp_path, resolution=resolution, low_vram=low_vram, **({"views": "transforms"} if task == "image_set_to_3d" else {}))
    if resolution is None:
        del j.settings["resolution"]
    with pytest.raises(ValueError, match="1024"):
        mod.run(None, j)
    assert all(not m.init_calls and not m.runs for m in fakes.values())


def test_pipeline_stays_loaded_until_model_path_or_low_vram_change(pixal, tmp_path):
    mod, fakes = pixal
    for low in (False, False, True, False):
        mod.run(None, job("image_to_3d", {"image": "/in/a.png"}, tmp_path, low_vram=low))
    assert fakes["inference"].init_calls == [("TencentARC/Pixal3D", False), ("TencentARC/Pixal3D", True), ("TencentARC/Pixal3D", False)]


def test_missing_output_is_an_error(launcher, tmp_path):
    repo = tmp_path / "repo"
    mod = launcher("pixal3d", {"inference": fake_upstream("inference", repo, write=False), "inference_mv": fake_upstream("inference_mv", repo)})
    with pytest.raises(RuntimeError, match="without writing"):
        mod.run(None, job("image_to_3d", {"image": "/in/a.png"}, tmp_path))


def test_transforms_folder_is_used_as_is_and_layout_settings_stay_in_lift(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "views", "a.png", "transforms.json")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, views="transforms", num_views=3))
    (kw,) = fakes["inference_mv"].runs
    assert kw["views_dir"] == folder and kw["num_views"] == 3
    assert not {"views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance"} & kw.keys()
    expected = {k: v for k, v in defaults("pixal3d", "image_set_to_3d").items() if not k.startswith("orbit_") and k != "views"}
    assert kw == {"views_dir": folder, **expected, "num_views": 3}  # every other setting, with its default


def test_num_views_zero_means_all(pixal, tmp_path):
    mod, fakes = pixal
    mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "transforms.json")}, tmp_path, views="transforms"))
    assert fakes["inference_mv"].runs[0]["num_views"] is None


def test_transforms_layout_without_transforms_json_is_rejected(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="transforms.json"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "a.png")}, tmp_path, views="transforms"))


def test_four_view_writes_upstream_example_cameras_with_your_files(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "v", "left.jpg", "FRONT.png", "back.PNG", "right.webp")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, views="four_view"))
    views_dir = fakes["inference_mv"].runs[0]["views_dir"]
    assert views_dir == f"{tmp_path}/out/views"
    meta = json.loads(Path(views_dir, "transforms.json").read_text())
    assert [f["file_path"] for f in meta["frames"]] == [f"{folder}/{n}" for n in ("FRONT.png", "right.webp", "back.PNG", "left.jpg")]
    assert [f["transform_matrix"] for f in meta["frames"]] == [f["transform_matrix"] for f in EXAMPLE["frames"]]
    assert meta["camera_angle_x"] == EXAMPLE["camera_angle_x"]


def test_four_view_names_the_missing_slots(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="missing: back, left"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "front.png", "right.png")}, tmp_path, views="four_view"))


def test_orbit_of_four_matches_the_upstream_example(pixal, tmp_path):
    mod, fakes = pixal
    folder = images(tmp_path / "v", "1.png", "2.png", "3.png", "4.png", "notes.txt")
    mod.run(None, job("image_set_to_3d", {"views": folder}, tmp_path, views="orbit"))
    meta = json.loads(Path(fakes["inference_mv"].runs[0]["views_dir"], "transforms.json").read_text())
    assert [f["file_path"] for f in meta["frames"]] == [f"{folder}/{n}.png" for n in "1234"]
    assert [f["name"] for f in meta["frames"]] == ["azim000", "azim090", "azim180", "azim270"]
    assert meta["camera_angle_x"] == pytest.approx(EXAMPLE["camera_angle_x"])
    for got, want in zip(meta["frames"], EXAMPLE["frames"]):
        for got_row, want_row in zip(got["transform_matrix"], want["transform_matrix"]):
            assert got_row == pytest.approx(want_row)


def test_orbit_elevation_raises_the_cameras_and_keeps_rotations_orthonormal(pixal, tmp_path):
    import pixal_views  # dev-recipes/pixal3d/files/, put on sys.path by the launcher
    meta = pixal_views.orbit(["a", "b", "c"], elevation_deg=30.0, fov_deg=40.0, distance=2.0)
    assert meta["camera_angle_x"] == pytest.approx(math.radians(40))
    for frame in meta["frames"]:
        m = frame["transform_matrix"]
        assert m[2][3] == pytest.approx(2.0 * math.sin(math.radians(30)))  # camera height
        assert math.dist((0, 0, 0), [m[r][3] for r in range(3)]) == pytest.approx(2.0)
        cols = [[m[r][c] for r in range(3)] for c in range(3)]
        for i in range(3):
            for k in range(3):
                assert sum(a * b for a, b in zip(cols[i], cols[k])) == pytest.approx(1.0 if i == k else 0.0, abs=1e-9)


def test_orbit_needs_images(pixal, tmp_path):
    mod, _ = pixal
    with pytest.raises(ValueError, match="no images"):
        mod.run(None, job("image_set_to_3d", {"views": images(tmp_path / "v", "notes.txt")}, tmp_path, views="orbit"))


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
    upstream = keyword_defaults(upstream_repo("pixal3d") / f"{module}.py", "run_inference",
                                {"MODEL_PATH": "TencentARC/Pixal3D", "CONFIG_FILE": "pipeline_mv.json"})
    if "num_views" in upstream:
        assert upstream["num_views"] is None
        upstream["num_views"] = 0  # Lift's 0 = upstream's None (all views)
    ours = {k: v for k, v in defaults("pixal3d", task).items() if k not in lift_only}
    assert upstream["resolution"] == -1
    upstream["resolution"] = 1024  # Mac decoder limit; Lift deliberately overrides upstream auto.
    assert ours == upstream
