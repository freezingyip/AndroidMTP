#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
export PATH="/opt/homebrew/bin:$PATH"
TASK_CHECK_DIR="$TASK_ROOT/.build/gallery-checks"
mkdir -p "$TASK_CHECK_DIR"
sed '/^import AndroidMTPCore$/d' Sources/AndroidMTP/BrowserModel.swift > "$TASK_CHECK_DIR/BrowserModel.swift"
sed '/^import AndroidMTPCore$/d' Sources/AndroidMTP/PhotoGallery.swift > "$TASK_CHECK_DIR/PhotoGallery.swift"
TASK_LINK_FLAGS=($(pkg-config --libs-only-L --libs-only-l libmtp))
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_ROOT/.build/ModuleCache" \
    -I Sources/CAndroidMTP/include Sources/AndroidMTPCore/*.swift \
    "$TASK_CHECK_DIR/BrowserModel.swift" "$TASK_CHECK_DIR/PhotoGallery.swift" \
    scripts/tests/gallery_checks.swift .build/core-checks/bridge.o \
    "${TASK_LINK_FLAGS[@]}" -o "$TASK_CHECK_DIR/gallery-checks"
"$TASK_CHECK_DIR/gallery-checks"

xcrun swiftc -swift-version 5 -module-cache-path "$TASK_ROOT/.build/ModuleCache" \
    -I Sources/CAndroidMTP/include Sources/AndroidMTPCore/*.swift \
    "$TASK_CHECK_DIR/BrowserModel.swift" "$TASK_CHECK_DIR/PhotoGallery.swift" \
    scripts/tests/clipboard_checks.swift .build/core-checks/bridge.o \
    "${TASK_LINK_FLAGS[@]}" -o "$TASK_CHECK_DIR/clipboard-checks"
"$TASK_CHECK_DIR/clipboard-checks"
