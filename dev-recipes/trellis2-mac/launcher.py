"""trellis2-mac launcher (shivampkumar/trellis-mac @ d58628f with microsoft/TRELLIS.2 @ 75fbf01). No lift_shim.

trellis-mac's generate.py keeps its whole flow inside main(), so it can't be imported piecewise. This file
mirrors it: the environment and sys.path set-up at import, the pipeline load once in load(), and per job
pipeline.run plus generate.py's bake block (files/trellis_bake.py). Re-check both against generate.py whenever the
trellis-mac pin moves.

Importing o_voxel here makes the installer's smoke check fail when setup.sh quietly fell back to the KDTree
baker (it still prints "Setup complete" when the Metal build failed).
"""
import os
import sys
import time

# As generate.py: before torch is imported anywhere (flex_gemm imports it).
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("ATTN_BACKEND", "sdpa")
os.environ.setdefault("SPARSE_ATTN_BACKEND", "sdpa")
try:
    import flex_gemm  # noqa: F401
    os.environ.setdefault("SPARSE_CONV_BACKEND", "flex_gemm")
except (ImportError, RuntimeError):
    os.environ.setdefault("SPARSE_CONV_BACKEND", "none")

REPO = os.getcwd()  # lift_worker runs in models/<id>/repo, which is trellis-mac's checkout
sys.path.insert(0, os.path.join(REPO, "TRELLIS.2"))
sys.path.append(os.path.join(REPO, "stubs"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "files"))  # this recipe's own helpers

import o_voxel.postprocess  # noqa: E402
from trellis_bake import bake  # noqa: E402

if o_voxel.postprocess._BACKEND != "metal" or not o_voxel.postprocess._HAS_DR:
    raise RuntimeError(f"o_voxel is not on its Metal backend (_BACKEND={o_voxel.postprocess._BACKEND!r}); "
                       "trellis-mac's setup.sh fell back to the KDTree baker. Reinstall after checking the Metal Toolchain.")

# generate.py's text for the macOS GPU watchdog failures, which surface as these errors or an empty mesh.
WATCHDOG_SIGNATURES = ("non-zero size", "BVH needs at least 8 triangles")
WATCHDOG_HELP = (
    "The decoder produced an empty mesh. On Apple Silicon this is almost always the macOS GPU watchdog "
    "killing a long-running Metal kernel in the SLat decoder (look for "
    "'kIOGPUCommandBufferCallbackErrorImpactingInteractivity' in the log). Workarounds, cheapest first: "
    "1. run headless (close the lid / unplug external displays); "
    "2. MTL_CAPTURE_ENABLED=1 (extends the watchdog timeout); "
    "3. SPARSE_CONV_BACKEND=none (slower path). "
    "See https://github.com/shivampkumar/trellis-mac/issues"
)


def load(ctx):
    import torch
    from trellis2.pipelines.trellis2_image_to_3d import Trellis2ImageTo3DPipeline

    print("Loading pipeline...")
    pipeline = Trellis2ImageTo3DPipeline.from_pretrained("microsoft/TRELLIS.2-4B")
    pipeline.to(torch.device("mps"))
    return pipeline


def run(pipeline, job):
    from PIL import Image

    s = job.settings
    img = Image.open(job.inputs["image"])
    base = os.path.join(job.out_dir, "mesh")
    overrides = {"steps": s["steps"]} if s["steps"] else {}
    print(f"Generating 3D model (pipeline={s['pipeline_type']}, seed={s['seed']})...")
    t0 = time.time()
    try:
        outputs = pipeline.run(img, seed=s["seed"], pipeline_type=s["pipeline_type"],
                               sparse_structure_sampler_params=overrides, shape_slat_sampler_params=overrides,
                               tex_slat_sampler_params=overrides)
    except (IndexError, AssertionError) as e:
        if any(sig in str(e) for sig in WATCHDOG_SIGNATURES):
            raise RuntimeError(WATCHDOG_HELP) from e
        raise
    mesh_out = outputs[0] if isinstance(outputs, list) else outputs
    verts = mesh_out.vertices.cpu().numpy()
    faces = mesh_out.faces.cpu().numpy()
    if verts.shape[0] == 0 or faces.shape[0] == 0:
        raise RuntimeError(WATCHDOG_HELP)
    print(f"Mesh: {verts.shape[0]:,} vertices, {faces.shape[0]:,} triangles; generation {time.time() - t0:.1f}s")

    glb_path = f"{base}.glb"
    tex_size = int(s["texture_size"])
    if hasattr(mesh_out, "attrs") and mesh_out.attrs is not None and not s["no_texture"]:
        bake(mesh_out, verts, faces, tex_size, base, glb_path)
    else:
        import trimesh

        print("Exporting with vertex colors...")
        trimesh.Trimesh(vertices=verts, faces=faces).export(glb_path)
    obj_path = f"{base}.obj"  # generate.py also writes the raw geometry as OBJ
    with open(obj_path, "w") as f:
        for v in verts:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        for face in faces:
            f.write(f"f {face[0] + 1} {face[1] + 1} {face[2] + 1}\n")
    return [glb_path, obj_path]
