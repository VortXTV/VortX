#!/usr/bin/env bash
# =============================================================================
# run-eac3.sh - build + run the E-AC-3 transcode acceptance harness.
#
# Links the REAL VortXAudioTranscoder against the FFmpeg we actually ship, runs it over a
# TrueHD source, and reads the muxed result back with ffprobe. See main.swift.
#
#   ./run-eac3.sh              our own rebuilt frameworks (app/Vendor/MPVKit-DVFEL)
#   ./run-eac3.sh --control    upstream MPVKit, i.e. before --enable-encoder=eac3.
#                              This run is EXPECTED to go RED; it is the before half of the
#                              before/after evidence, not a failure.
#
# Exit code = RED count (the harness's, plus one if ffprobe disagrees).
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

FRAMEWORK_KEYS=(Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL \
  Libswresample-GPL Libswscale-GPL Libplacebo \
  Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz \
  Libshaderc_combined lcms2 Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls \
  Libdav1d Libuavs3d)

LINK_FLAGS=()
OWN=()
for key in "${FRAMEWORK_KEYS[@]}"; do
  slice=""
  if [ -d "$PRIMARY/$key.xcframework" ]; then
    slice=$(find "$PRIMARY/$key.xcframework" -maxdepth 1 -type d -name 'macos-arm64*' | head -n 1)
    [ -n "$slice" ] && OWN+=("$key")
  fi
  [ -n "$slice" ] || slice=$(find "$FALLBACK/$key" -type d -name 'macos-arm64*' 2>/dev/null | head -n 1)
  [ -n "$slice" ] || { echo "missing macos slice for $key" >&2; exit 2; }
  fw=$(find "$slice" -maxdepth 1 -name '*.framework' -type d | head -n 1)
  LINK_FLAGS+=( -F "$(dirname "$fw")" -framework "$(basename "$fw" .framework)" )
done
MOLTEN=$(find "$FALLBACK/MoltenVK" -path '*macos-arm64*/libMoltenVK.a' | head -n 1)
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
echo "from own build: ${OWN[*]:-(none, this is the upstream control)}"

OUT=/tmp/dd-eac3
mkdir -p "$OUT"
FIXTURE="$OUT/truehd-source.mkv"
if [ ! -f "$FIXTURE" ]; then
  # TrueHD 5.1: the exact source shape whose audio AVPlayer cannot decode, so the DV remux
  # must transcode it. FFmpeg's truehd encoder is experimental, hence -strict -2.
  /opt/homebrew/bin/ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=320x180:rate=24:duration=10" \
    -f lavfi -i "sine=frequency=440:duration=10:sample_rate=48000" \
    -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" \
    -map 0:v -map "[a]" \
    -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p \
    -c:a truehd -strict -2 \
    "$FIXTURE"
fi

MUXED="$OUT/transcoded.mp4"
rm -f "$MUXED"
BIN="$OUT/eac3-transcode"
xcrun swiftc -sdk "$SDK_PATH" \
  "${LINK_FLAGS[@]}" "$MOLTEN" \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
  -framework CoreFoundation -framework CoreMedia -framework Metal -framework VideoToolbox \
  -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore -framework Network \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -o "$BIN" \
  app/Sources/Player/AudioTranscodePolicy.swift \
  app/Sources/Player/VortXAudioTranscoder.swift \
  test/eac3-transcode/main.swift

# Single source of truth for the muxer contract: read the shipping values straight out of
# DVPlaybackPolicy.swift rather than restating them here, so this harness can never drift from
# what the product actually muxes with. (The policy file itself is not standalone-compilable, it
# depends on types from the wider player module, hence extracting the strings instead of linking it.)
POLICY=app/Sources/Player/DVPlaybackPolicy.swift
MOVFLAGS=$(sed -n 's/.*static let movflags = "\(.*\)".*/\1/p' "$POLICY" | head -n 1)
MINFRAG=$(sed -n 's/.*static let minimumFragmentDurationMicroseconds = "\(.*\)".*/\1/p' "$POLICY" | head -n 1)
[ -n "$MOVFLAGS" ] && [ -n "$MINFRAG" ] || { echo "could not read movflags policy from $POLICY" >&2; exit 2; }
echo "movflags from $POLICY: $MOVFLAGS (min_frag_duration=$MINFRAG)"

set +e
"$BIN" "$FIXTURE" "$MUXED" "$MOVFLAGS" "$MINFRAG"
RC=$?
set -e

# Independent read-back: the muxed file must actually carry an E-AC-3 track, tagged so a
# receiver sees Dolby Digital Plus rather than decoded PCM.
if [ -f "$MUXED" ]; then
  CODEC=$(/opt/homebrew/bin/ffprobe -v error -select_streams a:0 \
          -show_entries stream=codec_name,codec_tag_string,channels,sample_rate \
          -of default=nw=1 "$MUXED" | tr '\n' ' ')
  echo "PROBE  muxed output: $CODEC"
  case "$CODEC" in
    *codec_name=eac3*) echo "GREEN  ffprobe read-back: the muxed track is E-AC-3 (ec-3)";;
    *) echo "RED    ffprobe read-back: expected eac3, got: $CODEC"; RC=$((RC+1));;
  esac
else
  echo "RED    ffprobe read-back: no output file was produced"; RC=$((RC+1))
fi
echo "run-eac3: exit $RC"
exit $RC
