#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
mkdir -p "$ROOT/build/module-cache"

/usr/bin/swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx26.0 \
  -Xcc -fmodules-cache-path="$ROOT/build/module-cache" \
  -O \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -o "$ROOT/build/YTMusicIsland"

echo "Built: $ROOT/build/YTMusicIsland"
