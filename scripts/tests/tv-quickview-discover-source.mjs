import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const base = '042ebd403bc45594429a74f907c8134fe9b02cc3';
const read = (path) => fs.readFileSync(path, 'utf8');
const baseline = (path) => execFileSync('git', ['show', `${base}:${path}`], { encoding: 'utf8' });
let checks = 0;
const expect = (condition, message) => { assert.ok(condition, message); checks++; };
function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing source boundary: ${start}`);
  return source.slice(from, to);
}

const quick = read('app/SourcesTV/TVQuickView.swift');
const route = section(quick, 'private struct TVQuickViewRouteModifier', 'extension View');
const card = section(quick, 'struct TVCatalogSelectionCard', '/// Focus lives');
expect(route.includes('.fullScreenCover(item: $routes.preview, onDismiss: finishDismissal)') &&
  route.includes('.navigationDestination(item: $routes.destination)'), 'real modal and destination live on a non-lazy screen owner');
expect(!card.includes('.navigationDestination') && !card.includes('.fullScreenCover'), 'lazy cards never register route destinations');
expect(card.includes('TVQuickViewPolicy.presents(enabled: quickViewEnabled, catalog: true)') &&
  card.includes('? { openPreview() } : nil') && card.includes('directPlay: action'), 'actual preference controls existing card activation');
expect(card.includes('menu: .catalog') && quick.includes('target.isCurrent(core: core, profiles: profiles, account: account)'),
  'existing long-press menu and captured owner guard remain real');
const dismissal = section(route, 'private func finishDismissal()', 'private func retirePreview()');
expect(dismissal.indexOf('target.isCurrent') < dismissal.indexOf('routes.destination = target'), 'dismissed Watch/Details route revalidates before navigation');
expect(route.includes('autoPlayOnAppear: target.autoPlay') && quick.includes('onOpen(true)') && quick.includes('onOpen(false)'),
  'real Watch intent and ordinary Details remain distinct');
expect(quick.includes('LibraryWatchedMutationPolicy.isCanonicalCatalogID(item.id)') &&
  quick.includes('LibraryAutoAdd.toggleWatchlistAcknowledged(') && quick.includes('target: mutationTarget'), 'watchlist uses canonical IDs and acknowledged native profile API');
expect(!quick.includes('core.metaDetails') && !quick.includes('loadMeta(') && !/presenter\.request\s*=(?!=)/.test(quick), 'preview consumes supplied facts and routes authoritative playback to Detail');
const root = read('app/SourcesTV/RootTabView.swift');
const discover = read('app/SourcesTV/DiscoverView.swift');
expect(root.includes('@AppStorage("vortx.mergeDiscoverSearch")') &&
  root.includes('TVDiscoverSearchPolicy.showsSeparateSearch(merged: mergeDiscoverSearch, hideSearch: hideSearchTab)') &&
  root.includes('selectionAfterMerge(selection, merged: merged,'), 'live setting hides separate Search and heals its selection');
expect(root.includes('DiscoverView(searchQuery: $discoverSearchQuery)') && discover.includes('TVMergedDiscoverSearch(query: $searchQuery)'),
  'mounted Discover actually receives the merged search consumer');
expect(root.indexOf('nav.popViewController(animated: true)') < root.indexOf('else if selection == 1, mergeDiscoverSearch'),
  'Back pops child detail before clearing a root search query');
const merged = read('app/SourcesTV/TVMergedDiscoverSearch.swift');
expect(merged.includes('TextField("Movies or series", text: $query)') && merged.includes('.onSubmit { submit() }'), 'merged search has real focused input and submission');
expect(merged.includes('core.search(value)') && merged.includes('core.suggestSearch(value)') && merged.includes('accountBoundary == account.credentialBoundaryGeneration'),
  'merged debounce dispatches existing engine callbacks under captured owner');
expect(merged.includes('SearchHistoryStore.load(profileID: profiles.activeID)') &&
  merged.includes('SearchHistoryStore.clear(profileID: profiles.activeID)') && merged.includes('onSelect: { saveQuery() }'),
  'recent/history/result callbacks use the real profile store');
expect(merged.includes('.onReceive(core.$searchResults)') && merged.includes('TVDiscoverSearchPolicy.acceptsResults(') &&
  merged.includes('admittedResults = results') && merged.includes('Searching more add-ons'), 'current engine publications render partial matches while slow add-ons remain loading');
expect(merged.includes('if hasQuery, debouncePending || submittedQuery != query.trimmingCharacters') &&
  merged.includes('schedule(query)'), 'a canceled retained query resumes after a temporary presentation');
for (const file of ['HomeView', 'DiscoverView', 'SearchView', 'TVCatalogBrowseView']) {
  const source = read(`app/SourcesTV/${file}.swift`);
  expect(source.includes('.tvCatalogQuickViewRoutes()') && source.includes('TVCatalogSelectionCard('), `${file} mounts routes and uses the catalog selection control`);
}
const home = read('app/SourcesTV/HomeView.swift');
assert.equal(section(home, 'struct CoreContinueWatchingRow:', '/// One engine catalog row'),
  section(baseline('app/SourcesTV/HomeView.swift'), 'struct CoreContinueWatchingRow:', '/// One engine catalog row'), 'all CW/private/direct resume logic is byte-identical'); checks++;
assert.equal(read('app/SourcesTV/LibraryView.swift'), baseline('app/SourcesTV/LibraryView.swift'), 'Library/history/local download routes are byte-identical'); checks++;
assert.equal(read('app/SourcesTV/SharedUI.swift'), baseline('app/SourcesTV/SharedUI.swift'), 'card controls/context menus/PIN-independent actions unchanged'); checks++;
const detail = read('app/SourcesTV/DetailView.swift');
const before = baseline('app/SourcesTV/DetailView.swift');
expect((detail.match(/var autoPlayOnAppear = false/g) ?? []).length === 3 && detail.includes('autoPlayOnAppear: Bool = false'),
  'Detail, episode, and source Watch seams default false');
expect(detail.includes('initialContinueWatchingIntent == nil, initialTraktSessionID == nil') &&
  detail.includes('resumeSeconds: primaryResumeSeconds') && detail.includes('initialStartAtSeconds: target.resumeSeconds'),
  'series explicit Watch freezes existing primary episode/resume and rejects private/CW retargeting');
const watch = section(detail, '@MainActor private func performQuickWatchIfRequested()', 'private func targetIsCurrent(');
expect(watch.includes('quickWatchOwner.begin(enabled: autoPlayOnAppear)') && watch.includes('sourceList.isSettled') &&
  watch.includes('for _ in 0..<120') && watch.includes('await playBestResolving('), 'one-shot structured Watch uses finite settled-source authority');
expect(!watch.includes('playBest(best') && watch.includes('quickWatchScope: scope'), 'explicit Watch never drops cancellation into unstructured playBest');
expect(detail.includes('if let scope = TVQuickViewWatchTask.scope, !quickWatchScopeIsCurrent(scope)') &&
  detail.includes('await TVQuickViewWatchTask.$scope.withValue(quickWatchScope)'), 'scope reaches every existing resolving/fallback admission boundary');
expect(detail.includes('quickWatchMutationTarget?.stillOwnsCurrentContext(core: core) == true') &&
  detail.includes('quickWatchAuxiliaryTarget == auxiliaryTarget') && detail.includes('taskCancelled: Task.isCancelled'), 'actual async admission rechecks native owner/source identity/cancellation');
expect(detail.includes('guard !autoPlayOnAppear, SourcePreferences.shared.autoPickBest'), 'explicit Watch and series automatic preference cannot both dispatch');
expect(section(detail, '    private func playBest(', '    private func proposedInitialStart(').includes('if autoPlayOnAppear { retireQuickWatch() }') &&
  section(detail, '    private func play(', '    /// #95: play a source-list TRAILER').includes('if autoPlayOnAppear { retireQuickWatch() }'),
  'manual Watch/source/quality choice retires pending explicit Watch before normal resolver dispatch');
expect(detail.includes('@StateObject private var quickWatchOwner = TVQuickViewWatchOwner()') &&
  (detail.match(/quickWatchOwner: quickWatchOwner/g) ?? []).length === 3, 'stable Detail-owned one-shot lifetime is threaded to movie/episode source children');
expect(detail.includes('if let meta = fencedMeta ?? quickWatchMoviePlaceholder') &&
  section(detail, '    private var quickWatchMoviePlaceholder:', '    /// Navigation-carried').includes('guard autoPlayOnAppear,'),
  'opt-in IMDb Watch keeps the same movie child through placeholder hydration while default Details retains its fallback');
function resolverBody(source, name) {
  const block = section(source, `@MainActor private func ${name}(`, '    /// `explicit`');
  return block.slice(block.indexOf(') async {') + ') async {'.length);
}
assert.equal(resolverBody(detail, 'playBestResolvingOwned'), resolverBody(before, 'playBestResolving'), 'ranked resolver policy unchanged inside optional scope wrapper'); checks++;
assert.equal(section(detail, '@MainActor private func playResolving(', '    private var launchPlayerLabel'),
  section(before, '@MainActor private func playResolving(', '    private var launchPlayerLabel'), 'single-source fallback implementation byte-identical'); checks++;
assert.equal(section(detail, '    private func hero(', '    private func resolveHeroDirectTrailer('),
  section(before, '    private func hero(', '    private func resolveHeroDirectTrailer('), 'visible default series/playback/trailer action route unchanged'); checks++;
console.log(`TVQuickViewDiscoverSourceWiring: ${checks} checks passed (static source contracts; no functional RED claimed)`);
