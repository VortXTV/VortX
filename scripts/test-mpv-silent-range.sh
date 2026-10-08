#!/usr/bin/env bash
# Synthetic local HTTP only. Requires an existing macOS framework products directory;
# does not build/launch VortX, open an audio/video device, or contact a provider.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?Usage: bash scripts/test-mpv-silent-range.sh /absolute/existing/macOS/framework-products}"
test -f "$fixture_libs/Libmpv.framework/Headers/mpv/client.h"
test -f "$fixture_libs/libMoltenVK.a"
command -v ffmpeg >/dev/null
build_dir="$repo_root/app/build/silent-seek-fixture"
mkdir -p "$build_dir"
xcrun clang -Wall -Wextra -Werror -c app/Tests/MPVSilentSeekFixture.c \
  -I "$fixture_libs/Libmpv.framework/Headers" -o "$build_dir/main.o"
frameworks=()
for framework in "$fixture_libs"/*.framework; do
  name="${framework##*/}"
  frameworks+=(-framework "${name%.framework}")
done
xcrun swiftc "$build_dir/main.o" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
  -framework QuartzCore -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/probe"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 160 -c:v libx264 -preset ultrafast -threads 1 \
  -g 48 -c:a aac -b:a 32k -y "$build_dir/synthetic.mkv"
for mode in range bounded206 ignored-range; do
  python3 scripts/mpv-silent-range-fixture.py --probe "$build_dir/probe" \
    --media "$build_dir/synthetic.mkv" --mode "$mode"
done
# Run the actual production decision policies against the reproduced deadline shape.
bash scripts/test-mpv-seek-settlement.sh
