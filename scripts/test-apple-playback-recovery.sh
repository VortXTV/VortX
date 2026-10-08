#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
recovery_test_dir=$(mktemp -d app/build/apple-recovery-tests.XXXXXX)
# These are generated dependency-free slices of production declarations, not alternate implementations.
sed -n '/^struct AVPlayerRemuxStartupSignal:/,/^\/\/ MARK: - PiP state machine/p' \
  app/Sources/Player/AVPlayerEngine.swift | sed '$d' > "$recovery_test_dir/remux-signal.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^enum NodeListenerRebindPolicy {/,/^\/\/ END Node listener rebind policy$/p' \
    app/Sources/NodeServer.swift | sed '$d'
} > "$recovery_test_dir/node-listener.swift"
shared_sources=(
  app/Sources/Player/ApplePlaybackRecoveryPolicy.swift
  app/Sources/Player/MPVTrack.swift
  app/Sources/Player/PlayerStallPolicy.swift
)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${shared_sources[@]}" app/Tests/AppleEngineSurfaceTransferTests.swift \
  -o "$recovery_test_dir/surface-transfer"
"$recovery_test_dir/surface-transfer"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${shared_sources[@]}" "$recovery_test_dir/remux-signal.swift" \
  app/Tests/TVAVStartWatchdogPolicyTests.swift -o "$recovery_test_dir/startup"
"$recovery_test_dir/startup"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${shared_sources[@]}" "$recovery_test_dir/node-listener.swift" \
  app/Tests/NodeListenerRebindAndTVAudioRecoveryTests.swift -o "$recovery_test_dir/tracks"
"$recovery_test_dir/tracks"
# Local article-stream buffering and repeated-starvation recovery use the same Apple source gate.
bash scripts/test-local-nntp-playback.sh
