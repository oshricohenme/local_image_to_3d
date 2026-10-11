#!/usr/bin/env bash
# THROWAWAY: upstream UniRig scripts, unmodified, with the shim injected through LIFT_SHIM + .pth.
set -euo pipefail
cd "$(dirname "$0")/work/unirig"
export PATH=$PWD/../venv-unirig/bin:$PATH
export LIFT_SHIM='{"standins":["flash_attn","spconv"],"patches":["transformers_fa2_to_sdpa","torch_scatter_mps","torch_cluster_mps"]}'
mkdir -p ../out
bash launch/inference/generate_skeleton.sh --input examples/giraffe.glb --output ../out/giraffe_skeleton.fbx
bash launch/inference/generate_skin.sh --input ../out/giraffe_skeleton.fbx --output ../out/giraffe_skin.fbx
bash launch/inference/merge.sh --source ../out/giraffe_skin.fbx --target examples/giraffe.glb --output ../out/giraffe_rigged.glb
