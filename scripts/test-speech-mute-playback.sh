#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-speech-mute-playback.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/MikuSpeechAuthorization.swift" \
  "$project_root/Sources/MikuDesktop/SpeechMute.swift" \
  "$project_root/Sources/MikuDesktop/SpeechQuietTimes.swift" \
  "$project_root/Sources/MikuDesktop/SpeechVoice.swift" \
  "$project_root/Sources/MikuDesktop/MikuSpeech.swift" \
  "$project_root/Tests/SpeechMutePlaybackTests.swift" \
  -o "$temporary_dir/speech-mute-playback-tests"

"$temporary_dir/speech-mute-playback-tests"
