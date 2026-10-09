#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
seek_gate_dir=$(mktemp -d app/build/hls-seek-producer-gate.XXXXXX)
# Compile the exact server methods against the real anchor, byte ledger and producer condition gate.
# No AVPlayer, provider, HTTP listener, audio session or installed app is started.
fixture=app/Tests/HLSSeekProducerGateTests.swift
server=app/Sources/Player/VortXRemuxHLSServer.swift
{
  sed '/^    \/\/ INSERT PRODUCTION SERVER METHODS/,$d' "$fixture"
  sed -n '/^    func reportPlaybackPosition(/,/^    private func playbackSegmentID(/p' "$server" | sed '$d'
  sed -n '/^    private func retireStartupProducerReservation(/,/^    \/\/\/ Updates the lead gate/p' "$server" | sed '$d'
  sed -n '/^    private func refreshProducerLeadGate(/,/^    private func producerDidPublish(/p' "$server" | sed '$d'
  sed -n '/^    \/\/ INSERT PRODUCTION SERVER METHODS/,$p' "$fixture" | sed '1d'
} > "$seek_gate_dir/server-fixture.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/VortXRemuxProducerLeadPolicy.swift \
  app/Sources/Player/VortXHLSSeekAnchorState.swift \
  "$seek_gate_dir/server-fixture.swift" -o "$seek_gate_dir/seek-producer-gate"
"$seek_gate_dir/seek-producer-gate"
