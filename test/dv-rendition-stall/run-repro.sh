#!/usr/bin/env bash
# Build + run the DV rendition/stall repro harness against the production remux +
# HLS server, standalone on macOS. Uses the same mpvkit link recipe as
# app/Tests/HLSFragmentPublicationIntegrationTests.swift. Exit code = RED count.
set -euo pipefail
cd "$(dirname "$0")/../.."

MPV_ROOT="${MPV_ROOT:-$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/VortX-*/SourcePackages/artifacts/mpvkit 2>/dev/null | head -n 1)}"
[ -n "$MPV_ROOT" ] || { echo "no mpvkit artifacts found; set MPV_ROOT" >&2; exit 2; }

FRAMEWORK_KEYS=(Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL \
  Libswresample-GPL Libswscale-GPL Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz \
  Libshaderc_combined lcms2 Libplacebo Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls \
  Libdav1d Libuavs3d)
LINK_FLAGS=()
for key in "${FRAMEWORK_KEYS[@]}"; do
  slice=$(find "$MPV_ROOT/$key" -type d -name macos-arm64_x86_64 2>/dev/null | head -n 1)
  [ -n "$slice" ] || { echo "missing slice for $key" >&2; exit 2; }
  framework_dir=$(find "$slice" -maxdepth 1 -name '*.framework' -type d | head -n 1)
  LINK_FLAGS+=( -F "$(dirname "$framework_dir")" -framework "$(basename "$framework_dir" .framework)" )
done
MOLTEN_ARCHIVE=$(find "$MPV_ROOT/MoltenVK" -path '*macos-arm64_x86_64/libMoltenVK.a' | head -n 1)
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

test/dv-rendition-stall/make-fixture.sh "${FIXTURE_SECONDS:-240}"

mkdir -p /tmp/dd-dvstall
xcrun swiftc -sdk "$SDK_PATH" \
  "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
  -framework CoreFoundation -framework CoreMedia -framework Metal -framework VideoToolbox \
  -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore \
  -framework Network \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -o /tmp/dd-dvstall/repro-harness \
  test/dv-rendition-stall/Stubs.swift \
  app/Sources/Player/DVPlaybackPolicy.swift \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/MultiAudioPolicy.swift \
  app/Sources/Player/SubtitleRenditionPolicy.swift \
  app/Sources/Player/RemuxResumePolicy.swift \
  app/Sources/Player/AudioTranscodePolicy.swift \
  app/Sources/Player/VortXAudioTranscoder.swift \
  app/Sources/Player/VortXMKVRemuxStream.swift \
  app/Sources/Player/VortXRemuxHLSServer.swift \
  test/dv-rendition-stall/main.swift

exec /tmp/dd-dvstall/repro-harness
