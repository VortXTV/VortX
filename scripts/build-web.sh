#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web"
PIN="v5.0.0-beta.37"
# Pin to the EXACT commit the tag points at (OSSF Scorecard Pinned-Dependencies). The readable tag
# stays for humans; the SHA check below fails the build if that tag is ever moved or re-pointed.
PIN_SHA="fed3499a403a927cd652759b7fda8f671b87db24"

if [ ! -d "$WEB/.git" ]; then
  git clone --branch "$PIN" --depth 1 https://github.com/Stremio/stremio-web.git "$WEB"
  got="$(git -C "$WEB" rev-parse HEAD)"
  [ "$got" = "$PIN_SHA" ] || { echo "stremio-web $PIN resolved to $got, expected $PIN_SHA" >&2; exit 1; }
fi

cd "$WEB"
# Apply our committed patches before install (Task 7 wires this up).
# corepack pins pnpm via stremio-web's packageManager field. Require it rather than falling back to
# an unpinned `npm i -g pnpm` (OSSF Scorecard Pinned-Dependencies); set -e aborts loudly if it fails.
corepack enable pnpm
pnpm install
pnpm build

DEST="$ROOT/app/Resources/web"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WEB/build/." "$DEST/"
echo "OK: web build copied to $DEST ($(du -sh "$DEST" | cut -f1))"
