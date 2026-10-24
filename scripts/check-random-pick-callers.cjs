// Runnable source contracts against the owning checkout. Mutations stay in memory, never touch source.
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
if (!root || !fs.existsSync(path.join(root, 'app/project.yml'))) throw Error('Exact VortX checkout required');
const sources = {};
for (const name of ['app/SourcesiOS/iOSRootView.swift', 'app/SourcesTV/LibraryView.swift',
                    'app/SourcesiOS/iOSDetailView.swift', 'app/SourcesTV/DetailView.swift',
                    'app/SourcesShared/RandomPickPolicy.swift', 'app/SourcesShared/RandomPickUIAccess.swift',
                    'app/SourcesShared/RandomPickPlayPolicy.swift', 'app/SourcesShared/SourceListModel.swift',
                    'app/SourcesShared/RandomPickPlayIntent.swift', 'app/project.yml']) {
  sources[name] = fs.readFileSync(path.join(root, name), 'utf8');
}
function need(ok, message) { if (!ok) throw Error(message); }
function block(source, label) {
  const start = source.indexOf('// BEGIN RANDOM PICK ' + label);
  const end = source.indexOf('// END RANDOM PICK ' + label, start);
  need(start >= 0 && end > start, 'missing actual caller block ' + label);
  return source.slice(start, end);
}
function method(source, name) {
  const start = source.indexOf('func ' + name + '(');
  need(start >= 0, 'missing method ' + name);
  const open = source.indexOf('{', start);
  let depth = 1, cursor = open + 1;
  for (; depth && cursor < source.length; cursor++) {
    if (source[cursor] === '{') depth++;
    if (source[cursor] === '}') depth--;
  }
  need(depth === 0, 'unclosed method ' + name);
  return source.slice(start, cursor);
}
function contracts(files) {
  for (const [file, kind] of [['app/SourcesiOS/iOSRootView.swift', 'Library'], ['app/SourcesTV/LibraryView.swift', 'Library'],
                            ['app/SourcesiOS/iOSDetailView.swift', 'Episode'], ['app/SourcesTV/DetailView.swift', 'Episode']]) {
    const source = files[file], stem = 'random' + kind, label = kind.toUpperCase();
    const helpers = block(source, label + ' HELPERS'), lifecycle = block(source, label + ' LIFECYCLE');
    const again = method(helpers, 'pickRandom' + kind + 'Again');
    const currentName = 'currentRandom' + kind + (kind === 'Library' ? 'Item' : '');
    const selectionName = 'selectRandom' + kind + (kind === 'Library' ? 'Item' : '');
    const current = method(helpers, currentName);
    need(again.indexOf('guard ' + currentName + '(origin) != nil') >= 0 &&
         again.indexOf('guard ') < again.indexOf(selectionName + '()'), file + ': Pick again must validate originating ticket');
    need(current.includes(stem + 'Session.ticket == origin'), file + ': exact callback ticket');
    need(current.includes(stem + 'Session.accepts(origin') && current.includes('currentRecord: current.map'), file + ': current record admission');
    need(current.includes(stem + 'Access?.isCurrent(profiles: profiles, core: core) == true'), file + ': full UI access fence');
    const select = method(helpers, selectionName);
    need(select.includes('guard let access = RandomPickUIAccess.capture(profiles: profiles, core: core)'), file + ': captured owner/profile/picker before selection');
    const clear = method(helpers, 'clearRandom' + kind + 'Pick');
    for (const field of ['Preview = nil', 'Route = nil', 'Access = nil', 'Session.clear()']) need(clear.includes(stem + field), file + ': route/preview revocation ' + field);
    need(helpers.includes('Binding(get: { ' + stem + 'Route != nil }, set: { if !$0 { clearRandom' + kind + 'Pick() } })'), file + ': pop revokes');
    need(lifecycle.includes('.onReceive(profiles.$activeID)') && lifecycle.includes('ticket.profileID != profileID'), file + ': profile publisher fences A-B-A');
    need(lifecycle.includes('.onReceive(core.$revision)') && lifecycle.includes('access.isCurrent(profiles: profiles, core: core)'), file + ': owner invalidation');
    need(lifecycle.includes('.onReceive(profiles.$profiles) { incoming in') && lifecycle.includes('access.matchesPublishedProfiles(incoming, pickedThisLaunch: profiles.pickedThisLaunch)'), file + ': incoming roster invalidation');
    need(lifecycle.includes('.onReceive(profiles.$pickedThisLaunch)') && lifecycle.includes('if !picked, profiles.profiles.count > 1'), file + ': picker revocation');
    need(lifecycle.includes('onOpen: { openRandom' + kind + (kind === 'Library' ? 'Item' : '') + '(ticket, autoPlay: false) }'), file + ': Open navigation intent');
    need(lifecycle.includes('onPickAgain: { pickRandom' + kind + 'Again(ticket) }'), file + ': sheet captures exact ticket');
    need(lifecycle.includes('.sheet(isPresented: ' + stem + 'PreviewPresented)') && lifecycle.includes('.id(ticket.id)'), file + ': stable sheet presentation across Pick again');
    need(!lifecycle.includes('.sheet(item:') && !lifecycle.includes('onDismiss:'), file + ': no old sheet dismissal can clear new ticket');
    need(helpers.includes('route.intent?.routeIsCurrent(core: core, profiles: profiles)') && helpers.includes('route.access.isNavigationCurrent(profiles: profiles, core: core)') && helpers.includes('profiles.activeID == route.ticket.profileID'), file + ': destination owner admission');
    if (file.includes('SourcesiOS')) {
      need(lifecycle.includes('(ticket, autoPlay: true)'), file + ': distinct Play intent');
      need(helpers.includes('autoPlayOnAppear: route.autoPlay'), file + ': supported explicit autoplay');
    } else {
      need(lifecycle.includes('onPlay: { openRandom' + kind + (kind === 'Library' ? 'Item' : '') + '(ticket, autoPlay: true) }'), file + ': explicit TV Play');
      need(helpers.includes('autoPlayOnAppear: route.autoPlay'), file + ': real TV autoplay forwarding');
      need(helpers.includes('let intent = autoPlay ? RandomPickPlayIntent(ticketID: origin.id, access: access)'), file + ': action-owned intent');
      need(helpers.includes(stem + 'Route?.ticket == origin && ' + (kind === 'Library' ? currentName + '(origin) != nil' : 'pendingRandomEpisodeOriginIsCurrent(origin, video: current, source: RandomPickPolicy.EpisodeSource(currentMeta))')), file + ': original route/record fence');
      need(clear.includes(stem + 'Route?.intent?.revoke()'), file + ': route revokes pending resolution');
    }
    if (kind === 'Episode') {
      need(current.includes('RandomPickPolicy.EpisodeSource(currentMeta) == randomEpisodeSource'), file + ': metadata receipt');
      need(lifecycle.includes('.onReceive(core.metaDetailsPublisher)') && lifecycle.includes('current.map(RandomPickPolicy.EpisodeSource.init) != source'), file + ': metadata invalidation');
      need(lifecycle.includes('guard randomEpisodePreview != nil, randomEpisodeRoute == nil,\n                  let source = randomEpisodeSource else { return }'), file + ': metadata invalidates only an uncommitted preview');
      need(lifecycle.includes('if randomEpisodeRoute == nil { clearRandomEpisodePick() }'), file + ': presenting disappearance preserves admitted session');
      const open = method(helpers, 'openRandomEpisode');
      need(open.includes('let (currentMeta, current) = currentRandomEpisode(origin)') &&
           open.includes('randomEpisodeRoute = RandomPickEpisodeRoute(ticket: origin, meta: currentMeta, video: current,\n            orderedEpisodes:'), file + ': route reacquires current record');
      for (const field of ['initialTraktSessionID:', 'initialContinueWatchingIntent:', 'initialTraktNextEpisodeOffer:', 'initialStartAtSeconds:']) need(!helpers.includes(field), file + ': no inherited continuation authority ' + field);
      const destination = helpers.slice(helpers.indexOf('@ViewBuilder private var randomEpisodeDestination'));
      need(!destination.includes('.orderedBySeasonEpisode') && !destination.includes('sortedEpisodes('), file + ': no body-time episode re-sort');
    } else {
      const invalidate = method(helpers, 'invalidateRandomLibraryRecord');
      need(invalidate.includes('guard randomLibraryPreview != nil, randomLibraryRoute == nil,\n              let ticket = randomLibrarySession.ticket else { return }') &&
           invalidate.indexOf('guard randomLibraryPreview') < invalidate.indexOf('let current = items.first'), file + ': Library updates invalidate only an uncommitted preview');
      need(invalidate.includes('RandomPickPolicy.libraryRecord(current) == ticket.record else { clearRandomLibraryPick(); return }'), file + ': changed pending Library records still revoke');
      const remainder = source.replace(helpers, '');
      need(!remainder.includes('randomLibraryCandidates()'), file + ': pool only on actions');
      const observer = file.includes('SourcesiOS') ? '.onValueChange' : '.onChange';
      need(lifecycle.includes(observer + '(of: segment)') && lifecycle.includes(observer + '(of: activeFilters)'), file + ': filter revocation');
      need(!helpers.includes('sourceGeneration'), file + ': no full-history body signature');
      if (file.includes('SourcesiOS')) need(lifecycle.includes('.onValueChange(of: isActive) { active in if !active { clearRandomLibraryPick() } }'), file + ': hidden mounted tab revokes');
    }
    for (const token of ['setNative', 'markWatched(', 'saveProgress(', 'recordProgress(', 'LastStreamStore.record', 'core.loadMeta(', 'URLSession']) need(!helpers.includes(token), file + ': pick helper must not mutate or resolve ' + token);
  }
  // TV Play executes through the actual ranked resolver, not a second direct URL launch path.
  const tv = files['app/SourcesTV/DetailView.swift'];
  const intent = files['app/SourcesShared/RandomPickPlayIntent.swift'];
  const uiAccess = files['app/SourcesShared/RandomPickUIAccess.swift'];
  const sourceModel = files['app/SourcesShared/SourceListModel.swift'];
  const sourceStart = tv.indexOf('struct CoreStreamList: View');
  const sourceView = tv.slice(sourceStart);
  need(sourceView.includes('@ObservedObject var profiles: ProfileStore'), 'TV source list receives the observed profile owner');
  need((tv.match(/CoreStreamList\(title: [^\n]+, profiles: profiles,\n/g) || []).length === 3,
       'all three TV source-list callers pass their existing profile owner');
  need((tv.match(/var autoPlayOnAppear = false/g) || []).length === 3, 'TV autoplay defaults off on all three surfaces');
  need(tv.includes('autoPlayOnAppear: Bool = false') && tv.includes('self.autoPlayOnAppear = autoPlayOnAppear'), 'episode custom initializer defaults off');
  need(tv.includes('autoPlayOnAppear: route.autoPlay') && tv.includes('randomPlayIntent: route.intent, suppressPreferenceAutoPlay: true'), 'random episode true Play / navigation-only Open');
  need(tv.includes('if randomSeriesPlayRoute == nil { randomPlayIntent?.revoke() }'), 'series child transfer preserves pending command');
  const seriesRoute = method(tv, 'routeRandomSeriesPlay');
  for (const term of ['autoPlayOnAppear', '!didRouteRandomSeriesPlay', 'eligibleEpisodes', 'intent.bind(', 'didRouteRandomSeriesPlay = true']) need(seriesRoute.includes(term), 'series Play route missing ' + term);
  need(!seriesRoute.includes('initialStartAtSeconds') && !seriesRoute.includes('initialTrakt'), 'new series Play inherits no resume offer');
  const lifecycleStart = sourceView.indexOf('// BEGIN TV RANDOM PLAY SOURCE LIFECYCLE');
  const lifecycleEnd = sourceView.indexOf('// END TV RANDOM PLAY SOURCE LIFECYCLE', lifecycleStart);
  const playTask = sourceView.slice(lifecycleStart, lifecycleEnd);
  for (const term of ['guard autoPlayOnAppear, let intent = randomPlayIntent, intent.isPending', 'intent.bind(meta: metadata, video: randomPlayVideo', '!Task.isCancelled, presenter.request == nil', 'sourceList.playbackReceipt(pin: sourcePin)', 'intent.claim(core: core, profiles: profiles)', 'await playBestResolving', 'fromStart: false', 'proposedInitialStart(fromStart: false)', 'randomAttempt: attempt', '.onDisappear { randomPlayIntent?.revoke() }']) need(playTask.includes(term), 'TV explicit task missing ' + term);
  need(!/presenter\.request\s*=(?!=)/.test(playTask) && !playTask.includes('Task {'), 'explicit task must await existing resolver, not detached handoff');
  need(playTask.includes('.task(id: randomPlayMetadata?.id)') && tv.includes('randomPlayMetadata: fencedMeta'), 'movie waits for actual metadata, not a transient placeholder');
  need(sourceView.includes('guard !suppressPreferenceAutoPlay, randomPlayIntent == nil,'), 'Open/pending request cannot inherit preference auto-pick');
  const target = method(sourceView, 'targetIsCurrent');
  for (const term of ['randomAttempt: RandomPlayAttempt? = nil', '!Task.isCancelled, presenter.request == nil', 'randomAttempt.intent.accepts(randomAttempt.claim', 'playbackReceiptIsCurrent(randomAttempt.source, pin: sourcePin)']) need(target.includes(term), 'TV async target fence missing ' + term);
  const consume = method(sourceView, 'consumeRandomPlay');
  for (const term of ['guard let attempt else { return true }', '!Task.isCancelled && presenter.request == nil', 'attempt.intent.consume(attempt.claim', 'playbackReceiptIsCurrent(attempt.source, pin: sourcePin)']) need(consume.includes(term), 'TV final consume missing ' + term);
  for (const name of ['play', 'playBest', 'refindSources']) need(method(sourceView, name).includes('randomPlayIntent?.revoke()'), name + ' must revoke pending Play before manual work');
  const resolving = sourceView.slice(sourceView.indexOf('@MainActor private func playBestResolving'), sourceView.indexOf('private var launchPlayerLabel'));
  need(resolving.includes('DebridCoordinator.shared.resolveFirstPlayable(') && resolving.includes('await playResolving('), 'Play uses normal ranked resolver/fallback');
  need(resolving.includes('startProposal: startProposal,\n            randomAttempt: randomAttempt'), 'fallback conserves exact original claim');
  const gates = [...resolving.matchAll(/targetIsCurrent\(([\s\S]*?)\)/g)];
  need(gates.length >= 12 && gates.every(m => m[1].includes('randomAttempt: randomAttempt')), 'every existing await/bind target fence carries claim');
  const handoffs = [...resolving.matchAll(/presenter\.request = PlaybackRequest/g)];
  need(handoffs.length === 4, 'four real TV content handoff sites');
  for (const m of handoffs) need(resolving.slice(Math.max(0,m.index-180),m.index).includes('guard consumeRandomPlay(randomAttempt) else { return }'), 'final handoff must atomically consume');
  for (const name of ['playExtra', 'playFullTrailerInApp', 'openTrailerInYouTubeApp']) need(method(tv, name).includes('randomPlayIntent?.revoke()'), 'manual trailer revokes pending content Play');
  need(resolving.includes('!randomHandedOff { win.ref.nativeUsenetLease?.close() }') && resolving.includes('!randomHandedOff { ref.nativeUsenetLease?.close() }'), 'rejected pending resolver releases native lease');
  for (const term of ['access.isCurrent(profiles: profiles, core: core), originIsCurrent?() == true', 'RandomPickPolicy.EpisodeSource(current) == source', 'policy.consume(claim, current: current)', 'case .consumed, .revoked: return false', 'access.isNavigationCurrent(profiles: profiles, core: core)', 'access.matchesPublishedNavigationProfiles(incoming, pickedThisLaunch: pickedThisLaunch)']) need(intent.includes(term), 'shared intent missing ' + term);
  need(method(intent, 'bind').includes('eligibleEpisodes(meta.videos ?? [], now: Date()).contains(video)'), 'one-time full inventory membership/ambiguity proof');
  const currentIntent = method(intent, 'isCurrent');
  need(currentIntent.includes('eligibleEpisodes([video], now: Date()).contains(video)') && !currentIntent.includes('eligibleEpisodes(current.videos'), 'pending polling must only recheck selected episode eligibility');
  for (const name of ['accepts', 'consume']) need(method(intent, name).includes('if !requiresFullAccess { releasePendingEvidence() }'), name + ': terminal evidence retirement');
  const release = method(intent, 'releasePendingEvidence');
  for (const term of ['originIsCurrent = nil', 'source = nil', 'video = nil']) need(release.includes(term), 'terminal evidence release missing ' + term);
  need(method(intent, 'revoke').includes('releasePendingEvidence()'), 'manual/cancel terminal releases parent capture');
  for (const name of ['app/SourcesiOS/iOSDetailView.swift', 'app/SourcesTV/DetailView.swift']) {
    const pending = method(files[name], 'pendingRandomEpisodeOriginIsCurrent');
    for (const term of ['randomEpisodeSession.ticket == origin', 'RandomPickPolicy.EpisodeSource(currentMeta) == source', 'eligibleEpisodes([video], now: Date()).contains(video)', 'randomEpisodeSession.accepts(origin', 'currentRecord: RandomPickPolicy.episodeRecord(video, type: currentMeta.type)']) need(pending.includes(term), name + ': pending selected-record fence missing ' + term);
    need(!pending.includes('currentRandomEpisode(') && !pending.includes('eligibleEpisodes(currentMeta.videos'), name + ': no full inventory rebuild through pending origin');
    need(method(files[name], 'openRandomEpisode').includes('!intent.bind(meta: currentMeta, video: current, core: core, profiles: profiles)'), name + ': one-time membership before queued Play');
    need(files[name].includes('randomEpisodeRoute?.intent?.invalidateMetadata(details)'), name + ': pending A-B-A metadata publication fence');
  }
  const navigation = method(uiAccess, 'navigationProfileMatches');
  for (const key of ['id', 'pin', 'isKids', 'usesOwnAccount', 'isOwner', 'email', 'familyEdit']) need(navigation.includes('current.' + key + ' == profile.' + key), 'navigation authority loses ' + key);
  need(!navigation.includes('playback') && !navigation.includes('current == profile'), 'admitted route must survive benign playback preference save');
  const sourceReceipt = method(sourceModel, 'playbackReceipt');
  for (const term of ['isSettled, pendingSignature == nil', 'let signature = publishedSignature', 'signature == currentPlaybackSignature(context: livePlaybackContext(pin: pin))', 'PlaybackReceipt(generation: generation, signature: signature)']) need(sourceReceipt.includes(term), 'settled source receipt missing ' + term);
  need(method(sourceModel, 'rebuild').includes('currentPlaybackSignature(context: ctx)'), 'receipt must reuse actual source producer signature');
  const signature = method(sourceModel, 'currentPlaybackSignature');
  for (const term of ['core.streamsEpoch', 'torbox.epoch', 'singularity.epoch', 'mediaServers.epoch', 'jsProvider?.epoch', 'SettlementEpoch', 'hasher.combine(ctx.pin', 'hasher.combine(ctx.prefsSignature)', 'hasher.combine(ctx.isKids)', 'hasher.combine(ctx.disabledAddons)', 'hasher.combine(cachedHashes)', 'hasher.combine(tombstones)']) need(signature.includes(term.replace('hasher.combine(ctx.pin', 'hasher.combine(String(describing: ctx.pin')), 'source signature missing ' + term);

  const policy = files['app/SourcesShared/RandomPickPolicy.swift'];
  for (const token of ['ticket == origin', 'origin.profileID == profileID', 'origin.scope == scope', 'ownerIsCurrent && currentRecord == origin.record', 'Ticket(id: UUID()']) need(policy.includes(token), 'policy missing ownership term ' + token);
  const access = files['app/SourcesShared/RandomPickUIAccess.swift'];
  for (const token of ['let profile: UserProfile', 'let target: PlaybackMutationTarget', 'guard !profiles.needsPicker, let profile = profiles.active', 'PlaybackMutationTarget.capture(core: core)', 'profiles.active == profile && target.stillOwnsCurrentContext(core: core)', 'incoming.first(where: { $0.id == profile.id }) == profile', '!(incoming.count > 1 && !pickedThisLaunch)']) need(access.includes(token), 'shared UI access missing ' + token);
  need(method(access, 'isCurrent').includes('!profiles.needsPicker'), 'UI access revalidates picker');
  const project = files['app/project.yml'];
  for (const [target, platform] of [['VortXiOSNative', 'SourcesiOS'], ['VortXMac', 'SourcesiOS'], ['VortXTV', 'SourcesTV'], ['VortXTVLite', 'SourcesTV']]) {
    const start = project.indexOf('  ' + target + ':\n');
    const next = project.slice(start + 3).search(/^  [A-Za-z0-9_]+:\s*$/m);
    const body = project.slice(start, next < 0 ? undefined : start + 3 + next);
    need(body.includes('path: SourcesShared') && body.includes(platform), target + ': actual source inclusion');
    need(!body.includes('RandomPickPolicy.swift') || !body.includes('excludes: ["RandomPickPolicy.swift"'), target + ': excluded policy');
  }
}
contracts(sources);
const mutations = [
  ['app/SourcesTV/DetailView.swift', '@ObservedObject var profiles: ProfileStore', '', 'TV child loses profile owner'],
  ['app/SourcesTV/DetailView.swift', 'CoreStreamList(title: m.name, profiles: profiles,', 'CoreStreamList(title: m.name,', 'TV movie source list loses injected owner'],
  ['app/SourcesiOS/iOSDetailView.swift', '.onReceive(core.metaDetailsPublisher) { details in', '.onReceive(core.revisionPublisher) { details in', 'iOS metadata observer follows unrelated revisions'],
  ['app/SourcesTV/DetailView.swift', '.onReceive(core.metaDetailsPublisher) { details in', '.onReceive(core.revisionPublisher) { details in', 'TV metadata observer follows unrelated revisions'],
  ['app/SourcesTV/LibraryView.swift', 'onPlay: { openRandomLibraryItem(ticket, autoPlay: true) }', 'onPlay: { openRandomLibraryItem(ticket, autoPlay: false) }', 'TV Play aliases Open'],
  ['app/SourcesTV/DetailView.swift', 'var autoPlayOnAppear = false', 'var autoPlayOnAppear = true', 'TV defaults autoplay on'],
  ['app/SourcesTV/DetailView.swift', 'guard autoPlayOnAppear, let intent = randomPlayIntent, intent.isPending', 'guard let intent = randomPlayIntent, intent.isPending', 'TV ignores explicit enabled flag'],
  ['app/SourcesTV/DetailView.swift', 'guard !suppressPreferenceAutoPlay, randomPlayIntent == nil,', 'guard', 'Open inherits preference auto-pick'],
  ['app/SourcesTV/DetailView.swift', 'sourceList.playbackReceipt(pin: sourcePin)', 'nil', 'TV bypasses settled source receipt'],
  ['app/SourcesTV/DetailView.swift', 'sourceIsCurrent: sourceList.playbackReceiptIsCurrent(randomAttempt.source, pin: sourcePin)', 'sourceIsCurrent: true', 'async source revocation omitted'],
  ['app/SourcesTV/DetailView.swift', 'guard consumeRandomPlay(randomAttempt) else { return }', '', 'first final handoff bypasses consumption'],
  ['app/SourcesTV/DetailView.swift', 'startProposal: startProposal,\n            randomAttempt: randomAttempt', 'startProposal: startProposal', 'fallback drops original claim'],
  ['app/SourcesTV/DetailView.swift', 'randomPlayIntent?.revoke() // A manual source/trailer selection wins over pending auto Play.', '', 'manual source loses to old auto resolver'],
  ['app/SourcesShared/RandomPickPlayIntent.swift', 'access.isCurrent(profiles: profiles, core: core), originIsCurrent?() == true', 'access.isCurrent(profiles: profiles, core: core)', 'stale ticket origin bypassed'],
  ['app/SourcesShared/RandomPickPlayIntent.swift', 'RandomPickPolicy.EpisodeSource(current) == source', 'true', 'metadata snapshot bypassed'],
  ['app/SourcesShared/RandomPickPlayIntent.swift', 'case .consumed, .revoked: return false', 'case .consumed, .revoked: return true', 'admitted player still full-profile fenced'],
  ['app/SourcesShared/RandomPickUIAccess.swift', 'current.pin == profile.pin', 'true', 'navigation loses PIN boundary'],
  ['app/SourcesShared/RandomPickUIAccess.swift', 'current.isKids == profile.isKids', 'true', 'navigation loses Kids boundary'],
  ['app/SourcesShared/SourceListModel.swift', 'isSettled, pendingSignature == nil', 'isSettled', 'pending source rebuild still admitted'],
  ['app/SourcesShared/SourceListModel.swift', 'signature == currentPlaybackSignature(context: livePlaybackContext(pin: pin))', 'true', 'source epoch changed before coalescer'],
  ['app/SourcesShared/RandomPickPlayIntent.swift', 'if !requiresFullAccess { releasePendingEvidence() }', '', 'terminal intent retains pending parent capture'],
  ['app/SourcesShared/RandomPickPlayIntent.swift', 'eligibleEpisodes([video], now: Date()).contains(video)', 'eligibleEpisodes(current.videos ?? [], now: Date()).contains(video)', 'pending poll rebuilds whole episode inventory'],
  ['app/SourcesiOS/iOSDetailView.swift', 'randomEpisodeRoute?.intent?.invalidateMetadata(details)', '', 'queued metadata A-B-A revocation removed'],

  ['app/SourcesiOS/iOSRootView.swift', 'guard currentRandomLibraryItem(origin) != nil else { return }', '', 'stale Pick again'],
  ['app/SourcesTV/LibraryView.swift', 'randomLibrarySession.ticket == origin', 'true', 'old ticket borrowing'],
  ['app/SourcesiOS/iOSDetailView.swift', 'meta: currentMeta, video: current,\n            orderedEpisodes:', 'meta: currentMeta, video: CoreVideo(id: "old", title: nil, released: nil, overview: nil, thumbnail: nil, season: 1, episode: 9),\n            orderedEpisodes:', 'old record routing'],
  ['app/SourcesiOS/iOSDetailView.swift', 'seasonEpisodes: route.orderedEpisodes, autoPlayOnAppear:', 'seasonEpisodes: route.orderedEpisodes, initialTraktSessionID: initialTraktSessionID, autoPlayOnAppear:', 'offer inheritance'],
  ['app/SourcesTV/DetailView.swift', 'randomEpisodeRoute = nil', '// retained route', 'route not revoked'],
  ['app/SourcesiOS/iOSDetailView.swift', 'autoPlayOnAppear: route.autoPlay', 'autoPlayOnAppear: false', 'Play aliases Open'],
  ['app/SourcesTV/DetailView.swift', 'current.map(RandomPickPolicy.EpisodeSource.init) != source', 'false', 'metadata invalidation missing'],
  ['app/SourcesTV/DetailView.swift', 'if randomEpisodeRoute == nil { clearRandomEpisodePick() }', 'clearRandomEpisodePick()', 'playing destination teardown'],
  ['app/SourcesShared/RandomPickPolicy.swift', 'ticket == origin', 'true', 'policy ignores selected generation'],
  ['app/SourcesShared/RandomPickPolicy.swift', 'ownerIsCurrent && currentRecord == origin.record', 'ownerIsCurrent', 'policy ignores coordinates/record'],
  ['app/SourcesiOS/iOSRootView.swift', '.sheet(isPresented: randomLibraryPreviewPresented)', '.sheet(item: $randomLibraryPreview)', 'Pick again replaces presented sheet'],
  ['app/SourcesiOS/iOSRootView.swift', '.onValueChange(of: isActive) { active in if !active { clearRandomLibraryPick() } }', '', 'hidden mounted Library remains authorized'],
  ['app/SourcesShared/RandomPickUIAccess.swift', 'profiles.active == profile && target.stillOwnsCurrentContext(core: core)', 'target.stillOwnsCurrentContext(core: core)', 'changed Kids/PIN/roster fields'],
  ['app/SourcesShared/RandomPickUIAccess.swift', '!profiles.needsPicker && profiles.activeID', 'profiles.activeID', 'picker newly required'],
  ['app/SourcesiOS/iOSRootView.swift', 'access.matchesPublishedProfiles(incoming, pickedThisLaunch:', 'access.matchesPublishedProfiles(profiles.profiles, pickedThisLaunch:', 'willSet reads old roster'],
  ['app/SourcesiOS/iOSRootView.swift', 'guard randomLibraryPreview != nil, randomLibraryRoute == nil,', 'guard', 'iOS Library refresh tears down admitted destination'],
  ['app/SourcesTV/LibraryView.swift', 'guard randomLibraryPreview != nil, randomLibraryRoute == nil,', 'guard', 'TV Library refresh tears down admitted destination'],
  ['app/SourcesiOS/iOSDetailView.swift', 'guard randomEpisodePreview != nil, randomEpisodeRoute == nil,', 'guard', 'iOS metadata refresh tears down admitted destination'],
  ['app/SourcesTV/DetailView.swift', 'guard randomEpisodePreview != nil, randomEpisodeRoute == nil,', 'guard', 'TV metadata refresh tears down admitted destination'],
  ['app/SourcesTV/LibraryView.swift', 'RandomPickPolicy.libraryRecord(current) == ticket.record else { clearRandomLibraryPick(); return }', 'RandomPickPolicy.libraryRecord(current) == ticket.record else { return }', 'changed pending Library record stays authorized'],
];
for (const [file, before, after, label] of mutations) {
  need(sources[file].includes(before), 'mutation anchor missing ' + label);
  let caught = false;
  try { contracts({...sources, [file]: sources[file].replace(before, after)}); } catch { caught = true; }
  need(caught, 'negative mutation survived: ' + label);
}
console.log('RandomPick actual caller contracts PASS; ' + mutations.length + ' negative mutations rejected; four target source lists verified');
