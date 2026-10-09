#!/usr/bin/env bash
# Compile one selected-vendor transport probe, then reuse existing synthetic media on literal loopback.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?existing macOS support framework products directory required}"
fixture_artifacts="${2:?selected vendor XCFramework artifacts directory required}"
fixture_media="${3:?existing synthetic MKV fixture path required}"
modes=("${@:4}")
if [[ ${#modes[@]} == 0 ]]; then modes=(immediate stalled); fi
test -f "$fixture_media"
build_dir="$repo_root/app/build/mpv-inflight-seek"
mkdir -p "$build_dir"
shasum -a 256 "$fixture_media" app/Sources/Player/MPVMetalViewController.swift \
  app/Tests/MPVInFlightSeekFixture.c scripts/mpv-inflight-seek-fixture.py
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
xcrun clang -Wall -Wextra -Werror -c app/Tests/MPVInFlightSeekFixture.c \
  -I "$fixture_artifacts/Libmpv-GPL.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers" -o "$build_dir/main.o"
xcrun swiftc "$build_dir/main.o" "${framework_paths[@]}" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
  -framework QuartzCore -framework Security -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/probe"
shasum -a 256 "$build_dir/probe"
for mode in "${modes[@]}"; do
  python3 scripts/mpv-inflight-seek-fixture.py --probe "$build_dir/probe" --media "$fixture_media" --mode "$mode" \
    | tee "$build_dir/$mode.log"
done
