#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
workspace_root="${project_root:h}"
output_app="$workspace_root/outputs/Miku Desktop.app"
output_zip="$workspace_root/outputs/Miku Desktop.zip"
build_product="$project_root/.build/debug/MikuDesktop"
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

swift build --package-path "$project_root"

rm -rf "$output_app"
rm -f "$output_zip"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources/Wallpaper"
cp "$build_product" "$staging_app/Contents/MacOS/MikuDesktop"
cp "$project_root/Info.plist" "$staging_app/Contents/Info.plist"
ditto --norsrc "$wallpaper_source/companion" "$staging_app/Contents/Resources/Wallpaper/companion"
ditto --norsrc "$wallpaper_source/assets" "$staging_app/Contents/Resources/Wallpaper/assets"
chmod 755 "$staging_app/Contents/MacOS/MikuDesktop"
xattr -cr "$staging_app"
codesign --force --deep --sign - "$staging_app"
codesign --verify --deep --strict "$staging_app"

rm -rf "$artifact_app"
mkdir -p "$artifact_root" "${output_app:h}"
ditto --norsrc "$staging_app" "$artifact_app"
codesign --verify --deep --strict "$artifact_app"
ln -s "$artifact_app" "$output_app"

ditto -c -k --norsrc --keepParent "$artifact_app" "$staging_zip"
mkdir -p "$staging_root/verify"
ditto -x -k "$staging_zip" "$staging_root/verify"
codesign --verify --deep --strict "$staging_root/verify/Miku Desktop.app"
cp "$staging_zip" "$output_zip"

echo "$output_app"
echo "$output_zip"
