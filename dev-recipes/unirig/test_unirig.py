import re
import os
from pathlib import Path

import pytest

from conftest import upstream_repo, FakeJob, defaults

# Stands in for upstream's launch/inference/*.sh: logs its arguments (and where --input points), then writes
# --output unless FAIL_<script> is set. Like upstream, it always exits 0.
FAKE_SCRIPT = """#!/bin/bash
name=$(basename "$0" .sh)
echo "$name" >> "$UNIRIG_LOG"
while [[ $# -gt 0 ]]; do
  echo "  $1" >> "$UNIRIG_LOG"
  case $1 in
    --input|--target) echo "  $2" >> "$UNIRIG_LOG"; [ -L "$2" ] && echo "  -> $(readlink "$2")" >> "$UNIRIG_LOG"; shift ;;
    --output) echo "  $2" >> "$UNIRIG_LOG"; out="$2"; shift ;;
  esac
  shift
done
fail="FAIL_$name"
[ -n "$out" ] && [ -z "${!fail}" ] && echo "$name" > "$out"
echo "Predicting DataLoader 0: 100%|##########| 1/1"
echo done
"""


@pytest.fixture
def unirig(launcher, tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    (repo / "launch/inference").mkdir(parents=True)
    for name in ("generate_skeleton", "generate_skin", "merge"):
        (repo / f"launch/inference/{name}.sh").write_text(FAKE_SCRIPT)
    monkeypatch.chdir(repo)  # lift_worker runs launchers in models/<id>/repo
    monkeypatch.setenv("UNIRIG_LOG", str(tmp_path / "calls.log"))
    return launcher("unirig", {})


def calls(tmp_path):
    out, current = [], None
    for line in (tmp_path / "calls.log").read_text().splitlines():
        if line.startswith("  "):
            current[1].append(line[2:])
        else:
            current = (line, [])
            out.append(current)
    return out


def job(tmp_path, mesh, **changes):
    out = tmp_path / "out"
    out.mkdir(exist_ok=True)
    return FakeJob("rig", {"mesh": str(mesh)}, {**defaults("unirig", "rig"), **changes}, out)


def mesh(tmp_path, name="giraffe.glb"):
    folder = tmp_path / "inputs"
    folder.mkdir(exist_ok=True)
    p = folder / name
    p.write_bytes(b"glTF")
    return p


def test_default_runs_skeleton_skin_merge_with_upstream_defaults(unirig, tmp_path):
    m = mesh(tmp_path)
    j = job(tmp_path, m)
    assert unirig.run(None, j) == [f"{j.out_dir}/rigged.glb", f"{j.out_dir}/skin.fbx", f"{j.out_dir}/skeleton.fbx"]
    (skel, skel_args), (skin, skin_args), (merge, merge_args) = calls(tmp_path)
    assert (skel, skin, merge) == ("generate_skeleton", "generate_skin", "merge")
    work = os.path.dirname(skel_args[1])
    assert skel_args == ["--input", f"{work}/input.glb", f"-> {m}", "--output", f"{work}/skeleton.fbx",
                         "--skeleton_task", "configs/task/quick_inference_skeleton_articulationxl_ar_256.yaml",
                         "--add_root", "false", "--force_override", "false",
                         "--config", "configs/data/quick_inference.yaml", "--require_suffix", "obj,fbx,FBX,dae,glb,gltf,vrm",
                         "--num_runs", "1", "--faces_target_count", "50000", "--seed", "12345"]
    assert skin_args[:6] == ["--input", f"{work}/skeleton.fbx", "--output", f"{work}/skin.fbx", "--skin_task", "configs/task/quick_inference_unirig_skin.yaml"]
    assert skin_args[6:10] == ["--force_override", "true", "--data_name", "raw_data.npz"]
    assert merge_args == ["--source", f"{work}/skin.fbx", "--target", f"{work}/input.glb", f"-> {m}",
                          "--output", f"{work}/rigged.glb", "--require_suffix", "obj,fbx,FBX,dae,glb,gltf,vrm"]
    assert [s[0] for s in j.stages] == ["Predicting the skeleton (UniRig step 1 of 3)",
                                       "Working out how the mesh bends with each bone (step 2 of 3)",
                                       "Putting the rig on your mesh and saving it (step 3 of 3)"]
    assert not os.path.exists(work)  # the temp folder is gone


def test_skeleton_only_merges_the_skeleton_and_fbx_format(unirig, tmp_path):
    j = job(tmp_path, mesh(tmp_path), stages="skeleton", format="fbx")
    assert unirig.run(None, j) == [f"{j.out_dir}/rigged.fbx", f"{j.out_dir}/skeleton.fbx"]
    names = [c[0] for c in calls(tmp_path)]
    assert names == ["generate_skeleton", "merge"]
    merge_args = calls(tmp_path)[1][1]
    assert merge_args[1].endswith("/skeleton.fbx") and merge_args[merge_args.index("--output") + 1].endswith("/rigged.fbx")


def test_paths_with_spaces_and_shell_characters_never_reach_the_scripts(unirig, tmp_path):
    m = mesh(tmp_path, "my $(touch pwned); model.GLB")
    unirig.run(None, job(tmp_path, m))
    args = [x for _, xs in calls(tmp_path) for x in xs if not x.startswith("-> ")]
    assert all(" " not in a and "$" not in a and ";" not in a for a in args)
    assert f"-> {m}" in calls(tmp_path)[0][1]
    assert args[1].endswith("/input.glb")


def test_string_settings_with_shell_characters_are_refused(unirig, tmp_path):
    with pytest.raises(ValueError, match="config"):
        unirig.run(None, job(tmp_path, mesh(tmp_path), config="configs/data/x.yaml; rm -rf ~"))
    assert not (tmp_path / "calls.log").exists()


def test_a_stage_that_writes_nothing_fails_the_job_and_stops(unirig, tmp_path, monkeypatch):
    monkeypatch.setenv("FAIL_generate_skin", "1")
    with pytest.raises(RuntimeError, match="generate_skin.sh finished without writing skin.fbx"):
        unirig.run(None, job(tmp_path, mesh(tmp_path)))
    assert [c[0] for c in calls(tmp_path)] == ["generate_skeleton", "generate_skin"]


def test_upstream_output_reaches_the_job_log(unirig, tmp_path, capsys):
    unirig.run(None, job(tmp_path, mesh(tmp_path)))
    out = capsys.readouterr().out
    assert "$ bash launch/inference/generate_skeleton.sh" in out
    assert "Predicting DataLoader 0: 100%|" in out


def test_unirig_settings_are_the_script_flags():
    ours = defaults("unirig", "rig")
    for script, renames in [("generate_skeleton", {"force_override": "skeleton_force_override"}),
                            ("generate_skin", {"force_override": "skin_force_override"}), ("merge", {})]:
        text = (upstream_repo("unirig") / f"launch/inference/{script}.sh").read_text()
        flags = re.findall(r"^\s+--(\w+)\) ", text, re.M)
        values = {k: a or b for k, a, b in re.findall(r'^(\w+)=(?:"([^"]*)"|(\S+))', text, re.M)}
        for flag in flags:
            if flag in {"input", "output", "input_dir", "output_dir", "source", "target"}:
                continue  # Lift passes the job's files
            value = ours[renames.get(flag, flag)]
            assert (str(value).lower() if isinstance(value, bool) else str(value)) == values[flag], (script, flag)
