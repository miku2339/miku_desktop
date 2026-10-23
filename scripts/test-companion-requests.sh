#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-requests.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc "$project_root/Sources/MikuDesktop/CompanionRequest.swift" \
  "$project_root/Tests/CompanionRequestTests.swift" -o "$temporary_dir/companion-request-tests"
"$temporary_dir/companion-request-tests"
