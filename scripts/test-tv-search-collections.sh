#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
baseline_ref=${1:-}
mkdir -p app/build
fixture_dir=$(mktemp -d "$PWD/app/build/tv-search-collections.XXXXXX")

if [[ -n "$baseline_ref" ]]; then
  git show "$baseline_ref:app/SourcesTV/SearchView.swift" > "$fixture_dir/baseline.swift"
fi

# Compile the query/grouping helpers from the shipping consumer, rather than a rewritten test policy.
# Only fixture inventory/prefs/core inputs are stubbed; neither variant links an app or private engine.
node --input-type=module - "$fixture_dir" "$baseline_ref" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const [dir, baseline] = process.argv.slice(2);
const read = path => readFileSync(path, 'utf8');
function block(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`Missing production declaration: ${marker}`);
  const brace = source.indexOf('{', start);
  let depth = 1, end = brace + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unterminated production declaration: ${marker}`);
  return source.slice(start, end).replace(/^private /, '');
}
const hub = read('app/SourcesShared/CollectionsHubModel.swift');
const models = read('app/SourcesShared/CoreModels.swift');
const declarations = [block(hub, 'enum HubTarget:'),
  block(read('app/SourcesShared/CatalogPreferences.swift'), 'enum HubCategoryKey'),
  block(models, 'struct CoreMeta:'), block(models, 'struct CoreLink:')];
const current = read('app/SourcesTV/SearchView.swift');
writeFileSync(`${dir}/field-model.swift`, `import Combine\nimport Foundation\n@MainActor\n${block(current, 'private final class TVSearchFieldModel:')}\n`);
for (const variant of baseline ? ['baseline', 'current'] : ['current']) {
  const source = variant === 'current' ? current : read(`${dir}/baseline.swift`);
  const isCurrent = variant === 'current';
  const helpers = ['private var emptyText:', 'private var isTyping:',
    'private var isWaitingForCurrentQuery:', 'private var hasSearchQuery:'].map(marker => block(source, marker));
  if (isCurrent) {
    helpers.push(block(source, 'private var matchingCollections:'));
    helpers.push(block(source, 'private func resultSections('));
    helpers.push(`func sectionSnapshot() -> [(String, [CoreMeta])] {
      resultSections(collections: matchingCollections).map { ($0.group.title, $0.items) }
    }`);
  } else {
    helpers.push(block(source, 'private var resultSections:'));
    // The old consumer has no inventory query. Expose that absence to the same fixture interface.
    helpers.push('var matchingCollections: [HubTarget] { [] }');
    helpers.push('func sectionSnapshot() -> [(String, [CoreMeta])] { resultSections.map { ($0.title, $0.items) } }');
  }
  writeFileSync(`${dir}/${variant}-production.swift`, `import Foundation
${declarations.join('\n')}
${isCurrent ? block(source, 'private enum TVSearchResultGroup:') : ''}
final class ProductionTVSearch {
  var query = ""
  var searchDebouncePending = false
  let core = CoreBridge()
  let collectionsHub = CollectionsHubModel()
  let catalogPrefs = CatalogPreferences()
  ${helpers.join('\n')}
}
`);
}
// Verify that the extracted helpers are wired into the real scrolling/navigation consumer.
const grid = block(current, '@ViewBuilder private var resultGrid:');
const row = block(current, 'private func resultRow(');
const matches = block(current, 'private var matchingCollections:');
const schedule = block(current, 'private func scheduleSearch(');
const tile = block(current, '@ViewBuilder private func collectionTile(');
function require(value, label) { if (!value) throw new Error(label); console.log(`PASS consumer: ${label}`); }
require(grid.includes('let collections = matchingCollections') && grid.includes('resultSections(collections: collections)'),
  'live collection matches feed the production result sections');
require(grid.includes('section.group == .collections ? collections : []'), 'hub targets only enter the Collections rail');
require(row.includes('ScrollView(.horizontal') && row.includes('LazyHStack(') && row.includes('ForEach(collections, id: \\.self)'),
  'collection targets render in a stable horizontal rail');
require(row.includes('NavigationLink { TVCategoryBrowse(target: target) }') && row.includes('.buttonStyle(CardFocusStyle())'),
  'collection selection retains its TV browse target and focus style');
require(!row.includes('.focusSection()'), 'result rails keep the established nearest-neighbor focus traversal');
require(row.includes('PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id'),
  'addon cards retain their exact metadata identity and destination');
for (const name of ['DiscoverCardTile', 'TVServiceTile', 'TVGenreTile', 'TVDecadeTile']) {
  require(tile.includes(name + '('), `${name} reuses the existing TV tile`);
}
require(!matches.includes('.load(') && !matches.includes('core.search('), 'typing filters inventory without a duplicate content request');
require(current.includes('@ObservedObject private var collectionsHub = CollectionsHubModel.shared') &&
  current.includes('@ObservedObject private var catalogPrefs = CatalogPreferences.shared'), 'shared inventory and preferences remain live');
require((current.match(/collectionsHub\.load\(\)/g) ?? []).length === 1 &&
  /\.onAppear\s*\{\s*collectionsHub\.load\(\)/.test(current), 'one appearance load uses the shared cadence cache');
require(schedule.includes('searchTask?.cancel()') && schedule.includes('core.prepareSearch(value)') &&
  schedule.includes('guard !Task.isCancelled else { return }'), 'query changes retain cancellation and publication preparation');
const host = block(current, 'private struct TVSearchHost:');
const submit = block(current, '.onChange(of: submitted.count)');
require(/\.onSubmit\(of: \.search\)\s*\{\s*field\.submitted\.fire\(\)\s*\}/.test(host),
  'search-field submission forwards to the content observer');
require(submit.includes('searchTask?.cancel()') && submit.includes('searchDebouncePending = false') &&
  submit.includes('core.suggestSearch(query)') && submit.includes('searchNow(query)'),
  'content submission retires debounce and immediately dispatches the live query');
require(!host.includes('@VisibleCore') && !host.includes('@ObservedObject') &&
  !host.includes('field.live.text') && host.includes('let _ = field.programmaticRevision'),
  'typing and engine publication stay out of the searchable host observation');
require(grid.includes('core.searchResults.isEmpty && isWaitingForCurrentQuery'), 'inventory matches retain addon loading feedback');
NODE

for variant in ${baseline_ref:+baseline} current; do
  xcrun swiftc -parse-as-library -warnings-as-errors "$fixture_dir/$variant-production.swift" \
    app/Tests/TVSearchCollectionsTests.swift -o "$fixture_dir/$variant"
  # macOS CI uses Bash 3.2: an empty array expansion is unbound under `set -u`.
  if [[ "$variant" == baseline ]]; then
    "$fixture_dir/$variant" --baseline | tee "$fixture_dir/$variant.log"
  else
    "$fixture_dir/$variant" | tee "$fixture_dir/$variant.log"
  fi
done
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$fixture_dir/field-model.swift" app/Tests/TVSearchFieldModelTests.swift -o "$fixture_dir/field-model"
"$fixture_dir/field-model" | tee "$fixture_dir/field-model.log"
xcrun swiftc -frontend -parse app/SourcesTV/SearchView.swift
shasum -a 256 app/SourcesTV/SearchView.swift app/Tests/TVSearchCollectionsTests.swift app/Tests/TVSearchFieldModelTests.swift \
  scripts/test-tv-search-collections.sh > "$fixture_dir/source-sha256.txt"
printf 'Retained TV search collection receipt: %s\n' "$fixture_dir"
