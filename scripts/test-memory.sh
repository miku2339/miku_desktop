#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-memory.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/RelationshipPolicy.swift" \
  "$project_root/Sources/MikuDesktop/CompanionModels.swift" \
  "$project_root/Sources/MikuDesktop/CompanionMemory.swift" \
  "$project_root/Sources/MikuDesktop/AIConfiguration.swift" \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/LocalAI.swift" \
  "$project_root/Sources/MikuDesktop/SpecialDays.swift" \
  "$project_root/Tests/CompanionMemoryTests.swift" \
  -o "$temporary_dir/memory-tests"

"$temporary_dir/memory-tests"
