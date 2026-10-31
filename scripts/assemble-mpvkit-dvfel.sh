#!/bin/bash
# Assemble app/Vendor/MPVKit-DVFEL from a completed MPVKit build tree.
#
# Only the libraries we actually rebuilt become LOCAL binaryTargets:
#   Libmpv-GPL, Libav{codec,device,filter,format,util}-GPL, Libsw{resample,scale}-GPL, Libplacebo,
#   lcms2, Libdav1d, Libssl, Libcrypto, gmp, nettle, hogweed, gnutls, Libsmbclient
# LittleCMS lcms2.20rc1 is a source-built prerelease candidate, not a stable shipping claim.
# dav1d 1.5.4 is also source-built; Shaderc alone moves to its paired 2026.1.0 wrapper.
# OpenSSL 4.1.0 is source-built; its two targets are actual local artifacts.
# Subtitle candidate sources replace the three retained remote libass transitive wrappers;
# libbluray1.5.0 also uses its authenticated, Apple-adapted source candidate.
# Everything else (libass, MoltenVK, uavs3d, luajit) is UNCHANGED from
# the 0.41.0-n8.1.2 pin and stays an upstream remote binaryTarget with its existing checksum. That
# keeps the remaining wrappers unchanged while the selected source candidate is evaluated.
#
# Usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>
set -euo pipefail

SRC="${1:?usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>}"
PKG="${2:?usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>}"
# Read from the per-library ZIPS, not dist/release/xcframework: each library's createXCFramework()
# wipes that directory before it writes, so only the LAST library built (libmpv) still has an
# unpacked .xcframework there. The zips are produced per library before the next wipe, so they are
# the only place all twenty-two survive together.
REL="$SRC/dist/release"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$PKG"
mkdir -p "$PKG/artifacts" "$PKG/Sources"

# MPVKit's dummy umbrella targets carry the linkerSettings (frameworks + system libs); reuse them.
for d in _MPVKit _MPVKit-GPL _FFmpeg _FFmpeg-GPL; do
  cp -R "$SRC/Sources/$d" "$PKG/Sources/$d"
done

# The GPL build emits UNSUFFIXED artifact names; SwiftPM requires the .xcframework basename to
# match the binaryTarget name, so unpack each under the name Package.swift expects.
while IFS=: read -r from to; do
  [ -f "$REL/$from.xcframework.zip" ] || { echo "MISSING: $REL/$from.xcframework.zip" >&2; exit 1; }
  rm -rf "$TMP/x"; mkdir -p "$TMP/x"
  unzip -q "$REL/$from.xcframework.zip" -d "$TMP/x"
  mv "$TMP/x/$from.xcframework" "$PKG/artifacts/$to.xcframework"
done <<'MAP'
Libmpv:Libmpv-GPL
Libavcodec:Libavcodec-GPL
Libavdevice:Libavdevice-GPL
Libavfilter:Libavfilter-GPL
Libavformat:Libavformat-GPL
Libavutil:Libavutil-GPL
Libswresample:Libswresample-GPL
Libswscale:Libswscale-GPL
Libplacebo:Libplacebo
lcms2:lcms2
Libdav1d:Libdav1d
Libssl:Libssl
Libcrypto:Libcrypto
gmp:gmp
nettle:nettle
hogweed:hogweed
gnutls:gnutls
Libsmbclient:Libsmbclient
Libunibreak:Libunibreak
Libfribidi:Libfribidi
Libharfbuzz:Libharfbuzz
Libbluray:Libbluray
Libfreetype:Libfreetype
Libdovi:Libdovi
MAP

# Rewrite the twenty-three rebuilt targets to local paths. The inherited root
# Package.swift still carries the old bluray1.4 template; it is never shipped here.
python3 - "$SRC/Package.swift" "$PKG/Package.swift" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
local = ["Libmpv-GPL","Libavcodec-GPL","Libavdevice-GPL","Libavfilter-GPL","Libavformat-GPL",
         "Libavutil-GPL","Libswresample-GPL","Libswscale-GPL","Libplacebo","lcms2","Libdav1d","Libssl","Libcrypto",
         "gmp","nettle","hogweed","gnutls","Libsmbclient","Libunibreak","Libfribidi","Libharfbuzz","Libbluray","Libfreetype","Libdovi"]
for name in local:
    pat = re.compile(r'\.binaryTarget\(\s*name:\s*"%s",\s*url:\s*"[^"]*",\s*checksum:\s*"[^"]*"\s*\)'
                     % re.escape(name))
    repl = ('.binaryTarget(\n            name: "%s",\n'
            '            path: "artifacts/%s.xcframework"\n        )' % (name, name))
    text, n = pat.subn(repl, text)
    if n != 1:
        sys.exit("expected exactly 1 match for %s, got %d" % (name, n))
open(dst, "w").write(text)
print("rewrote %d binaryTargets to local paths" % len(local))
PY

cat > "$PKG/.gitignore" <<'GI'
# Build OUTPUT (hundreds of MB), reproducible from the pinned refs via
# scripts/build-mpvkit-dvfel.sh. Must never enter git history.
artifacts/
GI

echo "package: $PKG"
du -sh "$PKG/artifacts" | sed 's/^/  artifacts total: /'
