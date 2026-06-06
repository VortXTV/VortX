#!/usr/bin/env bash
# Fetches the two proprietary/large pieces the embedded streaming server needs
# (both gitignored). Run once after cloning.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) nodejs-mobile v18.20.4 (matches the Node version Stremio's server.js targets)
mkdir -p app/Vendor
curl -sL "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.20.4/nodejs-mobile-v18.20.4-ios.zip" -o /tmp/nodejs-mobile-ios.zip
rm -rf app/Vendor/nodejs-mobile
unzip -q /tmp/nodejs-mobile-ios.zip -d app/Vendor/nodejs-mobile

# 2) server.js, extract from Stremio's macOS app (the standard build that runs under
#    plain Node; the iOS IPA's server.js needs a private apple_bridge binding).
#    Provide reference/macos/Stremio.app yourself (not committed).
cp "reference/macos/Stremio.app/Contents/MacOS/server.js" app/Resources/server.js
echo "Done. NodeMobile + server.js ready."
