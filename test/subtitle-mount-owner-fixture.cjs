// Extract actual coordinator, proof and retirement declarations into a synthetic host harness.
// Actual-source extraction for the maintained subtitle mount owner regression.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const [rootArg, outputArg] = process.argv.slice(2);
if (!rootArg || !outputArg || !path.isAbsolute(rootArg) || !path.isAbsolute(outputArg)) throw Error('absolute ROOT and OUTPUT required');
const root = fs.realpathSync(rootArg), buildRoot = fs.realpathSync(path.join(root, 'app/build'));
const buildRelative = path.relative(root, buildRoot);
if (!buildRelative || buildRelative === '..' || buildRelative.startsWith(`..${path.sep}`) || path.isAbsolute(buildRelative)) throw Error('real app/build escaped real repository root');
const output = path.resolve(outputArg);
if (fs.existsSync(output)) throw Error('output must be fresh');
const parent = fs.realpathSync(path.dirname(output)), parentRelative = path.relative(buildRoot, parent);
if (parentRelative === '..' || parentRelative.startsWith(`..${path.sep}`) || path.isAbsolute(parentRelative)) throw Error('output parent escaped real app/build');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const credential = read('app/SourcesShared/CredentialScope.swift');
const bridge = read('app/SourcesShared/CoreBridge.swift');
const facade = read('app/SourcesShared/VortxNativeCoreFacade.swift');
const legacy = read('app/SourcesShared/LegacyWatchOwnership.swift');
const epochAnchor = 'static func applicationEpochIsCurrent(_ expected: UUID) -> Bool {';
if (legacy.indexOf(epochAnchor) < 0 || legacy.indexOf(epochAnchor, legacy.indexOf(epochAnchor) + epochAnchor.length) >= 0) throw Error('actual application epoch predicate missing or ambiguous');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const inputs = Object.fromEntries([
  ['CredentialScope.swift', credential], ['CoreBridge.swift', bridge], ['VortxNativeCoreFacade.swift', facade], ['LegacyWatchOwnership.swift', legacy]
].map(([name, value]) => [name, sha(value)]));
const selections = {};
function once(source, marker) {
  const first = source.indexOf(marker);
  if (first < 0 || source.indexOf(marker, first + marker.length) >= 0) throw Error(`nonunique/missing anchor: ${marker}`);
  return first;
}
function section(source, begin, end) {
  const start = once(source, begin), finish = once(source, end);
  if (finish <= start) throw Error('reversed source anchors');
  const text = source.slice(start, finish); selections[begin] = sha(text); return text;
}
function enumBody(source, name) {
  const start = once(source, `enum ${name}:`), finish = source.indexOf('\n}\n', start);
  if (finish < 0) throw Error(`missing enum boundary: ${name}`);
  const text = source.slice(start, finish + 3); selections[name] = sha(text); return text;
}
const outbox = section(credential, 'enum CredentialPublicationOutbox {', '\n/// Shared transaction protocol');
const scope = section(credential, 'enum CredentialScope:', '\n/// Process-wide owner authority');
const registry = section(credential, 'final class CredentialScopeRegistry:', '\n/// Claim migration for a legacy global Keychain slot.');
const bridgeProof = section(bridge, '    struct NativeSubtitleOwnerProof:', '\n    @MainActor\n    func captureNativeSubtitleOwner');
const bridgeCapture = section(bridge, '    @MainActor\n    func captureNativeSubtitleOwner', '\n    private let nativePlaybackReadLifetime =');
const bridgeRetire = section(bridge, '    fileprivate final class NativePlaybackReadLifetime:', '\n    /// A read predicate only, never FIFO/mutation/checkpoint/metadata authority.');
const facadeProof = section(facade, '    struct NativeSubtitleOwnerProof:', '\n    private var sourceArchive: Data?');
const facadeLock = section(facade, 'final class VortxNativeFacadeLock:', '\n/// Original Bridge installation/request stamps');
const fifo = section(facade, '        let profileTransition = forceProfileTransition', '\n        // State intents are FIFO');
const originalTransitionTypes = 'let transitionTypes: Set<String> = ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"]';
once(facade, originalTransitionTypes);
const originalProfileTransition = 'let profileTransition = forceProfileTransition || ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"].contains(type)';
once(facade, originalProfileTransition);
for (const marker of ['let subtitleOwnerTransition = profileTransition || forceSubtitleOwnerTransition\n            || ["add_profile", "bind_sync_scope"].contains(type) || ownerOperation != nil', 'forceSubtitleOwnerTransition: true,']) once(facade, marker);
const drain = '            if let subtitleRetirement {\n                await CredentialPublicationOutbox.waitForSubtitleRetirement(subtitleRetirement)\n            }';
once(facade, drain);
once(facade, 'defer {\n                if let subtitleRetirement {\n                    CredentialPublicationOutbox.finishSubtitleRetirement(subtitleRetirement)');
if (facade.indexOf(drain) > once(facade, '                if let ownerOperation { try await ownerOperation() }')) throw Error('FIFO drain is ordered after owner operation');
const retire = 'let subtitleRetirement = CredentialPublicationOutbox.beginSubtitleRetirement(domain: nativeSubtitleDomain)';
if (bridge.split(retire).length - 1 !== 2) throw Error('expected exact two actual retirement sites');
once(bridge, 'let subtitle: CredentialPublicationOutbox.SubtitleRetirement');
if (bridge.split('nativePlaybackReadLifetime.retire()').length - 1 !== 7 || bridge.split('nativePlaybackReadLifetime.completeRetirement(').length - 1 !== 7) throw Error('expected exact seven Bridge retirement/after-unlock drains');
once(facade, 'lock.afterOutermostUnlock {\n            CredentialPublicationOutbox.drainSubtitleRenderers(retirement)');
once(facade, 'CredentialPublicationOutbox.drainSubtitleRenderers(subtitleRetirement)\n        session.revoke()');
const fixture = `import Foundation\nimport Darwin\nimport os\n
${facadeLock}
${enumBody(credential, 'CredentialMutationResult')}
${enumBody(credential, 'CredentialDurableReadResult')}
${enumBody(credential, 'CredentialPublicationOutboxState')}
${scope}
${registry}
${outbox}
struct FixtureBinding: Equatable, Sendable { let credential: CredentialScopeRegistry.Capture; let sessionGeneration: UUID; let profileID: UUID; let accountGeneration: UUID? }
enum PlaybackMutationTarget: Sendable { case native(FixtureBinding?) }
enum FixtureJSON: Equatable, Sendable { case string(String), object([String: FixtureJSON]); subscript(_ key: String) -> FixtureJSON? { if case let .object(value) = self { return value[key] }; return nil } }
final class CoreBridge {
 private let nativeFacadeLock = NSLock()
 private let nativePlaybackReadLifetime = NativePlaybackReadLifetime()
 private var nativeSubtitleDomain: UUID { nativePlaybackReadLifetime.subtitleDomain }
 private var nativeFacadeStorage: VortxNativeCoreFacade?
 private var binding: FixtureBinding?
 private func currentNativePlaybackBinding() -> FixtureBinding? { binding }
${bridgeProof}
${bridgeCapture}
${bridgeRetire}
 @MainActor static func fixture() -> (CoreBridge, PlaybackMutationTarget, VortxNativeCoreFacade, UUID) {
  guard let applicationEpoch = LegacyWatchOwnership.captureApplicationEpoch() else { fatalError("initial application epoch unavailable") }
  let core = CoreBridge(), capture = CredentialScopeRegistry.shared.capture()
  let facade = VortxNativeCoreFacade(capture: capture)
  let binding = FixtureBinding(credential: capture, sessionGeneration: UUID(), profileID: facade.profileID, accountGeneration: facade.accountEpoch)
  core.binding = binding; core.nativeFacadeStorage = facade; return (core, .native(binding), facade, applicationEpoch)
 }
 @MainActor func retireActualBridgeLifetime() { let retirement = nativeFacadeLock.withLock { nativePlaybackReadLifetime.retire() }; nativePlaybackReadLifetime.completeRetirement(retirement) }
 @MainActor func fixtureBridgeLock() -> NSLock { nativeFacadeLock }
}
final class VortxNativeCoreFacade {
 struct Scope { let account: String }; struct Session { let scope: Scope }
 let lock = VortxNativeFacadeLock(); let sourceID = UUID(), profileID = UUID()
 var accountEpoch = UUID(), watchlistProfileGeneration = UUID()
 var closed = false, checkpointReopenRequired = false, pendingProfileTransitions = 0
 var values: [String: FixtureJSON] = [:]; let session: Session
 init(capture: CredentialScopeRegistry.Capture) {
  session = Session(scope: Scope(account: capture.namespace))
  values["native_state"] = .object(["activeProfileId": .string(profileID.uuidString)])
 }
${facadeProof}
 func fixtureRetireForUncertainty() { lock.withLock { _ = retireSubtitleOwnerAfterSynchronousChangeLocked() } }
 var fixtureLockIsUnheld: @Sendable () -> Bool { let original = lock; return { original.fixtureIsUnheld } }
}
extension VortxNativeFacadeLock {
 var fixtureIsUnheld: Bool { storage.withLock { $0.depth == 0 } }
}
extension CredentialPublicationOutbox {
 static func fixtureDrainWaiterCount() -> Int {
  coordination.condition.lock(); defer { coordination.condition.unlock() }
  return coordination.subtitleDrainWaiters.values.reduce(0) { $0 + $1.count }
 }
 static func fixtureBoundaryWaiterCount() -> Int {
  coordination.condition.lock(); defer { coordination.condition.unlock() }
  return coordination.boundaryWaiters.count
 }
}
`;
fs.mkdirSync(output);
const generated = [['ActualSubtitleOwnerFixture.swift', fixture], ['ActualLegacyWatchOwnership.swift', legacy], ['ActualFIFOAdmission.swift.txt', fifo]];
for (const [name, contents] of generated) fs.writeFileSync(path.join(output, name), contents, { flag: 'wx' });
const outputs = Object.fromEntries(generated.map(([name, contents]) => [name, sha(contents)]));
fs.writeFileSync(path.join(output, 'extraction.json'), JSON.stringify({ schema: 1, status: 'READY', inputs, selections, outputs, runtime: 'UNRUN', fullFacadeFIFOComposition: 'UNRUN', fifo: 'source-order assertion only' }, null, 2) + '\n', { flag: 'wx' });
console.log(`Extracted actual-source fixture under ${output}`);
