'use strict';

// V3 SUCCESSOR: reject inline comment/attribute tokens before boundary acceptance.
// Frozen v1/v2 remain unchanged.
// PROPOSAL ONLY, UNRUN. The runner must call this with its already captured
// production bytes and its already captured extractDeclaration helper. This
// module neither opens source nor runs a parser/compiler/process.
//
// This intentionally FAILS until the finite 00 production cut is placed. It
// never patches a production method into a fixture-only implementation.
function metadataDispatchPeer(core, profiles, facade, extractDeclaration) {
    const declarations = [];
    // This is a deliberately narrow source contract, not a Swift parser.
    // Current selected declarations are unannotated except the dispatch
    // signature's explicitly included @discardableResult. Reject any other
    // prefix instead of dropping inline/comment-separated/multiline attributes.
    function supportedPrefix(text, start, label) {
        const lineStart = text.lastIndexOf('\n', start - 1) + 1;
        if (text.slice(lineStart, start).trim() !== '')
            throw new Error('Unsupported inline declaration/nominal prefix: ' + label);
        const lines = text.slice(0, lineStart).split(/\r?\n/);
        for (let index = lines.length - 1; index >= 0; index--) {
            const prior = lines[index].trim();
            if (!prior || prior.startsWith('//')) continue;
            if (prior.includes('/*') || prior.includes('*/') || prior.includes('//') || prior.includes('@'))
                throw new Error('Unsupported comment/attribute declaration prefix: ' + label);
            if (prior.endsWith('}')
                || /^(?:(?:private|fileprivate|internal|public|static|nonisolated)\s+)*(?:let|var)\s+[A-Za-z_]/.test(prior)
                || /^import\s+[A-Za-z_]/.test(prior)) return;
            throw new Error('Unsupported leading declaration/nominal prefix: ' + label);
        }
    }
    function exact(owner, text, signature) {
        const bytes = extractDeclaration(text, signature);
        supportedPrefix(text, text.indexOf(signature), signature);
        declarations.push({ owner, signature, bytes });
        return bytes;
    }
    function line(text) {
        const matches = core.split(/\r?\n/).filter(value => value === text);
        if (matches.length !== 1) throw new Error('Missing/ambiguous exact Bridge storage: ' + text);
        supportedPrefix(core, core.indexOf(text), text);
        declarations.push({ owner: 'app/SourcesShared/CoreBridge.swift', signature: text, bytes: matches[0] });
        return matches[0];
    }
    const owner = 'app/SourcesShared/CoreBridge.swift';
    const dispatch = exact(owner, core,
        '    @discardableResult\n    func dispatch(action: [String: Any], field: String? = nil, beforeDispatch: (() -> Void)? = nil) -> Bool {');
    for (const required of ['let isMetadataNavigation = field == "meta_details"',
        'let originalCredential = CredentialScopeRegistry.shared.capture()',
        'let originalProfile = ProfileSelectionRead.snapshot()?.activeID',
        'let admission = captureNativeMetadataDispatchAdmission()',
        'nativeMetaRequestScope = .init(credential: originalCredential, profileID: originalProfile)',
        'admissionFence: nativeMetadataAdmissionFence, original: original)',
        'nativeMetadataAdmissionFence.replaceRequest(request)',
        'facade.metadataSelectionIsCurrent(selection)',
        'if topLevelAction == "Unload", field == nil {']) {
        if (!dispatch.includes(required)) throw new Error('Actual dispatch prerequisite not placed: ' + required);
    }
    if (dispatch.includes('ProfileStore.shared') || dispatch.includes('requestedMetaLoadTarget = MetaLoadTarget('))
        throw new Error('Unclosed real ProfileStore dependency/dead metadata tracking remains; no fake ProfileStore fallback');
    if ((dispatch.match(/beforeDispatch\?\(\)/g) || []).length !== 2)
        throw new Error('Actual metadata/generic hook frontier changed; review extraction');
    const nominal = 'final class CoreBridge: ObservableObject {';
    const nominalStart = core.indexOf(nominal);
    if (nominalStart < 0 || core.indexOf(nominal, nominalStart + nominal.length) >= 0)
        throw new Error('Actual Bridge nominal changed/ambiguous; review the storage-peer boundary');
    const nominalEnd = core.indexOf('\n', nominalStart);
    if (core.slice(nominalStart, nominalEnd < 0 ? core.length : nominalEnd).replace(/\r$/, '') !== nominal)
        throw new Error('Actual Bridge nominal line changed; review the storage-peer boundary');
    supportedPrefix(core, nominalStart, nominal);
    // The WHOLE actual Facade remains a real compiler input. These reads only
    // require/record its real scalar primitive and cancellation-safe join; they
    // are not emitted a second time or replaced with test implementations.
    exact('app/SourcesShared/VortxNativeCoreFacade.swift', facade,
        'final class VortxNativeMetadataAdmissionFence: Sendable {');
    const begin = exact('app/SourcesShared/VortxNativeCoreFacade.swift', facade,
        '    private func begin(_ field: String, replacingSelection: Bool = true) -> UUID? {');
    if (!begin.includes('lock.afterOutermostUnlock { previous.cancel() }')
        || !facade.includes('lock.afterOutermostUnlock { task.cancel() }')
        || !facade.includes('admissionFence.withCurrent(original)'))
        throw new Error('Real fenced insertion/deferred cancellation not placed; no fixture fallback');

    const storage = [
        '    private let nativeFacadeLock = NSLock()',
        '    private let nativeMetadataAdmissionFence = VortxNativeMetadataAdmissionFence()',
        '    private var nativeFacadeStorage: VortxNativeCoreFacade?',
        '    private var nativeCredentialCapture: CredentialScopeRegistry.Capture?',
        '    private var nativeInstallGeneration = UUID()',
        '    private var nativePublishedAccountGeneration: UUID?',
        '    private let metaLoadTargetLock = NSLock()',
        '    private var requestedMetaLoadTarget: MetaLoadTarget?',
        '    private var nativeMetaRequestAction: Data?',
        '    private var nativeMetaRequestGeneration = UUID()',
        '    private var nativeMetaRequestScope: NativeResourceIntentScope?',
        '    private var signedOutRepairRequest: SignedOutRepairRequest?'
    ].map(line);
    const members = [
        '    private var nativeFacade: VortxNativeCoreFacade?',
        '    private struct NativeResourceIntentScope: Equatable {',
        '    struct NativeWatchlistTarget {',
        '    private func captureNativeWatchlistTarget()',
        '    func nativeWatchlistTargetIsCurrent(',
        '    struct NativeNavigationTarget {',
        '    func captureNativeNavigationTarget()',
        '    private struct NativeMetadataDispatchAdmission {',
        '    private func captureNativeMetadataDispatchAdmission()',
        '    private func nativeMetadataDispatchAdmissionIsCurrent(',
        '    private struct PublicationToken: Equatable {',
        '    private struct SignedOutRepairRequest: Equatable {',
        '    private var enginePublicationBlocked: Bool {',
        '    private var logoutAccountMutationPending: Bool {',
        '    private static func actionName('
    ].map(signature => exact(owner, core, signature));
    const mirror = exact('app/SourcesShared/Profiles.swift', profiles, 'enum ProfileSelectionRead {');

    // Only this shell and the following fixture-access methods are synthetic.
    // Every decision method, property body, mirror and carrier above remains
    // byte-for-byte exact. No ObservableObject/@Published/app initializer, real
    // ProfileStore, Manager, installer, account service or UI receiver is copied.
    const shell = `
// RAM storage peer, NOT the actual CoreBridge class/initializer/lifecycle.
final class CoreBridge {
${storage.join('\n')}
${members.join('\n\n')}
${dispatch}

    struct FixtureRequest: Sendable {
        let target: MetaLoadTarget?
        let action: Data?
        let generation: UUID
        let credential: CredentialScopeRegistry.Capture?
        let profileID: UUID?
    }
    func fixtureInstall(_ facade: VortxNativeCoreFacade?, capture: CredentialScopeRegistry.Capture,
                        publishedAccount: UUID?) {
        nativeFacadeLock.withLock {
            nativeMetadataAdmissionFence.retireInstallation()
            nativeFacadeStorage = facade
            nativeCredentialCapture = capture
            nativeInstallGeneration = UUID()
            nativePublishedAccountGeneration = publishedAccount
        }
    }
    func fixtureRequest() -> FixtureRequest {
        metaLoadTargetLock.withLock {
            .init(target: requestedMetaLoadTarget, action: nativeMetaRequestAction,
                  generation: nativeMetaRequestGeneration, credential: nativeMetaRequestScope?.credential,
                  profileID: nativeMetaRequestScope?.profileID)
        }
    }
    func fixtureSetLogoutPending(_ pending: Bool) {
        signedOutRepairRequest = pending
            ? .init(generation: 0, publicationToken: .init(epoch: 0), rearmSessionRepair: false) : nil
    }
    func fixtureBridgeLockProbe() -> @Sendable () -> Bool {
        let lock = nativeFacadeLock
        return {
            guard lock.try() else { return false }
            lock.unlock()
            return true
        }
    }
    struct FixtureInsertion: Sendable {
        let facade: VortxNativeCoreFacade
        let navigation: VortxNativeCoreFacade.AcceptedNavigationReceipt
        let stamp: VortxNativeMetadataAdmissionFence.Stamp
    }
    func fixturePrecheckedInsertion() -> FixtureInsertion? {
        guard let admission = captureNativeMetadataDispatchAdmission(),
              nativeMetadataDispatchAdmissionIsCurrent(admission) else { return nil }
        let request = metaLoadTargetLock.withLock { nativeMetaRequestGeneration }
        return .init(facade: admission.navigation.owner.facade, navigation: admission.receipt,
                     stamp: .init(installation: admission.installation, request: request))
    }
    func fixtureInsert(_ action: VortxJSON, original: FixtureInsertion)
        -> VortxNativeCoreFacade.MetadataSelectionReceipt? {
        original.facade.dispatchMetadata(action, expected: original.navigation,
            admissionFence: nativeMetadataAdmissionFence, original: original.stamp)
    }
    func fixtureAdmissionFence() -> VortxNativeMetadataAdmissionFence { nativeMetadataAdmissionFence }
}
`;
    return { source: 'import Foundation\nimport os\n\n' + mirror + '\n\n' + shell,
        declarations, declarationTransformations: [],
        shellOnly: ['CoreBridge nominal shell and exact RAM storage declarations',
            'fixtureInstall/fixtureRequest/fixtureSetLogoutPending/fixtureBridgeLockProbe',
            'fixturePrecheckedInsertion/fixtureInsert/fixtureAdmissionFence boundary access',
            'FixtureRequest/FixtureInsertion observation values'],
        excluded: ['CoreBridge ObservableObject conformance/initializer/lifecycle',
            'ProfileStore', 'Manager', 'UI receiver/presentation', 'engine symbols or SDK fabrication'] };
}

module.exports = { metadataDispatchPeer };
