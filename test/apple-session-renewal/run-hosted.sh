#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'Usage: run-hosted.sh <reviewed-source-directory> <Root-reviewed-exact-source-pins.json> <context-root> <NEW-owned-scratch>' >&2
  exit 2
fi
source_dir="$1"
source_pins="$2"
context_root="$3"
scratch="$4"
packet_dir="$(cd "$(dirname "$0")" && pwd)"
[[ ! -e "$scratch" ]] || { echo 'New scratch required' >&2; exit 2; }
mkdir -p "$scratch"
node "$packet_dir/generate.mjs" "$source_dir" "$source_pins" "$context_root" "$scratch" "$packet_dir/RenewalTests.swift"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  "$scratch/Production.swift" "$packet_dir/RenewalTests.swift" -o "$scratch/session-renewal-tests" 2>&1 | tee "$scratch/compile.log"
"$scratch/session-renewal-tests" 2>&1 | tee "$scratch/runtime.log"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  "$scratch/CredentialResultTypes.swift" "$scratch/original-suite/app/SourcesShared/Keychain.swift" \
  "$packet_dir/FileTransactionTests.swift" -o "$scratch/file-transaction-tests" 2>&1 | tee "$scratch/file-transaction.compile.log"
"$scratch/file-transaction-tests" "$scratch/files" 2>&1 | tee "$scratch/file-transaction.runtime.log"
# Preserve the original whole-suite route and its original compiler-default language mode.
xcrun swiftc -j 1 -num-threads 1 "$scratch/CredentialResultTypes.swift" "$scratch/original-suite/app/SourcesShared/Keychain.swift" \
  "$scratch/original-suite/app/Tests/KeychainFailureClosedTests.swift" -o "$scratch/original-keychain-tests" 2>&1 | tee "$scratch/original-keychain.compile.log"
"$scratch/original-keychain-tests" 2>&1 | tee "$scratch/original-keychain.runtime.log"
