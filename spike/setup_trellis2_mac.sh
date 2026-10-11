#!/usr/bin/env bash
# THROWAWAY: trellis-mac's own setup, unmodified. TRELLIS.2 is pre-placed at a pin so setup.sh skips its unpinned clone.
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p work && cd work
[ -d trellis-mac ] || git clone --filter=blob:none https://github.com/shivampkumar/trellis-mac trellis-mac
git -C trellis-mac checkout -q d58628f4f5b9c3de8274cb110074154f4b31cef2
[ -d trellis-mac/TRELLIS.2 ] || git clone --filter=blob:none https://github.com/microsoft/TRELLIS.2 trellis-mac/TRELLIS.2
git -C trellis-mac/TRELLIS.2 checkout -q 75fbf0183001ed9876c8dbb35de6b68552ee08bd
# setup.sh's deps clone has no submodules; o-voxel needs Eigen (else it silently falls back to the KDTree baker).
[ -d trellis-mac/deps/trellis2-apple ] && git -C trellis-mac/deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen
# setup.sh installs unpinned torch. 2.14 needs C++20 (mtl* build with -std=c++17 and fail); 2.9 lacks at::mps::dispatch_sync_with_rethrow; mtlgemm needs >=2.11. So 2.13 is the only fit.
# A uv constraint keeps every `uv pip install` (incl. the mtl* dependency resolution) on 2.13.
printf 'torch==2.13.0\n' > "$PWD/torch-constraint.txt"
export UV_CONSTRAINT="$PWD/torch-constraint.txt"
# Stale locally built wheels in uv's cache (built against another torch) fail at import; bypass the cache instead of deleting from it.
export UV_NO_CACHE=1
# Likewise setuptools reuses stale build/ dirs (untracked build products) in the deps clones.
rm -rf trellis-mac/deps/*/build trellis-mac/deps/trellis2-apple/o-voxel/build
(cd trellis-mac && bash setup.sh)
