#!/usr/bin/env bash
# THROWAWAY: UniRig on Apple Silicon with lift_shim. Never edits the cloned repo.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
ROOT=$(cd ../.. && pwd)
[ -d unirig ] || git clone --filter=blob:none https://github.com/VAST-AI-Research/UniRig unirig
git -C unirig checkout -q 6793c6640ff01c8fb389f3993434124bb43d2933

[ -d venv-unirig ] || uv venv venv-unirig --python 3.11
export VIRTUAL_ENV=$PWD/venv-unirig PATH=$PWD/venv-unirig/bin:$PATH
uv pip install torch torchvision
grep -v -E '^(flash_attn|wandb)' unirig/requirements.txt > req-unirig.txt   # flash_attn → shim stand-in
uv pip install -r req-unirig.txt
uv pip install setuptools wheel
uv pip install --no-build-isolation torch_scatter torch_cluster
uv pip install spconv || echo "SPCONV: no macOS wheel — record"
uv pip install numpy==1.26.4
uv pip install -e "$ROOT/dev-recipes/shared/lift_shim"
python -c "import site, lift_shim.pth as p; print(p.write_pth(site.getsitepackages()[0]))"
(cd unirig && python -c "import bpy, os; bpy.ops.preferences.addon_install(filepath=os.path.abspath('blender/add-on-vrm-v2.20.77_modified.zip'))")
python -c "import bpy, torch_scatter, torch_cluster; print('unirig deps OK')"
