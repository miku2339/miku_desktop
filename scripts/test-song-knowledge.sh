#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-song-knowledge.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/SongKnowledge.swift" \
  "$project_root/Tests/SongKnowledgeTests.swift" \
  -o "$temporary_dir/song-knowledge-tests"

cd "$project_root"
"$temporary_dir/song-knowledge-tests"
