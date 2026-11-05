#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-character-model.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/CharacterModel.swift" \
  "$project_root/Sources/MikuDesktop/StaticHTTPServer.swift" \
  "$project_root/Tests/CharacterModelTests.swift" \
  -o "$temporary_dir/character-model-tests"

"$temporary_dir/character-model-tests" "$@"
