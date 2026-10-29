#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
mkdir -p "$ROOT/.cache/clang" "$ROOT/.cache/swiftpm" "$ROOT/.tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.cache/clang"
export TMPDIR="$ROOT/.tmp/"
export SWIFT_BACKTRACE=enable=no
swift run --build-system native --disable-sandbox --cache-path "$ROOT/.cache/swiftpm" XattredCoreTests