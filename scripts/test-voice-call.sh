#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-voice-call.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/VoiceCallAudio.swift" \
  "$project_root/Sources/MikuDesktop/VoiceCallLanguage.swift" \
  "$project_root/Sources/MikuDesktop/LocalSpeechAnalyzer.swift" \
  "$project_root/Sources/MikuDesktop/VoiceCallController.swift" \
  "$project_root/Sources/MikuDesktop/LocalSpeechInput.swift" \
  "$project_root/Tests/VoiceCallTests.swift" \
  -o "$temporary_dir/voice-call-tests"

"$temporary_dir/voice-call-tests"
