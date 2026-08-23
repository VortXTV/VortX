#!/usr/bin/env bash
# Build + run the four executable policy suites plus the PlayerLive baseline, exactly as each suite's own
# header prescribes. Output goes to stdout; exit code is the number of suites that failed.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=.harness/bin
mkdir -p "$OUT"
FAIL=0

run() {
  local name="$1"; shift
  echo "===== SUITE $name ====="
  if ! xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o "$OUT/$name" "$@" 2>&1; then
    echo "SUITE $name BUILD FAILED"; FAIL=$((FAIL+1)); return
  fi
  if "$OUT/$name"; then echo "SUITE $name PASS"; else echo "SUITE $name FAIL"; FAIL=$((FAIL+1)); fi
}

run multi-audio-policy \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/AudioLanguagePolicy.swift \
  app/Sources/Player/MultiAudioPolicy.swift \
  app/Tests/MultiAudioPolicyTests.swift

run subtitle-rendition-policy \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/SubtitleRenditionPolicy.swift \
  app/Sources/Player/PGSOCRPolicy.swift \
  app/Tests/SubtitleRenditionPolicyTests.swift

run dv-playback-contract \
  app/Sources/Player/DVPlaybackPolicy.swift \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Tests/DVPlaybackContractTests.swift

run remux-resume-policy \
  app/Sources/Player/RemuxResumePolicy.swift \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/DVPlaybackPolicy.swift \
  app/Tests/RemuxResumePolicyTests.swift

run remux-first-packet-failure-policy \
  app/Sources/Player/RemuxFirstPacketFailurePolicy.swift \
  app/Tests/RemuxFirstPacketFailurePolicyTests.swift

run producer-lead-policy \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/VortXRemuxProducerLeadPolicy.swift \
  app/Tests/VortXRemuxProducerLeadPolicyTests.swift

run player-live-contract \
  app/Sources/Player/DVPlaybackPolicy.swift \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/PlayerStallPolicy.swift \
  app/Sources/Player/VortXHLSSeekAnchorState.swift \
  app/Sources/Player/AudioLanguagePolicy.swift \
  app/Sources/Player/MultiAudioPolicy.swift \
  app/Sources/Player/SubtitleRenditionPolicy.swift \
  app/Tests/PlayerLiveContractTests.swift

echo "===== SUITES FAILED: $FAIL ====="
exit "$FAIL"
