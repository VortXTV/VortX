#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/vortx-featured-hero-lifecycle.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  app/Tests/FeaturedHeroLifecycleContractTests.swift \
  -o "$build_dir/featured-hero-lifecycle-tests"
"$build_dir/featured-hero-lifecycle-tests" "$root"

# Parse the actual production files as a separate gate; a passing inert harness must not mask a syntax error.
xcrun swiftc -frontend -parse \
  app/SourcesiOS/FeaturedHeroModel.swift \
  app/SourcesShared/ERDBConfig.swift

print 'ok: featured hero production source parses and lifecycle contracts pass'
