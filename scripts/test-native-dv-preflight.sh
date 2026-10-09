#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
preflight_test_dir=$(mktemp -d app/build/native-preflight-tests.XXXXXX)
# Optional baseline uses the exact old engine methods against the same fixture/policy. No checkout or media.
if [[ $# -gt 0 ]]; then
  git show "$1:app/Sources/Player/AVPlayerEngine.swift" > "$preflight_test_dir/engine.swift"
else
  cp app/Sources/Player/AVPlayerEngine.swift "$preflight_test_dir/engine.swift"
fi
{
  printf '%s\n' 'import Foundation' 'enum DVPlaybackPolicy {'
  sed -n '/    enum NativePreAttachOutcome:/,/    \/\/ MARK: - HLS start position/p' \
    app/Sources/Player/DVPlaybackPolicy.swift | sed '$d'
  printf '%s\n' '}' '@MainActor extension PreflightFixtureEngine {'
  # The same current read-only phase accessor/policy is used on both sides of the baseline comparison;
  # only actual old begin/attach/invalidate methods are swapped, isolating missing production transitions.
  sed -n '/    var nativeStartupPhase:/,/^    }/p' app/Sources/Player/AVPlayerEngine.swift \
    | sed 's/var nativeStartupPhase:/var phase:/'
  sed -n '/    func invalidateLoadToken() {/,/^    }/p' "$preflight_test_dir/engine.swift" \
    | sed '/^[[:space:]]*#if os(tvOS)/d; /^[[:space:]]*#endif/d'
  sed -n '/    private func pendingLoadIsCurrent(/,/    \/\/ MARK: - External engine mode/p' \
    "$preflight_test_dir/engine.swift" \
    | sed '$d; /^[[:space:]]*#if os(tvOS)/d; /^[[:space:]]*#endif/d; s/private func /func /'
  printf '%s\n' '}'
} > "$preflight_test_dir/production-methods.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/ApplePlaybackRecoveryPolicy.swift \
  app/Sources/Player/MPVTrack.swift app/Sources/Player/PlayerStallPolicy.swift \
  "$preflight_test_dir/production-methods.swift" app/Tests/NativeDVPreflightMethodTests.swift \
  -o "$preflight_test_dir/preflight"
"$preflight_test_dir/preflight"
