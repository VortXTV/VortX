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
  printf '%s\n' 'import Foundation' 'import AVFoundation'
  if grep -Fq 'enum AVSubtitleRequestRetirementCause' "$preflight_test_dir/engine.swift" app/Sources/Player/*.swift 2>/dev/null; then
    printf '%s\n' 'enum AVSubtitleRequestRetirementCause { case successor, ownerRevoked, uncertainNativeCommit }'
  fi
  printf '%s\n' 'enum DVPlaybackPolicy {'
  sed -n '/    enum NativePreAttachOutcome:/,/    \/\/ MARK: - HLS start position/p' \
    app/Sources/Player/DVPlaybackPolicy.swift | sed '$d'
  printf '%s\n' '}' '@MainActor extension PreflightFixtureEngine {'
  # The same current read-only phase accessor/policy is used on both sides of the baseline comparison;
  # only actual old begin/attach/invalidate methods are swapped, isolating missing production transitions.
  sed -n '/    var nativeStartupPhase:/,/^    }/p' app/Sources/Player/AVPlayerEngine.swift \
    | sed 's/var nativeStartupPhase:/var phase:/'
  # Current invalidation calls this actual pure counter retirement before other teardown.
  # Historical engine inputs without that helper retain their original behavior.
  if grep -Fq '    private func retireSubtitleAlignment() {' "$preflight_test_dir/engine.swift"; then
    grep -Fq '    private var subtitleAlignmentGeneration: UInt64 = 0' "$preflight_test_dir/engine.swift" || {
      printf '%s\n' 'Missing current AV alignment retirement state' >&2
      exit 1
    }
    sed -n '/    private func retireSubtitleAlignment() {/,/^    }/p' "$preflight_test_dir/engine.swift" \
      | sed 's/private func /func /'
  elif grep -Fq '    private func retireSubtitleAlignment(revealRequestedFile: Bool = true,' "$preflight_test_dir/engine.swift"; then
    # The owned-alignment retirement (0a45fbd32) now resolves request and publication state this fixture does not
    # model; its own tests cover that. Here it keeps the counter retirement the preflight sequence depends on.
    printf '%s\n' \
      '    func retireSubtitleAlignment(revealRequestedFile: Bool = true, cause: AVSubtitleRequestRetirementCause? = nil) {' \
      '        subtitleAlignmentGeneration &+= 1' \
      '    }'
  fi
  # Subtitle contribution sharing (0a45fbd32) retires and publishes a contribution object the fixture does not
  # model; its own tests cover it. The item replacement itself is the actual production method.
  if grep -Fq '    private func retireSubtitleContributionLoad() {' "$preflight_test_dir/engine.swift"; then
    printf '%s\n' '    func retireSubtitleContributionLoad() {}' \
      '    func publishSubtitleContributionLoad(for token: PlayerLoadToken) {}'
    sed -n '/    private func replaceContributionPlayerItem(with replacement: AVPlayerItem?) {/,/^    }/p' \
      "$preflight_test_dir/engine.swift" | sed 's/private func /func /'
  fi
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
