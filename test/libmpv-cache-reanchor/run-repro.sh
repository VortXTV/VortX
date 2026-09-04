#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_REPO="$(dirname "$COMMON_DIR")"
ROOT="$(dirname "$MAIN_REPO")"
PRIMARY="${VORTX_LIBMPV_PRIMARY:-$MAIN_REPO/app/Vendor/MPVKit-DVFEL/artifacts}"
FALLBACK="${VORTX_LIBMPV_FALLBACK:-$ROOT/_build/xcode-packages/artifacts/mpvkit-dvfel}"
SCRATCH="${VORTX_LIBMPV_CACHE_SCRATCH:-$ROOT/_build/libmpv-cache-reanchor}"
mkdir -p "$SCRATCH"

[ -d "$PRIMARY/Libmpv-GPL.xcframework" ] || { echo "missing shipped Libmpv-GPL artifact" >&2; exit 2; }
[ -d "$FALLBACK" ] || { echo "missing MPVKit dependency cache" >&2; exit 2; }

FRAMEWORK_KEYS=(Libmpv-GPL Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL Libswresample-GPL Libswscale-GPL Libplacebo Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz Libshaderc_combined lcms2 Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls Libdav1d Libuavs3d Libuchardet Libbluray Libluajit)
LINK_FLAGS=()
for key in "${FRAMEWORK_KEYS[@]}"; do
  slice=""
  [ -d "$PRIMARY/$key.xcframework" ] && slice="$(find "$PRIMARY/$key.xcframework" -maxdepth 1 -type d -name 'macos-arm64*' -print -quit)"
  [ -z "$slice" ] && [ -d "$FALLBACK/$key" ] && slice="$(find "$FALLBACK/$key" -type d -name 'macos-arm64*' -print -quit)"
  [ -n "$slice" ] || { echo "missing macOS slice for $key" >&2; exit 2; }
  framework="$(find "$slice" -maxdepth 1 -type d -name '*.framework' -print -quit)"
  [ -n "$framework" ] || { echo "missing framework for $key" >&2; exit 2; }
  LINK_FLAGS+=(-F "$(dirname "$framework")" -framework "$(basename "$framework" .framework)")
done
MOLTEN_ARCHIVE="$(find "$FALLBACK/MoltenVK" -type f -name libMoltenVK.a -path '*macos-arm64*' -print -quit)"
[ -n "$MOLTEN_ARCHIVE" ] || { echo "missing macOS MoltenVK archive" >&2; exit 2; }

FIXTURE="${VORTX_LIBMPV_CACHE_FIXTURE:-$SCRATCH/low-bitrate-240s.mkv}"
FFMPEG="${VORTX_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
[ -f "$FIXTURE" ] || "$FFMPEG" -y -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=160x90:rate=12:duration=240' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=240' -map 0:v -map 1:a -c:v libx264 -preset ultrafast -crf 38 -g 24 -pix_fmt yuv420p -c:a aac -b:a 24k "$FIXTURE"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
BIN="$SCRATCH/libmpv-cache-reanchor"
xcrun swiftc -sdk "$SDK" -module-cache-path "$SCRATCH/ModuleCache" "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal -framework VideoToolbox -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore -framework CoreGraphics -framework Network -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$BIN" test/libmpv-cache-reanchor/main.swift
/usr/bin/perl -e 'alarm 120; exec @ARGV' "$BIN" "$FIXTURE"
