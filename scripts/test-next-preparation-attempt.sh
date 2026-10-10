#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p app/build
test_dir=$(mktemp -d app/build/next-preparation-attempt.XXXXXX)

test_source=app/Tests/NextEpisodePreparationAttemptTests.swift
owner_source=app/SourcesShared/NextEpisodePreparationAttemptOwner.swift
current_source=app/SourcesiOS/iOSNextEpisodePreparer.swift
baseline_source="$test_dir/iOSNextEpisodePreparer.baseline.swift"

compile() {
  local output=$1
  shift
  local log="$output.compile.log"
  if ! xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
      "$@" -o "$output" >"$log" 2>&1; then
    printf 'FAIL compile: %s\n' "$output"
    sed -n '1,240p' "$log"
    return 1
  fi
}

run_test() {
  local binary=$1
  local log="$binary.runtime.log"
  if "$binary" >"$log" 2>&1; then
    cat "$log"
    return 0
  fi
  cat "$log"
  return 1
}

git show f9c45518b:app/SourcesiOS/iOSNextEpisodePreparer.swift \
  | awk '{ print; if ($0 ~ /^[[:space:]]*let sources: \[StreamSource\]/) print "    let legacyAddons: [AddonDescriptor]" }' \
  >"$baseline_source"

printf '%s\n' '--- baseline negative control (f9c45518b) ---'
compile "$test_dir/baseline" "$baseline_source" "$test_source"
if run_test "$test_dir/baseline"; then
  printf '%s\n' 'FAIL baseline unexpectedly passed the held-cancellation race'
  exit 1
fi
if ! rg -q 'FAIL  old deferred cleanup does not clear successor auxiliary snapshots' \
    "$test_dir/baseline.runtime.log"; then
  printf '%s\n' 'FAIL baseline did not fail at the ownership regression assertion'
  exit 1
fi
printf '%s\n' 'PASS baseline fails the ownership regression as expected'

printf '%s\n' '--- current production implementation ---'
compile "$test_dir/current" "$owner_source" "$current_source" "$test_source"
run_test "$test_dir/current"
printf 'Receipts: %s\n' "$test_dir"
