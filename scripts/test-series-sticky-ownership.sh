#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
sticky_owner_test_dir=$(mktemp -d "$PWD/app/build/series-sticky-ownership.XXXXXX")
sticky_owner_phase=source
sticky_owner_supervisor="$PWD/test/mpv-bounded-child.mjs"
sticky_owner_inputs=(
  scripts/test-series-sticky-ownership.sh scripts/test-binge-language-continuity.sh
  test/mpv-bounded-child.mjs
  app/Sources/Player/AudioLanguagePolicy.swift app/SourcesShared/SeriesSourceSticky.swift
  app/Tests/SeriesStickyFixtureSupport.swift app/Tests/ProviderHealthConcurrencyTests.swift
  app/Tests/BingeLanguageContinuityTests.swift app/Tests/SeriesSourceStickyIsolationFailures.swift
  app/Sources/PlayerScreen.swift app/SourcesTV/TVPlayerView.swift
  app/SourcesTV/DetailView.swift app/SourcesTV/RootTabView.swift
)
sticky_owner_finish() {
  local terminal_status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sticky_owner_inputs[@]}" > "$sticky_owner_test_dir/source-after.sha256"
  [[ $? -eq 0 ]] || terminal_status=3
  cmp -s "$sticky_owner_test_dir/source-before.sha256" "$sticky_owner_test_dir/source-after.sha256" || terminal_status=3
  printf 'exit_code=%s\nphase=%s\nscope=whole-real-sticky-health-file-RAM-collaborators-not-app-or-durable-storage\n' \
    "$terminal_status" "$sticky_owner_phase" > "$sticky_owner_test_dir/result.txt"
  printf 'Sticky ownership exit %s; retained %s\n' "$terminal_status" "$sticky_owner_test_dir"
  exit "$terminal_status"
}
trap sticky_owner_finish EXIT
shasum -a 256 "${sticky_owner_inputs[@]}" > "$sticky_owner_test_dir/source-before.sha256"
git -C "$PWD" rev-parse HEAD > "$sticky_owner_test_dir/source-head.txt"
mkdir "$sticky_owner_test_dir/module-cache"
sticky_owner_flags=(-j 1 -num-threads 1 -whole-module-optimization
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library
  -module-cache-path "$sticky_owner_test_dir/module-cache")
sticky_owner_sources=(app/Sources/Player/AudioLanguagePolicy.swift
  app/SourcesShared/SeriesSourceSticky.swift app/Tests/SeriesStickyFixtureSupport.swift)

# Reuse the existing owned-process-group supervisor; confirmed cleanup precedes the next compiler.
# Whole actual production files are compiled; there is no source extractor or modeled owner here.
for fixture in ProviderHealthConcurrencyTests BingeLanguageContinuityTests; do
  sticky_owner_phase="compile-$fixture"
  /usr/bin/nice -n 15 node "$sticky_owner_supervisor" run 60 "$sticky_owner_test_dir/$fixture.compile-process.json" -- \
    /usr/bin/xcrun swiftc "${sticky_owner_flags[@]}" "${sticky_owner_sources[@]}" \
    "app/Tests/${fixture}.swift" -o "$sticky_owner_test_dir/$fixture" \
    > "$sticky_owner_test_dir/$fixture.compiler.log" 2>&1
  /usr/bin/nice -n 15 node "$sticky_owner_supervisor" check "$sticky_owner_test_dir/$fixture.compile-process.json" 0 normal-exit
  sticky_owner_phase="runtime-$fixture"
  /usr/bin/nice -n 15 node "$sticky_owner_supervisor" run 30 "$sticky_owner_test_dir/$fixture.runtime-process.json" -- \
    "$sticky_owner_test_dir/$fixture" > "$sticky_owner_test_dir/$fixture.runtime.log" 2>&1
  /usr/bin/nice -n 15 node "$sticky_owner_supervisor" check "$sticky_owner_test_dir/$fixture.runtime-process.json" 0 normal-exit
done

sticky_owner_cases=(SNAPSHOT CURRENT PREFERENCE RECORD AUDIO ADMISSION)
sticky_owner_members=(snapshot currentSnapshot preference record recordAudio admits)
for ((sticky_owner_index=0; sticky_owner_index<${#sticky_owner_cases[@]}; sticky_owner_index++)); do
  probe=${sticky_owner_cases[$sticky_owner_index]}
  member=${sticky_owner_members[$sticky_owner_index]}
  sticky_owner_phase="reject-$probe"
  if /usr/bin/nice -n 15 node "$sticky_owner_supervisor" run 60 "$sticky_owner_test_dir/$probe.compile-process.json" -- \
    /usr/bin/xcrun swiftc "${sticky_owner_flags[@]}" -typecheck -D "STICKY_FAIL_$probe" \
    "${sticky_owner_sources[@]}" app/Tests/SeriesSourceStickyIsolationFailures.swift \
    > "$sticky_owner_test_dir/$probe.compiler.log" 2>&1; then
    printf 'FAIL: nonisolated %s unexpectedly compiled\n' "$member" >&2
    exit 1
  else
    sticky_owner_probe_status=$?
  fi
  if [[ "$sticky_owner_probe_status" -ne 1 ]]; then
    printf 'FAIL: %s stopped with unexpected compiler status %s\n' "$probe" "$sticky_owner_probe_status" >&2
    exit "$sticky_owner_probe_status"
  fi
  /usr/bin/nice -n 15 node "$sticky_owner_supervisor" check "$sticky_owner_test_dir/$probe.compile-process.json" 1 normal-exit
  grep -F "main actor-isolated static method '$member" "$sticky_owner_test_dir/$probe.compiler.log" > /dev/null
  grep -F 'SeriesSourceStickyIsolationFailures.swift:' "$sticky_owner_test_dir/$probe.compiler.log" > /dev/null
  sticky_owner_probe_errors=$(grep -c ': error:' "$sticky_owner_test_dir/$probe.compiler.log")
  [[ "$sticky_owner_probe_errors" -eq 1 ]]
  printf 'Rejected nonisolated live API: %s (compiler status %s)\n' "$member" "$sticky_owner_probe_status" >> "$sticky_owner_test_dir/isolation.log"
done
sticky_owner_phase=complete
