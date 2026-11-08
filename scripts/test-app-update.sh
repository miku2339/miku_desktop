#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-app-update.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/AppUpdate.swift" \
  "$project_root/Tests/AppUpdateTests.swift" \
  -o "$temporary_dir/app-update-tests"

"$temporary_dir/app-update-tests"
