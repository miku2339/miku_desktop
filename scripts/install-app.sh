#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_dir=""
archive=""
skip_tda=false
launch_app=true

usage() {
  cat <<'EOF'
Usage: scripts/install-app.sh [--tda-archive original.zip] [--skip-tda] [--app-dir directory] [--no-open]

Installs Miku Desktop and configures the author's original Tda v1.1 model locally.
An existing verified import or original ZIP in Downloads is reused before downloading.
--skip-tda skips model setup and preserves any model already configured on this Mac.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --tda-archive)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      [[ -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      archive="$2"
      shift 2
      ;;
    --app-dir)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      [[ -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      app_dir="$2"
      shift 2
      ;;
    --skip-tda) skip_tda=true; shift ;;
    --no-open) launch_app=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ "$skip_tda" == true && -n "$archive" ]]; then
  echo "Use either --skip-tda or --tda-archive." >&2
  exit 2
fi
command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 1; }
command -v swift >/dev/null || { echo "Xcode Command Line Tools are required." >&2; exit 1; }

if [[ -z "$app_dir" ]]; then
  if [[ -d /Applications && -w /Applications ]]; then
    app_dir=/Applications
  else
    app_dir="$HOME/Applications"
  fi
fi
mkdir -p "$app_dir"
app_dir="${app_dir:A}"
destination="$app_dir/Miku Desktop.app"

if [[ "$skip_tda" == false ]]; then
  if [[ -n "$archive" ]]; then
    python3 "$project_root/scripts/import-tda-model.py" --user "$archive"
  else
    python3 "$project_root/scripts/import-tda-model.py" --user
  fi
fi
"$project_root/scripts/fetch-model.sh"
"$project_root/scripts/build-app.sh" --public

source_app="$HOME/Library/Application Support/com.qimake.MikuDesktopBuild/Miku Desktop.app"
staging_root="$(mktemp -d "$app_dir/.miku-install.XXXXXX")"
staged_app="$staging_root/Miku Desktop.app"
previous_app="$staging_root/previous.app"
installation_verified=false
app_replaced=false
cleanup() {
  if [[ "$installation_verified" == false ]]; then
    [[ "$app_replaced" == false ]] || rm -rf "$destination"
    [[ ! -d "$previous_app" ]] || mv "$previous_app" "$destination"
  fi
  rm -rf "$staging_root"
}
trap cleanup EXIT
ditto --norsrc "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -d "$destination" ]]; then
  rollback_dir="$HOME/Library/Application Support/com.qimake.MikuDesktopBuild"
  rollback_archive="$rollback_dir/rollback-next.zip"
  ditto -c -k --norsrc --keepParent "$destination" "$rollback_archive"
  mv -f "$rollback_archive" "$rollback_dir/rollback-latest.zip"
  python3 - "$destination" "$rollback_dir/rollback-metadata.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import time

app = Path(sys.argv[1])
metadata = {
    "saved_at": time.time(),
    "source": str(app),
    "binary_sha256": hashlib.sha256((app / "Contents/MacOS/MikuDesktop").read_bytes()).hexdigest(),
}
Path(sys.argv[2]).write_text(json.dumps(metadata, indent=2) + "\n")
PY
  mv "$destination" "$previous_app"
fi
if ! mv "$staged_app" "$destination"; then
  exit 1
fi
app_replaced=true
codesign --verify --deep --strict "$destination"
if [[ "$skip_tda" == false ]]; then
  python3 "$project_root/scripts/import-tda-model.py" --user --verify
fi
installation_verified=true
echo "Installed: $destination"

if [[ "$launch_app" == true ]]; then
  pkill -x MikuDesktop 2>/dev/null || true
  for attempt in {1..30}; do
    pgrep -x MikuDesktop >/dev/null || break
    sleep 0.1
  done
  if ! open -n "$destination"; then
    echo "The app is installed but could not be opened: $destination" >&2
    exit 1
  fi
fi
