#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-speech-authorization.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/MikuSpeechAuthorization.swift" \
  "$project_root/Tests/MikuSpeechAuthorizationTests.swift" \
  -o "$temporary_dir/miku-speech-authorization-tests"
"$temporary_dir/miku-speech-authorization-tests"

swiftc -typecheck "$project_root"/Sources/MikuDesktop/*.swift
