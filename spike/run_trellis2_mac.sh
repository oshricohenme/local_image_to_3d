#!/usr/bin/env bash
# THROWAWAY
set -euo pipefail
cd "$(dirname "$0")/work/trellis-mac"
source .venv/bin/activate
python generate.py assets/shoe_input.png --output ../out/trellis2_shoe --pipeline-type 512
