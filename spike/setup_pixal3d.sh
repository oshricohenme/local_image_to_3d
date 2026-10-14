#!/usr/bin/env bash
# THROWAWAY: Pixal3D on Apple Silicon with lift_shim. Never edits the cloned repo.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
ROOT=$(cd ../.. && pwd)

clone() { [ -d "$2" ] || git clone --filter=blob:none "$1" "$2"; git -C "$2" checkout -q "$3"; }
clone https://github.com/TencentARC/Pixal3D           pixal3d                 f7cf38429b0bd264f1995f0f8743a88b1c728b94
clone https://github.com/pedronaugusto/mtlgemm        deps/mtlgemm            566c133781ce4992de3f77c3a97dd6feaae9d013
clone https://github.com/pedronaugusto/mtldiffrast    deps/mtldiffrast        c9499ba2e4ed6849e95ce5da7aae5bf61addb528
clone https://github.com/pedronaugusto/mtlbvh         deps/mtlbvh             6b2a0f63b476ad8225695d092902104beafd7f58
clone https://github.com/pedronaugusto/mtlmesh        deps/mtlmesh            7de3864f783407201486bf6c900a4bd76a4018a3
clone https://github.com/pedronaugusto/trellis2-apple deps/trellis2-apple     17347247c91c36c8cdc1896234983e878a457bba

git -C deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen  # o-voxel needs Eigen headers

[ -d venv-pixal3d ] || uv venv venv-pixal3d --python 3.11
export VIRTUAL_ENV=$PWD/venv-pixal3d PATH=$PWD/venv-pixal3d/bin:$PATH
# torch>=2.14 headers need C++20 but mtl* setup.py hardcodes -std=c++17; mtlgemm needs >=2.11
uv pip install "torch==2.11.*" torchvision
# upstream pins trimesh==4.10.1 but MoGe (unpinned git HEAD) needs >=4.11
echo "trimesh>=4.11" > trimesh-override.txt
grep -v MoGe pixal3d/requirements.txt > reqs-no-moge.txt
uv pip install -r reqs-no-moge.txt --override trimesh-override.txt
# MoGe depends on CUDA-only flex-gemm (triton); the mtlgemm fork below provides flex_gemm instead
uv pip install --no-deps "moge @ git+https://github.com/microsoft/MoGe.git@74fbce054ebed49800de42d0ad0e83495065719a"
uv pip install "click>=8.3.1" matplotlib requests huggingface-hub starlette \
  "utils3d_moge @ git+https://github.com/EasternJournalist/utils3d-moge.git@62f09d58509485564e24d5d9f6aac9ee9ebc0c37" \
  "pipeline @ git+https://github.com/EasternJournalist/pipeline.git@1c511390d90226c00c101f34b84df26a0f8789b4"
uv pip install https://github.com/LDYang694/Storages/releases/download/20260430/utils3d-0.0.2-py3-none-any.whl
uv pip install setuptools wheel pybind11 xatlas fast-simplification scipy
export MACOSX_DEPLOYMENT_TARGET=12.0
for d in mtlbvh mtldiffrast mtlmesh mtlgemm trellis2-apple/o-voxel; do uv pip install --no-build-isolation "deps/$d"; done
uv pip install -e "$ROOT/dev-recipes/shared/lift_shim"
python -c "import site, lift_shim.pth as p; print(p.write_pth(site.getsitepackages()[0]))"
python -c "import flex_gemm, cumesh, mtldiffrast, o_voxel; print('substitutes import OK')"
