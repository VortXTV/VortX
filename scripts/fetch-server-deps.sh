#!/usr/bin/env bash
# Fetches the two pieces the embedded streaming server needs (both gitignored).
# Run once after cloning. No local Stremio install is required: everything has
# a public download fallback.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned SHA256s for everything downloaded below. These binaries ship inside the
# IPA, so verify them instead of trusting the transport. When replacing a vendor
# asset, recompute the matching hash (shasum -a 256 <file>).
NODEMOBILE_SHA256="6abd08685c35a2e4772533aeb8aab40483404ba184cb3b19a3e89f36376689bd"
FONTS_SHA256="11de005861655d43e53979325cdca3172951f93af566b6fc6778e6897dd53dbb"
SERVER_JS_4_21_0_SHA256="82175d7982bce864df071df93b4b3d567a401e65881a8ac579d7db0ce71dafd7"

verify_sha256() { # <file> <expected-hash> <label>
    local actual
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
    if [ "$actual" != "$2" ]; then
        echo "ERROR: $3 checksum mismatch" >&2
        echo "  expected: $2" >&2
        echo "  actual:   $actual" >&2
        rm -f "$1"
        exit 1
    fi
}

# 1) NodeMobile.xcframework. The official nodejs-mobile v18.20.4 release is
#    iOS-only; StremioX needs tvOS slices too (device + simulator), so a
#    tvOS-enabled build is hosted as a release asset on this repo.
NODEMOBILE_URL="https://github.com/mamaclapper/StremioX/releases/download/vendor-1/NodeMobile-v18.20.4-ios-tvos.xcframework.zip"
echo "Fetching NodeMobile.xcframework (iOS + tvOS)..."
mkdir -p app/Vendor
curl -sfL "$NODEMOBILE_URL" -o /tmp/nodemobile.zip
verify_sha256 /tmp/nodemobile.zip "$NODEMOBILE_SHA256" "NodeMobile.xcframework"
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
SERVER_VERSION="${STREMIO_SERVER_VERSION:-4.21.0}"
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
    if [ "$SERVER_VERSION" = "4.21.0" ]; then
        verify_sha256 "$SERVER_DEST" "$SERVER_JS_4_21_0_SHA256" "server.js v$SERVER_VERSION"
    else
        echo "WARNING: no pinned checksum for server.js v$SERVER_VERSION; skipping verification." >&2
    fi
fi

# 3) Subtitle fallback fonts (Noto Sans family, OFL 1.1) so mpv renders
#    non-Latin subtitles. Too big for git, hosted on the same vendor release.
#    v2 trims the CJK face to its practically-used coverage (BMP scripts, no
#    rare plane-2 ideographs or vertical/regional variant glyphs): 7.6 MB
#    instead of 16 MB, identical rendering for real-world subtitles.
FONTS_DIR="app/Resources/fonts"
if [ -z "$(ls "$FONTS_DIR"/*.ttf "$FONTS_DIR"/*.otf 2>/dev/null)" ]; then
    echo "Fetching subtitle fallback fonts..."
    mkdir -p "$FONTS_DIR"
    curl -sfL "https://github.com/mamaclapper/StremioX/releases/download/vendor-1/StremioX-subtitle-fonts-v2.zip" -o /tmp/stremiox-fonts.zip
    verify_sha256 /tmp/stremiox-fonts.zip "$FONTS_SHA256" "subtitle fonts"
    unzip -qo /tmp/stremiox-fonts.zip -d "$FONTS_DIR"
else
    echo "Subtitle fonts already present."
fi

echo "Done. NodeMobile + server.js + fonts ready. Next: scripts/build-core-xcframework.sh, then 'xcodegen generate' in app/."
