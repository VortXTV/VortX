#!/usr/bin/env bash
# Actual production Swift NODE reader + policies against explicitly selected fresh vendor artifacts.
# Silent synthetic localhost only: no app, display/audio device, or provider.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?existing macOS support framework products directory required}"
fixture_artifacts="${2:?selected vendor XCFramework artifacts directory required}"
build_dir="$repo_root/app/build/mpv-cache-snapshot"
mkdir -p "$build_dir"
framework_paths=()
for target in Libmpv-GPL Libavcodec-GPL Libavdevice-GPL Libavfilter-GPL Libavformat-GPL Libavutil-GPL Libswresample-GPL Libswscale-GPL Libplacebo; do
  slice="$fixture_artifacts/$target.xcframework/macos-arm64_x86_64"
  name="${target%-GPL}"
  test -f "$slice/$name.framework/$name"
  framework_paths+=(-F "$slice")
  shasum -a 256 "$slice/$name.framework/$name"
done
frameworks=()
for framework in "$fixture_libs"/*.framework; do
  name="${framework##*/}"
  frameworks+=(-framework "${name%.framework}")
done
# Also regenerate the narrow actual token declarations and check the previously fixed policy.
bash scripts/test-mpv-seek-settlement.sh
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/MPVDemuxerCacheSnapshot.swift app/Sources/Player/MPVCacheReanchorPolicy.swift \
  app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift app/Sources/Player/CacheShedPolicy.swift \
  app/Sources/Player/TVOSProactiveMemoryPressurePolicy.swift \
  app/build/mpv-seek-settlement/PlayerPositionEvent.swift app/Tests/MPVCacheSnapshotTests.swift \
  "${framework_paths[@]}" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
  -framework QuartzCore -framework Security -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/probe"
"$build_dir/probe"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 160 -c:v libx264 -preset ultrafast -threads 1 \
  -g 48 -c:a aac -b:a 32k -y "$build_dir/synthetic.mkv"
python3 scripts/mpv-silent-range-fixture.py --probe "$build_dir/probe" \
  --media "$build_dir/synthetic.mkv" --mode bounded206 --scenario paused
