#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
contract_test_dir=$(mktemp -d "$PWD/app/build/source-index-torrent-contract.XXXXXX")
printf 'Retained standalone contract artifacts: %s\n' "$contract_test_dir"
contract_inputs=(
  app/SourcesShared/SourceIndexContract.swift
  app/SourcesShared/SourceIndexIdentity.swift
  app/SourcesShared/SourceContributionWorkPolicy.swift
  app/SourcesShared/MoatToken.swift
  app/SourcesShared/SourceSettlementPolicy.swift
  app/SourcesShared/ProviderCircuitBreaker.swift
  app/SourcesShared/TorBoxSearchSource.swift
  app/SourcesShared/SourceIndexClient.swift
  app/Tests/SourceIndexTorrentContractTests.swift
)
shasum -a 256 "${contract_inputs[@]}" > "$contract_test_dir/inputs.before.sha256"
contract_compile_status=0
nice -n 15 /usr/bin/xcrun swiftc -j 1 -num-threads 1 -whole-module-optimization \
  -D SOURCE_INDEX_IDENTITY_TESTING -swift-version 6 \
  -strict-concurrency=complete -warnings-as-errors \
  -o "$contract_test_dir/source-index-torrent-contract" \
  "${contract_inputs[@]}" > "$contract_test_dir/compile.log" 2>&1 || contract_compile_status=$?
if (( contract_compile_status != 0 )); then
  cat "$contract_test_dir/compile.log"
  exit "$contract_compile_status"
fi
printf 'COMPILE PASS\n'
contract_run_status=0
nice -n 15 "$contract_test_dir/source-index-torrent-contract" \
  > "$contract_test_dir/run.log" 2>&1 || contract_run_status=$?
shasum -a 256 "${contract_inputs[@]}" > "$contract_test_dir/inputs.after.sha256"
if ! cmp -s "$contract_test_dir/inputs.before.sha256" "$contract_test_dir/inputs.after.sha256"; then
  printf 'FAIL: source inputs changed during compile or run; receipt is not current.\n' >&2
  exit 2
fi
cat "$contract_test_dir/run.log"
exit "$contract_run_status"
