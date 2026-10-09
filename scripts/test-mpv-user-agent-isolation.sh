#!/usr/bin/env bash
# Actual controller declaration/setup/header-admission extraction. No loadfile, network or devices.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fixture_libs="${1:?existing macOS support framework products directory required}"
fixture_artifacts="${2:?selected vendor XCFramework artifacts directory required}"
baseline_revision="${3:?immutable baseline revision required}"
build_dir="$repo_root/app/build/mpv-user-agent-isolation"
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
# Real ownership state; omit unrelated CoreModels types rather than replacing owner logic with a stub.
awk 'BEGIN { print "import Foundation" }
/^struct PlayerLoadToken:/ { token=1 }
token { print; if ($0 == "}") token=0 }
/^struct PlayerLoadProvenanceState / { provenance=1 }
provenance { print; if ($0 == "}") provenance=0 }
' app/SourcesShared/CoreModels.swift > "$build_dir/PlayerLoadProvenance.swift"
sed 's/enum MPVHTTPHeaderOptions {/enum NativeMPVHTTPHeaderOptions {/' \
  app/Sources/Player/MPVHTTPHeaderOptions.swift > "$build_dir/NativeMPVHTTPHeaderOptions.swift"
for mode in baseline candidate; do
  controller="$build_dir/$mode-controller.swift"
  if [[ "$mode" == baseline ]]; then
    git show "$baseline_revision:app/Sources/Player/MPVMetalViewController.swift" > "$controller"
  else
    cp app/Sources/Player/MPVMetalViewController.swift "$controller"
  fi
  awk '
  BEGIN {
    print "import Foundation\nimport Libmpv\n@MainActor final class ExtractedMPVUserAgentApplication {"
    print "let mpv: OpaquePointer?; init(mpv: OpaquePointer) { self.mpv = mpv }"
    print "var loggedHardwareDecoderNegotiation = true; var appliedDynamicRange: Int? = 7; var secondarySubtitleID = 42"
    print "let cacheFlushFlight = FixtureCacheFlight(); var cacheResets = 0; var lastStatus: Int32 = 0"
    print "var loadProvenance = PlayerLoadProvenanceState(); var nextEntry: Int64 = 1"
    print "func finishCacheFlushFlight(_ ignored: Bool) { cacheResets += 1 }; func checkError(_ status: Int32) { lastStatus = status }"
    print "func getString(_ name: String) -> String? { guard let mpv, let p = mpv_get_property_string(mpv, name) else { return nil }; defer { mpv_free(p) }; return String(cString: p) }"
    print "func setString(_ name: String, _ value: String) { if let mpv { mpv_set_property_string(mpv, name, value) } }"
  }
  /checkError\(mpv_set_option_string\(mpv, "user-agent",/ { setup=1; setupCount++; print "func configureNativeUserAgent() {" }
  setup { print; if (/\)\)/) { setup=0; print "}" } }
  /private (lazy var|let) defaultUserAgent =/ { print; declarationCount++ }
  /    private func loadFile\(/ { inload=1 }
  inload && /        \/\/ Header-admission transaction begins/ {
    copying=1; headerCount++
    print "func apply(_ headers: [String: String]?, url: URL = URL(string: \"https://fixture.invalid/video\")!, audioSidecar: URL? = nil) -> PlayerLoadToken {"
    print "let issuedToken = PlayerLoadToken()"
  }
  copying && /        \/\/ yt-direct adaptive pair:/ {
    copying=0
    # This models only the successful command result at the production admission boundary. No media opens.
    print "let commandResult: Int32 = 0; let entryID = nextEntry; nextEntry += 1"
  }
  copying { print }
  inload && /        loadProvenance.completeReplacement\(/ { admission=1; admissionCount++ }
  admission {
    print
    if (/^        \)/) {
      admission=0; inload=0
      print "loadProvenance.bindStart(entryID: entryID); loadProvenance.markFileLoaded(); return issuedToken }"
    }
  }
  END { print "}"; if (setupCount != 1 || declarationCount != 1 || headerCount != 1 || admissionCount != 1) exit 1 }
  ' "$controller" > "$build_dir/$mode-extracted.swift"
  shasum -a 256 "$controller" "$build_dir/$mode-extracted.swift"
  xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/Sources/Player/StreamRequestHeaderPolicy.swift "$build_dir/NativeMPVHTTPHeaderOptions.swift" \
    "$build_dir/PlayerLoadProvenance.swift" "$build_dir/$mode-extracted.swift" app/Tests/MPVUserAgentIsolationTests.swift \
    "${framework_paths[@]}" -F "$fixture_libs" "${frameworks[@]}" "$fixture_libs/libMoltenVK.a" \
    -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -framework CoreVideo -framework CoreFoundation -framework CoreMedia -framework Metal \
    -framework VideoToolbox -framework IOKit -framework OpenGL -framework UniformTypeIdentifiers \
    -framework QuartzCore -framework Security -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ -o "$build_dir/$mode-probe"
  set +e
  "$build_dir/$mode-probe" > "$build_dir/$mode.log" 2>&1
  status=$?
  set -e
  cat "$build_dir/$mode.log"
  if [[ "$mode" == baseline ]]; then
    [[ "$status" == 1 ]] && rg -q '^28/35 PASS; failures=7$' "$build_dir/$mode.log"
  else
    [[ "$status" == 0 ]] && rg -q '^35/35 PASS; failures=0$' "$build_dir/$mode.log"
  fi
  shasum -a 256 "$build_dir/$mode-probe" "$build_dir/$mode.log"
done
