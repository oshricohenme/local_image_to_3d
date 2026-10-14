"""Pixal3D launcher (TencentARC/Pixal3D @ f7cf384, through lift_shim).

image_to_3d calls upstream's inference.run_inference and image_set_to_3d calls inference_mv.run_inference, with
every setting passed as a keyword argument. Each module's init_pipeline is wrapped in lru_cache(maxsize=1), so a
loaded pipeline is reused by the next job and only rebuilt when model_path / low_vram change. Upstream is
imported here rather than in load(), so the installer's smoke check (`lift_worker --check`) imports it too.
The multi-view camera files come from this recipe's files/pixal_views.py.
"""
import functools
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "files"))  # this recipe's own helpers

import inference  # noqa: E402  upstream, unmodified: repo/ is on sys.path
import inference_mv  # noqa: E402
import o_voxel.postprocess  # noqa: E402
import trimesh  # noqa: E402
from lift_worker.stages import announce  # noqa: E402
from pixal3d.pipelines.pixal3d_image_to_3d import Pixal3DImageTo3DPipeline  # noqa: E402
from pixal_views import views_folder  # noqa: E402

# Each step upstream runs, named as it starts; the decoders and the GLB build have no progress bar of their own.
announce(Pixal3DImageTo3DPipeline, {
    "preprocess_image": "Removing the background",
    "sample_sparse_structure": "Laying out the rough 3D shape",
    "sample_shape_slat": "Sculpting the shape's detail",
    "sample_shape_slat_cascade": "Sculpting the shape's detail at high resolution",
    "sample_tex_slat": "Painting the texture",
    "decode_shape_slat": "Decoding the 3D shape (no progress bar; this can take a few minutes)",
    "decode_tex_slat": "Decoding the texture (no progress bar)",
})
announce(o_voxel.postprocess, {"to_glb": "Building the textured GLB: cleaning the mesh, unwrapping UVs, baking colours"})
announce(trimesh.Trimesh, {"export": "Saving the GLB file"})

for _module in (inference, inference_mv):
    _module.init_pipeline = functools.lru_cache(maxsize=1)(_module.init_pipeline)

LAYOUT_SETTINGS = ("views", "orbit_elevation_deg", "orbit_fov_deg", "orbit_distance")


def run(state, job):
    settings = dict(job.settings)
    out = os.path.join(job.out_dir, "mesh.glb")
    if job.task == "image_to_3d":
        inference.run_inference(image_path=job.inputs["image"], output_path=out, **settings)
    else:
        layout = {key: settings.pop(key) for key in LAYOUT_SETTINGS}
        settings["num_views"] = settings["num_views"] or None  # 0 → upstream's default, all views
        example = os.path.join(os.path.dirname(os.path.abspath(inference_mv.__file__)), "assets/mv_images/example/transforms.json")
        views_dir = views_folder(job.inputs["views"], layout, job.out_dir, example)
        inference_mv.run_inference(views_dir=views_dir, output_path=out, **settings)
    if not os.path.isfile(out):
        raise RuntimeError(f"Pixal3D finished without writing {out}")
    return [out]
