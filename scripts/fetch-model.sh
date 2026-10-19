#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
model_dir="$project_root/Wallpaper/assets/companion-model"
source_url="https://raw.githubusercontent.com/mrdoob/three.js/r171/examples/models/mmd/miku"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/miku-model.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

mkdir -p "$model_dir"

fetch_asset() {
  local filename="$1"
  local expected_hash="$2"
  if [[ -f "$model_dir/$filename" ]] && [[ "$(shasum -a 256 "$model_dir/$filename" | cut -d ' ' -f 1)" == "$expected_hash" ]]; then
    return
  fi
  curl --fail --location --retry 2 --proto '=https' --tlsv1.2 \
    "$source_url/$filename" --output "$temporary_dir/$filename"
  if [[ "$(shasum -a 256 "$temporary_dir/$filename" | cut -d ' ' -f 1)" != "$expected_hash" ]]; then
    echo "Checksum mismatch: $filename" >&2
    exit 1
  fi
  mv "$temporary_dir/$filename" "$model_dir/$filename"
}

fetch_asset miku_v2.pmd 45a5a2fb897266a1b371b30cf53ed9435d375ddea9fce7f095bba2739b9bdae5
fetch_asset eyeM2.bmp a318f2d5bd22e3ac3a5b8cab4021fd68e25042e7730e8c04720cee68e3548565
fetch_asset readme.txt 702a3f62567fc9c8becbdb47a73058683086ba75e236612a3e8e8d5486cd0a9e
fetch_asset readme_miku_v2.txt 6732866be1a712d7af142fcbf59f7e3bab8691ea472f86bb674020b13d51355a

echo "Model ready. Read Wallpaper/assets/companion-model/readme_miku_v2.txt before use."
