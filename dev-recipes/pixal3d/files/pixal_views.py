"""Multi-view layouts for Pixal3D's inference_mv (spec §4): the folder Lift hands upstream as views_dir.

transforms: the input folder already has transforms.json. four_view: photos named front/right/back/left get
the upstream example's cameras. orbit: every photo in name order, evenly spaced around the object.
"""
import json
import math
import os

FOUR_VIEW = ("front", "right", "back", "left")  # the frame order of upstream's assets/mv_images/example
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}  # what Lift accepts in an image_set (ImageSet.extensions)


def views_folder(folder, layout, out_dir, example):
    """The folder inference_mv reads: the input itself, or out_dir/views/ with a transforms.json Lift writes."""
    if layout["views"] == "transforms":
        if not os.path.isfile(os.path.join(folder, "transforms.json")):
            raise ValueError(f"views=transforms needs {folder}/transforms.json")
        return folder
    images = sorted(f for f in os.listdir(folder) if os.path.splitext(f)[1].lower() in IMAGE_EXTENSIONS)
    if layout["views"] == "four_view":
        by_stem = {os.path.splitext(f)[0].lower(): f for f in images}
        missing = [slot for slot in FOUR_VIEW if slot not in by_stem]
        if missing:
            raise ValueError(f"views=four_view needs images named {', '.join(FOUR_VIEW)}; missing: {', '.join(missing)}")
        with open(example) as f:
            meta = json.load(f)
        for frame, slot in zip(meta["frames"], FOUR_VIEW):
            frame["file_path"] = os.path.join(folder, by_stem[slot])
    else:
        if not images:
            raise ValueError(f"views=orbit found no images in {folder}")
        meta = orbit([os.path.join(folder, f) for f in images], layout["orbit_elevation_deg"],
                     layout["orbit_fov_deg"], layout["orbit_distance"])
    views = os.path.join(out_dir, "views")
    os.makedirs(views, exist_ok=True)
    with open(os.path.join(views, "transforms.json"), "w") as f:
        json.dump(meta, f, indent=2)
    return views  # file_path entries are absolute; upstream's os.path.join(views_dir, …) keeps them


def orbit(paths, elevation_deg, fov_deg, distance):
    """Cameras evenly spaced in azimuth with frame 0 in front, camera at (0, -d, 0), in upstream's convention
    (transforms.json, Blender/NeRF): Z-up world, camera-to-world matrices, camera looking down its -Z, +Y up."""
    e = math.radians(elevation_deg)
    frames = []
    for i, path in enumerate(paths):
        a = 2 * math.pi * i / len(paths)
        back = (math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e))  # camera +Z, away from the object
        right = (math.cos(a), math.sin(a), 0.0)
        up = (back[1] * right[2] - back[2] * right[1], back[2] * right[0] - back[0] * right[2], back[0] * right[1] - back[1] * right[0])
        matrix = [[_clean(v) for v in (right[r], up[r], back[r], distance * back[r])] for r in range(3)] + [[0.0, 0.0, 0.0, 1.0]]
        frames.append({"file_path": path, "name": f"azim{round(math.degrees(a)):03d}", "transform_matrix": matrix})
    return {"camera_angle_x": math.radians(fov_deg), "mesh_scale": 1.0, "frames": frames}


def _clean(v):
    return round(v, 12) + 0.0  # cos(90°) is 6e-17, and -0.0 reads badly
