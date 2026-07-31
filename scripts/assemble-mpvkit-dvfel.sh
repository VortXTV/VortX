#!/bin/bash
# Assemble app/Vendor/MPVKit-DVFEL from a completed MPVKit build tree.
#
# Only the libraries we actually rebuilt become LOCAL binaryTargets:
#   Libmpv-GPL, Libav{codec,device,filter,format,util}-GPL, Libsw{resample,scale}-GPL, Libplacebo
# Everything else (openssl, gnutls, libass, libdovi, MoltenVK, shaderc, lcms2, dav1d, uavs3d,
# smbclient, bluray, luajit, unibreak, freetype, fribidi, harfbuzz, gmp, nettle) is UNCHANGED from
# the 0.41.0-n8.1.2 pin and stays an upstream remote binaryTarget with its existing checksum. That
# keeps the delta to exactly the Dolby-Vision-relevant libraries.
#
# Usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>
set -euo pipefail

SRC="${1:?usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>}"
PKG="${2:?usage: assemble-mpvkit-dvfel.sh <mpvkit-build-dir> <dest-package-dir>}"
# Read from the per-library ZIPS, not dist/release/xcframework: each library's createXCFramework()
# wipes that directory before it writes, so only the LAST library built (libmpv) still has an
# unpacked .xcframework there. The zips are produced per library before the next wipe, so they are
# the only place all nine survive together.
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
MAP

# Rewrite the nine rebuilt binaryTargets from url+checksum to a local path.
python3 - "$SRC/Package.swift" "$PKG/Package.swift" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
local = ["Libmpv-GPL","Libavcodec-GPL","Libavdevice-GPL","Libavfilter-GPL","Libavformat-GPL",
         "Libavutil-GPL","Libswresample-GPL","Libswscale-GPL","Libplacebo"]
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
