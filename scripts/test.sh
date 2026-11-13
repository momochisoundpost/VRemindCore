#!/usr/bin/env bash
# Run VRemindCore tests on macOS (Xcode Command Line Tools or full Xcode) and Linux/Windows.
set -euo pipefail

cd "$(dirname "$0")/.."

CACHE="$PWD/.build/caches"
mkdir -p "$CACHE/modules"

export CLANG_MODULE_CACHE_PATH="$CACHE/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/modules"

CLT=/Library/Developer/CommandLineTools/Library/Developer
FW="$CLT/Frameworks"
LIB="$CLT/usr/lib"

EXTRA=()
if [[ -d "$FW/Testing.framework" ]]; then
  EXTRA+=(-Xswiftc -F -Xswiftc "$FW"
          -Xlinker -F -Xlinker "$FW"
          -Xlinker -rpath -Xlinker "$FW"
          -Xlinker -rpath -Xlinker "$LIB")
fi

swift test --disable-sandbox --cache-path "$CACHE/spm" ${EXTRA[@]+"${EXTRA[@]}"} "$@" 2>&1 \
  | grep -v -e "is not accessible or not writable" \
            -e "which was built for newer version 14.0"
exit "${PIPESTATUS[0]}"
