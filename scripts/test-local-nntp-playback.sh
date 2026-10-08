#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
nntp_test_dir=$(mktemp -d app/build/local-nntp-tests.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/CacheShedPolicy.swift \
  app/Sources/Player/TVOSProactiveMemoryPressurePolicy.swift \
  app/Tests/LocalNNTPPlaybackPolicyTests.swift -o "$nntp_test_dir/local-nntp"
"$nntp_test_dir/local-nntp"
