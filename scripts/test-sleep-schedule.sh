#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-sleep.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/SleepSchedule.swift" \
  "$project_root/Tests/SleepScheduleTests.swift" \
  -o "$temporary_dir/sleep-schedule-tests"

"$temporary_dir/sleep-schedule-tests"
