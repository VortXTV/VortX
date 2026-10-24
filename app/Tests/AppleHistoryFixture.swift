// Fixture-only original-source plumbing for the genuine Facade/Session SDK lane.
// Compiled in Combined.swift alongside exact production history/context/coarse
// methods and origin/lifetime guards. No SourceEvent initializer is accessible:
// source envelopes below come ONLY from actual Facade.create(sourceEvent:).
extension CoreBridge {
    @MainActor private final class HistoryFixtureReceiver {
        private weak var core: CoreBridge?
        init(core: CoreBridge) { self.core = core }
        func receive(_ receipt: VortxNativeCoreFacade.ChangeReceipt, fields: [String],
                     origin: NativeCallbackOrigin, coarse: Bool) {
            core?.publishHistoryForFixture(receipt, fields: fields, origin: origin, coarse: coarse)
        }
    }
    @MainActor func makeHistorySourceCallbackForFixture()
        -> @Sendable (VortxNativeCoreFacade.SourceEvent) -> Void {
        let installation = nativeCallbackGeneration
        let credential = CredentialScopeRegistry.shared.capture()
        let epoch = publicationEpochState, player = playerActiveSnapshotState
        let lifetime = nativeCallbackLifetime
        let receiver = HistoryFixtureReceiver(core: self)
        lifetime.prepare(installation)
        return { event in
            guard case .changed(let fields, let receipt?) = event.kind,
                  event.sourceID == receipt.sourceID,
                  event.sourceID == event.producer.sourceID,
                  CredentialScopeRegistry.shared.isCurrent(credential),
                  lifetime.accepts(installation, credential: credential, sourceID: event.sourceID) else { return }
            let origin = NativeCallbackOrigin(producer: event.producer, installation: installation,
                credential: credential, publication: epoch.withLock { PublicationToken(epoch: $0) },
                playerWasActive: player.withLock { $0 })
            Task { @MainActor in receiver.receive(receipt, fields: fields, origin: origin, coarse: true) }
        }
    }
    @MainActor func installHistoryFacadeForFixture(_ facade: VortxNativeCoreFacade) {
        let capture = CredentialScopeRegistry.shared.capture()
        nativeFacadeLock.withLock {
            nativeFacadeStorage = facade; nativeCredentialCapture = capture
            nativeCallbackLifetime.bind(nativeCallbackGeneration, credential: capture, sourceID: facade.sourceID)
        }
    }
    // Explicit HOST initiation used by the existing late-publication test. This
    // does not construct a SourceEvent or relabel a rejected callback as current.
    @MainActor func handleHistoryFields(_ fields: [String]) {
        guard let facade = nativeFacade, let credential = nativeCredentialCapture,
              let receipt = facade.captureHostChange(fields: fields) else { return }
        let origin = NativeCallbackOrigin(producer: facade, installation: nativeCallbackGeneration,
            credential: credential, publication: capturePublicationToken(), playerWasActive: playerActiveSnapshot())
        let receiver = HistoryFixtureReceiver(core: self)
        Task { @MainActor in receiver.receive(receipt, fields: fields, origin: origin, coarse: false) }
    }
    @MainActor private func publishHistoryForFixture(_ receipt: VortxNativeCoreFacade.ChangeReceipt,
        fields: [String], origin: NativeCallbackOrigin, coarse: Bool) {
        guard nativeCallbackOriginIsCurrent(origin), receipt.sourceID == origin.producer.sourceID else { return }
        let admitted = Set(fields).filter { nativeLegacyReceiptIsCurrent(receipt, origin: origin, field: $0) }
        // RAM fixture decode/generation plumbing only; NOT the actual05 worker,
        // metadata phase, source callback receiver or broad UI preparation path.
        let library = admitted.contains("library") ? try? receipt.values["library"]?.decode(CoreLibrary.self) : nil
        let preview = try? receipt.values["continue_watching_preview"]?.decode(CoreCWPreview.self)
        var generation: Int?
        if admitted.contains("continue_watching_preview") || (admitted.contains("library") && !origin.playerWasActive) {
            continueWatchingRebuildLock.lock()
            continueWatchingRebuildGeneration &+= 1; generation = continueWatchingRebuildGeneration
            continueWatchingRebuildLock.unlock()
        }
        if admitted.contains("ctx"), let context = try? receipt.values["ctx"]?.decode(CoreCtx.self) {
            var raw: [String: VortxJSON] = [:]
            for descriptor in receipt.values["ctx"]?["profile"]?["addons"]?.array ?? [] {
                if case .string(let url) = descriptor["transportUrl"] { raw[url] = descriptor }
            }
            publishNativeLegacyContext(context, rawAddons: raw, receipt: receipt, origin: origin)
        }
        publishNativeLegacyHistory(library: library, continueWatching: preview,
            fields: Set(admitted), receipt: receipt, origin: origin, cwGeneration: generation)
        if coarse {
            recordNativeLegacyCoarseEvent(legacyFields: fields, receipt: receipt,
                origin: origin, admittedFields: Set(admitted))
        }
    }
}
