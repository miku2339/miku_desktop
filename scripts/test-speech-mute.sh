#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-speech-mute.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/SpeechMute.swift" \
  "$project_root/Sources/MikuDesktop/SpeechQuietTimes.swift" \
  "$project_root/Sources/MikuDesktop/SpeechVoice.swift" \
  "$project_root/Tests/SpeechMuteTests.swift" \
  -o "$temporary_dir/speech-mute-tests"

"$temporary_dir/speech-mute-tests"
