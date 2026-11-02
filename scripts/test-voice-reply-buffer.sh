#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-voice-reply-buffer.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/VoiceReplyBuffer.swift" \
  "$project_root/Tests/VoiceReplyBufferTests.swift" \
  -o "$temporary_dir/voice-reply-buffer-tests"
"$temporary_dir/voice-reply-buffer-tests"
