#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-memory-album.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$project_root/Sources/MikuDesktop/MemoryAlbum.swift" \
  "$project_root/Sources/MikuDesktop/MikuTheme.swift" \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/MemoryPhotoCapture.swift" \
  "$project_root/Sources/MikuDesktop/MemoryAlbumWindowController.swift" \
  "$project_root/Tests/MemoryAlbumTests.swift" \
  -o "$temporary_dir/memory-album-tests"

"$temporary_dir/memory-album-tests"
