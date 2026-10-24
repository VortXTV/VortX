// Actual-source contracts for the bridge, facade and Random phase split. Negative controls are
// in-memory mutations; this script never changes source or starts a native session.
const fs = require('node:fs');
const root = process.argv[2];
const sources = Object.fromEntries(Object.entries({
  bridge: 'CoreBridge.swift', facade: 'VortxNativeCoreFacade.swift',
  access: 'RandomPickUIAccess.swift', intent: 'RandomPickPlayIntent.swift'
}).map(([key, path]) => [key, fs.readFileSync(root + '/app/SourcesShared/' + path, 'utf8')]));
function need(ok, message) { if (!ok) throw Error(message); }
function full(text, anchor) {
  const first = text.indexOf(anchor), open = text.indexOf('{', first);
  need(first >= 0 && open >= 0, 'missing source block: ' + anchor);
  let depth = 1, end = open + 1;
  for (; depth && end < text.length; end++) { if (text[end] === '{') depth++; if (text[end] === '}') depth--; }
  need(!depth, 'unbalanced source block: ' + anchor);
  return text.slice(first, end);
}
function has(text, tokens, label) { for (const token of tokens) need(text.includes(token), label + ': ' + token); }
function contract(s) {
  const capture = full(s.facade, 'func captureAcceptedNavigation(expected:');
  const current = full(s.facade, 'func acceptedNavigationIsCurrent(');
  has(capture, ['lock.withLock {', 'guard isAvailable, resourceRegistryValid,',
    'let owner = watchlistBinding, owner == expected', 'owner: owner, registry: .init(scope: session.scope, profileID: owner.profileID,',
    'generation: registryGeneration)'], 'atomic facade capture');
  has(current, ['lock.withLock {', 'guard isAvailable, resourceRegistryValid, let owner = watchlistBinding',
    'RegistryBinding(scope: session.scope, profileID: owner.profileID, generation: registryGeneration)',
    'return owner == receipt.owner && registry == receipt.registry'], 'atomic facade current');
  need(!/pendingProfileTransitions|registryBinding/.test(capture + current), 'accepted navigation must not depend on queue occupancy');
  has(full(s.facade, 'var isAvailable: Bool {'), ['!closed && !checkpointReopenRequired'], 'availability');
  has(full(s.facade, 'var watchlistBinding: WatchlistBinding? {'), ['lock.withLock {', '!closed',
    'values["native_state"]?["activeProfileId"]', 'scope: session.scope, profileID: profile, accountGeneration: accountEpoch,',
    'profileGeneration: watchlistProfileGeneration'], 'acknowledged owner');
  has(full(s.facade, 'var registryBinding: RegistryBinding? {'), ['pendingProfileTransitions == 0'], 'mutation fence unchanged');
  const queue = full(s.facade, 'private func enqueueMutation(');
  has(queue, ['["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"].contains(type)',
    'if profileTransition { pendingProfileTransitions += 1 }', 'tasks["native_state"] = Task',
    'let publication = try self.lock.withLock', 'if accountChanged { self.accountEpoch = UUID() }',
    'if accountChanged || self.values["native_state"]?["activeProfileId"] != state["activeProfileId"] {',
    'self.watchlistProfileGeneration = UUID()',
    'self.invalidateResourcePublications(); self.registryGeneration = UUID()'], 'real queue and acknowledgement producers');
  need(queue.indexOf('pendingProfileTransitions += 1') < queue.indexOf('tasks["native_state"] = Task'), 'busy interval is synchronous admission');
  has(full(s.facade, 'private func invalidateResourcePublications()'), ['resourceRegistryValid = false'], 'registry retirement');
  const bridgeCapture = full(s.bridge, '@MainActor func captureNativeAcceptedNavigationTarget()');
  has(bridgeCapture, ['guard let navigation = captureNativeNavigationTarget()', 'return nativeFacadeLock.withLock {',
    'guard acceptedNavigationOwnerIsCurrent(navigation)',
    'navigation.owner.facade.captureAcceptedNavigation(expected: navigation.owner.binding)'], 'bridge capture double check');
  need(bridgeCapture.indexOf('captureNativeNavigationTarget()') < bridgeCapture.indexOf('nativeFacadeLock.withLock'), 'no recursive NSLock capture');
  has(full(s.bridge, '@MainActor func nativeAcceptedNavigationTargetIsCurrent('), ['nativeFacadeLock.withLock {',
    'acceptedNavigationOwnerIsCurrent(target.navigation)',
    'target.navigation.owner.facade.acceptedNavigationIsCurrent(target.receipt)'], 'bridge current exact receipt');
  has(full(s.bridge, '@MainActor private func acceptedNavigationOwnerIsCurrent('), [
    'nativeFacadeStorage === captured.facade', 'nativeCredentialCapture == captured.owner.credential',
    'CredentialScopeRegistry.shared.isCurrent(captured.owner.credential)',
    'nativeInstallGeneration == captured.owner.sessionGeneration', 'ProfileStore.shared.activeID == captured.owner.profileID',
    'nativePublishedAccountGeneration == captured.binding.accountGeneration',
    'captured.owner.accountGeneration == captured.binding.accountGeneration'], 'bridge identity/credential/install/account fence');
  has(full(s.bridge, 'func installNativeSession('), ['let installGeneration = UUID()', 'nativeInstallGeneration = installGeneration'], 'install ABA producer');
  has(full(s.bridge, 'private func revokeNativeSession()'), ['nativeInstallGeneration = UUID()',
    'nativeFacadeStorage = nil; nativeCredentialCapture = nil', 'old?.close()'], 'session retirement producer');
  has(full(s.bridge, 'private func currentNativePlaybackBinding()'), ['facade.isAvailable, facade.registryBinding?.profileID == profile.uuidString'], 'pending mutation binding remains strict');
  const accessCapture = full(s.access, 'static func capture(');
  has(accessCapture, ['let target = PlaybackMutationTarget.capture(core: core)', 'core.captureNativeAcceptedNavigationTarget()',
    'profiles.active == profile', 'core.nativeAcceptedNavigationTargetIsCurrent(navigationTarget)'], 'initial full admission');
  need(accessCapture.split('target.stillOwnsCurrentContext(core: core)').length === 3, 'full target checked before and after navigation capture');
  has(full(s.access, 'func isCurrent('), ['!profiles.needsPicker', 'profiles.activeID == profile.id',
    'profiles.active == profile && target.stillOwnsCurrentContext(core: core)'], 'full pending access retained');
  const nav = full(s.access, 'func isNavigationCurrent(');
  has(nav, ['!profiles.needsPicker', 'profiles.activeID == profile.id', 'navigationProfileMatches(profiles.active)',
    'core.nativeAcceptedNavigationTargetIsCurrent(navigationTarget)'], 'accepted navigation access');
  need(!nav.includes('target.stillOwnsCurrentContext'), 'accepted navigation cannot depend on mutation busy gate');
  has(full(s.access, 'private func navigationProfileMatches('), ['current.pin == profile.pin', 'current.isKids == profile.isKids',
    'current.usesOwnAccount == profile.usesOwnAccount', 'current.isOwner == profile.isOwner',
    'current.email == profile.email', 'current.familyEdit == profile.familyEdit'], 'navigation security subset');
  has(full(s.intent, 'var requiresFullAccess: Bool {'), ['case .pending, .resolving: return true',
    'case .consumed, .revoked: return false'], 'phase split');
  has(full(s.intent, 'func routeIsCurrent('), ['requiresFullAccess ? access.isCurrent(profiles: profiles, core: core)',
    ': access.isNavigationCurrent(profiles: profiles, core: core)'], 'route phase split');
  has(full(s.intent, 'func isCurrent('), ['guard requiresFullAccess, access.isCurrent(profiles: profiles, core: core)'], 'pending intent remains strict');
  for (const anchor of ['func claim(', 'func accepts(', 'func consume(_ claim:']) {
    has(full(s.intent, anchor), ['isCurrent(core: core, profiles: profiles)'], 'final play admission remains strict');
  }
}
contract(sources);
const mutations = [
  ['facade', 'func captureAcceptedNavigation(expected:', 'owner == expected', 'true'],
  ['facade', 'func captureAcceptedNavigation(expected:', 'guard isAvailable, resourceRegistryValid,', 'guard isAvailable,'],
  ['facade', 'func acceptedNavigationIsCurrent(', 'guard isAvailable, resourceRegistryValid,', 'guard resourceRegistryValid,'],
  ['facade', 'func acceptedNavigationIsCurrent(', 'guard isAvailable, resourceRegistryValid,', 'guard isAvailable,'],
  ['facade', 'func acceptedNavigationIsCurrent(', 'owner == receipt.owner && registry == receipt.registry', 'owner == receipt.owner'],
  ['facade', 'func acceptedNavigationIsCurrent(', 'owner == receipt.owner && registry == receipt.registry', 'registry == receipt.registry'],
  ['facade', 'func acceptedNavigationIsCurrent(', 'guard isAvailable,', 'guard pendingProfileTransitions == 0, isAvailable,'],
  ['facade', 'var isAvailable: Bool {', '!closed && !checkpointReopenRequired', '!closed'],
  ['facade', 'var watchlistBinding: WatchlistBinding? {', 'profileGeneration: watchlistProfileGeneration', 'profileGeneration: UUID()'],
  ['facade', 'var registryBinding: RegistryBinding? {', 'pendingProfileTransitions == 0,', ''],
  ['facade', 'private func enqueueMutation(', 'if accountChanged { self.accountEpoch = UUID() }', ''],
  ['facade', 'private func enqueueMutation(', 'self.watchlistProfileGeneration = UUID()', ''],
  ['facade', 'private func enqueueMutation(', 'self.registryGeneration = UUID()', ''],
  ['facade', 'private func invalidateResourcePublications()', 'resourceRegistryValid = false', 'resourceRegistryValid = true'],
  ['bridge', '@MainActor func captureNativeAcceptedNavigationTarget()', 'acceptedNavigationOwnerIsCurrent(navigation)', 'true'],
  ['bridge', '@MainActor func nativeAcceptedNavigationTargetIsCurrent(', 'target.navigation.owner.facade.acceptedNavigationIsCurrent(target.receipt)', 'true'],
  ...['nativeFacadeStorage === captured.facade', 'nativeCredentialCapture == captured.owner.credential',
    'CredentialScopeRegistry.shared.isCurrent(captured.owner.credential)',
    'nativeInstallGeneration == captured.owner.sessionGeneration', 'ProfileStore.shared.activeID == captured.owner.profileID',
    'nativePublishedAccountGeneration == captured.binding.accountGeneration'].map(token =>
      ['bridge', '@MainActor private func acceptedNavigationOwnerIsCurrent(', token, 'true']),
  ['bridge', 'private func currentNativePlaybackBinding()', 'facade.registryBinding?.profileID == profile.uuidString', 'true'],
  ['access', 'static func capture(', 'target.stillOwnsCurrentContext(core: core)', 'true'],
  ['access', 'func isCurrent(', 'target.stillOwnsCurrentContext(core: core)', 'true'],
  ['access', 'func isNavigationCurrent(', 'core.nativeAcceptedNavigationTargetIsCurrent(navigationTarget)', 'target.stillOwnsCurrentContext(core: core)'],
  ['access', 'private func navigationProfileMatches(', 'current.pin == profile.pin', 'true'],
  ['intent', 'var requiresFullAccess: Bool {', 'case .pending, .resolving: return true', 'case .pending, .resolving: return false'],
  ['intent', 'func consume(_ claim:', 'isCurrent(core: core, profiles: profiles)', 'true']
];
for (const [key, anchor, from, to] of mutations) {
  const block = full(sources[key], anchor);
  need(block.includes(from), 'mutation target missing: ' + from);
  const altered = { ...sources, [key]: sources[key].replace(block, block.replace(from, to)) };
  let rejected = false;
  try { contract(altered); } catch { rejected = true; }
  need(rejected, 'negative control escaped: ' + from);
}
console.log('Random Pick navigation source contracts PASS; ' + mutations.length + ' negative controls rejected');
