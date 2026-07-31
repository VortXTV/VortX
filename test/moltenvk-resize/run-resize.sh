#!/usr/bin/env bash
# =============================================================================
# run-resize.sh - build + run the moltenvk layer-resize acceptance harness.
#
# Links libmpv and its whole dependency set the way the app does, stands up a real
# CAMetalLayer, plays a real file, then changes the layer's drawableSize and checks
# that mpv follows WITHOUT rebuilding its video chain. See main.swift for the
# signals it reads. Exit code = RED count.
#
#   ./run-resize.sh              our own rebuilt frameworks (app/Vendor/MPVKit-DVFEL)
#                                for everything we build, upstream prebuilts for the rest.
#   ./run-resize.sh --control    upstream MPVKit for EVERYTHING, i.e. the behaviour
#                                before scripts/mpv-moltenvk-resize.patch. This run is
#                                EXPECTED to go RED; that is the before half of the
#                                before/after evidence, not a failure.
#
# Env overrides: VORTX_MPV_PRIMARY, VORTX_MPV_FALLBACK.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"

CONTROL=0
[ "${1:-}" = "--control" ] && CONTROL=1

PRIMARY="${VORTX_MPV_PRIMARY:-$REPO/app/Vendor/MPVKit-DVFEL/artifacts}"
FALLBACK="${VORTX_MPV_FALLBACK:-$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/VortX-*/SourcePackages/artifacts/mpvkit 2>/dev/null | head -n 1)}"
[ -n "$FALLBACK" ] || { echo "no upstream mpvkit artifacts found; set VORTX_MPV_FALLBACK" >&2; exit 2; }
[ "$CONTROL" = "1" ] && PRIMARY="/nonexistent"

# Keys we rebuild ourselves carry the -GPL suffix; the rest come from MPVKit's prebuilt zips.
FRAMEWORK_KEYS=(Libmpv-GPL Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL \
  Libswresample-GPL Libswscale-GPL Libplacebo \
  Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz \
  Libshaderc_combined lcms2 Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls \
  Libdav1d Libuavs3d Libuchardet Libbluray Libluajit)

LINK_FLAGS=()
declare -a FROM_PRIMARY=()
for key in "${FRAMEWORK_KEYS[@]}"; do
  slice=""
  if [ -d "$PRIMARY/$key.xcframework" ]; then
    slice=$(find "$PRIMARY/$key.xcframework" -maxdepth 1 -type d -name 'macos-arm64*' | head -n 1)
    [ -n "$slice" ] && FROM_PRIMARY+=("$key")
  fi
  if [ -z "$slice" ]; then
    slice=$(find "$FALLBACK/$key" -type d -name 'macos-arm64*' 2>/dev/null | head -n 1)
  fi
  [ -n "$slice" ] || { echo "missing macos slice for $key" >&2; exit 2; }
  framework_dir=$(find "$slice" -maxdepth 1 -name '*.framework' -type d | head -n 1)
  [ -n "$framework_dir" ] || { echo "no framework inside $slice" >&2; exit 2; }
  LINK_FLAGS+=( -F "$(dirname "$framework_dir")" -framework "$(basename "$framework_dir" .framework)" )
done

MOLTEN_ARCHIVE=$(find "$FALLBACK/MoltenVK" -path '*macos-arm64*/libMoltenVK.a' | head -n 1)
[ -n "$MOLTEN_ARCHIVE" ] || { echo "no libMoltenVK.a" >&2; exit 2; }
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

echo "primary  : $PRIMARY"
echo "fallback : $FALLBACK"
echo "from own build: ${FROM_PRIMARY[*]:-(none, this is the upstream control)}"

# Fixture: a plain long-running HEVC clip. Media never enters the repo.
OUT=/tmp/dd-mvkresize/fixtures
mkdir -p "$OUT" /tmp/dd-mvkresize/bin
FIXTURE="$OUT/resize-fixture.mkv"
if [ ! -f "$FIXTURE" ]; then
  /opt/homebrew/bin/ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=120" \
    -c:v libx265 -preset ultrafast -tag:v hvc1 \
    -x265-params "keyint=24:min-keyint=24:scenecut=0:log-level=error" -pix_fmt yuv420p \
    "$FIXTURE"
fi

BIN=/tmp/dd-mvkresize/bin/moltenvk-resize
xcrun swiftc -sdk "$SDK_PATH" \
  "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework Foundation -framework IOKit -framework IOSurface \
  -framework QuartzCore -framework CoreGraphics -framework Network \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -o "$BIN" \
  test/moltenvk-resize/main.swift

exec "$BIN" "$FIXTURE"
