#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web"
PIN="v5.0.0-beta.37"

if [ ! -d "$WEB/.git" ]; then
  git clone --branch "$PIN" --depth 1 https://github.com/Stremio/stremio-web.git "$WEB"
fi

cd "$WEB"
# Apply our committed patches before install (Task 7 wires this up).
corepack enable pnpm 2>/dev/null || npm i -g pnpm >/dev/null 2>&1 || true
pnpm install
pnpm build

DEST="$ROOT/app/Resources/web"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WEB/build/." "$DEST/"
echo "OK: web build copied to $DEST ($(du -sh "$DEST" | cut -f1))"
