#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/tests/tv-quickview-discover-source.mjs
if [[ "${1:-}" == "--source-only" ]]; then exit 0; fi
mkdir -p app/build
tv_quickview_test_dir=$(mktemp -d app/build/tv-quickview-discover.XXXXXX)

# Extract only the actual shipping preview decoder dependencies. No UI, engine, account,
# source provider, application bootstrap, installed app, audio or media fixture is invoked.
node - "$tv_quickview_test_dir" <<'NODE'
const fs = require('node:fs');
const source = fs.readFileSync('app/SourcesShared/CoreModels.swift', 'utf8');
function slice(start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  if (from < 0 || to < 0) throw new Error('Missing production model boundary: ' + start);
  return source.slice(from, to);
}
fs.writeFileSync(process.argv[2] + '/Preview.swift', 'import Foundation\n' +
  slice('struct CoreMeta: Decodable, Identifiable {', 'struct CoreLocalSearchState:') +
  slice('struct CoreLink: Decodable, Equatable {', '\n}') + '\n}\n');
NODE
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$tv_quickview_test_dir/Preview.swift" app/SourcesShared/TVCatalogCinemaPolicy.swift \
  app/SourcesShared/CinemaQuickWatchScopePolicy.swift app/SourcesTV/TVQuickViewPolicy.swift \
  app/Tests/TVQuickViewDiscoverPolicyTests.swift -o "$tv_quickview_test_dir/tv-quickview-discover"
"$tv_quickview_test_dir/tv-quickview-discover"
