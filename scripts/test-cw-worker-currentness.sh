#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
cw_worker_dir=$(mktemp -d "$PWD/app/build/cw-worker.XXXXXX")
cw_worker_phase=source
cw_worker_inputs=(
 scripts/test-cw-worker-currentness.sh test/cw-worker-currentness.mjs test/xperience-harness-inputs.cjs
 app/Tests/CWWorkerCurrentnessTests.swift app/SourcesShared/Profiles.swift
 app/SourcesShared/HomeContinueWatchingSelection.swift app/SourcesShared/TraktPlaybackShadow.swift
 app/SourcesShared/SIMKLContinueWatchingShadow.swift app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
 app/SourcesShared/ContinueWatchingPreferences.swift app/SourcesShared/ProfileDiscoveryPreferences.swift
 app/SourcesShared/CredentialScope.swift app/SourcesShared/TraktScrobbleProgressPolicy.swift
 app/SourcesShared/SIMKLAuth.swift app/SourcesShared/ExternalSyncSessionPolicy.swift
 app/SourcesShared/TraktContinueWatchingFold.swift app/SourcesShared/TraktPlaybackCacheStorage.swift
 app/SourcesShared/TraktArtworkPolicy.swift
)
cw_worker_finish() {
 local status=$?
 trap - EXIT
 set +e
 shasum -a 256 "${cw_worker_inputs[@]}" > "$cw_worker_dir/source-after.sha256"
 [[ $? -eq 0 ]] || status=3
 cmp -s "$cw_worker_dir/source-before.sha256" "$cw_worker_dir/source-after.sha256" || status=3
 if [[ -f "$cw_worker_dir/generated-before.sha256" ]]; then
  shasum -a 256 "$cw_worker_dir/Combined.swift" > "$cw_worker_dir/generated-after.sha256"
  [[ $? -eq 0 ]] || status=3
  cmp -s "$cw_worker_dir/generated-before.sha256" "$cw_worker_dir/generated-after.sha256" || status=3
 fi
 printf 'exit_code=%s\nphase=%s\nscope=RAM-real-CW-predicates-not-whole-Trakt-or-app\n' "$status" "$cw_worker_phase" > "$cw_worker_dir/result.txt"
 printf 'CW worker exit %s; retained %s\n' "$status" "$cw_worker_dir"
 exit "$status"
}
trap cw_worker_finish EXIT
shasum -a 256 "${cw_worker_inputs[@]}" > "$cw_worker_dir/source-before.sha256"
export VORTX_CW_WORKER_SOURCE_HEAD
VORTX_CW_WORKER_SOURCE_HEAD=$(git -C "$PWD" rev-parse HEAD)
nice -n 15 node test/cw-worker-currentness.mjs "$cw_worker_dir" > "$cw_worker_dir/extraction.log" 2>&1
shasum -a 256 "$cw_worker_dir/Combined.swift" > "$cw_worker_dir/generated-before.sha256"
cw_worker_phase=compile
nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
 -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
 -module-cache-path "$cw_worker_dir/module-cache" "$cw_worker_dir/Combined.swift" \
 app/SourcesShared/PlaybackMutationOwnershipPolicy.swift app/SourcesShared/ContinueWatchingPreferences.swift \
 app/SourcesShared/TraktArtworkPolicy.swift -o "$cw_worker_dir/tests" > "$cw_worker_dir/compiler.log" 2>&1
cw_worker_phase=runtime
nice -n 15 "$cw_worker_dir/tests" > "$cw_worker_dir/runtime.log" 2>&1
cw_worker_phase=complete
