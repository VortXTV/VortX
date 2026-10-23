#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
run_dir=$(mktemp -d "$PWD/app/build/avplayer-recovery-settlement.XXXXXX")
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  app/Sources/Player/AVPlayerRecoverySettlementPolicy.swift app/Sources/Player/VortXHLSSeekAnchorState.swift \
  app/Sources/Player/RemuxResumePolicy.swift app/Tests/AVPlayerRecoverySettlementPolicyTests.swift -o "$run_dir/checks"
"$run_dir/checks"
printf 'Retained AVPlayer recovery checks: %s\n' "$run_dir"
