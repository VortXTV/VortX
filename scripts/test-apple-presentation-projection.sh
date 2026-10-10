#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
IFS= read -r projection_dir < <(mktemp -d app/build/apple-presentation-projection.XXXXXX)

# Compile the production cache, grouping and subscriber. Extract model/builders verbatim
# to avoid linking the app, accounts, storage, player or native engine into this fixture.
node --input-type=module - "$projection_dir" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const dir = process.argv[2];
const read = path => readFileSync(path, 'utf8');
function block(text, start) {
  const begin = text.indexOf(start);
  if (begin < 0) throw new Error(`Missing production declaration: ${start}`);
  const brace = text.indexOf('{', begin);
  let depth = 1, end = brace + 1;
  for (; depth && end < text.length; end++) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unterminated production declaration: ${start}`);
  return text.slice(begin, end);
}
const models = read('app/SourcesShared/CoreModels.swift');
const profiles = read('app/SourcesShared/Profiles.swift');
const root = read('app/SourcesiOS/iOSRootView.swift');
const core = read('app/SourcesShared/CoreBridge.swift');
const declarations = ['struct CoreCWItem:', 'struct CoreLibState:', 'struct CoreMeta:', 'struct CoreLink:']
  .map(start => block(models, start));
declarations.push(block(read('app/SourcesShared/ProfileSync.swift'), 'struct WatchEntry:'));
declarations.push(block(root, 'struct RailItem:'));
declarations.push(block(core, 'final class CoreSearchPublicationFence:'));
declarations.push(block(root, 'final class AppleSearchPresentation:'));
writeFileSync(`${dir}/ProductionDeclarations.swift`, 'import Foundation\nimport Combine\n' + declarations.join('\n'));
writeFileSync(`${dir}/ProductionOverlay.swift`, `import Foundation
final class ProfileStore {
  var watch: [String: WatchEntry] = [:]
  var activeID: UUID? = UUID()
  var activeUsesEngineHistory = false
  var cwBuilds = 0
  var libraryBuilds = 0
  ${block(profiles, 'var cwItems:').replace('{', '{ cwBuilds += 1;')}
  ${block(profiles, 'var libraryItems:').replace('{', '{ libraryBuilds += 1;')}
}
struct ProductionHomeProjection {
  let core: CoreBridge
  let profiles: ProfileStore
  var overlayHistory = ApplePresentationPublicationCache<[String: WatchEntry], (cw: [CoreCWItem], library: [CoreCWItem])>()
  ${block(root, 'private func refreshOverlayHistoryProjection()').replace('private func', 'mutating func')}
  ${block(root, 'private var localContinueWatchingItems:').replace('private var', 'var')}
  ${block(root, 'private var homeHistoryKey:').replace('private var', 'var')}
}
`);
const cacheDeclarations = ['struct CoreMeta:', 'struct CoreLink:'].map(start => block(models, start));
cacheDeclarations.push(block(read('app/SourcesShared/ProfileSync.swift'), 'struct WatchEntry:'));
cacheDeclarations.push(block(root, 'struct RailItem:'));
for (const start of ['private struct iOSCWProducerProvenance:', 'private struct iOSCWRenderSnapshot',
                     'private struct iOSCWPresentationSnapshot', 'private func cinemaHistoryRailItem(']) {
  cacheDeclarations.push(block(root, start).replace('private ', ''));
}
writeFileSync(`${dir}/HomeCacheDeclarations.swift`, 'import Foundation\n' + cacheDeclarations.join('\n'));
const fixtureStubs = read('app/Tests/HomeContinueWatchingFixtureStubs.swift')
  .replace('var library: CoreLibrary?', 'var library: CoreLibrary?\n    var boardRows: [FixtureBoardRow] = []\n    var metaDetails: FixtureMetaDetails?')
  .replace('struct CoreLibState {', 'struct CoreLibState {\n    let flaggedWatched = 0\n    let timesWatched = 0');
writeFileSync(`${dir}/HomeCacheFixtureStubs.swift`, fixtureStubs);
const refresh = block(root, 'private func refreshContinueWatchingPresentation(').replace('private ', '')
  .replace('snapshot = HomeContinueWatchingSelection.current', 'HomeCacheCounters.selectionPasses += 1\n            snapshot = HomeContinueWatchingSelection.current')
  .replace('let items = selection.items.map', 'HomeCacheCounters.cardPasses += 1\n        let items = selection.items.map');
writeFileSync(`${dir}/ProductionHomeCache.swift`, `import Foundation
final class ProductionHomePresentation {
  let core: CoreBridge
  let profiles: ProfileStore
  var overlayHistory = ApplePresentationPublicationCache<[String: WatchEntry], (cw: [CoreCWItem], library: [CoreCWItem])>()
  var cachedContinueWatching: iOSCWPresentationSnapshot?
  init(core: CoreBridge, profiles: ProfileStore) { self.core = core; self.profiles = profiles }
  ${block(root, 'private var localContinueWatchingItems:').replace('private ', '')}
  ${block(root, 'private var continueWatchingSnapshot:').replace('private ', '')}
  ${block(root, 'private var continueWatchingRenderSnapshot:').replace('private ', '')}
  ${refresh}
  ${block(root, 'private func refreshContinueWatchingAfterHistoryReceipt()').replace('private ', '')}
}
`);
NODE

xcrun swiftc -parse-as-library -warnings-as-errors \
  "$projection_dir/ProductionDeclarations.swift" "$projection_dir/ProductionOverlay.swift" \
  app/SourcesShared/ContinueWatchingDedupe.swift app/SourcesShared/ContinueWatchingPreferences.swift \
  app/SourcesiOS/ApplePresentationProjection.swift app/Tests/ApplePresentationProjectionTests.swift \
  -o "$projection_dir/projection"
"$projection_dir/projection" "$PWD" | tee "$projection_dir/fixture.log"
xcrun swiftc -parse-as-library -warnings-as-errors \
  "$projection_dir/HomeCacheFixtureStubs.swift" "$projection_dir/HomeCacheDeclarations.swift" \
  "$projection_dir/ProductionHomeCache.swift" app/Tests/AppleHomePresentationCacheTests.swift \
  app/SourcesShared/PlaybackMutationOwnershipPolicy.swift app/SourcesShared/ExternalSyncSessionPolicy.swift \
  app/SourcesShared/TraktScrobbleProgressPolicy.swift app/SourcesShared/TraktArtworkPolicy.swift \
  app/SourcesShared/TraktContinueWatchingFold.swift app/SourcesShared/ContinueWatchingPreferences.swift \
  app/SourcesShared/ProfileDiscoveryPreferences.swift app/SourcesShared/SIMKLContinueWatching.swift \
  app/SourcesShared/SIMKLContinueWatchingShadow.swift app/SourcesShared/TraktPlaybackShadow.swift \
  app/SourcesShared/HomeContinueWatchingSelection.swift app/SourcesiOS/ApplePresentationProjection.swift \
  -o "$projection_dir/home-cache"
"$projection_dir/home-cache" | tee "$projection_dir/home-cache.log"
xcrun swiftc -frontend -parse app/SourcesiOS/iOSRootView.swift app/SourcesiOS/iOSBrowseGridView.swift \
  app/SourcesShared/ProfilesView.swift app/SourcesShared/HomeContinueWatchingSelection.swift
printf '%s\n' "Retained projection receipt: $projection_dir"
