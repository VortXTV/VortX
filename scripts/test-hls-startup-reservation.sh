#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
fixture_dir=$(mktemp -d app/build/hls-startup-reservation.XXXXXX)
fixture=app/Tests/HLSStartupReservationTests.swift
server=app/Sources/Player/VortXRemuxHLSServer.swift
policy=app/Sources/Player/VortXRemuxProducerLeadPolicy.swift
flags=(-D STARTUP_RESERVATION)
if [[ ${1:-} == --baseline ]]; then
  baseline=b4ffe71ebe09c23b681ecc7bcd650b9e313521c3
  git show "$baseline:$server" > "$fixture_dir/baseline-server.swift"
  git show "$baseline:$policy" > "$fixture_dir/baseline-policy.swift"
  server="$fixture_dir/baseline-server.swift"
  policy="$fixture_dir/baseline-policy.swift"
  flags=(-D STARTUP_BASELINE)
elif [[ $# != 0 ]]; then
  exit 2
fi
# The only doubles are stream/storage receipts and scheduling: the gate, byte ledger, cohort policy,
# publication, real-clock admission, seek reanchor, preparation poll and adoption methods are production.
{
  sed '/^    \/\/ INSERT PRODUCTION SERVER METHODS/,$d' "$fixture"
  sed -n '/^    func reportPlaybackPosition(/,/^    private func playbackSegmentID(/p' "$server" | sed '$d'
  sed -n '/^    private func retireStartupProducerReservation(/,/^    \/\/\/ Updates the lead gate/p' "$server" | sed '$d'
  sed -n '/^    private func refreshProducerLeadGate(/,/^    private func producerDidPublish(/p' "$server" | sed '$d'
  sed -n '/^    private func prepareMasterPublication(/,/^    private func logStartupCohortTimeout(/p' "$server" | sed '$d'
  sed -n '/^    private func topologyMatches(/,/^    \/\/\/ Both video variants render/p' "$server" | sed '$d'
  sed -n '/^    private func pollPreparedReadiness(/,/^    \/\/\/ F3:/p' "$server" | sed '$d'
  sed -n '/^    func adoptPrepared(/,/^    var isPreparedForAdoption:/p' "$server" | sed '$d'
  sed -n '/^    \/\/ INSERT PRODUCTION SERVER METHODS/,$p' "$fixture" | sed '1d'
} > "$fixture_dir/actual-server.swift"
{
  echo 'import Foundation'
  sed -n '/^final class VortXRemuxPreparationGate:/,/^final class VortXRemuxProducerTicket:/p' \
    app/Sources/Player/VortXPreparedRemuxPolicy.swift | sed '$d'
} > "$fixture_dir/preparation-gate.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors "${flags[@]}" \
  app/Sources/Player/VortXRemuxBuffer.swift "$policy" \
  app/Sources/Player/DVPlaybackPolicy.swift app/Sources/Player/PlayerStallPolicy.swift \
  app/Sources/Player/VortXHLSSeekAnchorState.swift app/Sources/Player/AudioLanguagePolicy.swift \
  app/Sources/Player/MultiAudioPolicy.swift app/Sources/Player/SubtitleRenditionPolicy.swift \
  "$fixture_dir/preparation-gate.swift" "$fixture_dir/actual-server.swift" \
  -o "$fixture_dir/startup-reservation"
"$fixture_dir/startup-reservation" "$fixture_dir"
