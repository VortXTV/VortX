#!/usr/bin/env bash
# Root-owned focused lane. No provider/device operations; one serial strict Swift executable.
set -euo pipefail
facet_script_dir="$(cd "$(dirname "$0")" && pwd -P)"
facet_root="$(cd "$facet_script_dir/.." && pwd -P)"
[[ "$(git -C "$facet_root" rev-parse --show-toplevel)" == "$facet_root" ]] || exit 2
mkdir -p "$facet_root/app/build"
facet_out="$(mktemp -d "$facet_root/app/build/source-quick-filters.XXXXXX")"
facet_phase="source-conservation"
facet_inputs=(
  "$facet_root/app/SourcesShared/SourceQuickFilterPolicy.swift"
  "$facet_root/app/SourcesShared/SourceQuickFilterControls.swift"
  "$facet_root/app/SourcesShared/SourceListModel.swift"
  "$facet_root/app/SourcesShared/CoreModels.swift"
  "$facet_root/app/SourcesShared/CoreBridge.swift"
  "$facet_root/app/SourcesShared/CredentialScope.swift"
  "$facet_root/app/SourcesShared/UsenetStreamValidation.swift"
  "$facet_root/app/SourcesShared/StreamRanking.swift"
  "$facet_root/app/SourcesShared/DebridResolver.swift"
  "$facet_root/app/SourcesiOS/iOSDetailView.swift"
  "$facet_root/app/SourcesTV/DetailView.swift"
  "$facet_root/app/SourcesTV/TVDetailSourceColumnFocusPolicy.swift"
  "$facet_root/app/project.yml"
  "$facet_root/app/Tests/SourceQuickFilterTests.swift"
  "$facet_root/scripts/check-source-quick-filter-callers.cjs"
  "$facet_root/scripts/extract-source-quick-filter-models.cjs"
  "$facet_root/scripts/test-source-quick-filters.sh"
  "$facet_root/scripts/test-apple-playback-recovery.sh"
)
facet_finish() {
  local facet_status=$?
  trap - EXIT
  set +e
  /usr/bin/shasum -a 256 "${facet_inputs[@]}" > "$facet_out/source-after.sha256" 2> "$facet_out/source-after-errors.log"
  [[ $? -eq 0 ]] || facet_status=3
  cmp -s "$facet_out/source-before.sha256" "$facet_out/source-after.sha256" || facet_status=3
  if [[ -f "$facet_out/ExtractedSourceModels.swift" ]]; then
    /usr/bin/shasum -a 256 "$facet_out/ExtractedSourceModels.swift" > "$facet_out/generated-after.sha256"
    [[ $? -eq 0 ]] || facet_status=3
    if [[ -f "$facet_out/generated-before.sha256" ]]; then
      cmp -s "$facet_out/generated-before.sha256" "$facet_out/generated-after.sha256" || facet_status=3
    fi
  fi
  if [[ -f "$facet_out/source-quick-filter-tests" ]]; then
    /usr/bin/shasum -a 256 "$facet_out/source-quick-filter-tests" > "$facet_out/binary.sha256"
  fi
  git -C "$facet_root" rev-parse HEAD > "$facet_out/HEAD-after.txt"
  printf 'exit_code=%s\nphase=%s\ncheckout=%s\nevidence=actual-policy-and-source-contracts-only\n' \
    "$facet_status" "$facet_phase" "$facet_root" > "$facet_out/result.txt"
  printf 'Source quick-filter checks exit %s. Retained receipt: %s\n' "$facet_status" "$facet_out"
  exit "$facet_status"
}
trap facet_finish EXIT
git -C "$facet_root" rev-parse HEAD > "$facet_out/HEAD-before.txt"
/usr/bin/shasum -a 256 "${facet_inputs[@]}" > "$facet_out/source-before.sha256"
mkdir "$facet_out/module-cache"
export CLANG_MODULE_CACHE_PATH="$facet_out/module-cache"
export SWIFT_MODULE_CACHE_PATH="$facet_out/module-cache"
export SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export SWIFT_FRONTEND_THREADS=1
facet_phase="caller-contracts"
/usr/bin/nice -n 15 node "$facet_root/scripts/check-source-quick-filter-callers.cjs" "$facet_root" > "$facet_out/callers.log" 2>&1
facet_phase="actual-model-extraction"
/usr/bin/nice -n 15 node "$facet_root/scripts/extract-source-quick-filter-models.cjs" "$facet_root" > "$facet_out/ExtractedSourceModels.swift" 2> "$facet_out/extractor.log"
/usr/bin/shasum -a 256 "$facet_out/ExtractedSourceModels.swift" > "$facet_out/generated-before.sha256"
facet_phase="strict-swift-compile"
/usr/bin/nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
  -module-cache-path "$facet_out/module-cache" -module-name SourceQuickFilterHarness \
  "$facet_out/ExtractedSourceModels.swift" \
  "$facet_root/app/SourcesShared/UsenetStreamValidation.swift" \
  "$facet_root/app/SourcesShared/SourceQuickFilterPolicy.swift" \
  "$facet_root/app/SourcesTV/TVDetailSourceColumnFocusPolicy.swift" \
  "$facet_root/app/Tests/SourceQuickFilterTests.swift" \
  -o "$facet_out/source-quick-filter-tests" > "$facet_out/compiler.log" 2>&1
facet_phase="actual-policy-runtime"
/usr/bin/nice -n 15 "$facet_out/source-quick-filter-tests" > "$facet_out/runtime.log" 2>&1
facet_phase="complete"
