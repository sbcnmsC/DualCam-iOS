#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/scripts/DualCam-AppIcon.svg"
OUT="$ROOT/DualCam/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "缺少 rsvg-convert。请先运行：brew install librsvg" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
rsvg-convert --format=png --width=1024 --height=1024 "$SVG" > "$OUT"
file "$OUT"
