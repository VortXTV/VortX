#!/usr/bin/env bash
# One low-priority strict Swift 6 host lane. No build, network, player, provider or saved-data operation.
set -euo pipefail
ranking_root="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ "$(git -C "$ranking_root" rev-parse --show-toplevel)" == "$ranking_root" ]] || exit 2
mkdir -p "$ranking_root/app/build"
ranking_out="$(mktemp -d "$ranking_root/app/build/ranking-cache.XXXXXX")"
ranking_phase=source-conservation
ranking_inputs=(
  "$ranking_root/app/SourcesShared/RankingMemo.swift"
  "$ranking_root/app/SourcesShared/StreamRanking.swift"
  "$ranking_root/app/SourcesShared/SourcePreferences.swift"
  "$ranking_root/app/SourcesShared/SourcePin.swift"
  "$ranking_root/app/SourcesShared/CoreModels.swift"
  "$ranking_root/app/SourcesShared/UsenetStreamValidation.swift"
  "$ranking_root/app/SourcesShared/SourceSettlementPolicy.swift"
  "$ranking_root/app/Sources/Player/AudioLanguagePolicy.swift"
  "$ranking_root/app/Tests/RankingCacheConcurrencyTests.swift"
  "$ranking_root/scripts/extract-ranking-cache-fixtures.cjs"
  "$ranking_root/scripts/extract-source-quick-filter-models.cjs"
  "$ranking_root/scripts/test-ranking-cache-concurrency.sh"
  "$ranking_root/scripts/test-binge-language-continuity.sh"
  "$ranking_root/app/project.yml"
)
ranking_finish() {
  local ranking_status=$?
  trap - EXIT
  set +e
  /usr/bin/shasum -a 256 "${ranking_inputs[@]}" > "$ranking_out/source-after.sha256"
  [[ $? -eq 0 ]] || ranking_status=3
  cmp -s "$ranking_out/source-before.sha256" "$ranking_out/source-after.sha256" || ranking_status=3
  if [[ -f "$ranking_out/Fixtures.swift" ]]; then
    /usr/bin/shasum -a 256 "$ranking_out/Fixtures.swift" > "$ranking_out/generated-after.sha256"
    [[ $? -eq 0 ]] || ranking_status=3
    cmp -s "$ranking_out/generated-before.sha256" "$ranking_out/generated-after.sha256" || ranking_status=3
  fi
  git -C "$ranking_root" rev-parse HEAD > "$ranking_out/HEAD-after.txt"
  printf 'exit_code=%s\nphase=%s\nscope=whole-ranker-and-actual-value-types-not-live-owner-or-app\n' \
    "$ranking_status" "$ranking_phase" > "$ranking_out/result.txt"
  printf 'Ranking cache checks exit %s. Retained receipt: %s\n' "$ranking_status" "$ranking_out"
  exit "$ranking_status"
}
trap ranking_finish EXIT
git -C "$ranking_root" rev-parse HEAD > "$ranking_out/HEAD-before.txt"
/usr/bin/shasum -a 256 "${ranking_inputs[@]}" > "$ranking_out/source-before.sha256"
mkdir "$ranking_out/module-cache"
export CLANG_MODULE_CACHE_PATH="$ranking_out/module-cache"
export SWIFT_MODULE_CACHE_PATH="$ranking_out/module-cache"
export SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
ranking_phase=exact-value-extraction
/usr/bin/nice -n 15 node "$ranking_root/scripts/extract-ranking-cache-fixtures.cjs" "$ranking_root" \
  > "$ranking_out/Fixtures.swift" 2> "$ranking_out/extractor.log"
/usr/bin/shasum -a 256 "$ranking_out/Fixtures.swift" > "$ranking_out/generated-before.sha256"
ranking_phase=strict-swift6-compile
/usr/bin/nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
  -module-cache-path "$ranking_out/module-cache" -module-name RankingCacheHarness \
  "$ranking_out/Fixtures.swift" \
  "$ranking_root/app/SourcesShared/RankingMemo.swift" \
  "$ranking_root/app/SourcesShared/StreamRanking.swift" \
  "$ranking_root/app/SourcesShared/UsenetStreamValidation.swift" \
  "$ranking_root/app/SourcesShared/SourceSettlementPolicy.swift" \
  "$ranking_root/app/Sources/Player/AudioLanguagePolicy.swift" \
  "$ranking_root/app/Tests/RankingCacheConcurrencyTests.swift" \
  -o "$ranking_out/ranking-cache-tests" > "$ranking_out/compiler.log" 2>&1
ranking_phase=actual-ranker-and-memo-runtime
/usr/bin/nice -n 15 "$ranking_out/ranking-cache-tests" > "$ranking_out/runtime.log" 2>&1
/usr/bin/shasum -a 256 "$ranking_out/ranking-cache-tests" > "$ranking_out/binary.sha256"
ranking_phase=complete
