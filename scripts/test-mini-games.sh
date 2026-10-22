#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-mini-games.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/MikuTheme.swift" \
  "$project_root/Sources/MikuDesktop/MiniGames.swift" \
  "$project_root/Tests/MiniGamesTests.swift" \
  -o "$temporary_dir/mini-games-tests"

"$temporary_dir/mini-games-tests"
