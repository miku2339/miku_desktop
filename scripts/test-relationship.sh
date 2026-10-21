#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-relationship.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  "$project_root/Sources/MikuDesktop/RelationshipPolicy.swift" \
  "$project_root/Tests/RelationshipPolicyTests.swift" \
  -o "$temporary_dir/relationship-policy-tests"

"$temporary_dir/relationship-policy-tests"
