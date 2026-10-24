#!/usr/bin/env bash
# Focused, serial Random Pick policy and actual-caller regression lane.
set -euo pipefail
random_script_dir="$(cd "$(dirname "$0")" && pwd -P)"
checkout="$(cd "$random_script_dir/.." && pwd -P)"
[[ "$(git -C "$checkout" rev-parse --show-toplevel)" == "$checkout" ]] || exit 2
mkdir -p "$checkout/app/build"
out="$(mktemp -d "$checkout/app/build/random-pick.XXXXXX")"
source_paths=(
  "$checkout/app/SourcesShared/RandomPickPolicy.swift"
  "$checkout/app/SourcesShared/RandomPickPlayPolicy.swift"
  "$checkout/app/SourcesShared/PlaybackPreparationState.swift"
  "$checkout/app/SourcesShared/VortxResourceProjection.swift"
  "$checkout/app/SourcesShared/VortxNativeCoreFacade.swift"
  "$checkout/app/SourcesShared/VortxNativeSession.swift"
  "$checkout/app/SourcesShared/VortxResourceBridge.swift"
  "$checkout/app/SourcesShared/DetailMetaRecoveryPolicy.swift"
  "$checkout/app/SourcesShared/SourceListModel.swift"
  "$checkout/app/SourcesShared/RandomPickPlayIntent.swift"
  "$checkout/app/SourcesShared/RandomPickPreview.swift"
  "$checkout/app/SourcesShared/RandomPickUIAccess.swift"
  "$checkout/app/SourcesShared/CoreModels.swift"
  "$checkout/app/SourcesShared/Profiles.swift"
  "$checkout/app/SourcesShared/CoreBridge.swift"
  "$checkout/app/SourcesShared/StremioAccount.swift"
  "$checkout/app/SourcesiOS/iOSRootView.swift"
  "$checkout/app/SourcesiOS/iOSDetailView.swift"
  "$checkout/app/SourcesTV/LibraryView.swift"
  "$checkout/app/SourcesTV/DetailView.swift"
  "$checkout/app/project.yml"
)
harness_paths=(
  "$checkout/app/Tests/RandomPickPolicyTests.swift"
  "$checkout/app/Tests/RandomPickPlayPolicyTests.swift"
  "$checkout/app/Tests/PlaybackPreparationStateTests.swift"
  "$checkout/app/Tests/VortxMetaLoadingProjectionTests.swift"
  "$checkout/app/Tests/RandomPickNavigationOwnerTests.swift"
  "$checkout/scripts/check-random-pick-navigation.cjs"
  "$checkout/scripts/extract-random-pick-navigation.cjs"
  "$checkout/scripts/check-meta-loading-projection.cjs"
  "$checkout/scripts/check-random-pick-ios-play.cjs"
  "$checkout/scripts/check-random-pick-callers.cjs"
  "$checkout/scripts/extract-random-pick-models.cjs"
  "$checkout/scripts/test-random-pick.sh"
  "$checkout/scripts/test-apple-playback-recovery.sh"
)
finish() {
  result=$?
  trap - EXIT
  /usr/bin/shasum -a 256 "${source_paths[@]}" > "$out/source-after.sha256" 2> "$out/source-after-errors.log" || result=3
  /usr/bin/shasum -a 256 "${harness_paths[@]}" > "$out/harness-after.sha256" 2> "$out/harness-after-errors.log" || result=3
  if [[ -f "$out/source-before.sha256" ]] && ! cmp -s "$out/source-before.sha256" "$out/source-after.sha256"; then result=3; fi
  if [[ -f "$out/harness-before.sha256" ]] && ! cmp -s "$out/harness-before.sha256" "$out/harness-after.sha256"; then result=3; fi
  if [[ -f "$out/ExtractedModels.swift" ]]; then
    generated_paths=("$out/ExtractedModels.swift")
    if [[ -f "$out/ExtractedNavigation.swift" ]]; then generated_paths+=("$out/ExtractedNavigation.swift"); fi
    /usr/bin/shasum -a 256 "${generated_paths[@]}" > "$out/generated-after.sha256"
    if [[ -f "$out/generated-before.sha256" ]] && ! cmp -s "$out/generated-before.sha256" "$out/generated-after.sha256"; then result=3; fi
  fi
  if [[ -f "$out/random-pick-tests" ]]; then /usr/bin/shasum -a 256 "$out/random-pick-tests" > "$out/binary.sha256"; fi
  git -C "$checkout" rev-parse HEAD > "$out/HEAD-after.txt"
  printf 'exit_code=%s\ncheckout=%s\nreceipt=%s\n' "$result" "$checkout" "$out" > "$out/result.txt"
  printf 'Random Pick focused checks exit %s. Retained receipt: %s\n' "$result" "$out"
  exit "$result"
}
trap finish EXIT
git -C "$checkout" rev-parse HEAD > "$out/HEAD-before.txt"
git -C "$checkout" status --short -- app/SourcesShared/RandomPickPolicy.swift app/SourcesShared/RandomPickPreview.swift app/SourcesiOS/iOSRootView.swift app/SourcesiOS/iOSDetailView.swift app/SourcesTV/LibraryView.swift app/SourcesTV/DetailView.swift > "$out/placement-status.txt"
/usr/bin/shasum -a 256 "${source_paths[@]}" > "$out/source-before.sha256"
/usr/bin/shasum -a 256 "${harness_paths[@]}" > "$out/harness-before.sha256"
mkdir "$out/module-cache"
export SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export SWIFT_FRONTEND_THREADS=1
export CLANG_MODULE_CACHE_PATH="$out/module-cache"
/usr/bin/nice -n 15 node "$checkout/scripts/check-random-pick-callers.cjs" "$checkout" > "$out/callers.log" 2>&1
/usr/bin/nice -n 15 node "$checkout/scripts/check-random-pick-ios-play.cjs" "$checkout" > "$out/ios-play-callers.log" 2>&1
/usr/bin/nice -n 15 node "$checkout/scripts/check-meta-loading-projection.cjs" "$checkout" > "$out/meta-loading-callers.log" 2>&1
/usr/bin/nice -n 15 node "$checkout/scripts/check-random-pick-navigation.cjs" "$checkout" > "$out/navigation-callers.log" 2>&1
# Harness extraction is mechanical generated output, retained with the receipt.
/usr/bin/nice -n 15 node "$checkout/scripts/extract-random-pick-models.cjs" "$checkout" > "$out/ExtractedModels.swift" 2> "$out/extractor.log"
/usr/bin/nice -n 15 node "$checkout/scripts/extract-random-pick-navigation.cjs" "$checkout" > "$out/ExtractedNavigation.swift" 2> "$out/navigation-extractor.log"
/usr/bin/shasum -a 256 "$out/ExtractedModels.swift" "$out/ExtractedNavigation.swift" > "$out/generated-before.sha256"
/usr/bin/nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
  -module-cache-path "$out/module-cache" -module-name RandomPickPolicyHarness \
  "$out/ExtractedModels.swift" "$checkout/app/SourcesShared/RandomPickPolicy.swift" \
  "$out/ExtractedNavigation.swift" "$checkout/app/Tests/RandomPickNavigationOwnerTests.swift" \
  "$checkout/app/SourcesShared/RandomPickPlayPolicy.swift" \
  "$checkout/app/SourcesShared/PlaybackPreparationState.swift" \
  "$checkout/app/Tests/VortxMetaLoadingProjectionTests.swift" \
  "$checkout/app/Tests/RandomPickPlayPolicyTests.swift" \
  "$checkout/app/Tests/PlaybackPreparationStateTests.swift" \
  "$checkout/app/Tests/RandomPickPolicyTests.swift" -o "$out/random-pick-tests" > "$out/compiler.log" 2>&1
/usr/bin/nice -n 15 "$out/random-pick-tests" > "$out/runtime.log" 2>&1
