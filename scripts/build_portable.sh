#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$TASK_ROOT/scripts/build_release_dependencies.py"
export PKG_CONFIG_PATH="$TASK_ROOT/.build/release-dependencies/install/lib/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET=13.0
export ANDROIDMTP_PORTABLE_BUILD=1
"$TASK_ROOT/scripts/build.sh"
