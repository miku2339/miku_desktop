#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-voice-pcm.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
swiftc "$project_root/Sources/MikuDesktop/VoicePCMStream.swift" "$project_root/Tests/VoicePCMStreamTests.swift" -o "$temporary_dir/tests"
"$temporary_dir/tests"
