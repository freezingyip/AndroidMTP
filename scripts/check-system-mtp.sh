#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/pkg-config ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi
TASK_CHECK_DIR="$TASK_ROOT/.build/system-mtp-checks"
mkdir -p "$TASK_CHECK_DIR"
TASK_CFLAGS=($(pkg-config --cflags-only-I libmtp))
TASK_LINK_FLAGS=($(pkg-config --libs-only-L --libs-only-l libmtp))
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -isysroot "$TASK_SDK" -Wall -Wextra -Werror \
    -c Sources/CAndroidMTP/CAndroidMTP.c -I Sources/CAndroidMTP/include \
    "${TASK_CFLAGS[@]}" -o "$TASK_CHECK_DIR/bridge.o"
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_CHECK_DIR/ModuleCache" \
    -I Sources/CAndroidMTP/include Sources/AndroidMTPCore/Models.swift \
    Sources/AndroidMTPCore/PTPCodec.swift Sources/AndroidMTPCore/MTPService.swift \
    Sources/AndroidMTPCore/SystemMTPService.swift scripts/tests/system_mtp_checks.swift \
    "$TASK_CHECK_DIR/bridge.o" "${TASK_LINK_FLAGS[@]}" -o "$TASK_CHECK_DIR/system-mtp-checks"
"$TASK_CHECK_DIR/system-mtp-checks"
