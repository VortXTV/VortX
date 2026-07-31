#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$(pwd)"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_REPO="$(dirname "$COMMON_DIR")"

PRIMARY="${VORTX_LIBMPV_PRIMARY:-$REPO/app/Vendor/MPVKit-DVFEL/artifacts}"
if [ ! -d "$PRIMARY/Libmpv-GPL.xcframework" ]; then
  PRIMARY="$MAIN_REPO/app/Vendor/MPVKit-DVFEL/artifacts"
fi
FALLBACK="${VORTX_LIBMPV_FALLBACK:-}"
if [ -z "$FALLBACK" ]; then
  FALLBACK="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -path '*/SourcePackages/artifacts/mpvkit-dvfel' -print -quit 2>/dev/null || true)"
fi

[ -d "$PRIMARY/Libmpv-GPL.xcframework" ] \
  || { echo "missing shipped Libmpv-GPL artifact; set VORTX_LIBMPV_PRIMARY" >&2; exit 2; }
[ -n "$FALLBACK" ] && [ -d "$FALLBACK" ] \
  || { echo "missing MPVKit dependency cache; set VORTX_LIBMPV_FALLBACK" >&2; exit 2; }

FRAMEWORK_KEYS=(
  Libmpv-GPL Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL
  Libavfilter-GPL Libswresample-GPL Libswscale-GPL Libplacebo
  Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz
  Libshaderc_combined lcms2 Libdovi Libunibreak Libsmbclient gmp nettle
  hogweed gnutls Libdav1d Libuavs3d Libuchardet Libbluray Libluajit
)

LINK_FLAGS=()
for key in "${FRAMEWORK_KEYS[@]}"; do
  slice=""
  if [ -d "$PRIMARY/$key.xcframework" ]; then
    slice="$(find "$PRIMARY/$key.xcframework" -maxdepth 1 -type d \
      -name 'macos-arm64*' -print -quit)"
  fi
  if [ -z "$slice" ] && [ -d "$FALLBACK/$key" ]; then
    slice="$(find "$FALLBACK/$key" -type d -name 'macos-arm64*' -print -quit)"
  fi
  [ -n "$slice" ] || { echo "missing macOS slice for $key" >&2; exit 2; }
  framework_dir="$(find "$slice" -maxdepth 1 -type d -name '*.framework' -print -quit)"
  [ -n "$framework_dir" ] || { echo "missing framework for $key" >&2; exit 2; }
  LINK_FLAGS+=( -F "$(dirname "$framework_dir")" -framework "$(basename "$framework_dir" .framework)" )
done

MOLTEN_ARCHIVE="$(find "$FALLBACK/MoltenVK" -type f -name 'libMoltenVK.a' \
  -path '*macos-arm64*' -print -quit)"
[ -n "$MOLTEN_ARCHIVE" ] || { echo "missing macOS MoltenVK archive" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vortx-libmpv-fresh-start.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BASE="$WORK/base.mkv"
SHIFTED="$WORK/positive-start.mkv"
BIN="$WORK/libmpv-fresh-start"

FFMPEG="${VORTX_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FFPROBE="${VORTX_FFPROBE:-/opt/homebrew/bin/ffprobe}"
[ -x "$FFMPEG" ] || { echo "ffmpeg unavailable at $FFMPEG" >&2; exit 2; }
[ -x "$FFPROBE" ] || { echo "ffprobe unavailable at $FFPROBE" >&2; exit 2; }

"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=320x180:rate=24:duration=16" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=16" \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset ultrafast -g 24 -keyint_min 24 -sc_threshold 0 \
  -pix_fmt yuv420p -c:a aac -b:a 128k \
  "$BASE"

"$FFMPEG" -y -hide_banner -loglevel error \
  -itsoffset 5 -i "$BASE" -map 0 -c copy -copyts -avoid_negative_ts disabled \
  "$SHIFTED"

START="$("$FFPROBE" -v error -show_entries format=start_time \
  -of default=noprint_wrappers=1:nokey=1 "$SHIFTED")"
awk -v value="$START" 'BEGIN { exit !(value >= 4.9 && value <= 5.1) }' \
  || { echo "fixture start_time is $START, expected 5.000" >&2; exit 2; }

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -sdk "$SDK_PATH" \
  "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" \
  -framework AppKit -framework AVFoundation -framework CoreAudio \
  -framework AudioToolbox -framework CoreVideo -framework CoreFoundation \
  -framework CoreMedia -framework Metal -framework VideoToolbox \
  -framework Foundation -framework IOKit -framework IOSurface \
  -framework QuartzCore -framework CoreGraphics -framework Network \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -o "$BIN" \
  test/libmpv-fresh-start/main.swift

"$BIN" "$SHIFTED"
