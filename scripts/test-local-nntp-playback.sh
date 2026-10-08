#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
nntp_test_dir=$(mktemp -d app/build/local-nntp-tests.XXXXXX)
# Compile the actual dependency-free TV admission declaration, not a mirrored test implementation.
sed -n '/^enum TVLocalNNTPShortResumePolicy {/,/^\/\/ END TVLocalNNTPShortResumePolicy$/p' \
  app/SourcesTV/TVPlayerView.swift | sed '$d' > "$nntp_test_dir/tv-short-resume.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/CacheShedPolicy.swift \
  app/Sources/Player/TVOSProactiveMemoryPressurePolicy.swift \
  app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
  "$nntp_test_dir/tv-short-resume.swift" \
  app/Tests/LocalNNTPPlaybackPolicyTests.swift -o "$nntp_test_dir/local-nntp"
"$nntp_test_dir/local-nntp"
