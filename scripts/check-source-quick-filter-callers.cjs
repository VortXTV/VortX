const fs = require('node:fs');
const root = process.argv[2];
const paths = {
  policy: 'app/SourcesShared/SourceQuickFilterPolicy.swift', model: 'app/SourcesShared/SourceListModel.swift',
  controls: 'app/SourcesShared/SourceQuickFilterControls.swift', ios: 'app/SourcesiOS/iOSDetailView.swift',
  tv: 'app/SourcesTV/DetailView.swift', ranking: 'app/SourcesShared/StreamRanking.swift',
  cache: 'app/SourcesShared/DebridResolver.swift', project: 'app/project.yml'
};
const sources = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, fs.readFileSync(root + '/' + path, 'utf8')]));
function need(ok, message) { if (!ok) throw Error(message); }
function between(text, start, end) {
  const a = text.indexOf(start), b = text.indexOf(end, a + start.length);
  need(a >= 0 && b > a, 'missing source region: ' + start); return text.slice(a, b);
}
function has(text, tokens, message) { for (const token of tokens) need(text.includes(token), message + ': ' + token); }
function contract(s) {
  const rebuild = between(s.model, 'private func rebuild()', 'func sourceIndexLifecycleDidClose(');
  has(rebuild, ['let quickFilterIndex = SourceQuickFilterPolicy.Index(groups: ranked, previous: previousQuickFilterIndex,',
    'reportedTags: StreamRanking.flavorTags', 'quickFilterSession.index : .empty',
    'publicationOwner.installQuickFilterIndex(quickFilterIndex)', 'publicationOwner.publishedGroups = ranked', 'publicationOwner.publishedBest = rankedBest'], 'real ranked/display split');
  need(rebuild.indexOf('let quickFilterIndex =') < rebuild.indexOf('await MainActor.run'), 'tag parsing stays detached');
  has(rebuild, ['let owner = self', 'let originalCoreIdentity = ObjectIdentifier(core)',
    'Task.detached(priority: .userInitiated) { [weak owner] in',
    'guard let publicationOwner = owner else { return }', 'await MainActor.run { [publicationOwner] in',
    'guard gen == publicationOwner.generation, let core = publicationOwner.core,',
    'ObjectIdentifier(core) == originalCoreIdentity else { return }'], 'actual frozen actor owner and original-core publication admission');
  const publication = rebuild.slice(rebuild.indexOf('await MainActor.run { [publicationOwner] in'));
  need(publication.indexOf('ObjectIdentifier(core) == originalCoreIdentity else { return }') <
    publication.indexOf('publicationOwner.installQuickFilterIndex(quickFilterIndex)'), 'index is installed only after original owner/core admission');
  need(!/\bself\./.test(publication), 'publication writes stay on the frozen checked owner');

  const display = between(s.model, '@Published private var quickFilterSession', '    var groups:');
  const selection = between(display, 'func setQuickFilters(', '    private func projectQuickFilters()');
  const projection = between(display, 'private func projectQuickFilters()', '    private func installQuickFilterIndex(');
  need(!/trigger\.send|rebuild\(|refind|debridCache\??\.refresh|UserDefaults|\.save\(/.test(display), 'facets cannot persist, refetch or rerank');
  for (const path of [selection, projection]) has(path, ['let snapshot = debridCache?.confirmedCacheSnapshot',
    'quickFilterCacheCapture = snapshot?.capture', 'cachedHashes: snapshot?.hashes ?? [], cachedUsenetURLs: snapshot?.usenetURLs ?? []'], 'fresh cache evidence on each projection action');
  has(display, ['quickFilterSession.select(selection,', 'quickFilterSession.refresh(cachedHashes:',
    'quickFilterSession.install(index, resetSelection: reset,',
    'quickFilterIdentity != identity || quickFilterProfileID != profileID',
    'quickFilterSession.displayed(', 'scopeIsCurrent: publishedIdentity == outputIdentity(for: context) && quickFilterIdentity == publishedIdentity',
    'cacheIsCurrent: quickFilterCacheCapture.map { CredentialScopeRegistry.shared.isCurrent($0) } == true'], 'actual shared display lifecycle and cache-only gate');
  need(!/NativeAccepted|nativeAccepted|registryGeneration|quickFilterOwner/.test(display + rebuild), 'optional facets cannot add a native registry availability gate');
  const retired = s.model.slice(s.model.indexOf('func sourceIndexLifecycleDidClose('));
  has(retired, ['quickFilterSession.invalidate()', 'quickFilterIdentity = nil', 'quickFilterProfileID = nil',
    'quickFilterCacheCapture = nil'], 'retired source projection cannot be repopulated by a late cache event');
  const cache = between(s.model, 'Publishers.CombineLatest(debridCache.$cachedHashes', '        var events:');
  has(cache, ['debridCache.$cachedUsenetURLs', '.removeDuplicates', '.receive(on: DispatchQueue.main)',
    'self.projectQuickFilters()'], 'current cache snapshot');
  need(!/trigger\.send|\.refresh\(/.test(cache), 'cache facts do not trigger providers');
  const receipt = between(s.cache, 'var confirmedCacheSnapshot:', '    /// Collect the RAW-torrent');
  has(receipt, ['CredentialScopeRegistry.shared.capture()', 'CredentialScopeRegistry.shared.isCurrent(capture)',
    'lastQueriedCapture == capture ? cachedHashes : []',
    'lastUsenetQueriedCapture == capture ? cachedUsenetURLs : []'], 'actual cache-owner receipt');
  const producer = between(s.cache, 'final class DebridCacheAwareness:', '// MARK: - Browsable cloud library');
  has(producer, ['self.cacheGeneration == generation', 'self.usenetGeneration == generation',
    'CredentialScopeRegistry.shared.isCurrent(capture)', 'self.lastQueriedCapture = capture',
    'self.lastUsenetQueriedCapture = capture'], 'successful owner-fenced cache producers');
  has(s.policy, ['guard selection.isActive else { return groups }', String.raw`rows.map(\.stream)`,
    'row.cacheHash.map(cachedHashes.contains) == true', 'row.cacheURLs.contains(where: cachedUsenetURLs.contains)',
    'if ranges.isEmpty { ranges.insert(.unknown) }', 'if codecs.isEmpty { codecs.insert(.unknown) }',
    'let occurrence = used[key, default: 0]', 'used[key] = occurrence + 1',
    'lhs.stream == rhs.stream', 'let previous = priorIDs[key] ?? []',
    'occurrence < previous.count ? previous[occurrence] : UUID()',
    'hasher.combine(stream.fileIdx)', 'hasher.combine(hints?.filename)', 'hasher.combine(headers?[key])'], 'actual pure projection and full-record row reuse');
  need(s.policy.indexOf('let occurrence =') < s.policy.indexOf('func project('), 'duplicate identity allocated before filtering');
  const identity = between(s.policy, 'var priorIDs:', '        func project(');
  need(!/firstIndex|removeFirst|remove\(at:|contains\(.*\.id|usedIDs/.test(identity), 'duplicate buckets use O(1) cursor consumption, never repeated scans or shifts');
  need(!/UserDefaults|SourcePreferences|TrackPreferences|StreamRanking\.isCached|playableURL|JSONEncoder|JSONSerialization/.test(s.policy), 'policy cannot persist/rank/resolve/serialize or treat URL as cache proof');
  const projected = between(s.policy, 'func project(', '    /// The actual model');
  need(!/\.sort(?:ed)?\(/.test(projected), 'projection preserves admitted source order');
  has(s.policy, ['struct Session: Sendable', 'groups = index.project(selection,', 'mutating func invalidate() { self = Session() }',
    'guard scopeIsCurrent, !selection.confirmedCacheOnly || cacheIsCurrent else { return [] }'], 'actual tested session preserves All without cache availability');
  has(s.controls, ['Cache: Confirmed', 'Reported range:', 'Reported codec:', 'Reset quick filters',
    'All ranges', 'All codecs', 'provider-reported, not verified', 'Play and Quality are unchanged',
    'let change: @MainActor (SourceQuickFilterPolicy.Selection) -> Void'], 'honest controls, actor isolation and reset');
  need((s.ios.match(/sourceRows: suspended \? \[\] : sourceList.quickFilterGroups/g) || []).length === 3, 'movie/live/episode display binding');
  need((s.ios.match(/onQuickFiltersChange: \{ sourceList.setQuickFilters\(\$0\) \}/g) || []).length === 3, 'three real selection setters');
  has(s.ios, ['bestStream: sourceList.best', 'resolutionTiers: sourceList.tiers',
    'sourceRows.filter { sourceFilter == nil || $0.group.id == sourceFilter }',
    'private typealias SourceRow = SourceQuickFilterPolicy.Row', 'Array(sortedStreams(display).prefix(take))',
    'lhs.sourceRows == rhs.sourceRows', 'lhs.quickFilters == rhs.quickFilters', 'No sources match these list filters.',
    'var onQuickFiltersChange: (@MainActor (SourceQuickFilterPolicy.Selection) -> Void)? = nil'], 'iOS displayed rows and immutable play choice');
  has(s.tv, ['let groups = sourceList.groups', 'let best = sourceList.best',
    'let visible = sourceList.quickFilterGroups.filter', 'for row in g.rows {', 'rows.append(row)',
    'private typealias SourceRow = SourceQuickFilterPolicy.Row',
    'SourceQuickFilterControls(selection: sourceList.quickFilters, change: sourceList.setQuickFilters)',
    'filterBarOwnsUpEscape(groupsCount: groups.count, hasQuickFilters: true)',
    'sourceRowOwnsUpEscape(at: index, groupsCount: groups.count, hasQuickFilters: true)',
    'No sources match these list filters.'], 'TV source projection/focus wiring');
  const tags = between(s.ranking, 'static func flavorTags(', '    /// The parsed file size');
  has(tags, ['let t = qualityText(s)', 'tags.append("DV")', 'tags.append("HDR10+")',
    'tags.append("HEVC")', 'tags.append("H.264")', 'tags.append("AV1")'], 'actual provider-text tag origin');
  for (const target of ['VortXiOSNative', 'VortXMac', 'VortXTV', 'VortXTVLite']) {
    const start = s.project.indexOf('  ' + target + ':\n');
    need(start >= 0, 'missing app target ' + target);
    const next = s.project.slice(start + 3).search(/^  \w[^\n]*:\s*$/m);
    const block = next < 0 ? s.project.slice(start) : s.project.slice(start, start + 3 + next);
    need(block.includes('- path: SourcesShared'), 'shared helper not enrolled: ' + target);
    need(block.includes(target.startsWith('VortXTV') ? '- path: SourcesTV' : '- SourcesiOS'), 'real source surface missing: ' + target);
  }
}
contract(sources);
const mutations = [
  ['model', 'reportedTags: StreamRanking.flavorTags', 'reportedTags: { _ in [] }'],
  ['model', 'publicationOwner.installQuickFilterIndex(quickFilterIndex)', ''],
  ['model', 'guard let publicationOwner = owner else { return }', 'let publicationOwner = owner!'],
  ['model', 'guard gen == publicationOwner.generation, let core = publicationOwner.core,', 'guard let core = publicationOwner.core,'],
  ['model', 'ObjectIdentifier(core) == originalCoreIdentity else { return }', 'true else { return }'],
  ['model', 'publicationOwner.publishedGroups = ranked', 'self.publishedGroups = ranked'],

  ['model', 'quickFilterSession.select(selection,', 'trigger.send(); quickFilterSession.select(selection,'],
  ['model', 'quickFilterProfileID != profileID', 'false'],
  ['model', 'let snapshot = debridCache?.confirmedCacheSnapshot', 'let snapshot = nil'],
  ['model', 'cacheIsCurrent: quickFilterCacheCapture.map { CredentialScopeRegistry.shared.isCurrent($0) } == true', 'cacheIsCurrent: true'],
  ['model', 'quickFilterSession.invalidate()', ''],
  ['model', 'quickFilterSession.displayed(', 'quickFilterOwner.map { _ in [] } ?? quickFilterSession.displayed('],
  ['model', 'previous: previousQuickFilterIndex', 'previous: nil'],
  ['cache', 'lastQueriedCapture == capture ? cachedHashes : []', 'cachedHashes'],
  ['cache', 'lastUsenetQueriedCapture == capture ? cachedUsenetURLs : []', 'cachedUsenetURLs'],
  ['policy', 'row.cacheHash.map(cachedHashes.contains) == true', 'true'],
  ['policy', 'row.cacheURLs.contains(where: cachedUsenetURLs.contains)', 'false'],
  ['policy', 'if ranges.isEmpty { ranges.insert(.unknown) }', ''],
  ['policy', 'let occurrence = used[key, default: 0]', 'let occurrence = 0'],
  ['policy', 'lhs.stream == rhs.stream', 'lhs.stream.id == rhs.stream.id'],
  ['policy', 'occurrence < previous.count ? previous[occurrence] : UUID()', 'UUID()'],
  ['policy', '!selection.confirmedCacheOnly || cacheIsCurrent', 'cacheIsCurrent'],
  ['controls', 'provider-reported, not verified', 'verified'],
  ['controls', 'let change: @MainActor', 'let change:'],
  ['ios', 'sourceRows: suspended ? [] : sourceList.quickFilterGroups', 'sourceRows: []'],
  ['ios', 'lhs.quickFilters == rhs.quickFilters', 'true'],
  ['ios', 'sourceRows.filter { sourceFilter == nil || $0.group.id == sourceFilter }', 'sourceRows.filter { sourceFilter == nil || $0.group.addon == sourceFilter }'],
  ['tv', 'let visible = sourceList.quickFilterGroups.filter', 'let visible = sourceList.groups.filter'],
  ['tv', 'filterBarOwnsUpEscape(groupsCount: groups.count, hasQuickFilters: true)', 'filterBarOwnsUpEscape(groupsCount: groups.count)']
];
for (const [key, from, to] of mutations) {
  need(sources[key].includes(from), 'missing negative-control site');
  let rejected = false;
  try { contract({ ...sources, [key]: sources[key].replace(from, to) }); } catch { rejected = true; }
  need(rejected, 'source contract missed mutation: ' + from);
}
console.log('Source quick-filter caller contracts PASS; ' + mutations.length + ' negative controls rejected');
