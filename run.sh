#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/YTMusicIsland"

if [[ ! -x "$APP" ]]; then
  "$ROOT/build.sh"
fi

"$APP"
