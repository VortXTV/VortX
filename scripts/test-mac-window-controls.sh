#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
mac_controls_test_dir=$(mktemp -d app/build/mac-controls-tests.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/MacWindowControls.swift app/Tests/MacWindowControlsTests.swift \
  -o "$mac_controls_test_dir/controls"
"$mac_controls_test_dir/controls"
# Compile the actual representable/coordinator, with only its unrelated playback singleton stubbed.
{
  printf '%s\n' 'import SwiftUI'
  sed -n '/^private struct MacWindowChrome: NSViewRepresentable {/,/^#endif/p' app/SourcesiOS/VortXiOSApp.swift \
    | sed '$d; s/^private struct MacWindowChrome:/struct MacWindowChrome:/'
} > "$mac_controls_test_dir/MacWindowChrome.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/MacWindowControls.swift "$mac_controls_test_dir/MacWindowChrome.swift" \
  app/Tests/MacWindowChromeLifecycleTests.swift -o "$mac_controls_test_dir/lifecycle"
"$mac_controls_test_dir/lifecycle"
