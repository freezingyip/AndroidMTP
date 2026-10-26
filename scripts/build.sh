#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/pkg-config ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
elif [[ -x /usr/local/bin/pkg-config ]]; then
    export PATH="/usr/local/bin:$PATH"
fi
if ! pkg-config --exists libmtp; then
    echo "MTP libraries are missing. Install them with: brew install libmtp pkgconf" >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/ModuleCache"
swift build --package-path "$TASK_ROOT" --build-system native --disable-sandbox \
    --cache-path "$TASK_ROOT/.build/cache" -c release
TASK_BIN_DIR="$(swift build --package-path "$TASK_ROOT" --build-system native --disable-sandbox \
    --cache-path "$TASK_ROOT/.build/cache" -c release --show-bin-path)"
python3 "$TASK_ROOT/scripts/package_app.py" "$TASK_BIN_DIR/AndroidMTP"
