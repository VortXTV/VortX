#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -f app/SourcesShared/TVCatalogCinemaPolicy.swift
mkdir -p app/build
tv_catalog_test_dir=$(mktemp -d app/build/tv-catalog-cinema.XXXXXX)

# Test the shipping preview decoder and pure catalog navigation/page callback policies. This
# executable has no SwiftUI, CoreBridge, account, media, app bootstrap, or network dependencies.
node - "$tv_catalog_test_dir" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const models = fs.readFileSync('app/SourcesShared/CoreModels.swift', 'utf8');
function slice(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  if (from < 0 || to < 0) throw new Error('Missing production model slice: ' + start);
  return source.slice(from, to);
}
function preview(source) {
  return 'import Foundation\n' +
    slice(source, 'struct CoreMeta: Decodable, Identifiable {', 'struct CoreLocalSearchState:') +
    slice(source, 'struct CoreLink: Decodable, Equatable {', '\n}') + '\n}\n';
}
fs.writeFileSync(process.argv[2] + '/Preview.swift', preview(models));
const baseline = cp.execFileSync('git', ['-C', process.cwd(), 'show', '844782d29a93ae51991bfadc639d50bc3619d40b:app/SourcesShared/CoreModels.swift'], {encoding: 'utf8'});
fs.writeFileSync(process.argv[2] + '/BaselinePreview.swift', preview(baseline));
const navigation = fs.readFileSync('app/SourcesTV/TVCatalogBrowseView.swift', 'utf8');
fs.writeFileSync(process.argv[2] + '/Navigation.swift', 'import Foundation\n' +
  slice(navigation, 'struct TVCatalogBrowseTarget: Hashable {', '/// Read-only heavy-field access'));
NODE
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_catalog_test_dir/BaselinePreview.swift" app/Tests/TVCatalogRuntimeRegressionTests.swift \
  -o "$tv_catalog_test_dir/baseline-runtime"
set +e
"$tv_catalog_test_dir/baseline-runtime"
baseline_status=$?
"$tv_catalog_test_dir/baseline-runtime" --provider
baseline_provider_status=$?
set -e
test "$baseline_status" -eq 42
test "$baseline_provider_status" -eq 43
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_catalog_test_dir/Preview.swift" app/Tests/TVCatalogRuntimeRegressionTests.swift \
  -o "$tv_catalog_test_dir/candidate-runtime"
"$tv_catalog_test_dir/candidate-runtime"
"$tv_catalog_test_dir/candidate-runtime" --provider
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_catalog_test_dir/Preview.swift" app/SourcesShared/TVCatalogCinemaPolicy.swift \
  app/Tests/TVCatalogCinemaPolicyTests.swift -o "$tv_catalog_test_dir/tv-catalog-cinema"
"$tv_catalog_test_dir/tv-catalog-cinema"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_catalog_test_dir/Preview.swift" app/SourcesShared/TVCatalogCinemaPolicy.swift \
  "$tv_catalog_test_dir/Navigation.swift" app/Tests/TVCatalogBrowseNavigationTests.swift \
  -o "$tv_catalog_test_dir/tv-catalog-navigation"
"$tv_catalog_test_dir/tv-catalog-navigation"
