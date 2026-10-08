#!/usr/bin/env bash
# No loadfile/network/media/output devices. Native status/format proof + controller source contracts.
# Baseline RED means these diagnostic fields are absent, NOT that playback was reproduced/fixed.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?existing macOS support framework products directory required}"
fixture_artifacts="${2:?selected vendor XCFramework artifacts directory required}"
baseline_revision="${3:?immutable baseline revision required}"
build_dir="$repo_root/app/build/mpv-seek-transport-diagnostic"
mkdir -p "$build_dir"
controller="app/Sources/Player/MPVMetalViewController.swift"
git show "$baseline_revision:$controller" > "$build_dir/baseline-controller.swift"
cp "$controller" "$build_dir/candidate-controller.swift"
shasum -a 256 "$build_dir/baseline-controller.swift" "$build_dir/candidate-controller.swift" \
  app/Sources/Player/MPVSeekTransportDiagnostic.swift app/Tests/MPVSeekTransportDiagnosticTests.swift
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
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/MPVSeekTransportDiagnostic.swift app/Tests/MPVSeekTransportDiagnosticTests.swift \
  "${framework_paths[@]}" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
  -framework QuartzCore -framework Security -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/probe"
shasum -a 256 "$build_dir/probe"
set +e
"$build_dir/probe" "$build_dir/baseline-controller.swift" > "$build_dir/baseline.log" 2>&1
baseline_status=$?
set -e
cat "$build_dir/baseline.log"
if [[ "$baseline_status" != 1 ]] || ! rg -q 'native/pure failures=0; controller-wiring failures=4$' "$build_dir/baseline.log"; then
  echo "Unexpected baseline: require exactly four absent diagnostic wiring contracts and no native/pure failure"
  exit 1
fi
"$build_dir/probe" "$build_dir/candidate-controller.swift" | tee "$build_dir/candidate.log"
shasum -a 256 "$build_dir/baseline.log" "$build_dir/candidate.log"
