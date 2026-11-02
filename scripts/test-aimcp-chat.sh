#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/miku-aimcp-chat.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

swiftc \
  -D AIMCP_TEST_KEYCHAIN_STUB \
  "$project_root/Sources/MikuDesktop/RelationshipPolicy.swift" \
  "$project_root/Sources/MikuDesktop/CompanionModels.swift" \
  "$project_root/Sources/MikuDesktop/CompanionMemory.swift" \
  "$project_root/Sources/MikuDesktop/AIConfiguration.swift" \
  "$project_root/Sources/MikuDesktop/Localization.swift" \
  "$project_root/Sources/MikuDesktop/LocalAI.swift" \
  "$project_root/Sources/MikuDesktop/MusicRequest.swift" \
  "$project_root/Sources/MikuDesktop/VocaDB.swift" \
  "$project_root/Sources/MikuDesktop/HumText.swift" \
  "$project_root/Sources/MikuDesktop/SpeechVoice.swift" \
  "$project_root/Tests/KeychainStoreStub.swift" \
  "$project_root/Sources/MikuDesktop/SongKnowledge.swift" \
  "$project_root/Sources/MikuDesktop/SpecialDays.swift" \
  "$project_root/Tests/AIMCPChatTests.swift" \
  -o "$temporary_dir/aimcp-chat-tests"

"$temporary_dir/aimcp-chat-tests"
