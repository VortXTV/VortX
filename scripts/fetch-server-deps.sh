#!/usr/bin/env bash
# Fetches the two pieces the embedded streaming server needs (both gitignored).
# Run once after cloning. No local Stremio install is required: everything has
# a public download fallback.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) NodeMobile.xcframework. The official nodejs-mobile v18.20.4 release is
#    iOS-only; StremioX needs tvOS slices too (device + simulator), so a
#    tvOS-enabled build is hosted as a release asset on this repo.
NODEMOBILE_URL="https://github.com/mamaclapper/StremioX/releases/download/vendor-1/NodeMobile-v18.20.4-ios-tvos.xcframework.zip"
echo "Fetching NodeMobile.xcframework (iOS + tvOS)..."
mkdir -p app/Vendor
curl -sfL "$NODEMOBILE_URL" -o /tmp/nodemobile.zip
rm -rf app/Vendor/nodejs-mobile
mkdir -p app/Vendor/nodejs-mobile
unzip -q /tmp/nodemobile.zip -d app/Vendor/nodejs-mobile

# 2) server.js, the standard desktop build that runs under plain Node.
#    Preference order:
#      a) STREMIO_APP env var pointing at a Stremio.app bundle
#      b) reference/macos/Stremio.app (maintainer layout, not committed)
#      c) /Applications/Stremio.app (typical install)
#      d) Stremio's public CDN (no local install needed)
SERVER_DEST="app/Resources/server.js"
SERVER_VERSION="${STREMIO_SERVER_VERSION:-4.20.17}"
found=""
for candidate in "${STREMIO_APP:-}" "reference/macos/Stremio.app" "/Applications/Stremio.app"; do
    if [ -n "$candidate" ] && [ -f "$candidate/Contents/MacOS/server.js" ]; then
        cp "$candidate/Contents/MacOS/server.js" "$SERVER_DEST"
        found="$candidate"
        break
    fi
done
if [ -n "$found" ]; then
    echo "server.js copied from $found"
else
    echo "No local Stremio.app found; downloading server.js v$SERVER_VERSION from dl.strem.io..."
    curl -sfL "https://dl.strem.io/server/v$SERVER_VERSION/desktop/server.js" -o "$SERVER_DEST"
fi

# 3) Subtitle fallback fonts (Noto Sans family, OFL 1.1) so mpv renders
#    non-Latin subtitles. Too big for git, hosted on the same vendor release.
FONTS_DIR="app/Resources/fonts"
if [ -z "$(ls "$FONTS_DIR"/*.ttf "$FONTS_DIR"/*.otf 2>/dev/null)" ]; then
    echo "Fetching subtitle fallback fonts..."
    mkdir -p "$FONTS_DIR"
    curl -sfL "https://github.com/mamaclapper/StremioX/releases/download/vendor-1/StremioX-subtitle-fonts.zip" -o /tmp/stremiox-fonts.zip
    unzip -qo /tmp/stremiox-fonts.zip -d "$FONTS_DIR"
else
    echo "Subtitle fonts already present."
fi

echo "Done. NodeMobile + server.js + fonts ready. Next: scripts/build-core-xcframework.sh, then 'xcodegen generate' in app/."
