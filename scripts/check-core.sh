#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/pkg-config ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi
TASK_CHECK_DIR="$TASK_ROOT/.build/core-checks"
mkdir -p "$TASK_CHECK_DIR"
TASK_CFLAGS=($(pkg-config --cflags-only-I libmtp))
TASK_LINK_FLAGS=($(pkg-config --libs-only-L --libs-only-l libmtp))
clang -Wall -Wextra -Werror -c Sources/CAndroidMTP/CAndroidMTP.c \
    -I Sources/CAndroidMTP/include "${TASK_CFLAGS[@]}" -o "$TASK_CHECK_DIR/bridge.o"
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_ROOT/.build/ModuleCache" \
    -I Sources/CAndroidMTP/include Sources/AndroidMTPCore/Models.swift \
    Sources/AndroidMTPCore/MTPService.swift scripts/tests/file_checks.swift \
    "$TASK_CHECK_DIR/bridge.o" "${TASK_LINK_FLAGS[@]}" -o "$TASK_CHECK_DIR/file-checks"
"$TASK_CHECK_DIR/file-checks"
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_ROOT/.build/ModuleCache" \
    Sources/AndroidMTPCore/Models.swift Sources/AndroidMTPCore/ADBService.swift \
    scripts/tests/adb_checks.swift -o "$TASK_CHECK_DIR/adb-checks"
"$TASK_CHECK_DIR/adb-checks"
