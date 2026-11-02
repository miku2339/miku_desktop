#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-localization.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Tests/LocalizationTests.swift" \
  -o "$temporary_dir/localization-tests"

"$temporary_dir/localization-tests" "$project_root/Sources/MikuDesktop/Localization.swift"
