#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
issue240_test_dir=$(mktemp -d app/build/issue240-tests.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/PlayerEngineRouter.swift \
  app/Sources/Player/TerminalLoadFailurePolicy.swift \
  app/Tests/Issue240PlaybackFailureTests.swift -o "$issue240_test_dir/failure-boundaries"
"$issue240_test_dir/failure-boundaries"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/TerminalLoadFailurePolicy.swift \
  app/Tests/TerminalLoadFailureContractTests.swift -o "$issue240_test_dir/terminal-retirement"
"$issue240_test_dir/terminal-retirement"
