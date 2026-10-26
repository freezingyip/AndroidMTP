#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" != "--xctest" ]]; then
    "$TASK_ROOT/scripts/check-core.sh"
    "$TASK_ROOT/scripts/check-system-mtp.sh"
    exec "$TASK_ROOT/scripts/check-gallery.sh"
fi
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/pkg-config ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/ModuleCache"
swift test --package-path "$TASK_ROOT" --build-system native --disable-sandbox \
    --cache-path "$TASK_ROOT/.build/cache"
