#!/bin/zsh
set -euo pipefail

app_dir=''
launch=true
while (( $# )); do
  case "$1" in
    --app-dir) (( $# >= 2 )) && [[ -n "$2" ]] || { echo 'Expected --app-dir DIRECTORY.' >&2; exit 2; }; app_dir="$2"; shift 2 ;;
    --no-open) launch=false; shift ;;
    *) echo 'Usage: install-macos-release.sh [--app-dir DIRECTORY] [--no-open]' >&2; exit 2 ;;
  esac
done

fail() { echo "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(/usr/sbin/sysctl -in hw.optional.arm64)" == 1 ]] || fail 'Miku Desktop requires an Apple silicon Mac.'
os_version="$(/usr/bin/sw_vers -productVersion)"
(( ${os_version%%.*} >= 13 )) || fail 'Miku Desktop requires macOS 13 or later.'

app_name='Miku Desktop.app'
if [[ -z "$app_dir" ]]; then
  if [[ -d "/Applications/$app_name" ]]; then app_dir=/Applications
  elif [[ -d "$HOME/Applications/$app_name" ]]; then app_dir="$HOME/Applications"
  elif [[ -w /Applications ]]; then app_dir=/Applications
  else app_dir="$HOME/Applications"; fi
fi
mkdir -p "$app_dir"
app_dir="${app_dir:A}"
destination="$app_dir/$app_name"
verify_app() {
  [[ -d "$1" && ! -L "$1" && -x "$1/Contents/MacOS/MikuDesktop" ]] &&
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist")" == com.qimake.MikuDesktop ]] &&
    /usr/bin/codesign --verify --strict --deep "$1"
}

if [[ -e "$destination" || -L "$destination" ]]; then
  verify_app "$destination" || fail "An unexpected item already exists at $destination."
  echo "Already installed: $destination. Use Check for Updates in Miku Desktop."
else
  staging="$(mktemp -d "$app_dir/.miku-install.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
  trap 'exit 1' HUP INT TERM
  repo='miku2339/miku_desktop'
  asset_name='MikuDesktop-macOS.zip'
  page=1
  while true; do
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --retry 2 \
      "https://api.github.com/repos/$repo/releases?per_page=100&page=$page" -o "$staging/releases.json"
    asset="$(/usr/bin/osascript -l JavaScript - "$staging/releases.json" "$asset_name" <<'JXA'
function run([file, name]) {
  ObjC.import('Foundation');
  const releases = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null).js);
  for (const release of releases) {
    if (release.draft || release.prerelease) continue;
    const asset = release.assets.find(item => item.name === name && item.state === 'uploaded');
    if (!asset) continue;
    if (!/^sha256:[0-9a-f]{64}$/.test(asset.digest)) throw Error('Missing release SHA-256.');
    return asset.digest.slice(7) + ' ' + encodeURIComponent(release.tag_name);
  }
  return releases.length === 100 ? 'next' : 'none';
}
JXA
)"
    [[ "$asset" != none ]] || fail 'No official macOS installer has been published.'
    [[ "$asset" == next ]] || break
    (( ++page ))
  done
  echo "Downloading Miku Desktop ${asset#* }..."
  /usr/bin/curl --fail --silent --show-error --location --proto '=https' --retry 2 \
    "https://github.com/$repo/releases/download/${asset#* }/$asset_name" -o "$staging/release.zip"
  checksum="$(/usr/bin/shasum -a 256 < "$staging/release.zip")"
  [[ "${checksum%% *}" == "${asset%% *}" ]] || fail 'The downloaded archive failed SHA-256 verification.'
  /usr/bin/ditto -x -k "$staging/release.zip" "$staging"
  verify_app "$staging/$app_name" || fail 'The downloaded app failed verification.'
  # curl does not mark downloads for Gatekeeper as a browser does.
  /usr/bin/xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Miku Desktop Installer;" "$staging/$app_name"
  /bin/mv -n "$staging/$app_name" "$app_dir/"
  [[ ! -e "$staging/$app_name" ]] || fail "Another item already exists at $destination."
  echo "Installed: $destination"
fi
if [[ "$launch" == true ]]; then /usr/bin/open "$destination"; fi
