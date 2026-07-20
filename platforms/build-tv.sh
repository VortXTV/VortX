#!/usr/bin/env bash
# Package the VortX webapp as an LG webOS (.ipk) or Samsung Tizen (.wgt) TV app.
#
#   platforms/build-tv.sh webos     # stage + validate + (if ares-cli present) package an .ipk
#   platforms/build-tv.sh tizen     # stage + validate + (if tizen CLI present) package a .wgt
#
# It is ADDITIVE to the web build: it runs the SAME `npm run build` the browser target uses, then wraps
# the resulting dist/ (index.html + hashed assets) with the platform manifest + icons in a staging dir.
# The webapp is never forked; the TV behaviour is the runtime `html.tv` layer (src/lib/tvnav.ts +
# src/styles/tv.css), which only activates on a webOS/Tizen user agent.
#
# If the platform packager CLI is not installed, the script still builds, stages, and VALIDATES the
# manifest, then prints the exact package command to run on a machine with the SDK. It never fabricates
# an .ipk / .wgt.
set -euo pipefail

PLATFORM="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBAPP="$ROOT/webapp"
DIST="$WEBAPP/dist"

if [[ "$PLATFORM" != "webos" && "$PLATFORM" != "tizen" ]]; then
  echo "usage: platforms/build-tv.sh <webos|tizen>" >&2
  exit 2
fi

STAGE="$ROOT/platforms/$PLATFORM/.stage"
OUT="$ROOT/platforms/$PLATFORM/out"

echo "==> Building the webapp (shared with the web target)"
( cd "$WEBAPP" && npm run build )

echo "==> Staging $PLATFORM app at $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"
cp -R "$DIST"/. "$STAGE"/

if [[ "$PLATFORM" == "webos" ]]; then
  cp "$ROOT/platforms/webos/appinfo.json" "$STAGE/appinfo.json"
  cp "$ROOT/platforms/webos/icon.png" "$STAGE/icon.png"
  cp "$ROOT/platforms/webos/largeIcon.png" "$STAGE/largeIcon.png"

  echo "==> Validating appinfo.json"
  node -e "JSON.parse(require('fs').readFileSync('$STAGE/appinfo.json','utf8')); console.log('    appinfo.json: valid JSON')"

  if command -v ares-package >/dev/null 2>&1; then
    echo "==> ares-package -> $OUT"
    ares-package "$STAGE" -o "$OUT"
    echo "==> Done. Install with: ares-install -d <device> \"$OUT\"/*.ipk"
  else
    echo "==> ares-cli not found; staged only (no .ipk fabricated)."
    echo "    Install the SDK CLI (npm i -g @webos-tools/cli), then run:"
    echo "        ares-package \"$STAGE\" -o \"$OUT\""
    echo "        ares-install -d <device> \"$OUT\"/*.ipk"
  fi
else
  cp "$ROOT/platforms/tizen/config.xml" "$STAGE/config.xml"
  cp "$ROOT/platforms/tizen/icon.png" "$STAGE/icon.png"

  echo "==> Validating config.xml"
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$STAGE/config.xml" && echo "    config.xml: well-formed XML"
  else
    python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$STAGE/config.xml'); print('    config.xml: well-formed XML')"
  fi

  if command -v tizen >/dev/null 2>&1; then
    echo "==> tizen package -> $OUT (needs a signing profile; see platforms/tizen/README.md)"
    tizen build-web -- "$STAGE"
    tizen package -t wgt -s "${TIZEN_PROFILE:-VortX}" -- "$STAGE/.buildResult" -o "$OUT"
    echo "==> Done. Install with: tizen install -n \"$OUT\"/*.wgt -t <target>"
  else
    echo "==> tizen CLI not found; staged only (no .wgt fabricated)."
    echo "    Install Tizen Studio + create a signing profile, then run:"
    echo "        tizen build-web -- \"$STAGE\""
    echo "        tizen package -t wgt -s <profile> -- \"$STAGE/.buildResult\" -o \"$OUT\""
    echo "        tizen install -n \"$OUT\"/*.wgt -t <tv-target>"
  fi
fi

echo "==> Staged files:"
ls -1 "$STAGE" | sed 's/^/    /'
