import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const base = '3b69b542fe19cee7902279abd0e578f52ac285f3';
const repo = fs.realpathSync(process.cwd());
const read = (path) => fs.readFileSync(path, 'utf8');
const baseline = (path) => execFileSync('git', ['-C', repo, 'show', `${base}:${path}`], { encoding: 'utf8' });
let checks = 0;
const expect = (condition, message) => { assert.ok(condition, message); checks++; };
const equal = (actual, expected, message) => { assert.equal(actual, expected, message); checks++; };
function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing source boundary: ${start}`);
  return source.slice(from, to);
}

const home = read('app/SourcesTV/HomeView.swift');
const originalHome = baseline('app/SourcesTV/HomeView.swift');
const topPicks = section(home, 'struct TopPicksRow:', '/// An external service');
const originalTopPicks = section(originalHome, 'struct TopPicksRow:', '/// An external service');
expect(topPicks.includes('TVCatalogSelectionCard(presentation: .preview(item), cinematic: false,'),
  'normal Top Picks uses truthful supplied preview and keeps existing poster-style geometry');
expect(topPicks.includes('isWatched: watchedIndex.ids.contains(item.id)') &&
  topPicks.includes('{ model.focus(hero(for: item)) }'), 'Top Picks retains watched/focus callbacks');
equal(home.replace(topPicks, originalTopPicks), originalHome,
  'all other Home code, including CW/resume/private/remote Watchlist/server/imported/upcoming Library, is byte-identical');

const adapter = read('app/SourcesTV/TVQuickViewCatalogRailPolicy.swift');
expect(adapter.includes('.init(id: item.id, type: item.type, title: item.name, poster: item.poster)'),
  'legacy adapter carries exact supplied identity/title/poster');
expect(!adapter.includes('background:') && !adapter.includes('rating:') && !adapter.includes('runtime:') &&
  !adapter.includes('releaseInfo:') && !adapter.includes('overview:'), 'unknown legacy facts and wide art are not invented');
expect(!adapter.includes('CoreBridge') && !adapter.includes('loadMeta(') && !adapter.includes('TMDBClient'),
  'preview projection never issues provider or metadata work');
equal(read('app/SourcesShared/Addon.swift'), baseline('app/SourcesShared/Addon.swift'), 'shipping legacy decoder/provider implementation unchanged');
equal(read('app/SourcesShared/CoreModels.swift'), baseline('app/SourcesShared/CoreModels.swift'), 'shipping rich decoder unchanged');
equal(read('app/SourcesShared/TVCatalogCinemaPolicy.swift'), baseline('app/SourcesShared/TVCatalogCinemaPolicy.swift'), 'existing rich catalog projection unchanged');
for (const file of ['TVQuickView', 'TVQuickViewPolicy', 'TVMergedDiscoverSearch', 'DetailView', 'DiscoverView', 'RootTabView', 'SearchView', 'TVCatalogBrowseView', 'LibraryView', 'SharedUI']) {
  equal(read(`app/SourcesTV/${file}.swift`), baseline(`app/SourcesTV/${file}.swift`), `${file} preserves the accepted checkpoint behavior`);
}
const quick = read('app/SourcesTV/TVQuickView.swift');
expect(quick.includes('@AppStorage("vortx.quickViewEnabled") private var quickViewEnabled = true') &&
  quick.includes('? { openPreview() } : nil') && quick.includes('directPlay: action'),
  'normal legacy catalog selections use live true default and retain direct Details when off');
expect(home.includes('.tvCatalogQuickViewRoutes()'), 'normal Top Picks inherits the non-lazy Home route owner');

const browse = read('app/SourcesTV/BrowseGridView.swift');
const originalBrowse = baseline('app/SourcesTV/BrowseGridView.swift');
const oldCard = `PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               isWatched: watchedIndex.ids.contains(item.id),
                               width: TVGridMetrics.posterCellWidth, landscapeWidth: TVGridMetrics.landscapeCellWidth,
                               menu: .catalog,`;
const newCard = `TVCatalogSelectionCard(presentation: .preview(item), width: TVGridMetrics.landscapeCellWidth,
                               posterWidth: TVGridMetrics.posterCellWidth, cinematic: false,
                               isWatched: watchedIndex.ids.contains(item.id),`;
expect(browse.includes(newCard), 'normal provider/genre category results use supplied preview and preserve both fixed cell widths');
expect(browse.includes('onFocus: { focusModel.focus(hero(for: item)) })\n                        .onAppear { if item.id == items.last?.id { Task { await loadNext() } } }'),
  'category card focus and exact last-item pagination callback remain real');
const oldMount = `.background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { if selectedID.isEmpty, let first = subs.first { select(first.id) } }`;
const newMount = `.background(Theme.Palette.canvas.ignoresSafeArea())
        .tvCatalogQuickViewRoutes()
        .onAppear { if selectedID.isEmpty, let first = subs.first { select(first.id) } }`;
expect(browse.includes(newMount), 'category browser mounts its own routes on the non-lazy screen owner');
equal(browse.replace(newCard, oldCard).replace(newMount, oldMount), originalBrowse,
  'fetch/model, collection tile actions, pagination, pills, focus and category lifecycle otherwise remain byte-identical');
expect(!section(browse, '    @ViewBuilder private var grid:', '    private func select(').includes('.tvCatalogQuickViewRoutes()'),
  'lazy category grid cells never own modal/destination registration');
console.log(`TVQuickViewCatalogRailSourceWiring: ${checks} checks passed (static source contracts; no functional RED claimed)`);
