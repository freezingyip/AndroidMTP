#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/pkg-config ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi
TASK_CHECK_DIR="$TASK_ROOT/.build/device-check"
mkdir -p "$TASK_CHECK_DIR"
python3 scripts/prepare-device-check.py "$TASK_ROOT/.build/device-test"
TASK_CFLAGS=($(pkg-config --cflags-only-I libmtp))
TASK_LINK_FLAGS=($(pkg-config --libs-only-L --libs-only-l libmtp))
clang -Wall -Wextra -Werror -c Sources/CAndroidMTP/CAndroidMTP.c \
    -I Sources/CAndroidMTP/include "${TASK_CFLAGS[@]}" -o "$TASK_CHECK_DIR/bridge.o"
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_CHECK_DIR/ModuleCache" \
    -I Sources/CAndroidMTP/include Sources/AndroidMTPCore/*.swift \
    scripts/tests/device_roundtrip.swift \
    "$TASK_CHECK_DIR/bridge.o" "${TASK_LINK_FLAGS[@]}" -o "$TASK_CHECK_DIR/roundtrip"
echo "Built the hardware check. Run .build/device-check/roundtrip .build/device-test with the unlocked phone in File transfer mode."
