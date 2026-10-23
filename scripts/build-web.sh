#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Reuse the source checkout managed alongside the canonical app, including from app worktrees.
# Never silently create a nested checkout or replace an unrelated existing source tree.
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
CANONICAL_APP="$(cd "$COMMON/.." && pwd -P)"
CANONICAL_WORKSPACE="$(cd "$CANONICAL_APP/.." && pwd -P)"
WEB="${STREMIO_WEB_DIR:-$CANONICAL_APP/../stremio-web}"
PIN="v5.0.0-beta.37"
# Pin to the EXACT commit the tag points at (OSSF Scorecard Pinned-Dependencies). The readable tag
# stays for humans; the SHA check below fails the build if that tag is ever moved or re-pointed.
PIN_SHA="fed3499a403a927cd652759b7fda8f671b87db24"

[ -e "$WEB/.git" ] || { echo "Missing managed stremio-web checkout; set STREMIO_WEB_DIR to the existing canonical source checkout." >&2; exit 1; }
WEB="$(cd "$WEB" && pwd -P)"
case "$WEB/" in
  "$CANONICAL_WORKSPACE/"*) ;;
  *) echo "stremio-web source escapes the canonical workspace: $WEB" >&2; exit 1 ;;
esac
remote="$(git -C "$WEB" remote get-url origin)"
case "$remote" in
  https://github.com/Stremio/stremio-web.git|https://github.com/Stremio/stremio-web|git@github.com:Stremio/stremio-web.git) ;;
  *) echo "Unexpected stremio-web source remote: $remote" >&2; exit 1 ;;
esac
got="$(git -C "$WEB" rev-parse HEAD^{commit})"
[ "$got" = "$PIN_SHA" ] || { echo "stremio-web $PIN resolved to $got, expected $PIN_SHA" >&2; exit 1; }
[ -z "$(git -C "$WEB" status --porcelain --untracked-files=all)" ] || { echo "stremio-web source has unreviewed changes; refusing to build it" >&2; exit 1; }

cd "$WEB"
# Apply our committed patches before install (Task 7 wires this up).
# corepack pins pnpm via stremio-web's packageManager field. Require it rather than falling back to
# an unpinned `npm i -g pnpm` (OSSF Scorecard Pinned-Dependencies); set -e aborts loudly if it fails.
corepack enable pnpm
pnpm install --frozen-lockfile
pnpm build

[ -d "$WEB/build" ] || { echo "stremio-web build did not produce build/" >&2; exit 1; }
DEST="$ROOT/app/Resources/web"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WEB/build/." "$DEST/"
echo "OK: web build copied to $DEST ($(du -sh "$DEST" | cut -f1))"
