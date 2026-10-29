#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRAINING_ROOT="$HOME/Library/Application Support/MikuTraining"
mkdir -p "$TRAINING_ROOT/envs" "$TRAINING_ROOT/reports"
chmod 700 "$TRAINING_ROOT"
if [ ! -x "$TRAINING_ROOT/envs/mac/bin/python" ]; then
  /opt/homebrew/bin/python3.12 -m venv "$TRAINING_ROOT/envs/mac"
fi
uv pip install --python "$TRAINING_ROOT/envs/mac/bin/python" \
  --cache-dir "$TRAINING_ROOT/cache/uv" \
  'mlx-vlm[train] @ git+https://github.com/Blaizzy/mlx-vlm.git@138d7617d39653b39a5cbc379b1b5907a4481d67' \
  'mlx==0.32.4' 'transformers==5.14.0'
uv pip freeze --python "$TRAINING_ROOT/envs/mac/bin/python" > "$TRAINING_ROOT/reports/mac-environment.lock"
"$TRAINING_ROOT/envs/mac/bin/python" "$SCRIPT_DIR/environment_check.py"
