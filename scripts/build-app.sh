#!/bin/zsh
set -euo pipefail

# Usage: scripts/build-app.sh [--public]
#   --public  Leave out the optional Tda／金子卵黄 model so the zip can be shared.
#             Without it the build is for local use only and must not be redistributed.

public_build=false
for argument in "$@"; do
  case "$argument" in
    --public) public_build=true ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

project_root="${0:A:h:h}"
workspace_root="${project_root:h}"
output_app="$workspace_root/outputs/Miku Desktop.app"
if [[ "$public_build" == true ]]; then
  output_zip="$workspace_root/outputs/Miku Desktop (Public).zip"
else
  output_zip="$workspace_root/outputs/Miku Desktop.zip"
fi
build_product="$project_root/.build/release/MikuDesktop"
wallpaper_source="$project_root/Wallpaper"
artifact_root="$HOME/Library/Application Support/com.qimake.MikuDesktopBuild"
artifact_app="$artifact_root/Miku Desktop.app"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/miku-desktop-app.XXXXXX")"
staging_app="$staging_root/Miku Desktop.app"
staging_zip="$staging_root/Miku Desktop.zip"
trap 'rm -rf "$staging_root"' EXIT

if [[ ! -f "$wallpaper_source/assets/companion-model/miku_v2.pmd" || ! -f "$wallpaper_source/assets/companion-model/eyeM2.bmp" ]]; then
  echo "Missing Miku model assets. Run scripts/fetch-model.sh first." >&2
  exit 1
fi

swift build -c release --package-path "$project_root"

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources/Wallpaper"
cp "$build_product" "$staging_app/Contents/MacOS/MikuDesktop"
cp "$project_root/Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$staging_app/Contents/Resources/LICENSE"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$staging_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc "$project_root/Resources/Knowledge" "$staging_app/Contents/Resources/Knowledge"
ditto --norsrc "$wallpaper_source/companion" "$staging_app/Contents/Resources/Wallpaper/companion"
ditto --norsrc "$wallpaper_source/assets" "$staging_app/Contents/Resources/Wallpaper/assets"
if [[ "$public_build" == true ]]; then
  rm -rf "$staging_app/Contents/Resources/Wallpaper/assets/companion-model/tda"
  echo "Public build: optional Tda model excluded."
elif [[ -d "$wallpaper_source/assets/companion-model/tda" ]]; then
  echo "Note: this build includes the Tda model. Do not share the zip; use --public for a shareable build." >&2
fi
chmod 755 "$staging_app/Contents/MacOS/MikuDesktop"
xattr -cr "$staging_app"
codesign --force --deep --sign - "$staging_app"
codesign --verify --deep --strict "$staging_app"

ditto -c -k --norsrc --keepParent "$staging_app" "$staging_zip"
mkdir -p "$staging_root/verify"
ditto -x -k "$staging_zip" "$staging_root/verify"
codesign --verify --deep --strict "$staging_root/verify/Miku Desktop.app"
mkdir -p "${output_zip:h}"
rm -f "$output_zip"
cp "$staging_zip" "$output_zip"

# The local test copy always mirrors the last build.
rm -rf "$artifact_app" "$output_app"
mkdir -p "$artifact_root"
ditto --norsrc "$staging_app" "$artifact_app"
codesign --verify --deep --strict "$artifact_app"
ln -s "$artifact_app" "$output_app"

echo "$output_app"
echo "$output_zip"
