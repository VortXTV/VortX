#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
recovery_test_dir=$(mktemp -d app/build/apple-recovery-tests.XXXXXX)
# These are generated dependency-free slices of production declarations, not alternate implementations.
sed -n '/^struct AVPlayerRemuxStartupSignal:/,/^}/p' \
  app/Sources/Player/AVPlayerEngine.swift > "$recovery_test_dir/remux-signal.swift"
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
bash scripts/test-native-dv-preflight.sh
bash scripts/test-avplayer-subtitle-clock.sh
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${shared_sources[@]}" \
  app/Tests/NodeListenerRebindAndTVAudioRecoveryTests.swift -o "$recovery_test_dir/tracks"
"$recovery_test_dir/tracks"
# Local article-stream buffering and repeated-starvation recovery use the same Apple source gate.
bash scripts/test-local-nntp-playback.sh
bash scripts/test-player-first-frame-artwork.sh
bash scripts/test-random-pick.sh
bash scripts/test-player-session-audio-presets.sh
bash scripts/test-source-quick-filters.sh
bash scripts/test-ranking-cache-concurrency.sh
