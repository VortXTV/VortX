#!/usr/bin/env bash
set -euo pipefail
# Repackage an extracted app bundle into an .ipa for Signulous to re-sign.
# Usage: repackage-ipa.sh <dir-containing-Payload> <out.ipa>
SRC="${1:?usage: repackage-ipa.sh <dir-containing-Payload> <out.ipa>}"
OUT="${2:?output .ipa path}"
[ -d "$SRC/Payload" ] || { echo "no Payload/ in $SRC"; exit 1; }
mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
# IPA = zip with Payload/ at the archive root. iOS frameworks are flat (no symlinks), so plain zip is safe.
( cd "$SRC" && zip -qry "$OUT" Payload -x '*.DS_Store' )
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | grep -E 'Payload/Stremio.app/(Stremio|Info.plist|server.js)$' || true
