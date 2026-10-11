from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from conftest import FakeJob, defaults, module


class Tensor:
    """Just enough of a torch tensor for the launcher: .cpu(), .numpy(), .float(), .device."""

    def __init__(self, a):
        self.a, self.device = np.asarray(a), "mps"

    def cpu(self):
        return self

    def float(self):
        return self

    def numpy(self):
        return self.a


def mesh_out(verts=8, faces=12, attrs=True):
    return SimpleNamespace(vertices=Tensor(np.zeros((verts, 3))), faces=Tensor(np.zeros((faces, 3), dtype=int)),
                           attrs=Tensor(np.zeros((4, 6))) if attrs else None, coords=Tensor(np.zeros((4, 4))),
                           origin=Tensor(np.zeros(3)), layout={"base_color": slice(0, 3)}, voxel_size=1 / 64)


class Pipeline:
    def __init__(self):
        self.device, self.runs, self.result = None, [], mesh_out()

    def to(self, device):
        self.device = device

    def run(self, img, **kw):
        self.runs.append((img, kw))
        if isinstance(self.result, Exception):
            raise self.result
        return [self.result]


class Glb:
    def export(self, path):
        Path(path).write_bytes(b"glTF")


def fakes(backend="metal"):
    pipeline = Pipeline()
    to_glb_calls = []

    def to_glb(**kw):
        to_glb_calls.append(kw)
        if isinstance(fakes.to_glb_error, Exception):
            raise fakes.to_glb_error
        return Glb()

    fakes.to_glb_error = None
    postprocess = module("o_voxel.postprocess", _BACKEND=backend, _HAS_DR=backend == "metal", _HAS_FLEX_GEMM=True, to_glb=to_glb)
    pil_image = module("PIL.Image", open=lambda p: ("image", p), fromarray=lambda a: SimpleNamespace(save=lambda p: Path(p).write_bytes(b"png")))
    baker = module("backends.texture_baker",
                   uv_unwrap=lambda v, f: (v, f, np.zeros((len(v), 2)), None),
                   bake_texture=lambda *a, **k: (np.zeros((2, 2, 3)), np.zeros((2, 2, 3)), None),
                   export_glb_with_texture=lambda v, f, uv, bc, mr, path: Path(path).write_bytes(b"kdtree"))
    return {
        "flex_gemm": module("flex_gemm"),
        "torch": module("torch", device=lambda name: ("device", name)),
        "o_voxel": module("o_voxel", postprocess=postprocess), "o_voxel.postprocess": postprocess,
        "PIL": module("PIL", Image=pil_image), "PIL.Image": pil_image,
        "trimesh": module("trimesh", Trimesh=lambda vertices, faces: Glb()),
        "fast_simplification": module("fast_simplification"),
        "backends": module("backends"), "backends.texture_baker": baker,
        "trellis2": module("trellis2"), "trellis2.pipelines": module("trellis2.pipelines"),
        "trellis2.pipelines.trellis2_image_to_3d": module(
            "trellis2.pipelines.trellis2_image_to_3d",
            Trellis2ImageTo3DPipeline=SimpleNamespace(from_pretrained=lambda name: (pipeline.__setattr__("name", name), pipeline)[1])),
    }, pipeline, to_glb_calls


@pytest.fixture
def trellis(launcher, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    f, pipeline, to_glb_calls = fakes()
    mod = launcher("trellis2-mac", f)
    return mod, mod.load(SimpleNamespace(repo_dir=str(tmp_path))), to_glb_calls


def job(tmp_path, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob("image_to_3d", {"image": "/in/shoe.png"}, {**defaults("trellis2-mac", "image_to_3d"), **changes}, out)


def test_import_refuses_the_kdtree_fallback(launcher, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    with pytest.raises(RuntimeError, match="KDTree"):
        launcher("trellis2-mac", fakes(backend=None)[0])


def test_load_puts_the_pinned_pipeline_on_mps(trellis):
    _, pipeline, _ = trellis
    assert pipeline.name == "microsoft/TRELLIS.2-4B" and pipeline.device == ("device", "mps")


def test_defaults_map_to_generate_py_and_bake_on_metal(trellis, tmp_path):
    mod, pipeline, to_glb_calls = trellis
    j = job(tmp_path)
    assert mod.run(pipeline, j) == [f"{j.out_dir}/mesh.glb", f"{j.out_dir}/mesh.obj"]
    ((img, kw),) = pipeline.runs
    assert img == ("image", "/in/shoe.png")
    assert kw == {"seed": 42, "pipeline_type": "512", "sparse_structure_sampler_params": {},
                  "shape_slat_sampler_params": {}, "tex_slat_sampler_params": {}}
    ((bake,),) = [tuple(to_glb_calls)]
    assert bake["texture_size"] == 1024 and bake["decimation_target"] == 12
    assert bake["aabb"] == [[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]]
    obj = Path(j.out_dir, "mesh.obj").read_text().splitlines()
    assert sum(l.startswith("v ") for l in obj) == 8 and sum(l.startswith("f ") for l in obj) == 12


def test_steps_override_all_three_phases(trellis, tmp_path):
    mod, pipeline, _ = trellis
    mod.run(pipeline, job(tmp_path, steps=8, pipeline_type="1024_cascade", seed=7))
    kw = pipeline.runs[0][1]
    assert kw["seed"] == 7 and kw["pipeline_type"] == "1024_cascade"
    assert kw["sparse_structure_sampler_params"] == kw["shape_slat_sampler_params"] == kw["tex_slat_sampler_params"] == {"steps": 8}


def test_no_texture_exports_geometry_without_baking(trellis, tmp_path):
    mod, pipeline, to_glb_calls = trellis
    j = job(tmp_path, no_texture=True)
    mod.run(pipeline, j)
    assert to_glb_calls == [] and Path(j.out_dir, "mesh.glb").read_bytes() == b"glTF"


def test_metal_bake_failure_falls_back_to_kdtree_like_generate_py(trellis, tmp_path):
    mod, pipeline, _ = trellis
    fakes.to_glb_error = RuntimeError("command buffer failed")
    j = job(tmp_path)
    mod.run(pipeline, j)
    assert Path(j.out_dir, "mesh.glb").read_bytes() == b"kdtree" and Path(j.out_dir, "mesh_basecolor.png").exists()


@pytest.mark.parametrize("error", [IndexError("max(): Expected reduction dim 0 to have non-zero size"),
                                   AssertionError("BVH needs at least 8 triangles, got 0")])
def test_watchdog_signatures_become_trellis_mac_advice(trellis, tmp_path, error):
    mod, pipeline, _ = trellis
    pipeline.result = error
    with pytest.raises(RuntimeError, match="GPU watchdog"):
        mod.run(pipeline, job(tmp_path))


def test_empty_mesh_is_the_watchdog_too(trellis, tmp_path):
    mod, pipeline, _ = trellis
    pipeline.result = mesh_out(verts=0, faces=0)
    with pytest.raises(RuntimeError, match="GPU watchdog"):
        mod.run(pipeline, job(tmp_path))


def test_other_errors_pass_through(trellis, tmp_path):
    mod, pipeline, _ = trellis
    pipeline.result = IndexError("list index out of range")
    with pytest.raises(IndexError, match="list index"):
        mod.run(pipeline, job(tmp_path))
