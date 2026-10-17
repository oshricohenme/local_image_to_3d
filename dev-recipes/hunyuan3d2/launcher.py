"""Hunyuan3D 2.0 launcher (Tencent-Hunyuan/Hunyuan3D-2 @ f8db630, weights tencent/Hunyuan3D-2 fp16).

The README quickstart keeps its whole flow inline, so this file mirrors it: the shape pipeline loads once
in load(), then per job its __call__ with the demo's arguments (num_inference_steps, guidance_scale,
octree_resolution), optional texture painting via Hunyuan3DPaintPipeline — loaded lazily, only when a
job asks for a texture — and a trimesh GLB export plus a hand-written OBJ. The install step already
patched every hardcoded 'cuda' onto 'mps' or the CPU raster path. Re-check against the README quickstart
whenever the pin moves.
"""
import os
import sys
import time

# Before torch is imported anywhere: lets MPS fall back to the CPU for the few ops it lacks.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

REPO = os.getcwd()  # lift_worker runs in models/hunyuan3d2/repo, the upstream checkout
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "files"))  # recipe helpers, if any

import torch  # noqa: E402
from lift_worker.stages import announce  # noqa: E402

OOM_HELP = ("Your Mac ran out of memory generating this model. Close other apps, lower 'Mesh detail', "
            "or switch off 'Paint texture', then try again.")


def load(ctx):
    from hy3dgen.shapegen.pipelines import Hunyuan3DDiTFlowMatchingPipeline

    announce(Hunyuan3DDiTFlowMatchingPipeline, {"__call__": "Generating the shape"})
    print("[Stage] Loading Hunyuan3D 2.0 shape model")
    pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        "tencent/Hunyuan3D-2", device="mps", dtype=torch.float16,
        use_safetensors=True, variant="fp16", subfolder="hunyuan3d-dit-v2-0")
    pipeline._lift_paint = None
    return pipeline


def _paint_pipeline(pipeline):
    """The texture models (delight + multiview paint, ~8 GB more) load only when a job wants them."""
    if pipeline._lift_paint is None:
        from hy3dgen.texgen.pipelines import Hunyuan3DPaintPipeline

        announce(Hunyuan3DPaintPipeline, {"__call__": "Painting the texture"})
        print("[Stage] Loading the texture models (delight and multiview; no progress bar)")
        pipeline._lift_paint = Hunyuan3DPaintPipeline.from_pretrained(
            "tencent/Hunyuan3D-2", subfolder="hunyuan3d-paint-v2-0-turbo")
    return pipeline._lift_paint


def run(pipeline, job):
    from PIL import Image

    s = job.settings
    image = Image.open(job.inputs["image"])
    t0 = time.time()
    try:
        mesh = pipeline(
            image=image,
            num_inference_steps=int(s.get("steps", 50)),
            guidance_scale=float(s.get("guidance", 5.0)),
            octree_resolution=int(s.get("octree_resolution", 256)),
            enable_pbar=True,
        )
        if s.get("texture", True):
            mesh = _paint_pipeline(pipeline)(mesh, image)
    except RuntimeError as e:
        if "out of memory" in str(e).lower() or "MPS backend" in str(e):
            raise RuntimeError(OOM_HELP) from e
        raise
    verts, faces = mesh.vertices, mesh.faces
    if hasattr(verts, "detach"):  # torch tensors on MPS
        verts, faces = verts.detach().cpu().numpy(), faces.detach().cpu().numpy()
    elif hasattr(verts, "numpy"):
        verts, faces = verts.numpy(), faces.numpy()
    print(f"Mesh: {verts.shape[0]:,} vertices, {faces.shape[0]:,} triangles; generation {time.time() - t0:.1f}s")

    glb_path = os.path.join(job.out_dir, "mesh.glb")
    print("[Stage] Saving the GLB file")
    mesh.export(glb_path)
    obj_path = os.path.join(job.out_dir, "mesh.obj")  # the README demo also writes the raw geometry as OBJ
    print(f"[Stage] Writing the OBJ file ({verts.shape[0]:,} vertices; no progress bar)", flush=True)
    with open(obj_path, "w") as f:
        for v in verts:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        for face in faces:
            f.write(f"f {face[0] + 1} {face[1] + 1} {face[2] + 1}\n")
    return [glb_path, obj_path]
