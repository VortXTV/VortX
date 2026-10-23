#!/usr/bin/env bash
# Infuse round trip (play link + x-success callback policy) and the external-player handoff contract.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/infuse-return.XXXXXX)
trap 'rm -rf "$dir"' EXIT
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/InfuseReturn.swift app/SourcesShared/InfuseDeepLink.swift \
  app/Tests/InfuseReturnPolicyTests.swift -o "$dir/policy"
"$dir/policy"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/InfuseReturn.swift app/SourcesShared/InfuseDeepLink.swift \
  app/Sources/ExternalPlayer.swift app/Tests/ExternalPlayerHandoffContractTests.swift -o "$dir/handoff"
"$dir/handoff"
