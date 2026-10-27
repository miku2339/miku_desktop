#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-speech-mute-playback.XXXXXX")
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

# A stand-in TTS service for the retry checks (fails once, then answers).
python3 "$project_root/Tests/fake_tts_server.py" "$temporary_dir/tts-port" &
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$temporary_dir/tts-port" ] && break; sleep 0.2; done

swiftc \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/MikuSpeechAuthorization.swift" \
  "$project_root/Sources/MikuDesktop/SpeechMute.swift" \
  "$project_root/Sources/MikuDesktop/SpeechQuietTimes.swift" \
  "$project_root/Sources/MikuDesktop/SpeechVoice.swift" \
  "$project_root/Sources/MikuDesktop/MikuSpeech.swift" \
  "$project_root/Sources/MikuDesktop/HumText.swift" \
  "$project_root/Sources/MikuDesktop/HumPlayer.swift" \
  "$project_root/Tests/SpeechMutePlaybackTests.swift" \
  -o "$temporary_dir/speech-mute-playback-tests"

MIKU_FAKE_TTS_PORT=$(cat "$temporary_dir/tts-port" 2>/dev/null || true) "$temporary_dir/speech-mute-playback-tests"
