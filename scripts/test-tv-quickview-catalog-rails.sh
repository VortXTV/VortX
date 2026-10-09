#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/tests/tv-quickview-catalog-rails-source.mjs
if [[ "${1:-}" == "--source-only" ]]; then exit 0; fi
mkdir -p app/build
tv_quickview_rail_test_dir=$(mktemp -d app/build/tv-quickview-catalog-rails.XXXXXX)

# Extract only the actual shipping catalog decoders. No application bootstrap, provider,
# account, engine, audio, or media fixture is invoked.
node - "$tv_quickview_rail_test_dir" <<'NODE'
const fs = require('node:fs');
function slice(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  if (from < 0 || to < 0) throw new Error('Missing production model boundary: ' + start);
  return source.slice(from, to);
}
const core = fs.readFileSync('app/SourcesShared/CoreModels.swift', 'utf8');
const legacy = fs.readFileSync('app/SourcesShared/Addon.swift', 'utf8');
fs.writeFileSync(process.argv[2] + '/Catalog.swift', 'import Foundation\n' +
  slice(core, 'struct CoreMeta: Decodable, Identifiable {', 'struct CoreLocalSearchState:') +
  slice(core, 'struct CoreLink: Decodable, Equatable {', '\n}') + '\n}\n' +
  slice(legacy, 'struct MetaPreview: Identifiable, Decodable, Hashable {', '/// Full meta'));
NODE
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_quickview_rail_test_dir/Catalog.swift" app/SourcesShared/TVCatalogCinemaPolicy.swift \
  app/SourcesShared/CinemaQuickWatchScopePolicy.swift app/SourcesTV/TVQuickViewPolicy.swift \
  app/SourcesTV/TVQuickViewCatalogRailPolicy.swift app/Tests/TVQuickViewCatalogRailPolicyTests.swift \
  -o "$tv_quickview_rail_test_dir/tv-quickview-catalog-rails"
"$tv_quickview_rail_test_dir/tv-quickview-catalog-rails"
