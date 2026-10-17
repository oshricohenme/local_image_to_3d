from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from conftest import upstream_repo, FakeJob, defaults, module


class Tensor:
    """Just enough of a torch tensor for the launcher: .detach().cpu().numpy() or .numpy()."""

    def __init__(self, a):
        self.a = np.asarray(a)

    def detach(self):
        return self

    def cpu(self):
        return self

    def numpy(self):
        return self.a


class Mesh:
    def __init__(self, verts=8, faces=12):
        self.vertices, self.faces = Tensor(np.zeros((verts, 3))), Tensor(np.zeros((faces, 3), dtype=int))
        self.exported = []

    def export(self, path):
        self.exported.append(path)
        Path(path).write_bytes(b"glTF")


class ShapePipeline:
    def __init__(self):
        self.runs, self.result, self._lift_paint = [], Mesh(), None

    def __call__(self, **kw):
        self.runs.append(kw)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class PaintPipeline:
    def __init__(self):
        self.runs, self.loaded = [], None

    def __call__(self, mesh, image):
        self.runs.append((mesh, image))
        return mesh


def fakes(shape, paint):
    def shape_from(model_path, **kw):
        shape.loaded = {"model_path": model_path, **kw}
        return shape

    def paint_from(model_path, **kw):
        paint.loaded = {"model_path": model_path, **kw}
        return paint

    return {
        "torch": module("torch", float16="fp16"),
        "PIL": module("PIL"), "PIL.Image": module("PIL.Image", open=lambda p: ("image", p)),
        "hy3dgen": module("hy3dgen"),
        "hy3dgen.shapegen": module("hy3dgen.shapegen"),
        "hy3dgen.shapegen.pipelines": module(
            "hy3dgen.shapegen.pipelines",
            Hunyuan3DDiTFlowMatchingPipeline=SimpleNamespace(from_pretrained=shape_from)),
        "hy3dgen.texgen": module("hy3dgen.texgen"),
        "hy3dgen.texgen.pipelines": module(
            "hy3dgen.texgen.pipelines",
            Hunyuan3DPaintPipeline=SimpleNamespace(from_pretrained=paint_from)),
    }


@pytest.fixture
def hy3d(launcher, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    shape, paint = ShapePipeline(), PaintPipeline()
    mod = launcher("hunyuan3d2", fakes(shape, paint))
    return mod, mod.load(SimpleNamespace(repo_dir=str(tmp_path))), shape, paint


def job(tmp_path, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob("image_to_3d", {"image": "/in/shoe.png"},
                   {**defaults("hunyuan3d2", "image_to_3d"), **changes}, out)


def test_load_puts_the_shape_pipeline_on_mps_and_skips_the_texture_models(hy3d):
    _, _, shape, paint = hy3d
    assert shape.loaded == {"model_path": "tencent/Hunyuan3D-2", "device": "mps", "dtype": "fp16",
                            "use_safetensors": True, "variant": "fp16", "subfolder": "hunyuan3d-dit-v2-0"}
    assert paint.loaded is None and paint.runs == []  # texture models load lazily


def test_defaults_mirror_the_readme_quickstart(hy3d, tmp_path):
    mod, _, shape, paint = hy3d
    j = job(tmp_path)
    assert mod.run(shape, j) == [f"{j.out_dir}/mesh.glb", f"{j.out_dir}/mesh.obj"]
    (kw,) = shape.runs
    assert kw == {"image": ("image", "/in/shoe.png"), "num_inference_steps": 50,
                  "guidance_scale": 5.0, "octree_resolution": 256, "enable_pbar": True}
    ((mesh, image),) = paint.runs  # texture is on by default
    assert image == ("image", "/in/shoe.png")
    obj = Path(j.out_dir, "mesh.obj").read_text().splitlines()
    assert sum(l.startswith("v ") for l in obj) == 8 and sum(l.startswith("f ") for l in obj) == 12
    assert Path(j.out_dir, "mesh.glb").read_bytes() == b"glTF"


def test_settings_override_the_quickstart_args(hy3d, tmp_path):
    mod, _, shape, _ = hy3d
    mod.run(shape, job(tmp_path, steps=25, guidance=7.5, octree_resolution=384))
    kw = shape.runs[0]
    assert kw["num_inference_steps"] == 25 and kw["guidance_scale"] == 7.5 and kw["octree_resolution"] == 384


def test_shape_only_never_loads_or_runs_the_texture_models(hy3d, tmp_path):
    mod, _, shape, paint = hy3d
    j = job(tmp_path, texture=False)
    mod.run(shape, j)
    assert paint.loaded is None and paint.runs == []
    assert shape.runs and Path(j.out_dir, "mesh.glb").exists()


def test_the_texture_models_load_once_across_jobs(hy3d, tmp_path):
    mod, _, shape, paint = hy3d
    mod.run(shape, job(tmp_path))
    mod.run(shape, job(tmp_path))
    assert paint.loaded == {"model_path": "tencent/Hunyuan3D-2",
                            "subfolder": "hunyuan3d-paint-v2-0-turbo"}  # loaded once, not per job
    assert len(paint.runs) == 2 and len(shape.runs) == 2


def test_oom_becomes_mac_advice(hy3d, tmp_path):
    mod, _, shape, _ = hy3d
    shape.result = RuntimeError("MPS backend out of memory: requested to allocate")
    with pytest.raises(RuntimeError, match="ran out of memory"):
        mod.run(shape, job(tmp_path))


def test_other_errors_pass_through(hy3d, tmp_path):
    mod, _, shape, _ = hy3d
    shape.result = IndexError("list index out of range")
    with pytest.raises(IndexError, match="list index"):
        mod.run(shape, job(tmp_path))


def test_installed_repo_is_fully_patched():
    """With LIFT_MODELS_DIR set: the install's exact-string patches leave no CUDA surface behind."""
    repo = upstream_repo("hunyuan3d2")
    kern = "hy3dgen/texgen/custom_rasterizer/lib/custom_rasterizer_kernel"
    assert "cuda" not in (repo / f"{kern}/rasterizer.h").read_text().lower()
    assert "rasterize_image_gpu" not in (repo / f"{kern}/rasterizer.cpp").read_text()
    assert "CUDAExtension" not in (repo / "hy3dgen/texgen/custom_rasterizer/setup.py").read_text()
    assert "'cuda'" not in (repo / "hy3dgen/texgen/pipelines.py").read_text()
    assert "'cuda'" not in (repo / "hy3dgen/texgen/hunyuanpaint/pipeline.py").read_text()
    assert '"cuda"' not in (repo / "hy3dgen/texgen/hunyuanpaint/pipeline.py").read_text()
    # render.py is in the custom_rasterizer package folder; its patch moves the raster onto the CPU.
    render = (repo / "hy3dgen/texgen/custom_rasterizer/custom_rasterizer/render.py").read_text()
    assert "rasterize_image(pos[0].cpu()" in render
    assert "findices.to(pos.device)" in render
