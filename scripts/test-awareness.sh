#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-awareness.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/AwarenessPolicy.swift" \
  "$project_root/Tests/AwarenessPolicyTests.swift" \
  -o "$temporary_dir/awareness-policy-tests"

"$temporary_dir/awareness-policy-tests"
