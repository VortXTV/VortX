#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

build_dir="$root/app/build/featured-hero-lifecycle"
mkdir -p "$build_dir"

# Preserve the exact baseline receipt so the old defect is proven RED before the current source is exercised.
base_ref="d848197e7e7f955a46bd86a219a16e49948459a3"
baseline_logo="$build_dir/baseline-ERDBConfig.swift"
baseline_model="$build_dir/baseline-FeaturedHeroModel.swift"
git show "${base_ref}:app/SourcesShared/ERDBConfig.swift" > "$baseline_logo"
git show "${base_ref}:app/SourcesiOS/FeaturedHeroModel.swift" > "$baseline_model"
if rg -q "AsyncImage" "$baseline_logo" \
  && ! rg -q "private var enrichmentTasks: \[String: Task<Void, Never>\]" "$baseline_model" \
  && rg -q "Task \{ \[weak self\]" "$baseline_model"; then
  print "baseline RED confirmed: raw logo AsyncImage and unowned enrichment work"
else
  print -u2 "baseline RED control failed for $base_ref"
  exit 1
fi

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  app/Tests/FeaturedHeroLifecycleContractTests.swift \
  -o "$build_dir/contract-runner"
"$build_dir/contract-runner" "$root" | tee "$build_dir/contract.log"

# Parse the actual production files as a separate gate; a passing extracted harness must not mask a syntax error.
xcrun swiftc -frontend -parse \
  app/SourcesiOS/FeaturedHeroModel.swift \
  app/SourcesShared/ERDBConfig.swift

print 'ok: featured hero baseline RED, extracted production lifecycle, and source parse gates pass'
