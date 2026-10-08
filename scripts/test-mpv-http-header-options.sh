#!/usr/bin/env bash
# Property-only fixture: no loadfile, HTTP request, audio/display device or installed app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?existing macOS support framework products directory required}"
fixture_artifacts="${2:?selected vendor XCFramework artifacts directory required}"
baseline_revision="${3:-}"
mode="candidate"
if [[ -n "$baseline_revision" ]]; then mode="baseline-${baseline_revision:0:12}"; fi
build_dir="$repo_root/app/build/mpv-http-header-admission-$mode"
mkdir -p "$build_dir"
controller="app/Sources/Player/MPVMetalViewController.swift"
if [[ -n "$baseline_revision" ]]; then
  git show "$baseline_revision:$controller" > "$build_dir/controller.swift"
else
  cp "$controller" "$build_dir/controller.swift"
fi
shasum -a 256 "$build_dir/controller.swift"
# Compile the real controller block including state resets and the entire trailer branch. Only native
# setter failure and non-header dependencies are isolated by the test host; no media/proxy is opened.
awk '
BEGIN {
  print "import Foundation"
  print "import Libmpv"
  print "@MainActor"
  print "struct ExtractedMPVHTTPHeaderApplication {"
  print "let mpv: OpaquePointer?; let defaultUserAgent = \"fixture\"; var issuedToken: Int32 = -1"
  print "var loggedHardwareDecoderNegotiation = true; var appliedDynamicRange: Int? = 7; var secondarySubtitleID = 42"
  print "let cacheFlushFlight = FixtureCacheFlight(); var cacheResets = 0"
  print "mutating func finishCacheFlushFlight(_ ignored: Bool) { cacheResets += 1 }"
  print "mutating func checkError(_ status: Int32) { issuedToken = status }"
  print "func setString(_ name: String, _ value: String) { if let mpv { mpv_set_property_string(mpv, name, value) } }"
  print "mutating func apply(_ headers: [String: String]?, url: URL = URL(string: \"https://fixture.invalid/video\")!, audioSidecar: URL? = nil) -> Int32 {"
}
/    private func loadFile\(/ { inload=1 }
inload && !copying && /        finishCacheFlushFlight\(cacheFlushFlight.reset\(\)\)/ { print }
inload && !copying && (/        loggedHardwareDecoderNegotiation = false/ || /        \/\/ Header-admission transaction begins/) { copying=1; found++ }
copying && /        \/\/ yt-direct adaptive pair:/ { copying=0; inload=0 }
copying { print }
END {
  print "return 0 } }"
  if (found != 1) exit 1
}' "$build_dir/controller.swift" > "$build_dir/ExtractedMPVHTTPHeaderApplication.swift"
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
sources=(app/Sources/Player/StreamRequestHeaderPolicy.swift "$build_dir/ExtractedMPVHTTPHeaderApplication.swift" app/Tests/MPVHTTPHeaderOptionsTests.swift)
helper="app/Sources/Player/MPVHTTPHeaderOptions.swift"
if [[ -n "$baseline_revision" ]] && ! git cat-file -e "$baseline_revision:$helper" 2>/dev/null; then
  sources+=(-D MPV_HTTP_HEADER_BASELINE)
else
  if [[ -n "$baseline_revision" ]]; then
    git show "$baseline_revision:$helper" > "$build_dir/helper.swift"
  else
    cp "$helper" "$build_dir/helper.swift"
  fi
  shasum -a 256 "$build_dir/helper.swift"
  # Rename only the type to let the controller-bound fixture inject a negative setter return.
  sed 's/enum MPVHTTPHeaderOptions {/enum NativeMPVHTTPHeaderOptions {/' "$build_dir/helper.swift" > "$build_dir/NativeMPVHTTPHeaderOptions.swift"
  sources+=("$build_dir/NativeMPVHTTPHeaderOptions.swift")
fi
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${sources[@]}" "${framework_paths[@]}" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
  -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
  -framework QuartzCore -framework Security -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/probe"
shasum -a 256 "$build_dir/probe"
"$build_dir/probe"
