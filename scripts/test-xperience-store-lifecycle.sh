#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_case="${1:-all}"
mutant="${2:-baseline}"
mkdir -p app/build
lifecycle_dir=$(mktemp -d "$PWD/app/build/xperience-store-lifecycle.XXXXXX")
printf 'Retained lifecycle directory %s\n' "$lifecycle_dir"
source_inputs=(
  app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxNativeRuntime.swift
  app/SourcesShared/XperienceNativePersistence.swift app/SourcesShared/XperienceCollectionsStore.swift
  app/SourcesShared/XperienceCollectionsViewModel.swift
  app/SourcesShared/VortxNativeHostFieldMutation.swift app/SourcesShared/XperienceExportObservation.swift
  app/SourcesShared/XperienceCollections.swift app/SourcesShared/XperienceAddonBinding.swift
  app/SourcesShared/XperienceFileChooserAdmission.swift app/SourcesShared/XperienceImportPrivacy.swift
  app/SourcesShared/VortxNativeBootstrapArchive.swift
  app/Tests/XperienceCollectionsStoreHarnessSupport.swift app/Tests/XperienceCollectionsStoreLifecycleTests.swift
  scripts/extract-xperience-store-harness.mjs scripts/test-xperience-store-lifecycle.sh
)
shasum -a 256 "${source_inputs[@]}" > "$lifecycle_dir/input-sha256.txt"
node scripts/extract-xperience-store-harness.mjs "$PWD" "$lifecycle_dir" "$mutant"
if [[ "$mutant" == baseline ]]; then
  cmp app/SourcesShared/XperienceCollectionsStore.swift "$lifecycle_dir/XperienceCollectionsStore.swift"
  cmp app/SourcesShared/XperienceCollectionsViewModel.swift "$lifecycle_dir/XperienceCollectionsViewModel.swift"
fi
inputs=(
  "$lifecycle_dir/ExactProductionDeclarations.swift"
  app/SourcesShared/VortxNativeHostFieldMutation.swift app/SourcesShared/XperienceExportObservation.swift
  app/SourcesShared/XperienceCollections.swift app/SourcesShared/XperienceAddonBinding.swift
  app/SourcesShared/XperienceFileChooserAdmission.swift app/SourcesShared/XperienceImportPrivacy.swift
  app/SourcesShared/VortxNativeBootstrapArchive.swift
  app/Tests/XperienceCollectionsStoreHarnessSupport.swift
  "$lifecycle_dir/XperienceCollectionsStore.swift" "$lifecycle_dir/XperienceCollectionsViewModel.swift"
  app/Tests/XperienceCollectionsStoreLifecycleTests.swift
)
shasum -a 256 "${inputs[@]}" > "$lifecycle_dir/compiled-input-sha256.txt"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -j 1 -num-threads 1 -whole-module-optimization \
  -D VORTX_NATIVE_DATA_ENGINE "${inputs[@]}" -o "$lifecycle_dir/lifecycle-tests"
set +e
nice -n 15 "$lifecycle_dir/lifecycle-tests" "$test_case" > "$lifecycle_dir/result.txt" 2>&1
result=$?
set -e
shasum -a 256 --check "$lifecycle_dir/input-sha256.txt"
shasum -a 256 --check "$lifecycle_dir/compiled-input-sha256.txt"
printf 'Lifecycle runtime exit %s (%s / %s); retained output %s\n' "$result" "$test_case" "$mutant" "$lifecycle_dir/result.txt"
exit "$result"
