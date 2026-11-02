#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-training-activity.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/MikuTrainingActivity.swift" \
  "$project_root/Tests/TrainingActivityTests.swift" \
  -o "$temporary_dir/training-activity-tests"

"$temporary_dir/training-activity-tests"
