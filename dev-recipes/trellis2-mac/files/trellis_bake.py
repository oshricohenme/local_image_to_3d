"""generate.py's bake block (trellis-mac @ d58628f), as a function: Metal (o_voxel.postprocess.to_glb) when
o_voxel is on its Metal backend, else, or when the Metal bake fails, trellis-mac's KDTree baker."""
import o_voxel.postprocess


def bake(mesh_out, verts, faces, tex_size, base, glb_path):
    """Writes glb_path (and <base>_basecolor.png on the KDTree path)."""
    import torch

    pp = o_voxel.postprocess
    use_metal = pp._BACKEND == "metal" and pp._HAS_DR
    if use_metal and not getattr(pp, "_HAS_FLEX_GEMM", False):
        pp._grid_sample_3d = _grid_sample_3d_fix  # generate.py's fix for o_voxel's fallback layout
    if use_metal:
        try:
            print(f"Baking PBR textures via Metal ({tex_size}x{tex_size})...")
            import fast_simplification

            target_faces = min(200000, len(faces))
            if len(faces) > target_faces:
                print(f"  Simplifying mesh: {len(faces):,} -> ~{target_faces:,} faces")
                sv, sf = fast_simplification.simplify(verts, faces, 1.0 - target_faces / len(faces))
                sv_t = torch.from_numpy(sv).float().to(mesh_out.vertices.device)
                sf_t = torch.from_numpy(sf.astype("int32")).to(mesh_out.faces.device)
            else:
                sv_t, sf_t = mesh_out.vertices, mesh_out.faces
            glb = pp.to_glb(vertices=sv_t.cpu(), faces=sf_t.cpu(), attr_volume=mesh_out.attrs.cpu(),
                            coords=mesh_out.coords.cpu(), attr_layout=mesh_out.layout, voxel_size=mesh_out.voxel_size,
                            aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]], decimation_target=target_faces,
                            texture_size=tex_size, verbose=True)
            glb.export(glb_path)
            return
        except RuntimeError as e:
            print(f"  Metal bake failed: {e}\n  Falling back to KDTree texture baker...")
    from PIL import Image
    from backends.texture_baker import bake_texture, export_glb_with_texture, uv_unwrap

    print(f"Baking PBR textures via KDTree ({tex_size}x{tex_size})...")
    bv, bf = verts, faces
    target_faces = min(200000, len(faces))
    if len(faces) > target_faces:
        import fast_simplification

        bv, bf = fast_simplification.simplify(verts, faces, 1.0 - target_faces / len(faces))
    new_verts, new_faces, uvs, _ = uv_unwrap(bv, bf)
    base_color, mr, _ = bake_texture(new_verts, new_faces, uvs, mesh_out.coords.cpu().float().numpy(),
                                     mesh_out.attrs.cpu().float().numpy(), mesh_out.origin.cpu().float().numpy(),
                                     mesh_out.voxel_size, texture_size=tex_size)
    Image.fromarray(base_color).save(f"{base}_basecolor.png")
    export_glb_with_texture(new_verts, new_faces, uvs, base_color, mr, glb_path)


def _grid_sample_3d_fix(feats, coords, shape, grid, mode="trilinear"):
    import torch
    import torch.nn.functional as F

    B, C, D, H, W = shape[0], shape[1], shape[2], shape[3], shape[4]
    dense = torch.zeros(B, C, D, H, W, dtype=feats.dtype, device=feats.device)
    b, x, y, z = coords[:, 0].long(), coords[:, 1].long(), coords[:, 2].long(), coords[:, 3].long()
    dense[b, :, x, y, z] = feats
    g = torch.stack([grid[..., 2] / (W - 1) * 2 - 1, grid[..., 1] / (H - 1) * 2 - 1, grid[..., 0] / (D - 1) * 2 - 1],
                    dim=-1).reshape(B, 1, 1, -1, 3)
    sampled = F.grid_sample(dense, g, mode="bilinear", align_corners=True, padding_mode="border")
    return sampled.reshape(B, C, grid.shape[1]).permute(0, 2, 1).reshape(B * grid.shape[1], C)
