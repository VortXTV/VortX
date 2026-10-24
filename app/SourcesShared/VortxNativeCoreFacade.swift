import Foundation
import Darwin
import os

/// Detail membership is independent of the Library screen's type/sort/watched filters. Build this value
/// once from the complete acknowledged projection, then overlay metadata without scanning history again.
struct VortxLibraryMembership: Sendable {
    private let savedByID: [String: VortxJSON]

    init(_ projected: [VortxJSON] = []) {
        var saved: [String: VortxJSON] = [:]
        for row in projected {
            guard row["previouslyWatched"] != .bool(true), case .string(let id) = row["_id"],
                  saved[id] == nil else { continue }
            saved[id] = row
        }
        savedByID = saved
    }

    func item(for id: String) -> VortxJSON? { savedByID[id] }
}

/// One recursive transaction boundary for both the facade and its FIFO admission helper.
/// Checked Sendable: both stored locks are immutable imported synchronization primitives;
/// every mutable owner/depth/queue value lives in the unfair lock's checked Sendable State.
final class VortxNativeFacadeLock: NSLocking, Sendable {
    private struct State: Sendable {
        var owner: UInt64?
        var depth = 0
        var pending: [@Sendable () -> Void] = []
    }
    private let underlying = NSRecursiveLock()
    private let storage = OSAllocatedUnfairLock(initialState: State())

    func lock() {
        underlying.lock()
        let thread = UInt64(pthread_mach_thread_np(pthread_self()))
        storage.withLock { state in
            precondition(state.owner == nil || state.owner == thread)
            state.owner = thread; state.depth += 1
        }
    }
    func unlock() {
        let thread = UInt64(pthread_mach_thread_np(pthread_self()))
        let ready = storage.withLock { state -> [@Sendable () -> Void] in
            precondition(state.owner == thread && state.depth > 0)
            state.depth -= 1
            guard state.depth == 0 else { return [] }
            state.owner = nil
            var ready: [@Sendable () -> Void] = []
            swap(&ready, &state.pending)
            return ready
        }
        underlying.unlock()
        // Swap retains the entire batch before releasing F. Neither queue reset nor an
        // element's final capture destruction can call external code while F is held.
        withExtendedLifetime(ready) {
            for delivery in ready { delivery() }
        }
    }
    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock(); defer { unlock() }
        return try operation()
    }
    func afterOutermostUnlock(_ delivery: @escaping @Sendable () -> Void) {
        withLock { storage.withLock { $0.pending.append(delivery) } }
    }
}

/// Original Bridge installation/request stamps checked in the same Facade transaction
/// as metadata insertion. Retiring either stamp never calls the Facade under this lock.
final class VortxNativeMetadataAdmissionFence: Sendable {
    struct Stamp: Sendable {
        let installation: UUID
        let request: UUID
    }
    private struct State: Sendable {
        var installation = UUID()
        var request = UUID()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func captureInstallation() -> UUID { state.withLock { $0.installation } }
    func retireInstallation() { state.withLock { $0.installation = UUID() } }
    func replaceRequest(_ request: UUID) { state.withLock { $0.request = request } }
    fileprivate func withCurrent<Result: Sendable>(_ stamp: Stamp,
        _ operation: @Sendable () -> Result) -> Result? {
        state.withLock { state in
            guard state.installation == stamp.installation, state.request == stamp.request else { return nil }
            // Only local metadata insertion runs here. Cancellation and callbacks
            // are staged until the outer Facade transaction has released both locks.
            return operation()
        }
    }
}

/// Compatibility entry point for CoreBridge's existing Load/Unload wire. It never initializes or
/// calls Stremio. Unsupported actions return false and record a non-sensitive diagnostic code.
/// Account migration/key acquisition remain explicit prerequisites to constructing the session.
final class VortxNativeCoreFacade: @unchecked Sendable {
    /// Immutable presentation input captured by the ORIGINAL publishing transaction.
    /// `fields` retains control markers; `values` never includes their private carriers.
    struct ChangeReceipt: Sendable {
        let sourceID: UUID
        let fields: [String]
        let values: [String: VortxJSON]
        let sequence: UInt64
        let accountGeneration: UUID
        let profileGeneration: UUID
        let registryGeneration: UUID
        let profileID: String
        /// Selection lifetime, preserved across range/page tasks for that same selection.
        let resources: [String: UUID]
        /// Last task that ACTUALLY published each retained resource value, not latest scheduled.
        let resourceValues: [String: UUID]
        fileprivate init(sourceID: UUID, fields: [String], values: [String: VortxJSON], sequence: UInt64,
                         accountGeneration: UUID, profileGeneration: UUID, registryGeneration: UUID,
                         profileID: String, resources: [String: UUID], resourceValues: [String: UUID]) {
            self.sourceID = sourceID; self.fields = fields; self.values = values; self.sequence = sequence
            self.accountGeneration = accountGeneration; self.profileGeneration = profileGeneration
            self.registryGeneration = registryGeneration; self.profileID = profileID
            self.resources = resources; self.resourceValues = resourceValues
        }
    }
    /// Original callback origin, captured before delivery or any executor hop.
    /// The source reference is historical identity, not fresh admission authority.
    struct SourceEvent: Sendable {
        enum Kind: Sendable {
            case changed(legacyFields: [String], receipt: ChangeReceipt?)
            case mutationAccepted
            case progressAccepted
        }
        let producer: VortxNativeCoreFacade
        let sourceID: UUID
        let kind: Kind
        fileprivate init(producer: VortxNativeCoreFacade, kind: Kind) {
            self.producer = producer
            self.sourceID = producer.sourceID
            self.kind = kind
        }
    }

    let sourceID = UUID()
    private static let presentationFields: Set<String> = ["ctx", "board", "search", "discover",
        "library", "meta_details", "local_search", "continue_watching_preview"]
    private var changeSequence: UInt64 = 0
    private var latestChangeSequence: [String: UInt64] = [:]
    private var resourceSelections: [String: UUID] = [:]
    private var resourceValueTasks: [String: UUID] = [:]
    struct RegistryBinding: Equatable, Sendable { let scope: VortxAccountScope; let profileID: String; let generation: UUID }
    struct WatchlistBinding: Equatable, Sendable {
        let scope: VortxAccountScope
        let profileID: String
        let accountGeneration: UUID
        let profileGeneration: UUID
    }
    private let session: VortxNativeSession
    private var registry: [VortxResourceAddon]
    private var registryGeneration = UUID()
    private var registrySnapshot: [VortxResourceAddon] { lock.withLock { registry } }
    // Dispatch admission is one synchronous transaction, including nested begin/enqueue helpers.
    // This prevents a profile change/rebind from slipping between a UI identity read and enqueue.
    private let lock: VortxNativeFacadeLock
    private let mutationFIFO: VortxNativeFIFOAdmission
    private var values: [String: VortxJSON] = [:]
    // Replaced with acknowledged state under lock, never with a filtered Library screen response.
    private var metadataLibraryMembership = VortxLibraryMembership()
    private var externalMetadataReceipts: [Data: (Data, UUID)] = [:]
    private var externalMetadataObservation = UUID()
    private var selections: [String: VortxJSON] = [:]
    private var generations: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var closed = false
    // A commit may have reached disk before readback failed. Keep the last acknowledged
    // projections readable, but only a new authenticated session may certify more writes.
    private var checkpointReopenRequired = false {
        willSet {
            if newValue && !checkpointReopenRequired { retireSubtitleOwnerAfterSynchronousChangeLocked() }
        }
    }
    // Installed only by private init, before exposure. Builders are pure local value capture;
    // the returned delivery, never the client callback, is invoked after the outermost F.
    private var sourceChangedDelivery: (@Sendable ([String], ChangeReceipt?) -> (@Sendable () -> Void)?)?
    private var sourceAcceptedDelivery: (@Sendable (Bool) -> (@Sendable () -> Void)?)?
    private let ownedChange: (@Sendable (ChangeReceipt) -> Void)?
    private let changed: @Sendable ([String]) -> Void
    private let mutationAccepted: @Sendable () -> Void
    /// Playback progress alone; nil keeps reporting it through `mutationAccepted`.
    private let progressAccepted: (@Sendable () -> Void)?
    private var failure: String?
    private var resourceRegistryValid = true
    // Full engine materialization: includes protected and profile-disabled members. Resource/UI
    // visibility is separate, and no host comparison of membership clocks is authoritative.
    private var addonInventories: [String: [VortxJSON]] = [:]
    /// Ephemeral acknowledgement of one submitted add-on operation. Kernel-normalized manifests
    /// cannot be compared with their wire input to confirm an update. Keep both privately, bound
    /// to the exact accepted owner/profile/registry and the latest attempted operation instead.
    private struct AddonConfirmation {
        let operation: UUID
        let account: UUID
        let profile: String
        let owner: String
        let registry: UUID
        let url: String
        let submittedManifest: VortxJSON
        let acceptedDescriptor: VortxJSON
    }
    private var addonOperation = UUID()
    private var addonConfirmation: AddonConfirmation?
    /// FIFO tasks are unstructured, so cancellation belongs to the original import operation.
    /// The latch linearizes cancellation with the final checkpoint, not merely queue admission.
    private final class ImportCommitAuthority: VortxMutationAuthority, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let source: any VortxMutationAuthority
        init(source: any VortxMutationAuthority) { self.source = source }
        func cancel() { lock.withLock { cancelled = true } }
        func withActive(_ operation: () throws -> Void) throws {
            try source.withActive {
                try lock.withLock {
                    guard !cancelled else { throw VortxNativeError.superseded }
                    try operation()
                }
            }
        }
    }
    private var pendingProfileTransitions = 0
    private var accountEpoch = UUID()
    private var watchlistProfileGeneration = UUID()
    struct NativeSubtitleOwnerProof: Equatable, Sendable {
        let bridge: CoreBridge.NativeSubtitleOwnerProof
        let profileGeneration: UUID
        fileprivate init(bridge: CoreBridge.NativeSubtitleOwnerProof, profileGeneration: UUID) {
            self.bridge = bridge; self.profileGeneration = profileGeneration
        }
    }
    /// Caller holds B. This joins the original Bridge installation to the actual acknowledged
    /// profile generation under F, then registers using only scalar condition bookkeeping.
    func captureNativeSubtitleOwner(_ original: CoreBridge.NativeSubtitleOwnerProof)
        -> CredentialPublicationOutbox.SubtitleMountOwner? {
        lock.withLock {
            guard !closed, !checkpointReopenRequired, pendingProfileTransitions == 0,
                  original.sourceID == sourceID, original.accountGeneration == accountEpoch,
                  values["native_state"]?["activeProfileId"] == .string(original.profileID.uuidString),
                  session.scope.account == original.credential.namespace else { return nil }
            return CredentialPublicationOutbox.registerSubtitleOwner(.init(bridge: original,
                profileGeneration: watchlistProfileGeneration))
        }
    }
    /// Caller owns F; records retirement synchronously before any owner field changes.
    /// Only scalar stamps enter the coordinator. Native work and its wakeups never need F.
    private func retireSubtitleOwnerAfterSynchronousChangeLocked() {
        let retirement = CredentialPublicationOutbox.beginSubtitleRetirement(domain: sourceID)
        Task {
            await CredentialPublicationOutbox.waitForSubtitleRetirement(retirement)
            CredentialPublicationOutbox.finishSubtitleRetirement(retirement)
        }
    }
    private var sourceArchive: Data?
    private var ownerHistoryActive = false
    private var ownerHistoryACKGeneration = UUID()
    var hasOwnerHistorySession: Bool { lock.withLock { ownerHistoryActive && !closed } }
    private struct HeldOwnerProgress {
        let raw: String
        let binding: WatchlistBinding
    }
    private var heldOwnerProgress: HeldOwnerProgress?
    private var lastOwnerProgressCommit: TimeInterval?
    var authenticatedSourceArchive: Data? { lock.withLock { sourceArchive } }
    func migrationDraft(isCurrent: @escaping @Sendable () -> Bool = { true },
        checkpoint: (@Sendable () async throws -> Void)? = nil) async throws -> Data? {
        try await session.migrationDraft(isCurrent: isCurrent, checkpoint: checkpoint)
    }
    func retainMigrationProgress(_ archive: Data, expected: Data?, authority: any VortxMutationAuthority) async throws {
        try await session.retainMigrationProgress(archive, expected: expected, authority: authority)
    }
    var accountGeneration: UUID { lock.withLock { accountEpoch } }
    /// Queued host/sync edits are busy work, not a new owner. Only acknowledged identity changes
    /// retire this fence; FIFO admission will recheck it after any preceding profile transaction.
    var watchlistBinding: WatchlistBinding? {
        lock.withLock {
            guard !closed, let profile = string(values["native_state"]?["activeProfileId"]) else { return nil }
            return .init(scope: session.scope, profileID: profile, accountGeneration: accountEpoch,
                         profileGeneration: watchlistProfileGeneration)
        }
    }
    func captureSourceFence() -> @Sendable () -> Bool {
        guard let captured = profileSnapshot() else { return { false } }
        let archive = authenticatedSourceArchive
        return { [weak self] in
            guard let current = self?.profileSnapshot() else { return false }
            return current.generation == captured.generation && current.pending == captured.pending && self?.authenticatedSourceArchive == archive
        }
    }
    private func accountIdentity(_ state: VortxJSON?) -> VortxJSON {
        var bindings: [String: VortxJSON] = [:]
        if case .object(let profiles) = state?["roster"]?["profiles"] {
            for (id, profile) in profiles {
                bindings[id] = state?["nativeSync"]?["accountSlots"]?[id]?["activeBinding"]
                    ?? .object(["account": profile["account"] ?? .null, "revision": .integer(0), "transactionId": .null])
            }
        }
        return .object(bindings)
    }
    private var playback: VortxJSON?
    private var libraryRequest: VortxJSON?
    var lastFailure: String? { lock.withLock { failure } }
    var isAvailable: Bool { lock.withLock { !closed && !checkpointReopenRequired } }
    var requiresCheckpointReopen: Bool { lock.withLock { !closed && checkpointReopenRequired } }
    func cachedResumeSeconds(id: String) -> Double? {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, let value = playback?["resumeById"]?[id] else { return nil }
            if value == .null { return 0 }
            guard let offset = try? value["offsetMs"]?.decode(UInt64.self) else { return nil }
            return Double(offset) / 1000
        }
    }
    func resumeSeconds(id: String, profileID: String, expectedAccountGeneration: UUID) async throws -> Double {
        let accepted = lock.withLock { !closed && accountEpoch == expectedAccountGeneration && pendingProfileTransitions == 0 && values["native_state"]?["activeProfileId"] == .string(profileID) }
        guard accepted else { throw VortxNativeError.superseded }
        let seconds = try await session.resumeSeconds(id: id, profileID: profileID)
        guard lock.withLock({ !closed && accountEpoch == expectedAccountGeneration && pendingProfileTransitions == 0 && values["native_state"]?["activeProfileId"] == .string(profileID) }) else { throw VortxNativeError.superseded }
        return seconds
    }
    func dispatchForProfile(_ action: VortxJSON, profileID: String, expectedAccountGeneration: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, values["native_state"]?["activeProfileId"] == .string(profileID),
              let type = string(action["type"]), ["report_progress", "mark_watched", "reset_watched", "remove_from_continue_watching"].contains(type),
              let bytes = try? JSONEncoder().encode(action) else { return fail("stale_profile_intent") }
        return enqueueMutation(type: type, raw: String(decoding: bytes, as: UTF8.self))
    }
    func dispatchCaptured(data: Data, field: String?, expectedAccountGeneration: UUID) -> Bool {
        lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration else { return false }
            return dispatch(data: data, field: field)
        }
    }
    enum CatalogPageAdmission: Equatable {
        case started(itemCount: Int, pageCount: Int)
        case busy, exhausted, rejected
    }
    /// Atomically distinguish a started page from an exhausted no-op. A Boolean dispatch result
    /// cannot tell the UI whether it should retain its latch, retry after settlement, or stop.
    func dispatchCatalogPage(field: String, index: Int) -> CatalogPageAdmission {
        lock.withLock {
            guard !closed, resourceRegistryValid, ["board", "search"].contains(field),
                  let rows = values[field]?["catalogs"]?.array, rows.indices.contains(index) else { return .rejected }
            guard pendingProfileTransitions == 0,
                  !rows.contains(where: { $0.array?.contains { $0["content"]?["type"] == .string("Loading") } == true }) else { return .busy }
            let pages = rows[index].array ?? []
            guard nextCatalogPage(pages) != nil else { return .exhausted }
            let action: VortxJSON = .object(["action": .string("CatalogsWithExtra"), "args": .object([
                "action": .string("LoadNextPage"), "args": .integer(Int64(index))])])
            guard let data = try? JSONEncoder().encode(action), dispatch(data: data, field: field) else { return .rejected }
            let itemCount = pages.reduce(0) { $0 + ($1["content"]?["content"]?.array?.count ?? 0) }
            return .started(itemCount: itemCount, pageCount: pages.count)
        }
    }

    static func create(session: VortxNativeSession, registry: [VortxResourceAddon],
                       mutationAccepted: @escaping @Sendable () -> Void = {},
                       progressAccepted: (@Sendable () -> Void)? = nil,
                       sourceEvent: (@Sendable (SourceEvent) -> Void)? = nil,
                       ownedChange: (@Sendable (ChangeReceipt) -> Void)? = nil,
                       changed: @escaping @Sendable ([String]) -> Void) async throws -> VortxNativeCoreFacade {
        guard Set(registry.map(\.id)).count == registry.count else { throw VortxNativeError.invalidResponse }
        let facade = VortxNativeCoreFacade(session: session, registry: registry, mutationAccepted: mutationAccepted,
                                           progressAccepted: progressAccepted, sourceEvent: sourceEvent,
                                           ownedChange: ownedChange, changed: changed)
        let addonSnapshot = try await session.addonSnapshot()
        let state = addonSnapshot.state
        facade.addonInventories = addonSnapshot.inventories
        facade.playback = try await session.playbackProjection()
        facade.values = try facade.stateFields(state)
        facade.values["native_host_preferences"] = try await session.hostPreferencesDocument()
        facade.values["native_own_overlay_pending"] = try await session.pendingOwnAccountOverlays()
        facade.sourceArchive = try await session.authenticatedSourceArchive()
        facade.ownerHistoryActive = await session.usesOwnerHistory()
        return facade
    }
    private init(session: VortxNativeSession, registry: [VortxResourceAddon], mutationAccepted: @escaping @Sendable () -> Void,
                 progressAccepted: (@Sendable () -> Void)?, sourceEvent: (@Sendable (SourceEvent) -> Void)?,
                 ownedChange: (@Sendable (ChangeReceipt) -> Void)?,
                 changed: @escaping @Sendable ([String]) -> Void) {
        let lock = VortxNativeFacadeLock()
        self.lock = lock; self.mutationFIFO = VortxNativeFIFOAdmission(lock: lock)
        self.session = session; self.registry = registry; self.changed = changed; self.mutationAccepted = mutationAccepted
        self.progressAccepted = progressAccepted; self.ownedChange = ownedChange
        if let sourceEvent {
            sourceChangedDelivery = { [weak self] fields, receipt in
                guard let self else { return nil }
                let event = SourceEvent(producer: self, kind: .changed(legacyFields: fields, receipt: receipt))
                return { sourceEvent(event) }
            }
            sourceAcceptedDelivery = { [weak self] progressOnly in
                guard let self else { return nil }
                let event = SourceEvent(producer: self, kind: progressOnly ? .progressAccepted : .mutationAccepted)
                return { sourceEvent(event) }
            }
        }
    }
    /// F is held by the publishing transaction. Host reads set recordingChanges=false;
    /// they never create a source callback or mark a retained value as freshly produced.
    private func makeChangeReceipt(_ fields: [String], recordingChanges: Bool = true) -> ChangeReceipt? {
        guard !closed, let profile = string(values["native_state"]?["activeProfileId"]) else { return nil }
        changeSequence += 1
        let fields = Array(Set(fields)).sorted()
        if recordingChanges { for field in fields { latestChangeSequence[field] = changeSequence } }
        return .init(sourceID: sourceID, fields: fields,
            values: values.filter { Self.presentationFields.contains($0.key) }, sequence: changeSequence,
            accountGeneration: accountEpoch, profileGeneration: watchlistProfileGeneration,
            registryGeneration: registryGeneration, profileID: profile,
            resources: resourceSelections, resourceValues: resourceValueTasks)
    }
    /// Delivery ONLY. Never read current values or mint a receipt here: FIFO ACK stages its
    /// already captured receipt at the original callback point after pending-profile release.
    private func stageChanged(_ legacyFields: [String], receipt: ChangeReceipt?) {
        guard receipt != nil || !legacyFields.isEmpty else { return }
        lock.withLock {
            let legacy = changed, owned = ownedChange
            let source = sourceChangedDelivery?(legacyFields, receipt)
            lock.afterOutermostUnlock {
                source?()
                if let receipt { owned?(receipt) }
                if !legacyFields.isEmpty { legacy(legacyFields) }
            }
        }
    }
    /// Stage at the existing ACK callback point, after changed delivery has returned.
    /// Do not add availability filtering: legacy ACK counts survive synchronous close/reentry.
    private func stageAccepted(progressOnly: Bool, legacy: @escaping @Sendable () -> Void) {
        lock.withLock {
            let source = sourceAcceptedDelivery?(progressOnly)
            lock.afterOutermostUnlock {
                source?()
                legacy()
            }
        }
    }
    /// Original HOST initiation snapshot, not a callback upgrade or resource/write admission.
    /// Last acknowledged cache remains readable during queued work/checkpoint uncertainty.
    func captureHostChange(fields: [String]) -> ChangeReceipt? {
        lock.withLock { makeChangeReceipt(fields, recordingChanges: false) }
    }
    /// Recheck immediately before the owning sink commits. Original Bridge installation,
    /// credential and Session authority remain separate; no Session lease is acquired under F.
    func acceptsChange(_ receipt: ChangeReceipt, field: String? = nil, settlingResource: Bool = false) -> Bool {
        lock.withLock {
            guard !closed, receipt.sourceID == sourceID, receipt.sequence > 0,
                  receipt.sequence <= changeSequence, receipt.accountGeneration == accountEpoch,
                  receipt.profileGeneration == watchlistProfileGeneration,
                  receipt.registryGeneration == registryGeneration,
                  values["native_state"]?["activeProfileId"] == .string(receipt.profileID) else { return false }
            guard let field else { return !settlingResource }
            guard Self.presentationFields.contains(field), values[field] != nil, receipt.values[field] != nil,
                  (latestChangeSequence[field] ?? 0) <= receipt.sequence,
                  receipt.resources[field] == resourceSelections[field] else { return false }
            if settlingResource {
                guard let producer = receipt.resourceValues[field], producer == generations[field] else { return false }
            }
            return true
        }
    }
    func ownsSession(_ candidate: VortxNativeSession) -> Bool { session === candidate }
    func stateData(_ field: String) -> Data? {
        // VortxJSON is a copy-on-write value. Encoding a large board under this shared lock
        // stalls main-thread profile/binding reads even when the encoder runs off-main.
        guard let value = lock.withLock({ closed ? nil : values[field] }) else { return nil }
        return try? JSONEncoder().encode(value)
    }
    /// Owned, copy-on-write playback value for an exact accepted account/profile generation.
    /// This is deliberately not a generic state getter: a body-time history read must not
    /// serialize the whole projection, nor cross a queued transition or profile/account ABA.
    func playbackSnapshot(expected: WatchlistBinding) -> VortxJSON? {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, expected.scope == session.scope,
                  expected.accountGeneration == accountEpoch,
                  expected.profileGeneration == watchlistProfileGeneration,
                  values["native_state"]?["activeProfileId"] == .string(expected.profileID) else { return nil }
            return values["native_playback"]
        }
    }
    func profileSnapshot() -> (state: VortxJSON, host: VortxJSON, pending: VortxJSON, generation: UUID)? {
        lock.withLock {
            guard !closed, let state = values["native_state"], let host = values["native_host_preferences"] else { return nil }
            return (state, host, values["native_own_overlay_pending"] ?? .object([:]), accountEpoch)
        }
    }
    @discardableResult
    func close() -> CredentialPublicationOutbox.SubtitleRetirement {
        let subtitleRetirement = CredentialPublicationOutbox.beginSubtitleRetirement(domain: sourceID)
        lock.lock(); closed = true; mutationFIFO.close(); let old = Array(tasks.values); tasks.removeAll(); generations.removeAll(); resourceSelections.removeAll(); resourceValueTasks.removeAll(); latestChangeSequence.removeAll(); values.removeAll(); metadataLibraryMembership = VortxLibraryMembership(); addonInventories.removeAll(); addonConfirmation = nil; addonOperation = UUID(); lock.unlock()
        session.revoke()
        old.forEach { $0.cancel() }
        Task {
            await CredentialPublicationOutbox.waitForSubtitleRetirement(subtitleRetirement)
            CredentialPublicationOutbox.finishSubtitleRetirement(subtitleRetirement)
            await session.close()
        }
        return subtitleRetirement
    }
    func shutdown() async {
        if lock.withLock({ ownerHistoryActive }) {
            await withCheckedContinuation { continuation in flushPendingProgress { continuation.resume() } }
        }
        let retirement = close()
        await CredentialPublicationOutbox.waitForSubtitleRetirement(retirement)
        await session.close()
    }
    var registryBinding: RegistryBinding? {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, let profile = string(values["native_state"]?["activeProfileId"]) else { return nil }
            return RegistryBinding(scope: session.scope, profileID: profile, generation: registryGeneration)
        }
    }
    /// Accepted navigation may survive ordinary queued sync work, but never an unavailable
    /// session or an acknowledged owner/resource replacement. No writes use this receipt.
    struct AcceptedNavigationReceipt: Equatable, Sendable {
        let owner: WatchlistBinding
        let registry: RegistryBinding
    }
    func captureAcceptedNavigation(expected: WatchlistBinding) -> AcceptedNavigationReceipt? {
        lock.withLock {
            guard isAvailable, resourceRegistryValid,
                  let owner = watchlistBinding, owner == expected else { return nil }
            return .init(owner: owner, registry: .init(scope: session.scope, profileID: owner.profileID,
                generation: registryGeneration))
        }
    }
    func acceptedNavigationIsCurrent(_ receipt: AcceptedNavigationReceipt) -> Bool {
        lock.withLock {
            guard isAvailable, resourceRegistryValid, let owner = watchlistBinding else { return false }
            let registry = RegistryBinding(scope: session.scope, profileID: owner.profileID, generation: registryGeneration)
            return owner == receipt.owner && registry == receipt.registry
        }
    }

    /// One admitted metadata selection, not a terminal/ready or persistence receipt.
    /// Its ticket is the existing resource-producing-task identity. An owner/registry
    /// ABA, different facade, explicit Unload/Load, rebind or close retires it.
    struct MetadataSelectionReceipt: Equatable, Sendable {
        let navigation: AcceptedNavigationReceipt
        fileprivate let facade: ObjectIdentifier
        fileprivate let ticket: UUID
        let selection: VortxJSON?
    }

    /// Only navigation of the metadata RESOURCE is allowed here. This receipt
    /// cannot authorize a native mutation, watched edit, token/auth or checkpoint.
    /// Check and insertion are in the SAME F transaction; the composed lock drains
    /// changed callbacks only after this method's outermost unlock. Call without B.
    func dispatchMetadata(_ action: VortxJSON,
                          expected: AcceptedNavigationReceipt) -> MetadataSelectionReceipt? {
        lock.lock(); defer { lock.unlock() }
        guard acceptedNavigationIsCurrent(expected), pendingProfileTransitions == 0 else { return nil }
        let name = string(action["action"])
        guard name == "Unload"
            || (name == "Load" && string(action["args"]?["model"]) == "MetaDetails") else { return nil }
        guard let data = try? JSONEncoder().encode(action),
              dispatch(data: data, field: "meta_details"),
              acceptedNavigationIsCurrent(expected), let ticket = generations["meta_details"] else { return nil }
        return .init(navigation: expected, facade: ObjectIdentifier(self), ticket: ticket,
                     selection: values["meta_details"]?["selected"])
    }

    func dispatchMetadata(_ action: VortxJSON, expected: AcceptedNavigationReceipt,
        admissionFence: VortxNativeMetadataAdmissionFence,
        original: VortxNativeMetadataAdmissionFence.Stamp) -> MetadataSelectionReceipt? {
        lock.lock(); defer { lock.unlock() }
        // F -> witness, never F -> Bridge/request locks. Recursive inner unlocks
        // cannot drain; the witness releases before this outer F drains callouts.
        return admissionFence.withCurrent(original) {
            dispatchMetadata(action, expected: expected)
        } ?? nil
    }

    /// Current-task check, not merely a matching title. In particular a same-title
    /// episode replacement has another ticket even if its selected metaPath matches.
    func metadataSelectionIsCurrent(_ receipt: MetadataSelectionReceipt) -> Bool {
        lock.withLock {
            receipt.facade == ObjectIdentifier(self)
                && acceptedNavigationIsCurrent(receipt.navigation)
                && generations["meta_details"] == receipt.ticket
                && values["meta_details"]?["selected"] == receipt.selection
        }
    }

    /// Join only ORIGINAL receipt values and their actual producing-task ticket.
    /// Settlement requires a metadata marker; retained library overlays do not settle a phase.
    /// A library caller must separately validate its original library marker/field sequence,
    /// then recheck this original selection at the sink. Neither path captures a newer task.
    func metadataSelection(for change: ChangeReceipt, expected: AcceptedNavigationReceipt,
                           settlingResource: Bool = true) -> MetadataSelectionReceipt? {
        lock.withLock {
            guard !settlingResource || change.fields.contains("meta_details"),
                  acceptsChange(change, field: "meta_details", settlingResource: settlingResource),
                  acceptedNavigationIsCurrent(expected),
                  let ticket = change.resourceValues["meta_details"],
                  let value = change.values["meta_details"] else { return nil }
            let selection = MetadataSelectionReceipt(navigation: expected,
                facade: ObjectIdentifier(self), ticket: ticket, selection: value["selected"])
            return metadataSelectionIsCurrent(selection) ? selection : nil
        }
    }

    /// Copy the immutable checked-Sendable value, not a UI model or Foundation Any
    /// graph. Consumer decoding is outside F; this API never admits a callback upgrade.
    /// A missing field is not an explicit null/unloaded receipt.
    func metadataSnapshot(expected receipt: MetadataSelectionReceipt) -> VortxJSON? {
        lock.withLock {
            guard metadataSelectionIsCurrent(receipt) else { return nil }
            return values["meta_details"]
        }
    }

    /// Linearize ONLY the already-prepared immutable presentation frame store
    /// with the ORIGINAL source sequence/producing task. The trusted nonescaping
    /// store performs a single eager plain reference swap; it sends nothing and
    /// releases no last old payload reference while F is held. Source owner and
    /// Bridge/M/proposal checks happen BEFORE entering here, never under F.
    ///
    /// Current first-party callers enter after actor admission, not from inside
    /// an existing F transaction. No F callbacks are staged by this read/store
    /// method. The changed/event notifications and subject fanout stay outside F.
    @MainActor
    func storeOriginalMetadataPresentationFrame(_ change: ChangeReceipt,
        selection: MetadataSelectionReceipt, libraryOverlay: Bool,
        storePreparedFrame: @MainActor () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard change.sourceID == sourceID,
              metadataSelectionIsCurrent(selection),
              let joined = metadataSelection(for: change, expected: selection.navigation,
                  settlingResource: !libraryOverlay),
              joined == selection else { return false }
        if libraryOverlay {
            guard change.fields.contains("library"),
                  acceptsChange(change, field: "library"),
                  acceptsChange(change, field: "meta_details", settlingResource: false) else { return false }
        } else {
            guard change.fields.contains("meta_details"),
                  acceptsChange(change, field: "meta_details", settlingResource: true) else { return false }
        }
        // SEALED CALL GRAPH REQUIREMENT: the only callee is the02b plain store,
        // whose new/old frame boxes and all sidecars were prepared outside F.
        storePreparedFrame()
        return true
    }

    /// Explicit HOST effects (a spinner/clear or independent selected-task
    /// contribution) carry their admitted selection, not a manufactured source
    /// receipt. Native bytes may have advanced within that SAME task; a different
    /// producing selection, registry, profile or source may not own this store.
    @MainActor
    func storeOriginalMetadataHostFrame(selection: MetadataSelectionReceipt,
        storePreparedFrame: @MainActor () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard metadataSelectionIsCurrent(selection) else { return false }
        storePreparedFrame() // exact same sealed plain-frame-only call graph
        return true
    }

    /// Capture the CURRENT original task for a HOST refresh, under the caller's
    /// original navigation receipt. Never use this to upgrade an admitted callback:
    /// changed callbacks must carry their producing receipt from Facade publication.
    func captureMetadataSelection(expected: AcceptedNavigationReceipt) -> MetadataSelectionReceipt? {
        lock.withLock {
            guard acceptedNavigationIsCurrent(expected), let ticket = generations["meta_details"] else { return nil }
            return .init(navigation: expected, facade: ObjectIdentifier(self), ticket: ticket,
                         selection: values["meta_details"]?["selected"])
        }
    }

    /// One atomic, active-profile resource inventory. Ordinary queued progress/sync work is not a
    /// new owner; acknowledged registry/profile/account changes (including ABA) retire this receipt.
    func captureEpisodeSourceRegistry() -> (data: Data, isCurrent: @Sendable () -> Bool)? {
        lock.withLock {
            guard !closed, resourceRegistryValid, let profile = string(values["native_state"]?["activeProfileId"]) else { return nil }
            let generation = registryGeneration, account = accountEpoch, selection = watchlistProfileGeneration
            let descriptors = registry.map { VortxJSON.object(["transportUrl": .string($0.transportUrl), "manifest": $0.manifest ?? .object([:])]) }
            guard let data = try? JSONEncoder().encode(VortxJSON.array(descriptors)) else { return nil }
            return (data, { [weak self] in
                guard let self else { return false }
                return self.lock.withLock {
                    !self.closed && self.resourceRegistryValid && self.registryGeneration == generation
                        && self.accountEpoch == account && self.watchlistProfileGeneration == selection
                        && self.string(self.values["native_state"]?["activeProfileId"]) == profile
                }
            })
        }
    }
    /// Caller-confirmed registry replacement is bound to the accepted account/profile generation.
    /// New loads stay rejected during replacement; all previous resource publications are revoked.
    func rebindRegistry(_ replacement: [VortxResourceAddon], expected: RegistryBinding) async throws {
        let admission = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard Set(replacement.map(\.id)).count == replacement.count, registryBinding == expected else { return (false, nil) }
            // A watched-card admission may already have passed its lock check and be waiting to
            // enter the session actor. Wait for that exact FIFO member before invalidating the
            // resource host; otherwise a rebind can land between the facade check and dispatch.
            let predecessor = tasks["native_state"]
            addonConfirmation = nil; addonOperation = UUID()
            invalidateResourcePublications(); return (true, predecessor)
        }
        guard admission.0 else { throw VortxNativeError.superseded }
        await admission.1?.value
        await session.invalidateResources()
        let addonSnapshot = try await session.addonSnapshot()
        let accepted = lock.withLock { () -> Bool in
            guard !closed, expected.scope == session.scope, expected.generation == registryGeneration,
                  values["native_state"]?["activeProfileId"] == .string(expected.profileID), values["native_state"] == addonSnapshot.state else { return false }
            addonInventories = addonSnapshot.inventories
            registry = replacement; resourceRegistryValid = true; registryGeneration = UUID()
            values["ctx"] = .object(["profile": .object(["addons": .array(replacement.map {
                .object(["transportUrl": .string($0.transportUrl), "manifest": $0.manifest ?? .object([:])])
            })])])
            stageChanged(["ctx"], receipt: makeChangeReceipt(["ctx"]))
            return true
        }
        guard accepted else { throw VortxNativeError.superseded }
    }
    /// Called under lock. Keep the durable-state publication, discard only prior resource ownership.
    private func invalidateResourcePublications() {
        externalMetadataReceipts.removeAll()
        addonInventories = [:]
        resourceRegistryValid = false
        for (field, task) in tasks where field != "native_state" { task.cancel() }
        generations = generations.filter { $0.key == "native_state" }
        resourceSelections.removeAll(); resourceValueTasks.removeAll()
        values = values.filter { ["native_state", "library"].contains($0.key) }; selections = [:]
    }
    private func resourceIdentity(_ state: VortxJSON?) -> VortxJSON {
        let active = string(state?["activeProfileId"]) ?? ""
        let profile = state?["roster"]?["profiles"]?[active]
        return .object(["active": .string(active), "binding": profile?["addons"] ?? .null,
                        "account": accountIdentity(state),
                        "settings": profile?["settings"] ?? .null, "parental": profile?["parental"] ?? .null,
                        "addons": state?["nativeSync"]?["addons"] ?? .null])
    }
    private func fail(_ code: String) -> Bool { lock.lock(); failure = code; lock.unlock(); return false }
    private func string(_ value: VortxJSON?) -> String? { if case .string(let text) = value { return text }; return nil }
    private func path(_ value: VortxJSON?) throws -> VortxResourceRequest {
        guard let value else { throw VortxNativeError.invalidResponse }; return try value.decode(VortxResourceRequest.self)
    }
    private func begin(_ field: String, replacingSelection: Bool = true) -> UUID? {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return nil }
        if replacingSelection || resourceSelections[field] == nil { resourceSelections[field] = UUID() }
        let ticket = UUID()
        let previous = tasks.removeValue(forKey: field)
        generations[field] = ticket; failure = nil
        if let previous { lock.afterOutermostUnlock { previous.cancel() } }
        return ticket
    }
    private func publish(_ fields: [String: VortxJSON], field: String, ticket: UUID) {
        lock.lock()
        guard !closed, generations[field] == ticket else { lock.unlock(); return }
        var changedFields: [String] = []
        var ownedFields: [String] = []
        fields.forEach {
            let projected = $0.key == "meta_details" ? metaWithPlayback($0.value, library: metadataLibraryMembership) : $0.value
            if values[$0.key] != projected { changedFields.append($0.key) }
            // The first accepted value of a NEW task must reach owned consumers even if
            // its bytes equal the prior task's value. Legacy value suppression is unchanged.
            if values[$0.key] != projected || resourceValueTasks[$0.key] != ticket { ownedFields.append($0.key) }
            values[$0.key] = projected
            resourceValueTasks[$0.key] = ticket
            if $0.key == "meta_details" { observeExternalMetadata(projected) }
        }
        stageChanged(changedFields.sorted(), receipt: ownedFields.isEmpty ? nil : makeChangeReceipt(ownedFields))
        lock.unlock()
    }
    private func enqueue(_ field: String, initial: VortxJSON? = nil, replacingSelection: Bool = true,
                         operation: @escaping @Sendable () async throws -> [String: VortxJSON]) -> Bool {
        enqueue(field, initial: initial, replacingSelection: replacingSelection) { _ in try await operation() }
    }
    private func enqueue(_ field: String, initial: VortxJSON? = nil, replacingSelection: Bool = true,
                         operation: @escaping @Sendable (@escaping @Sendable (VortxJSON) -> Void) async throws -> [String: VortxJSON]) -> Bool {
        guard let ticket = begin(field, replacingSelection: replacingSelection) else { return false }
        if let initial { publish([field: initial], field: field, ticket: ticket) }
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await operation { [weak self] value in
                    self?.publish([field: value], field: field, ticket: ticket)
                }
                try Task.checkCancellation(); self?.publish(result, field: field, ticket: ticket)
            }
            catch {
                guard let self else { return }
                let accepted = self.lock.withLock { () -> Bool in
                    guard self.generations[field] == ticket && !self.closed else { return false }
                    self.failure = "native_operation_failed"; return true
                }
                guard accepted else { return }
                let category = error is CancellationError ? "cancelled" : error is VortxNativeError ? VortxNativeError.diagnosticCode(error) : "transport_failed"
                let route = ["board", "search", "discover", "meta_details", "subtitles"].contains(field) ? field : "other"
                // Static categories only; provider URLs, headers, request paths and raw errors may
                // contain private account material and must never enter the diagnostic log.
                NSLog("[VortXNative] resource=%@ result=failed category=%@", route, category)
                self.publish([field: .object(["nativeError": .string("native_operation_failed"), "nativeErrorCategory": .string(category)])], field: field, ticket: ticket)
            }
        }
        lock.lock()
        if closed || generations[field] != ticket {
            lock.afterOutermostUnlock { task.cancel() }
        } else { tasks[field] = task }
        lock.unlock(); return true
    }
    private func enqueueMutation(type: String, raw: String, legacyMaterial: Data? = nil,
                                 actions: [String]? = nil, hostRemote: VortxJSON? = nil,
                                 hostEdits: [VortxNativeHostPreferences.Edit] = [],
                                 hostFieldCAS: VortxHostFieldCAS? = nil,
                                 checkpointValidator: (any VortxProspectiveCheckpointValidator)? = nil,
                                 legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]] = [:],
                                 admission: (@Sendable () throws -> Bool)? = nil,
                                 websiteEvents: [VortxJSON] = [], websiteAddonEvents: [VortxJSON] = [], websiteBaseline: VortxNativeProfileEditHost.Baselines = [:],
                                 sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil,
                                 fifoMember: VortxNativeFIFOAdmission.Member? = nil, forceProfileTransition: Bool = false,
                                 forceSubtitleOwnerTransition: Bool = false,
                                 forceProgress: Bool = false,
                                 ownerOperation: (@Sendable () async throws -> Void)? = nil,
                                 completion: (@Sendable (Result<VortxJSON, Error>) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return false }
        guard !checkpointReopenRequired else { return fail("checkpoint_uncertain_reopen_required") }
        if !forceProgress, !admitProgress(type: type, raw: raw), completion == nil { return true }
        if type == "report_progress", let held = heldOwnerProgress {
            let old = try? JSONDecoder().decode(VortxJSON.self, from: Data(held.raw.utf8))
            let next = try? JSONDecoder().decode(VortxJSON.self, from: Data(raw.utf8))
            if old?["metaId"] != next?["metaId"] || old?["videoId"] != next?["videoId"] {
                guard flushHeldOwnerProgress() else { return false }
            }
        }
        if ownerHistoryActive, type == "report_progress", !forceProgress,
           completion == nil, fifoMember == nil, sourceAuthority == nil,
           let binding = watchlistBinding, let last = lastOwnerProgressCommit,
           ProcessInfo.processInfo.systemUptime - last < VortxNativeSession.progressCommitInterval {
            heldOwnerProgress = HeldOwnerProgress(raw: raw, binding: binding)
            return true // retained intent only; no native mutation/publication/ACK
        }
        if type != "report_progress", !flushHeldOwnerProgress() { return false }
        let queueMember: VortxNativeFIFOAdmission.Member
        let mutationAuthority: (any VortxMutationAuthority)?
        do {
            if let fifoMember {
                mutationAuthority = try mutationFIFO.capturedAuthority(for: fifoMember)
                queueMember = fifoMember
            } else { queueMember = try mutationFIFO.admit(); mutationAuthority = sourceAuthority }
        } catch { return fail("native_fifo_unavailable") }
        if type == "report_progress" { heldOwnerProgress = nil }
        let predecessor = tasks["native_state"]
        let ticket = UUID(); generations["native_state"] = ticket
        let profileTransition = forceProfileTransition || ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"].contains(type)
        // Separate from pendingProfileTransitions: add/bind and typed owner-route work
        // can replace accepted ownership without changing the selected profile.
        let subtitleOwnerTransition = profileTransition || forceSubtitleOwnerTransition
            || ["add_profile", "bind_sync_scope"].contains(type) || ownerOperation != nil
            || legacyMaterial != nil || hostRemote != nil
            || !websiteEvents.isEmpty || !websiteAddonEvents.isEmpty
        let subtitleRetirement = subtitleOwnerTransition
            ? CredentialPublicationOutbox.beginSubtitleRetirement(domain: sourceID) : nil
        if profileTransition { pendingProfileTransitions += 1 }
        // State intents are FIFO, never latest-wins: dropping one would lose progress/profile edits.
        tasks["native_state"] = Task { [weak self] in
            await predecessor?.value
            if let subtitleRetirement {
                await CredentialPublicationOutbox.waitForSubtitleRetirement(subtitleRetirement)
            }
            defer {
                if let subtitleRetirement {
                    CredentialPublicationOutbox.finishSubtitleRetirement(subtitleRetirement)
                }
            }
            defer { queueMember.finish() }
            guard let self else { completion?(.failure(VortxNativeError.closed)); return }
            var transitionReleased = false
            defer { if profileTransition && !transitionReleased { self.lock.withLock { self.pendingProfileTransitions -= 1 } } }
            var durableCommitted = false
            do {
                try Task.checkCancellation()
                try queueMember.begin()
                if fifoMember != nil { try mutationAuthority?.withActive {} }
                // Resource-backed gestures may wait behind an add-on/profile mutation.  Their
                // metadata was accepted for an earlier registry generation, so revalidate at
                // the FIFO boundary rather than treating the pre-enqueue check as durable.
                guard try admission?() ?? true else {
                    _ = self.fail("stale_native_mutation")
                    completion?(.failure(VortxNativeError.superseded))
                    return
                }
                if let ownerOperation { try await ownerOperation() }
                else {
                    _ = try await session.dispatch(actions ?? [raw], now: UInt64(Date().timeIntervalSince1970), legacyMaterial: legacyMaterial,
                        hostRemote: hostRemote, hostEdits: hostEdits, legacyWatchlists: legacyWatchlists,
                        websiteEvents: websiteEvents, websiteAddonEvents: websiteAddonEvents, websiteBaseline: websiteBaseline,
                        sourceAuthority: mutationAuthority, authenticatedSourceArchive: authenticatedSourceArchive,
                        hostFieldCAS: hostFieldCAS, checkpointValidator: checkpointValidator,
                        fifoAuthority: queueMember.runningAuthority)
                }
                durableCommitted = true
                let addonSnapshot = try await session.addonSnapshot()
                let state = addonSnapshot.state
                let playback = try await session.playbackProjection()
                let host = try await session.hostPreferencesDocument()
                let website = try await session.websiteEditOutcome()
                let ownPending = try await session.pendingOwnAccountOverlays()
                let sourceArchive = try await session.authenticatedSourceArchive()
                let websiteChanged = (!websiteEvents.isEmpty || !websiteAddonEvents.isEmpty) && self.lock.withLock {
                    self.values["native_state"]?["nativeSync"] != state["nativeSync"] ||
                        self.values["native_host_preferences"] != host || self.values["native_website_edits"] != website
                }
                let resourceChanged = self.lock.withLock { self.resourceIdentity(self.values["native_state"]) != self.resourceIdentity(state) }
                // Only the native registry query determines installed membership/order. It also
                // resolves own/share-primary before new-profile resource loads can be admitted.
                let replacement = resourceChanged ? try? await session.resourceRegistry() : nil
                if resourceChanged { await session.invalidateResources() }
                let publication = try self.lock.withLock { () -> (fields: [String: VortxJSON], changed: [String], receipt: ChangeReceipt?)? in
                    guard !self.closed else { return nil }
                    // Compare against the acknowledged cache before a resource identity change
                    // clears it. Progress and unchanged sync reads must not synthesize ctx events.
                    let previousValues = self.values
                    let identityChanged = self.resourceIdentity(previousValues["native_state"]) != self.resourceIdentity(state)
                    let accountChanged = self.accountIdentity(self.values["native_state"]) != self.accountIdentity(state)
                    if accountChanged { self.accountEpoch = UUID() }
                    if accountChanged || self.values["native_state"]?["activeProfileId"] != state["activeProfileId"] {
                        self.watchlistProfileGeneration = UUID()
                    }
                    self.failure = nil
                    if ownerOperation != nil { self.ownerHistoryActive = true }
                    if self.ownerHistoryActive { self.ownerHistoryACKGeneration = UUID() }
                    if self.ownerHistoryActive, type == "report_progress" {
                        self.lastOwnerProgressCommit = ProcessInfo.processInfo.systemUptime
                    }
                    self.playback = playback
                    self.sourceArchive = sourceArchive
                    if identityChanged {
                        self.invalidateResourcePublications(); self.registryGeneration = UUID()
                        if let replacement { self.registry = replacement; self.resourceRegistryValid = true }
                        else { self.failure = "registry_unavailable" }
                    }
                    self.addonInventories = addonSnapshot.inventories
                    var fields = try self.stateFields(state)
                    fields["native_host_preferences"] = host
                    fields["native_website_edits"] = website
                    fields["native_own_overlay_pending"] = ownPending
                    var changedFields = Set(fields.compactMap { previousValues[$0.key] != $0.value ? $0.key : nil })
                    // Two profiles may have identical add-on descriptors but different resource
                    // ownership. Their identity transition still requires one fenced ctx event.
                    if identityChanged { changedFields.insert("ctx") }
                    fields.forEach { self.values[$0.key] = $0.value }
                    let changed = changedFields.sorted()
                    return (fields, changed, changed.isEmpty ? nil : self.makeChangeReceipt(changed))
                }
                // FIFO intents each publish their acknowledged state before the next task executes.
                // A later get_state must not hide the profile transition's accepted state.
                if profileTransition { self.lock.withLock { self.pendingProfileTransitions -= 1 }; transitionReleased = true }
                if let publication { self.stageChanged(publication.changed, receipt: publication.receipt) }
                guard publication != nil, let document = state["nativeSync"] else { throw VortxNativeError.closed }
                if ["report_progress", "mark_watched", "reset_watched"].contains(type) {
                    let count = playback["continueWatching"]?.array?.count ?? 0
                    let saved = publication?.fields["library"]?["catalog"]?.array?.count ?? 0
                    NSLog("[VortXNative] mutation=%@ result=acknowledged continueWatching=%ld savedLibrary=%ld", type, count, saved)
                }
                if type == "report_progress", hostEdits.isEmpty, !websiteChanged, let progressAccepted = self.progressAccepted {
                    self.stageAccepted(progressOnly: true, legacy: progressAccepted)
                } else if !["get_state", "merge_native_sync", "bind_sync_scope"].contains(type) || !hostEdits.isEmpty || websiteChanged {
                    self.stageAccepted(progressOnly: false, legacy: self.mutationAccepted)
                }
                completion?(.success(document))
            } catch VortxNativeError.checkpointUncertain {
                if ownerOperation != nil {
                    let owns = await session.usesOwnerHistory()
                    self.lock.withLock { self.ownerHistoryActive = owns }
                }
                self.lock.withLock { self.checkpointReopenRequired = true; self.mutationFIFO.markUncertain() }
                _ = self.fail("checkpoint_uncertain_reopen_required"); completion?(.failure(VortxNativeError.checkpointUncertain))
            } catch {
                if ownerOperation != nil || self.lock.withLock({ self.ownerHistoryActive }) {
                    let status = await session.ownerHistoryRouteStatus()
                    self.lock.withLock {
                        self.ownerHistoryActive = status.ownsHistory
                        if status.requiresAuthenticatedReopen {
                            self.checkpointReopenRequired = true
                            self.mutationFIFO.markUncertain()
                        }
                    }
                    if status.requiresAuthenticatedReopen {
                        _ = self.fail("checkpoint_uncertain_reopen_required")
                        completion?(.failure(VortxNativeError.checkpointUncertain))
                        return
                    }
                }
                if durableCommitted {
                    // The acknowledged snapshot exists, but its required projection failed. Do
                    // not relabel the previous/empty history as the successful new profile state.
                    self.close(); _ = self.fail("native_projection_unavailable_reopen_required")
                } else { _ = self.fail("native_mutation_failed") }
                completion?(.failure(error))
            }
        }
        return true
    }
    /// One playback tick reaches the engine through two lanes on Apple (the player's TimeChanged and the
    /// account save) as two identical report_progress mutations, and each mutation rewrites the whole sealed
    /// checkpoint. The second is dropped: same active profile and title (a movie's videoId equal to its metaId
    /// counts as none), within 3 s and 1.5 s of position of the last admitted report. Any other mutation, a
    /// different title or episode, or a real move still goes through. Caller holds `lock`.
    private struct ProgressAdmission {
        let profile: String, metaId: String, videoId: String?, positionMs: UInt64, at: TimeInterval
    }
    private var lastProgressAdmission: ProgressAdmission?
    private static let progressDuplicateWindow: TimeInterval = 3
    private static let progressDuplicateDistanceMs: UInt64 = 1_500
    private func admitProgress(type: String, raw: String) -> Bool {
        guard type == "report_progress",
              let action = try? JSONDecoder().decode(VortxJSON.self, from: Data(raw.utf8)),
              let metaId = string(action["metaId"]), let profile = string(values["native_state"]?["activeProfileId"]),
              let position = try? action["positionMs"]?.decode(UInt64.self) else {
            lastProgressAdmission = nil
            return true
        }
        let videoId = string(action["videoId"]).flatMap { $0 == metaId ? nil : $0 }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastProgressAdmission, last.profile == profile, last.metaId == metaId, last.videoId == videoId,
           now - last.at < Self.progressDuplicateWindow,
           (position > last.positionMs ? position - last.positionMs : last.positionMs - position) <= Self.progressDuplicateDistanceMs {
            return false
        }
        lastProgressAdmission = ProgressAdmission(profile: profile, metaId: metaId, videoId: videoId, positionMs: position, at: now)
        return true
    }
    /// Caller owns the existing Facade lock. Install on the SAME native_state FIFO before
    /// the following profile/control intent. Rejected/cancelled work never gets an ACK.
    private func flushHeldOwnerProgress() -> Bool {
        guard let held = heldOwnerProgress else { return true }
        heldOwnerProgress = nil
        let accepted = enqueueMutation(type: "report_progress", raw: held.raw,
            admission: { [weak self] in
                guard let self else { return false }
                return self.lock.withLock { self.watchlistBinding == held.binding }
            }, forceProgress: true)
        if !accepted { heldOwnerProgress = held }
        return accepted
    }
    /// Make progress the session held back durable now (player pause or close, app background or quit). It
    /// queues behind every mutation already admitted, and the next progress report is also written at once,
    /// so a save still on its way from the player is not held back either.
    func flushPendingProgress(completion: (@Sendable () -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !checkpointReopenRequired else { completion?(); return }
        guard flushHeldOwnerProgress() else { completion?(); return }
        lastOwnerProgressCommit = nil
        guard let queueMember = try? mutationFIFO.admit() else { completion?(); return }
        let predecessor = tasks["native_state"]
        tasks["native_state"] = Task { [weak self] in
            await predecessor?.value
            defer { queueMember.finish() }
            guard let self else { completion?(); return }
            do {
                try Task.checkCancellation()
                try queueMember.begin()
                try await self.session.flushPendingProgress()
            }
            catch VortxNativeError.checkpointUncertain {
                self.lock.withLock { self.checkpointReopenRequired = true; self.mutationFIFO.markUncertain() }
                _ = self.fail("checkpoint_uncertain_reopen_required")
            } catch {
                _ = self.fail("native_progress_flush_failed")
            }
            completion?()
        }
    }
    /// Resource-backed public actions need a durable result, unlike synchronous UI wires whose
    /// Bool only reports admission.  In particular, a registry may change while this intent is
    /// waiting behind another state mutation; report that rejection to the card caller.
    private func enqueueWatchedMutation(type: String, actions: [String], admission: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let admitted = enqueueMutation(type: type, raw: "", actions: actions, admission: admission, completion: { result in
                switch result {
                case .success: continuation.resume(returning: true)
                case .failure: continuation.resume(returning: false)
                }
            })
            if !admitted { continuation.resume(returning: false) }
        }
    }
    /// Merge the fresh authenticated remote carrier and export only the accepted CRDT document.
    /// This shares the exact FIFO with profile/progress intents; a stale read cannot overwrite a
    /// concurrent local change, and a failed merge/checkpoint never becomes an outgoing snapshot.
    func mergeSyncDocument(_ remote: VortxJSON?, legacyMaterial: Data? = nil) async throws -> VortxJSON {
        let action = remote.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
            ?? .object(["type": .string("get_state")])
        let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            if !enqueueMutation(type: remote == nil ? "get_state" : "merge_native_sync", raw: raw, legacyMaterial: legacyMaterial,
                                completion: { continuation.resume(with: $0) }) {
                continuation.resume(throwing: VortxNativeError.closed)
            }
        }
    }
    /// One durable transaction contains both private-kernel state and public host preferences.
    /// Its returned carrier is read only after the same FIFO's merge/checkpoint acknowledgement.
    func mergeAccountDocument(_ remote: VortxJSON?, hostRemote: VortxJSON?, legacyMaterial: Data?,
                              hostEdits: [VortxNativeHostPreferences.Edit] = [], websiteEvents: [VortxJSON] = [], websiteAddonEvents: [VortxJSON] = [],
                              legacyWatchlists: [UUID: [VortxNativeWatchlist.Entry]] = [:],
                              websiteBaseline: VortxNativeProfileEditHost.Baselines = [:],
                              sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil) async throws -> VortxJSON {
        let action = remote.map { VortxJSON.object(["type": .string("merge_native_sync"), "document": $0]) }
            ?? .object(["type": .string("get_state")])
        let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            if !enqueueMutation(type: remote == nil ? "get_state" : "merge_native_sync", raw: raw, legacyMaterial: legacyMaterial,
                                hostRemote: hostRemote, hostEdits: hostEdits, legacyWatchlists: legacyWatchlists, websiteEvents: websiteEvents, websiteAddonEvents: websiteAddonEvents, websiteBaseline: websiteBaseline,
                                sourceAuthority: sourceAuthority, authenticatedSourceArchive: authenticatedSourceArchive, completion: { [weak self] result in
                switch result {
                case .success(let native):
                    guard let self, let host = self.lock.withLock({ self.values["native_host_preferences"] }) else { continuation.resume(throwing: VortxNativeError.closed); return }
                    let website = self.lock.withLock { self.values["native_website_edits"] ?? .object([:]) }
                    continuation.resume(returning: .object(["nativeSync": native, "nativeHostPreferences": host, "profileEditResults": website]))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }) { continuation.resume(throwing: VortxNativeError.closed) }
        }
    }
    func mutateProfiles(_ actions: [VortxJSON], hostEdits: [VortxNativeHostPreferences.Edit], expectedProfileID: String, expectedAccountGeneration: UUID,
                        preferenceAdmission: (@Sendable (VortxJSON, VortxJSON) -> Bool)? = nil,
                        sourceAuthority: (any VortxMutationAuthority)? = nil, authenticatedSourceArchive: Data? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, values["native_state"]?["activeProfileId"] == .string(expectedProfileID),
                  actions.allSatisfy({ ["add_profile", "patch_profile", "delete_profile", "switch_profile", "rebind_profile_account"].contains(string($0["type"]) ?? "") }) else { continuation.resume(throwing: VortxNativeError.superseded); return }
            do {
                let raw = try actions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                let admission: (@Sendable () throws -> Bool)?
                if let preferenceAdmission {
                    admission = { [weak self] in
                        guard let self else { return false }
                        let context = self.lock.withLock { () -> (VortxJSON, VortxJSON)? in
                            guard !self.closed, self.accountEpoch == expectedAccountGeneration,
                                  let state = self.values["native_state"], state["activeProfileId"] == .string(expectedProfileID),
                                  let host = self.values["native_host_preferences"] else { return nil }
                            return (state, host)
                        }
                        guard let context else { return false }
                        // The acknowledged FIFO snapshot is immutable. Evaluate the composed
                        // Bridge/credential fence outside this lock to avoid lock-order inversion.
                        return preferenceAdmission(context.0, context.1)
                    }
                } else { admission = nil }
                if !enqueueMutation(type: "patch_profile", raw: "", actions: raw, hostEdits: hostEdits,
                                    admission: admission,
                                    sourceAuthority: sourceAuthority, authenticatedSourceArchive: authenticatedSourceArchive,
                                    completion: { result in continuation.resume(with: result.map { _ in () }) }) {
                    continuation.resume(throwing: VortxNativeError.closed)
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    func setWatchlist(_ entry: VortxNativeWatchlist.Entry, present: Bool, expected: WatchlistBinding) async throws -> Bool {
        guard let profile = UUID(uuidString: expected.profileID) else { throw VortxNativeError.invalidSnapshot }
        let field = try VortxNativeWatchlist.field(id: entry.id, type: entry.type)
        let value: VortxJSON = present ? try VortxNativeWatchlist.value(entry) : .null
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard watchlistBinding == expected else { continuation.resume(throwing: VortxNativeError.superseded); return }
            if !enqueueMutation(type: "edit_watchlist", raw: "", actions: [],
                hostEdits: [.init(profileID: expected.profileID, fields: [field: value])], admission: { [weak self] in
                    guard let self else { return false }
                    return try self.lock.withLock {
                        guard self.watchlistBinding == expected, let host = self.values["native_host_preferences"] else { return false }
                        let entries = try VortxNativeWatchlist.entries(host: host, profileID: profile)
                        if present, !entries.contains(where: { $0.id == entry.id && $0.type == entry.type }), entries.count >= VortxNativeWatchlist.displayCap {
                            throw VortxNativeWatchlist.Failure.capacity
                        }
                        return true
                    }
                }, completion: { [weak self] result in
                    do {
                        _ = try result.get()
                        guard let self else { throw VortxNativeError.closed }
                        let membership = try self.lock.withLock {
                            guard self.watchlistBinding == expected, let host = self.values["native_host_preferences"] else { throw VortxNativeError.superseded }
                            return try VortxNativeWatchlist.entries(host: host, profileID: profile).contains { $0.id == entry.id && $0.type == entry.type }
                        }
                        continuation.resume(returning: membership)
                    } catch { continuation.resume(throwing: error) }
                }) { continuation.resume(throwing: VortxNativeError.closed) }
        }
    }
    /// One `forYou.` profile field (interests or a smart collection). Same fence as `setWatchlist`:
    /// the edit lands only for the profile and account generation it was captured on, and the
    /// continuation resumes after the durable commit, not on admission.
    func setForYouField(_ field: String, value: VortxJSON, expected: WatchlistBinding) async throws {
        try VortxNativeHostPreferences.validateForYouField(field, value: value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            guard watchlistBinding == expected else { continuation.resume(throwing: VortxNativeError.superseded); return }
            if !enqueueMutation(type: "edit_for_you", raw: "", actions: [],
                hostEdits: [.init(profileID: expected.profileID, fields: [field: value])], admission: { [weak self] in
                    guard let self else { return false }
                    return self.lock.withLock { self.watchlistBinding == expected }
                }, completion: { result in continuation.resume(with: result.map { _ in () }) }) {
                continuation.resume(throwing: VortxNativeError.closed)
            }
        }
    }
    /// A synchronous UI admission receipt, not a durable-write acknowledgement. The native FIFO
    /// owns persistence and rejects stale profile gestures before resolving their effective bucket.
    func reorderAddonURLs(_ urls: [String], profileID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pendingProfileTransitions == 0,
              values["native_state"]?["activeProfileId"] == .string(profileID),
              let binding = values["native_state"]?["roster"]?["profiles"]?[profileID]?["addons"],
              [.string("own"), .string("share_primary")].contains(binding),
              urls.allSatisfy({ !$0.isEmpty }), Set(urls).count == urls.count else { return fail("stale_or_invalid_addon_order") }
        let bucket = binding == .string("share_primary") ? session.scope.ownerProfileID : profileID
        let action: VortxJSON = .object(["type": .string("reorder_addons"), "profileId": .string(bucket), "transportUrls": .array(urls.map(VortxJSON.string))])
        guard let data = try? JSONEncoder().encode(action) else { return false }
        return enqueueMutation(type: "reorder_addons", raw: String(decoding: data, as: UTF8.self))
    }
    /// Deliberate authenticated owner import. Keep every existing live member and its position,
    /// append new imported identities in source order, and commit the complete batch before success.
    /// Only this Facade's own durable add-on completion constructs this stage receipt.
    /// It authorizes deliberate post-own-ACK capture, never recovery from a rejected source.
    struct OwnerAddonImportReceipt: Sendable {
        fileprivate let facade: ObjectIdentifier
        fileprivate let binding: WatchlistBinding
        fileprivate let registry: RegistryBinding
        fileprivate let state: VortxJSON
        fileprivate init(facade: ObjectIdentifier, binding: WatchlistBinding, registry: RegistryBinding, state: VortxJSON) {
            self.facade = facade; self.binding = binding; self.registry = registry; self.state = state
        }
    }
    @discardableResult func importOwnerAddons(_ imported: [VortxJSON], expectedProfileID: String, expectedAccountGeneration: UUID,
                           sourceAuthority: any VortxMutationAuthority) async throws -> OwnerAddonImportReceipt {
        let operationAuthority = ImportCommitAuthority(source: sourceAuthority)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OwnerAddonImportReceipt, Error>) in
                lock.lock(); defer { lock.unlock() }
                let owner = session.scope.ownerProfileID
                guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0,
                      values["native_state"]?["activeProfileId"] == .string(expectedProfileID),
                      let state = values["native_state"], let current = installedAddonURLs(state: state, owner: owner) else {
                    continuation.resume(throwing: VortxNativeError.superseded); return
                }
                let capturedRegistry = registryGeneration
                do {
                    var order = current, identities = Set(current.compactMap(addonMemberKey)), seen = Set<String>()
                    var actions: [VortxJSON] = []
                    for addon in imported {
                        guard let descriptor = addonDescriptor(addon), let identity = addonMemberKey(descriptor.url), seen.insert(identity).inserted else {
                            throw VortxNativeError.invalidResponse
                        }
                        actions.append(.object(["type": .string("install_addon"), "profileId": .string(owner), "addon": addon]))
                        if identities.insert(identity).inserted { order.append(descriptor.url) }
                    }
                    if order != current {
                        actions.append(.object(["type": .string("reorder_addons"), "profileId": .string(owner), "transportUrls": .array(order.map(VortxJSON.string))]))
                    }
                    if actions.isEmpty { actions = [.object(["type": .string("get_state")])] }
                    let raw = try actions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                    guard enqueueMutation(type: "import_owner_addons", raw: "", actions: raw, admission: { [weak self] in
                        guard let self else { return false }
                        return self.lock.withLock {
                            !self.closed && self.accountEpoch == expectedAccountGeneration && self.pendingProfileTransitions == 0
                                && self.registryGeneration == capturedRegistry
                                && self.values["native_state"]?["activeProfileId"] == .string(expectedProfileID)
                        }
                    }, sourceAuthority: operationAuthority, completion: { [weak self] result in
                        do {
                            _ = try result.get()
                            guard let self else { throw VortxNativeError.closed }
                            let receipt = try self.lock.withLock { () throws -> OwnerAddonImportReceipt in
                                guard !self.closed, self.accountEpoch == expectedAccountGeneration,
                                      let binding = self.watchlistBinding, let registry = self.registryBinding,
                                      binding.profileID == expectedProfileID,
                                      let state = self.values["native_state"] else { throw VortxNativeError.superseded }
                                return OwnerAddonImportReceipt(facade: ObjectIdentifier(self),
                                    binding: binding, registry: registry, state: state)
                            }
                            continuation.resume(returning: receipt)
                        } catch { continuation.resume(throwing: error) }
                    }) else {
                        throw VortxNativeError.closed
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { operationAuthority.cancel() })
    }
    /// Apply a complete, already-resolved episode inventory in one kernel transaction.  Series
    /// actions deliberately contain only opaque IDs supplied by the current metadata response:
    /// a title-level mark would incorrectly claim future or unavailable episodes are watched.
    func setWatchedVideos(metaID: String, videoIDs: [String], name: String, type: String, poster: String?, watched: Bool,
                          profileID: String, expectedAccountGeneration: UUID,
                          completion: (@Sendable (Result<VortxJSON, Error>) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accountEpoch == expectedAccountGeneration else { return fail("stale_watched_account") }
        let uniqueIDs = Array(Set(videoIDs.filter { !$0.isEmpty })).sorted()
        guard !closed, pendingProfileTransitions == 0,
              values["native_state"]?["activeProfileId"] == .string(profileID), !uniqueIDs.isEmpty,
              let inventory = acceptedMetadataInventory(metaID: metaID, type: type),
              Set(uniqueIDs).isSubset(of: Set(inventory)) else {
            return fail("stale_or_empty_watched_inventory")
        }
        let generation = registryGeneration
        do {
            let actions = try uniqueIDs.map { videoID -> String in
                let action: VortxJSON = .object([
                    "type": .string(watched ? "mark_watched" : "reset_watched"),
                    "metaId": .string(metaID), "videoId": .string(videoID), "name": .string(name),
                    "metadata": .object(["type": .string(type), "poster": poster.map(VortxJSON.string) ?? .null]),
                ])
                return String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
            }
            return enqueueMutation(type: watched ? "mark_watched" : "reset_watched", raw: "", actions: actions,
                                   admission: { [weak self] in
                guard let self else { return false }
                return self.lock.withLock {
                    guard !self.closed, self.accountEpoch == expectedAccountGeneration, self.pendingProfileTransitions == 0,
                          self.resourceRegistryValid, self.registryGeneration == generation,
                          self.values["native_state"]?["activeProfileId"] == .string(profileID),
                          let current = self.acceptedMetadataInventory(metaID: metaID, type: type) else { return false }
                    return Set(uniqueIDs).isSubset(of: Set(current))
                }
            }, completion: completion)
        } catch { return fail("invalid_watched_inventory") }
    }
    /// Shares the exact metadata/registry fences with bulk watched intents, but reports durable
    /// rejection to a manual episode caller instead of treating FIFO admission as success.
    func setWatchedVideosAcknowledged(metaID: String, videoIDs: [String], name: String, type: String, poster: String?, watched: Bool,
                                      profileID: String, expectedAccountGeneration: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let admitted = setWatchedVideos(metaID: metaID, videoIDs: videoIDs, name: name, type: type, poster: poster,
                watched: watched, profileID: profileID, expectedAccountGeneration: expectedAccountGeneration,
                completion: { continuation.resume(with: $0.map { _ in () }) })
            if !admitted {
                continuation.resume(throwing: requiresCheckpointReopen ? VortxNativeError.checkpointUncertain : VortxNativeError.superseded)
            }
        }
    }
    /// Card actions may not have a resident detail page. Resolve their exact metadata through the
    /// native resource host without publishing into the navigation slot, then recheck the captured
    /// profile and registry generation before one atomic episode transaction is admitted.
    func resolveAndSetWatchedVideos(metaID: String, type: String, name: String, poster: String?, watched: Bool,
                                    profileID: String, expectedAccountGeneration: UUID, season: Int? = nil) async -> Bool {
        let captured: (UUID, [VortxResourceAddon])? = lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else { return nil }
            return (registryGeneration, registry)
        }
        guard let captured else { return fail("stale_watched_resolution") }
        // libraryMetadata owns a unique resource-host slot.  In particular, this must not use
        // loadMeta: that owns the visible meta_details slot and would cancel/clobber navigation.
        guard let meta = try? await session.libraryMetadata(id: metaID, type: type, profileID: profileID, addons: captured.1) else {
            return fail("watched_metadata_unavailable")
        }
        let ids = (meta["videos"]?.array ?? []).filter { season == nil || (try? $0["season"]?.decode(Int.self)) == season }.compactMap { string($0["id"]) }
        guard !ids.isEmpty else { return fail("watched_metadata_unavailable") }
        let actions: [String]? = lock.withLock {
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, registryGeneration == captured.0,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else {
                _ = fail("stale_watched_resolution"); return nil
            }
            do {
                return try Array(Set(ids)).sorted().map { videoID in
                    let action: VortxJSON = .object(["type": .string(watched ? "mark_watched" : "reset_watched"), "metaId": .string(metaID), "videoId": .string(videoID), "name": .string(name), "metadata": .object(["type": .string(type), "poster": poster.map(VortxJSON.string) ?? .null])])
                    return String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                }
            } catch { _ = fail("invalid_watched_inventory"); return nil }
        }
        guard let actions else { return false }
        return await enqueueWatchedMutation(type: watched ? "mark_watched" : "reset_watched", actions: actions,
                                            admission: { [weak self] in
            guard let self else { return false }
            return self.lock.withLock {
                !self.closed && self.accountEpoch == expectedAccountGeneration
                    && self.pendingProfileTransitions == 0 && self.resourceRegistryValid
                    && self.registryGeneration == captured.0
                    && self.values["native_state"]?["activeProfileId"] == .string(profileID)
            }
        })
    }
    /// Metadata comes only from the accepted native registry. The return value acknowledges the
    /// durable FIFO add, not merely HTTP success or UI dispatch. Legacy recovery may only confirm
    /// existing native membership; it cannot manufacture a new save over a native removal.
    func addCatalogItem(id: String, type: String, profileID: String, allowInsert: Bool, expectedAccountGeneration: UUID) async throws -> Bool {
        let captured = try lock.withLock { () -> (UUID, [VortxResourceAddon], Bool) in
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else { throw VortxNativeError.superseded }
            let saved = values["native_state"]?["libraries"]?[profileID]?["items"]?.array?.contains {
                $0["kind"] == .string("standard") && $0["id"] == .string(id) && $0["type"] == .string(type)
            } == true
            return (registryGeneration, registry, saved)
        }
        if captured.2 { return true }
        guard allowInsert else { return false }
        let meta = try await session.libraryMetadata(id: id, type: type, profileID: profileID, addons: captured.1)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard !closed, accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0, resourceRegistryValid, registryGeneration == captured.0,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else {
                continuation.resume(throwing: VortxNativeError.superseded); return
            }
            let item: VortxJSON = .object(["kind": .string("standard"), "id": .string(id), "type": .string(type),
                                           "name": meta["name"]!, "poster": meta["poster"] ?? .null])
            let action: VortxJSON = .object(["type": .string("add_library_item"), "profileId": .string(profileID), "item": item])
            do {
                let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                guard enqueueMutation(type: "add_library_item", raw: raw, completion: { result in continuation.resume(with: result.map { _ in true }) }) else {
                    continuation.resume(throwing: VortxNativeError.closed); return
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    /// A manual library gesture is complete only after its checkpoint and accepted projection.
    /// Bind the intent at both enqueue and execution so a queued profile switch cannot redirect it.
    func setLibraryMembership(id: String, type: String, name: String, poster: String?, present: Bool,
                              profileID: String, expectedAccountGeneration: UUID) async throws {
        guard !id.isEmpty, !type.isEmpty, !name.isEmpty else { throw VortxNativeError.invalidResponse }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            guard !closed else { continuation.resume(throwing: VortxNativeError.closed); return }
            guard !checkpointReopenRequired else { continuation.resume(throwing: VortxNativeError.checkpointUncertain); return }
            guard accountEpoch == expectedAccountGeneration, pendingProfileTransitions == 0,
                  values["native_state"]?["activeProfileId"] == .string(profileID) else {
                continuation.resume(throwing: VortxNativeError.superseded); return
            }
            let profileGeneration = watchlistProfileGeneration
            let action: VortxJSON = present
                ? .object(["type": .string("add_library_item"), "profileId": .string(profileID),
                           "item": .object(["kind": .string("standard"), "id": .string(id), "type": .string(type),
                                            "name": .string(name), "poster": poster.map(VortxJSON.string) ?? .null])])
                : .object(["type": .string("remove_library_item"), "profileId": .string(profileID),
                           "key": .string(type + ":" + id)])
            do {
                let raw = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                let accepted = enqueueMutation(type: present ? "add_library_item" : "remove_library_item", raw: raw,
                    admission: { [weak self] in
                        guard let self else { return false }
                        return self.lock.withLock {
                            !self.closed && !self.checkpointReopenRequired && self.accountEpoch == expectedAccountGeneration
                                && self.watchlistProfileGeneration == profileGeneration
                                && self.values["native_state"]?["activeProfileId"] == .string(profileID)
                        }
                    }, completion: { continuation.resume(with: $0.map { _ in () }) })
                if !accepted { continuation.resume(throwing: VortxNativeError.closed) }
            } catch { continuation.resume(throwing: error) }
        }
    }
    /// Profile admission waits for durable state FIFO work, never unrelated provider responses.
    func settleNativeMutations() async {
        let pending = lock.withLock { tasks["native_state"] }
        await pending?.value
    }
    /// Testing/integration receipt: waits for currently admitted operations, never launches UI/media.
    func settled() async {
        let pending = lock.withLock { Array(tasks.values) }
        for task in pending { await task.value }
    }

    func dispatch(data: Data, field: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        guard let action = try? JSONDecoder().decode(VortxJSON.self, from: data),
              let name = string(action["action"]) else { return fail("invalid_action") }
        let field = field ?? "ctx"
        if name == "Unload", ["board", "search", "discover", "meta_details", "subtitles", "player"].contains(field) {
            guard let ticket = begin(field) else { return false }
            _ = lock.withLock { selections.removeValue(forKey: field) }
            publish([field: .object(["selected": .null, "catalogs": .array([]), "metaItems": .array([]), "streams": .array([]), "metaStreams": .array([])])], field: field, ticket: ticket)
            return true
        }
        // Explicit native action admission. No authentication/session-token operation is translated.
        if name == "Vortx", let native = action["args"], let type = string(native["type"]),
           Self.nativeActions.contains(type), let encoded = try? JSONEncoder().encode(native) {
            let raw = String(decoding: encoded, as: UTF8.self)
            return enqueueMutation(type: type, raw: raw)
        }
        // UI translations below refer to the currently published profile/selection. While a queued
        // transition is unsettled, do not infer whether a gesture belongs to the old or new profile.
        if lock.withLock({ pendingProfileTransitions > 0 }) { return fail("profile_transition_pending") }
        if name == "Ctx", string(action["args"]?["action"]) == "LibraryItemMarkAsWatched",
           let id = string(action["args"]?["args"]?["id"]), case .bool(let watched) = action["args"]?["args"]?["is_watched"] {
            var intent: [String: VortxJSON] = ["type": .string(watched ? "mark_watched" : "reset_watched"), "metaId": .string(id)]
            if let video = action["args"]?["args"]?["videoId"] ?? action["args"]?["args"]?["video_id"] {
                guard string(video) != nil else { return fail("invalid_episode_identity") }; intent["videoId"] = video
            }
            let native: VortxJSON = .object(["action": .string("Vortx"), "args": .object(intent)])
            guard let bytes = try? JSONEncoder().encode(native) else { return false }; return dispatch(data: bytes, field: "native_state")
        }
        if name == "Ctx", let subaction = string(action["args"]?["action"]),
           ["InstallAddon", "InstallAddonLocal", "ReplaceAddon", "ReplaceAddonLocal", "UninstallAddon", "UninstallAddonLocal"].contains(subaction) {
            return dispatchAddonMutation(subaction: subaction, args: action["args"]?["args"])
        }
        if name == "Ctx", let subaction = string(action["args"]?["action"]), ["AddToLibrary", "RemoveFromLibrary"].contains(subaction) {
            let state = lock.withLock { values["native_state"] }
            guard let profile = string(state?["activeProfileId"]) else { return fail("missing_profile") }
            var native: [String: VortxJSON] = ["profileId": .string(profile)]
            if subaction == "AddToLibrary" {
                guard let meta = action["args"]?["args"], let id = string(meta["id"]), let type = string(meta["type"]), let title = string(meta["name"]) else { return fail("invalid_library_meta") }
                native["type"] = .string("add_library_item")
                native["item"] = .object(["kind": .string("standard"), "id": .string(id), "type": .string(type), "name": .string(title), "poster": meta["poster"] ?? .null])
            } else {
                guard let id = string(action["args"]?["args"]) else { return fail("invalid_library_id") }
                let matches = state?["libraries"]?[profile]?["items"]?.array?.filter { $0["id"] == .string(id) && $0["kind"] == .string("standard") } ?? []
                // A watched-only Library title is removed under its own watch type (the engine records it).
                let watchedType = matches.isEmpty ? VortxNativePreviouslyWatched.type(of: id, playback: lock.withLock { playback }) : nil
                guard let type = matches.count == 1 ? string(matches[0]["type"]) : watchedType else { return fail("ambiguous_library_id") }
                native["type"] = .string("remove_library_item"); native["key"] = .string(type + ":" + id)
            }
            guard let bytes = try? JSONEncoder().encode(VortxJSON.object(["action": .string("Vortx"), "args": .object(native)])) else { return false }
            return dispatch(data: bytes, field: "native_state")
        }
        if name == "MetaDetails", let subaction = string(action["args"]?["action"]), ["MarkAsWatched", "MarkVideoAsWatched"].contains(subaction) {
            let detail = lock.withLock { values["meta_details"] }
            guard let metaID = string(detail?["selected"]?["metaPath"]?["id"]) else { return fail("missing_meta_selection") }
            let arguments = action["args"]?["args"]
            let watched: VortxJSON? = subaction == "MarkAsWatched" ? arguments : arguments?.array?.last
            guard case .bool(let marked) = watched else { return fail("invalid_watched_intent") }
            var native: [String: VortxJSON] = ["type": .string(marked ? "mark_watched" : "reset_watched"), "metaId": .string(metaID)]
            if subaction == "MarkVideoAsWatched" {
                guard let video = string(arguments?.array?.first?["id"]) else { return fail("invalid_episode_identity") }; native["videoId"] = .string(video)
            }
            guard let bytes = try? JSONEncoder().encode(VortxJSON.object(native)) else { return false }
            return enqueueMutation(type: marked ? "mark_watched" : "reset_watched", raw: String(decoding: bytes, as: UTF8.self))
        }
        let model = string(action["args"]?["model"])
        if ["board", "search", "discover", "meta_details", "subtitles"].contains(field),
           !lock.withLock({ resourceRegistryValid }) { return fail("registry_rebind_required") }
        if name == "Load", model == "Player", field == "player", let selected = action["args"]?["args"],
           let meta = try? path(selected["metaRequest"]?["path"]), let stream = try? path(selected["streamRequest"]?["path"]),
           meta.resource == .meta, stream.resource == .stream, meta.type == stream.type,
           selected["stream"] != nil, lock.withLock({ resourceRegistryValid }) {
            guard let ticket = begin(field) else { return false }
            lock.withLock { selections[field] = selected }
            publish([field: .object(["selected": selected])], field: field, ticket: ticket)
            return true
        }
        if name == "Player", string(action["args"]?["action"]) == "TimeChanged", field == "player" {
            let selected = lock.withLock { selections["player"] }
            guard let metaID = string(selected?["metaRequest"]?["path"]?["id"]),
                  let videoID = string(selected?["streamRequest"]?["path"]?["id"]),
                  let time = try? action["args"]?["args"]?["time"]?.decode(UInt64.self),
                  let duration = try? action["args"]?["args"]?["duration"]?.decode(UInt64.self), duration > 0 else { return fail("invalid_player_progress") }
            guard let mediaType = selected?["metaRequest"]?["path"]?["type"] else { return fail("invalid_player_type") }
            let readyMeta = values["meta_details"]?["metaItems"]?.array?.compactMap { $0["content"]?["content"] }.first { $0["id"] == .string(metaID) }
            let native: VortxJSON = .object(["type": .string("report_progress"), "metaId": .string(metaID), "videoId": .string(videoID),
                                           "name": readyMeta?["name"] ?? .string(metaID), "positionMs": .unsigned(time), "durationMs": .unsigned(duration),
                                           "metadata": .object(["type": mediaType, "poster": readyMeta?["poster"] ?? .null])])
            guard let bytes = try? JSONEncoder().encode(native) else { return false }
            return enqueueMutation(type: "report_progress", raw: String(decoding: bytes, as: UTF8.self))
        }
        if name == "Load", model == "CatalogsWithExtra", ["board", "search"].contains(field) {
            guard let ticket = begin(field) else { return false }
            let selection = action["args"]?["args"] ?? .object([:])
            lock.withLock { selections[field] = selection }
            let extra = (try? selection["extra"]?.decode([[String]].self)) ?? []
            let loading = catalogRequests(extra: extra, type: string(selection["type"])).compactMap { try? loadingEntry($0.0, $0.1) }
            publish([field: .object(["selected": selection, "catalogs": .array(loading.map { .array([$0]) })])], field: field, ticket: ticket)
            return true
        }
        if name == "CatalogsWithExtra", string(action["args"]?["action"]) == "LoadRange", ["board", "search"].contains(field) {
            let selection = lock.withLock { selections[field] }
            guard let selection, let screen = VortxNativeSession.CatalogScreen(rawValue: field) else { return fail("missing_selection") }
            let extra = (try? selection["extra"]?.decode([[String]].self)) ?? []
            let catalogs = catalogRequests(extra: extra, type: string(selection["type"]))
            let start = (try? action["args"]?["args"]?["start"]?.decode(Int.self)) ?? 0
            let end = (try? action["args"]?["args"]?["end"]?.decode(Int.self)) ?? catalogs.count
            guard start >= 0, end >= start else { return fail("invalid_range") }
            let previous = values[field]
            guard let profile = string(values["native_state"]?["activeProfileId"]) else { return fail("missing_profile") }
            return enqueue(field, replacingSelection: false) { [self] publish in
                [field: try await session.loadCatalogs(screen, catalogs: catalogs, selection: selection,
                    range: start...end, previous: previous, expectedProfileID: profile, onUpdate: publish)]
            }
        }
        if name == "CatalogsWithExtra", string(action["args"]?["action"]) == "LoadNextPage", ["board", "search"].contains(field) {
            guard let index = try? action["args"]?["args"]?.decode(Int.self), index >= 0,
                  let rows = values[field]?["catalogs"]?.array, index < rows.count,
                  let screen = VortxNativeSession.CatalogScreen(rawValue: field) else { return fail("invalid_catalog_page") }
            // A page must not replace the range's screen ticket while other initial rows are
            // still loading. CoreBridge queues that intent and retries it once the range settles.
            guard !rows.contains(where: { $0.array?.contains { $0["content"]?["type"] == .string("Loading") } == true })
            else { return fail("catalog_range_loading") }
            guard let next = nextCatalogPage(rows[index].array ?? []) else { return true }
            guard let loading = try? loadingEntry(next.0, next.1) else { return fail("invalid_catalog_page") }
            var pendingRows = rows; pendingRows[index] = .array((rows[index].array ?? []) + [loading])
            let pending: VortxJSON = .object(["selected": values[field]?["selected"] ?? .null, "catalogs": .array(pendingRows)])
            return enqueue(field, initial: pending, replacingSelection: false) { [self] in
                [field: try await session.loadCatalog(screen, request: next.1, addons: [next.0], append: true)]
            }
        }
        if name == "Load", model == "MetaDetails", field == "meta_details" {
            guard let request = try? path(action["args"]?["args"]?["metaPath"]) else { return fail("invalid_meta_path") }
            let streamValue = action["args"]?["args"]?["streamPath"]
            let stream = streamValue == nil || streamValue == .null ? nil : try? path(streamValue)
            if streamValue != nil && streamValue != .null && stream == nil { return fail("invalid_stream_path") }
            let addons = registrySnapshot
            let loading: VortxJSON = .object([
                "selected": .object(["metaPath": (try? VortxResourceProjection.path(request)) ?? .null, "streamPath": (try? stream.map(VortxResourceProjection.path)) ?? .null]),
                "metaItems": .array(addons.compactMap { try? loadingEntry($0, request) }),
                "streams": .array(stream.map { path in addons.compactMap { try? loadingEntry($0, path) } } ?? []), "metaStreams": .array([])])
            guard let profile = string(values["native_state"]?["activeProfileId"]) else { return fail("missing_profile") }
            // Dispatch owns the lock: capture the preceding value and acknowledged owner together.
            // A queued sync is not a new owner; committed identity changes retire these generations
            // and the enqueue publication ticket, including profile/account/registry A -> B -> A.
            let previous = values[field], account = accountEpoch
            let profileGeneration = watchlistProfileGeneration, capturedRegistry = registryGeneration
            let project: @Sendable (VortxJSON) -> VortxJSON = { [weak self] incoming in
                guard let self else { return incoming }
                return self.lock.withLock {
                    let current = !self.closed && self.resourceRegistryValid
                        && self.accountEpoch == account && self.watchlistProfileGeneration == profileGeneration
                        && self.registryGeneration == capturedRegistry
                        && self.values["native_state"]?["activeProfileId"] == .string(profile)
                    return VortxMetaLoadingProjection.retainingReadyMetadata(previous: previous,
                        incoming: incoming, ownerIsCurrent: current)
                }
            }
            return enqueue(field, initial: project(loading)) { [self] publish in
                let result = try await session.loadMeta(request: request, stream: stream, addons: addons,
                    expectedProfileID: profile, onUpdate: { value in publish(project(value)) })
                return [field: project(result)]
            }
        }
        if name == "Load", model == "CatalogWithFilters", field == "discover" {
            let supplied = action["args"]?["args"]?["request"]
            let requests = catalogRequests(extra: [], type: nil)
            let chosen: (VortxResourceAddon, VortxResourceRequest)?
            if let supplied, let request = try? path(supplied["path"]), let addon = registrySnapshot.first(where: { .string($0.transportUrl) == supplied["base"] }), validCatalogRequest(request, addon: addon) { chosen = (addon, request) }
            else if supplied == nil { chosen = requests.first } else { return fail("invalid_catalog_request") }
            guard let chosen else {
                guard let ticket = begin(field) else { return false }
                publish([field: .object(["catalog": .array([]), "selectable": .object([
                    "types": .array([]), "catalogs": .array([]), "extra": .array([]), "next_page": .null])])], field: field, ticket: ticket)
                return true
            }
            let previous = values[field]?["catalog"]?.array ?? []
            let retryPage = supplied != nil && supplied == values[field]?["retryRequest"]
                && chosen.1.extra.contains { $0.first == "skip" }
                && previous.first?["request"] != supplied
            return enqueueDiscover(chosen: chosen, requests: requests, append: retryPage)
        }
        if name == "CatalogWithFilters", string(action["args"]?["action"]) == "LoadNextPage", field == "discover" {
            guard let pages = values[field]?["catalog"]?.array else { return fail("missing_selection") }
            guard let next = nextCatalogPage(pages) else { return true }
            return enqueueDiscover(chosen: next, requests: catalogRequests(extra: [], type: nil), append: true)
        }
        if name == "Load", model == "LibraryWithFilters", field == "library" {
            let request = action["args"]?["args"]?["request"]
            guard let state = values["native_state"], let value = libraryProjection(state: state, request: request),
                  let ticket = begin(field) else { return fail("unsupported_library_filter") }
            libraryRequest = request
            publish([field: value], field: field, ticket: ticket); return true
        }
        if name == "Load", model == "LocalSearch", field == "local_search" {
            guard let ticket = begin(field) else { return false }
            publish([field: .object(["searchResults": .array([])])], field: field, ticket: ticket); return true
        }
        if name == "Search", field == "local_search" {
            guard let query = string(action["args"]?["searchQuery"]),
                  let maxResults = try? action["args"]?["maxResults"]?.decode(Int.self), (1...100).contains(maxResults),
                  let state = values["native_state"], let projection = localSearchProjection(state: state, query: query, maxResults: maxResults),
                  let ticket = begin(field) else { return fail("invalid_local_search_request") }
            publish([field: projection], field: field, ticket: ticket); return true
        }
        if name == "Load", model == "Subtitles", field == "subtitles", let request = try? path(action["args"]?["args"]) {
            let addons = registrySnapshot
            return enqueue(field) { [self] in [field: try await session.loadSubtitles(request: request, addons: addons)] }
        }
        return fail("unsupported_action")
    }
    private static let nativeActions: Set<String> = ["add_profile", "switch_profile", "delete_profile", "set_parental", "set_ranking_prefs", "report_progress", "mark_watched", "reset_watched", "remove_from_continue_watching", "merge_watch_state", "merge_watch_document", "link_resume_identity", "get_state", "bind_sync_scope", "merge_native_sync", "patch_profile", "rebind_profile_account", "install_addon", "remove_addon", "reorder_addons", "add_library_item", "remove_library_item"]
    private func addonOwner(for state: VortxJSON) -> String? {
        guard let active = string(state["activeProfileId"]),
              let binding = state["roster"]?["profiles"]?[active]?["addons"],
              [.string("own"), .string("share_primary")].contains(binding) else { return nil }
        return binding == .string("share_primary") ? session.scope.ownerProfileID : active
    }
    /// CoreBridge verifies the fetched response before it reaches this adapter.  Revalidate the
    /// immutable transport identity and the manifest's required human/API identity here as well,
    /// because a raw Ctx action can otherwise bypass that async installer boundary.
    private func addonDescriptor(_ value: VortxJSON?) -> (url: String, addon: VortxJSON)? {
        guard let url = string(value?["transportUrl"]), addonMemberKey(url) != nil,
              let manifest = value?["manifest"], case .object = manifest,
              let id = string(manifest["id"]), !id.isEmpty, let name = string(manifest["name"]), !name.isEmpty else { return nil }
        return (url, .object(["transportUrl": .string(url), "manifest": manifest]))
    }
    /// Kernel membership keys fold only URL scheme and host. The descriptor keeps the original
    /// transport URL, including path and presentation casing, for actions and resource hosting.
    private func addonMemberKey(_ url: String) -> String? {
        VortxNativeWebsiteAddonEdits.memberKey(url)
    }
    /// The input comparison ties this caller to the acknowledged operation; it does not compare
    /// unsupported wire fields with the canonical manifest or reproduce the kernel normalizer.
    func confirmsInstalledAddon(_ identity: String, submittedManifest: VortxJSON) -> Bool {
        lock.withLock {
            guard !closed, pendingProfileTransitions == 0, resourceRegistryValid,
                  let receipt = addonConfirmation, receipt.operation == addonOperation,
                  receipt.account == accountEpoch, receipt.registry == registryGeneration,
                  receipt.url == identity, receipt.submittedManifest == submittedManifest,
                  let state = values["native_state"], string(state["activeProfileId"]) == receipt.profile,
                  addonOwner(for: state) == receipt.owner,
                  addonInventories[receipt.owner]?.contains(receipt.acceptedDescriptor) == true else { return false }
            return true
        }
    }
    private func dispatchAddonMutation(subaction: String, args: VortxJSON?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A rejected or superseding call cannot borrow the previous operation's acknowledgement.
        addonConfirmation = nil; addonOperation = UUID()
        let operation = addonOperation, account = accountEpoch
        guard !closed, pendingProfileTransitions == 0, let state = values["native_state"], let owner = addonOwner(for: state),
              let profile = string(state["activeProfileId"]) else {
            return fail("stale_or_invalid_addon_owner")
        }
        guard let current = installedAddonURLs(state: state, owner: owner) else { return fail("invalid_native_addon_inventory") }
        func raw(_ action: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(action), as: UTF8.self) }
        func enqueueInstall(type: String, actions: [String], descriptor: (url: String, addon: VortxJSON)) -> Bool {
            enqueueMutation(type: type, raw: "", actions: actions, admission: { [weak self] in
                guard let self else { return false }
                return self.lock.withLock {
                    !self.closed && self.accountEpoch == account
                        && self.string(self.values["native_state"]?["activeProfileId"]) == profile
                        && self.values["native_state"].flatMap(self.addonOwner) == owner
                }
            }, completion: { [weak self] result in
                guard case .success = result, let self else { return }
                self.lock.withLock {
                    guard !self.closed, self.pendingProfileTransitions == 0,
                          self.addonOperation == operation, self.accountEpoch == account,
                          self.string(self.values["native_state"]?["activeProfileId"]) == profile,
                          self.values["native_state"].flatMap(self.addonOwner) == owner,
                          let accepted = self.addonInventories[owner]?.first(where: { self.string($0["transportUrl"]) == descriptor.url }),
                          let submitted = descriptor.addon["manifest"] else { return }
                    self.addonConfirmation = .init(operation: operation, account: account, profile: profile, owner: owner,
                                                  registry: self.registryGeneration, url: descriptor.url,
                                                  submittedManifest: submitted, acceptedDescriptor: accepted)
                }
            })
        }
        do {
            switch subaction {
            case "InstallAddon", "InstallAddonLocal":
                guard let descriptor = addonDescriptor(args), let identity = addonMemberKey(descriptor.url),
                      !current.contains(where: { addonMemberKey($0) == identity }) else {
                    return fail("invalid_or_duplicate_addon")
                }
                return enqueueInstall(type: "install_addon", actions: [try raw(.object([
                    "type": .string("install_addon"), "profileId": .string(owner), "addon": descriptor.addon,
                ]))], descriptor: descriptor)
            case "UninstallAddon", "UninstallAddonLocal":
                guard let descriptor = addonDescriptor(args), let identity = addonMemberKey(descriptor.url),
                      current.contains(where: { addonMemberKey($0) == identity }) else {
                    return fail("unknown_addon_identity")
                }
                return enqueueMutation(type: "remove_addon", raw: try raw(.object([
                    "type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(descriptor.url),
                ])))
            case "ReplaceAddon", "ReplaceAddonLocal":
                // Validate both immutable identities before queuing any removal.  `dispatch` runs
                // the whole list against one throwaway runtime, so an install/reorder failure leaves
                // the old membership, order and visible registry untouched.
                guard let old = addonDescriptor(args?["old"]), let new = addonDescriptor(args?["new"]),
                      let oldIdentity = addonMemberKey(old.url), let newIdentity = addonMemberKey(new.url),
                      let oldIndex = current.firstIndex(where: { addonMemberKey($0) == oldIdentity }),
                      (oldIdentity == newIdentity || !current.contains(where: { addonMemberKey($0) == newIdentity })) else {
                    return fail("invalid_addon_replacement")
                }
                var order = current; order[oldIndex] = new.url
                let install = VortxJSON.object(["type": .string("install_addon"), "profileId": .string(owner), "addon": new.addon])
                let remove = VortxJSON.object(["type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(old.url)])
                let reorder = VortxJSON.object(["type": .string("reorder_addons"), "profileId": .string(owner), "transportUrls": .array(order.map(VortxJSON.string))])
                // Case-only scheme/host changes address one kernel membership key. Remove that
                // key before installing its replacement; install-then-remove would tombstone the
                // newly written record and make the following canonical reorder fail.
                let actions = oldIdentity == newIdentity ? [remove, install, reorder] : [install, remove, reorder]
                return enqueueInstall(type: "replace_addon", actions: try actions.map(raw), descriptor: new)
            default: return fail("unsupported_addon_mutation")
            }
        } catch { return fail("invalid_addon_mutation") }
    }
    /// Resource registry omits profile-disabled add-ons. Kernel reorder requires every live
    /// owner-bucket identity exactly once, so mutation order comes from the unfiltered CRDT map.
    private func installedAddonURLs(state: VortxJSON, owner: String) -> [String]? {
        guard state == values["native_state"], let rows = addonInventories[owner] else { return nil }
        let urls = rows.compactMap { string($0["transportUrl"]) }
        guard urls.count == rows.count, Set(urls.compactMap(addonMemberKey)).count == rows.count else { return nil }
        return urls
    }
    private func acceptedMetadataInventory(metaID: String, type: String) -> [String]? {
        guard let detail = values["meta_details"], detail["selected"]?["metaPath"]?["id"] == .string(metaID),
              detail["selected"]?["metaPath"]?["type"] == .string(type) else { return nil }
        let ready = detail["metaItems"]?.array?.compactMap { $0["content"]?["content"] }.first {
            $0["id"] == .string(metaID) && $0["type"] == .string(type)
        }
        guard let ready else { return nil }
        let inventory = ready["videos"]?.array?.compactMap { string($0["id"]) }.filter { !$0.isEmpty } ?? []
        return inventory.isEmpty ? nil : inventory
    }
    private func catalogDefinition(_ request: VortxResourceRequest, addon: VortxResourceAddon) -> VortxJSON? {
        addon.manifest?["catalogs"]?.array?.first { $0["id"] == .string(request.id) && $0["type"] == .string(request.type) }
    }
    private func validCatalogRequest(_ request: VortxResourceRequest, addon: VortxResourceAddon) -> Bool {
        guard request.resource == .catalog, let definition = catalogDefinition(request, addon: addon),
              request.extra.allSatisfy({ $0.count == 2 }), Set(request.extra.map { $0[0] }).count == request.extra.count else { return false }
        let extras = definition["extra"]?.array ?? []
        let supported = Set(extras.compactMap { string($0["name"]) } + (definition["extraSupported"]?.array ?? []).compactMap { string($0) })
        guard request.extra.allSatisfy({ supported.contains($0[0]) }),
              extras.filter({ $0["isRequired"] == .bool(true) }).allSatisfy({ definition in request.extra.contains { .string($0[0]) == definition["name"] } }) else { return false }
        for extra in request.extra {
            if extra[0] == "skip", UInt64(extra[1]) == nil { return false }
            if let options = extras.first(where: { $0["name"] == .string(extra[0]) })?["options"]?.array,
               !options.contains(.string(extra[1])) { return false }
        }
        return true
    }
    private func catalogRequest(_ addon: VortxResourceAddon, _ request: VortxResourceRequest) -> VortxJSON {
        .object(["base": .string(addon.transportUrl), "path": (try? VortxResourceProjection.path(request)) ?? .null])
    }
    private func nextCatalogPage(_ pages: [VortxJSON]) -> (VortxResourceAddon, VortxResourceRequest)? {
        guard let last = pages.last, last["content"]?["type"] == .string("Ready"),
              let items = last["content"]?["content"]?.array, !items.isEmpty,
              let request = try? path(last["request"]?["path"]),
              let addon = registrySnapshot.first(where: { .string($0.transportUrl) == last["request"]?["base"] }),
              let definition = catalogDefinition(request, addon: addon),
              (definition["extra"]?.array ?? []).contains(where: { $0["name"] == .string("skip") }) || (definition["extraSupported"]?.array ?? []).contains(.string("skip")) else { return nil }
        let offset = request.extra.first(where: { $0.first == "skip" }).flatMap { UInt64($0[1]) } ?? 0
        let (next, overflow) = offset.addingReportingOverflow(UInt64(items.count))
        guard !overflow else { return nil }
        let result = VortxResourceRequest(resource: .catalog, type: request.type, id: request.id,
                                         extra: request.extra.filter { $0.first != "skip" } + [["skip", String(next)]])
        return validCatalogRequest(result, addon: addon) ? (addon, result) : nil
    }
    private func discoverProjection(pages: [VortxJSON], chosen: (VortxResourceAddon, VortxResourceRequest),
                                    requests: [(VortxResourceAddon, VortxResourceRequest)]) -> VortxJSON {
        var seenTypes = Set<String>()
        let types = requests.compactMap { item -> VortxJSON? in
            guard seenTypes.insert(item.1.type).inserted else { return nil }
            return .object(["type": .string(item.1.type), "selected": .bool(item.1.type == chosen.1.type), "request": catalogRequest(item.0, item.1)])
        }
        let catalogs = requests.filter { $0.1.type == chosen.1.type }.map { item -> VortxJSON in
            .object(["catalog": catalogDefinition(item.1, addon: item.0)?["name"] ?? .string(item.1.id),
                     "selected": .bool(item.0.id == chosen.0.id && item.1.id == chosen.1.id), "request": catalogRequest(item.0, item.1)])
        }
        let extras = (catalogDefinition(chosen.1, addon: chosen.0)?["extra"]?.array ?? []).compactMap { definition -> VortxJSON? in
            guard let name = string(definition["name"]), !["skip", "search"].contains(name),
                  let options = definition["options"]?.array else { return nil }
            let candidates: [VortxJSON] = (definition["isRequired"] == .bool(true) ? [] : [.null]) + options
            let selected = chosen.1.extra.first { $0.first == name }.map { VortxJSON.string($0[1]) } ?? .null
            let choices = candidates.map { value -> VortxJSON in
                var extra = chosen.1.extra.filter { $0.first != name && $0.first != "skip" }
                if let value = string(value) { extra.append([name, value]) }
                let request = VortxResourceRequest(resource: .catalog, type: chosen.1.type, id: chosen.1.id, extra: extra)
                return .object(["value": value, "selected": .bool(value == selected), "request": catalogRequest(chosen.0, request)])
            }
            return .object(["name": .string(name), "options": .array(choices)])
        }
        let next = nextCatalogPage(pages).map { VortxJSON.object(["request": catalogRequest($0.0, $0.1)]) } ?? .null
        let retry = pages.first(where: { $0["content"]?["type"] == .string("Err") })?["request"] ?? .null
        return .object(["catalog": .array(pages), "retryRequest": retry,
                        "selectable": .object(["types": .array(types), "catalogs": .array(catalogs), "extra": .array(extras), "next_page": next])])
    }
    /// Keep Discover decodable through a failed first page. Its selectable controls and exact
    /// failed request (including genre/skip) remain available to retry, under enqueue's ticket fence.
    private func enqueueDiscover(chosen: (VortxResourceAddon, VortxResourceRequest),
                                 requests: [(VortxResourceAddon, VortxResourceRequest)], append: Bool) -> Bool {
        guard let loading = try? loadingEntry(chosen.0, chosen.1) else { return fail("invalid_catalog_request") }
        let previous = values["discover"]?["catalog"]?.array ?? []
        let sameSelection = previous.first?["request"] == catalogRequest(chosen.0, chosen.1)
        let retained = append || sameSelection ? previous.filter { $0["content"]?["type"] == .string("Ready") } : []
        let initial = discoverProjection(pages: retained + [loading], chosen: chosen, requests: requests)
        return enqueue("discover", initial: initial, replacingSelection: !append) { [self] in
            let pages: [VortxJSON]
            do {
                let board = try await session.loadCatalog(.discover, request: chosen.1, addons: [chosen.0], append: append)
                let received = board["catalogs"]?.array?.flatMap { $0.array ?? [] } ?? []
                // A transport can return an Err group without throwing. Retain last good content
                // for a refresh failure just as for a thrown failure; success replaces it normally.
                pages = !append && received.contains(where: { $0["content"]?["type"] == .string("Err") })
                    ? retained + received : received
            } catch {
                try Task.checkCancellation()
                if case VortxNativeError.superseded = error { throw error }
                let failed = try VortxResourceProjection.entry(.failed(addonId: chosen.0.id,
                    failure: .from(error)), request: chosen.1, registry: [chosen.0])
                pages = retained + [failed]
            }
            return ["discover": discoverProjection(pages: pages, chosen: chosen, requests: requests)]
        }
    }
    private func loadingEntry(_ addon: VortxResourceAddon, _ request: VortxResourceRequest) throws -> VortxJSON {
        .object(["request": .object(["base": .string(addon.transportUrl), "path": try VortxResourceProjection.path(request)]), "content": .object(["type": .string("Loading")])])
    }
    private func catalogRequests(extra: [[String]], type: String?) -> [(VortxResourceAddon, VortxResourceRequest)] {
        registrySnapshot.flatMap { addon in
            (addon.manifest?["catalogs"]?.array ?? []).compactMap { catalog in
                guard let id = string(catalog["id"]), let kind = string(catalog["type"]), type == nil || type == kind else { return nil }
                let supported = Set((catalog["extra"]?.array ?? []).compactMap { string($0["name"]) } + (catalog["extraSupported"]?.array ?? []).compactMap { string($0) })
                guard extra.allSatisfy({ $0.count == 2 && supported.contains($0[0]) }) else { return nil }
                let required = (catalog["extra"]?.array ?? []).filter { $0["isRequired"] == .bool(true) }.compactMap { string($0["name"]) }
                guard required.allSatisfy({ name in extra.contains { $0.first == name } }) else { return nil }
                return (addon, VortxResourceRequest(resource: .catalog, type: kind, id: id, extra: extra))
            }
        }
    }
    /// The Library: every saved title, then every title watched or started, most recent
    /// first. A watched title leaves only when the viewer removed it from the Library after its last
    /// watch; watching it again brings it back.
    private func projectedLibraryItems(_ state: VortxJSON, formatter: ISO8601DateFormatter = ISO8601DateFormatter()) throws -> [VortxJSON] {
        guard let active = string(state["activeProfileId"]), let library = state["libraries"]?[active] else { throw VortxNativeError.invalidSnapshot }
        // Preserve the selected-unit, first-match semantics even if an input repeats a title.
        // One index replaces a full Continue Watching scan for every saved/history row.
        var resumeByID: [String: VortxJSON] = [:]
        for row in playback?["continueWatching"]?.array ?? [] {
            if case .string(let id)? = row["metaId"], resumeByID[id] == nil { resumeByID[id] = row }
        }
        let saved = (library["items"]?.array ?? []).filter { $0["kind"] == .string("standard") }.compactMap { item -> VortxJSON? in
            guard let id = string(item["id"]), let type = string(item["type"]) else { return nil }
            return libraryRow(id: id, type: type, name: item["name"] ?? .string(id), poster: item["poster"] ?? .null, resume: resumeByID[id], formatter: formatter)
        }
        let savedIDs = Set(saved.compactMap { string($0["_id"]) })
        let records = state["nativeSync"]?["libraries"]?[active]?["records"]
        return saved + VortxNativePreviouslyWatched.titles(playback: playback, excluding: savedIDs) { type, id in
            try? records?[type + ":" + id]?["removedAt"]?.decode(UInt64.self)
        }.map { libraryRow(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, previouslyWatched: true, resume: resumeByID[$0.id], formatter: formatter) }
    }
    /// `previouslyWatched` marks a watched-only row: listed in the Library, but not saved membership, so Detail
    /// still offers Add to Library and a removal never edits a Trakt/SIMKL watchlist.
    private func libraryRow(id: String, type: String, name: VortxJSON, poster: VortxJSON, previouslyWatched: Bool = false,
                            resume: VortxJSON?, formatter: ISO8601DateFormatter) -> VortxJSON {
        // Exact native selected-unit projection, never max(old episode offsets). A saved
        // membership without watch evidence stays unwatched and out of Continue Watching.
        let offset = resume?["offsetMs"] ?? .integer(0)
        let duration = resume?["durationMs"] ?? .integer(0)
        let watched = playback?["watchedTitles"]?[id] ?? .integer(0)
        var row: [String: VortxJSON] = ["_id": .string(id), "type": .string(type), "name": name, "poster": poster,
                        "state": .object(["timeOffset": offset, "duration": duration,
                                          "video_id": resume?["videoId"] ?? .null, "lastWatched": isoTimestamp(resume?["updatedAt"], formatter: formatter),
                                          "flaggedWatched": watched, "timesWatched": watched])]
        if previouslyWatched { row["previouslyWatched"] = .bool(true) }
        return .object(row)
    }
    private func libraryProjection(state: VortxJSON, request: VortxJSON?, projected: [VortxJSON]? = nil) -> VortxJSON? {
        let requestedType: String?
        switch request?["type"] {
        case nil, .some(.null): requestedType = nil
        case .some(.string(let type)) where !type.isEmpty: requestedType = type
        default: return nil
        }
        let sort: String
        switch request?["sort"] {
        case nil: sort = "lastwatched"
        case .some(.string(let value)): sort = value
        default: return nil
        }
        guard ["lastwatched", "name", "namereverse", "timeswatched", "watched", "notwatched"].contains(sort),
              request?["page"] == nil || request?["page"] == .integer(1),
              let all = projected ?? (try? projectedLibraryItems(state)) else { return nil }
        var availableTypes = Array(Set(all.compactMap { string($0["type"]) })).sorted()
        if let requestedType, !availableTypes.contains(requestedType) { availableTypes.append(requestedType); availableTypes.sort() }
        var rows = all.enumerated().map { (index: $0.offset, row: $0.element) }
        if let requestedType { rows.removeAll { string($0.row["type"]) != requestedType } }
        func watched(_ row: VortxJSON) -> Bool { (try? row["state"]?["flaggedWatched"]?.decode(UInt64.self)) ?? 0 > 0 }
        func count(_ row: VortxJSON) -> UInt64 { (try? row["state"]?["timesWatched"]?.decode(UInt64.self)) ?? 0 }
        switch sort {
        case "name": rows.sort { let left = string($0.row["name"]) ?? ""; let right = string($1.row["name"]) ?? ""; return left == right ? $0.index < $1.index : left.localizedCaseInsensitiveCompare(right) == .orderedAscending }
        case "namereverse": rows.sort { let left = string($0.row["name"]) ?? ""; let right = string($1.row["name"]) ?? ""; return left == right ? $0.index < $1.index : left.localizedCaseInsensitiveCompare(right) == .orderedDescending }
        case "timeswatched": rows.sort { count($0.row) == count($1.row) ? $0.index < $1.index : count($0.row) > count($1.row) }
        case "watched": rows.removeAll { !watched($0.row) }
        case "notwatched": rows.removeAll { watched($0.row) }
        default: break // Preserve the kernel's current native order for most-recent.
        }
        func option(_ type: String?, selected: Bool) -> VortxJSON {
            .object(["type": type.map(VortxJSON.string) ?? .null, "selected": .bool(selected),
                     "request": .object(["type": type.map(VortxJSON.string) ?? .null, "sort": .string(sort), "page": .integer(1)])])
        }
        let types = [option(nil, selected: requestedType == nil)] + availableTypes.map { option($0, selected: requestedType == $0) }
        let sorts = ["lastwatched", "name", "namereverse", "timeswatched", "watched", "notwatched"].map {
            VortxJSON.object(["sort": .string($0), "selected": .bool($0 == sort),
                              "request": .object(["type": requestedType.map(VortxJSON.string) ?? .null, "sort": .string($0), "page": .integer(1)])])
        }
        return .object(["catalog": .array(rows.map(\.row)), "selectable": .object(["types": .array(types), "sorts": .array(sorts)])])
    }
    private func localSearchProjection(state: VortxJSON, query: String, maxResults: Int) -> VortxJSON? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2, let rows = try? projectedLibraryItems(state) else { return nil }
        let matches = rows.filter { row in
            (string(row["name"]) ?? "").localizedCaseInsensitiveContains(needle) ||
            (string(row["_id"]) ?? "").localizedCaseInsensitiveContains(needle)
        }.prefix(maxResults).compactMap { row -> VortxJSON? in
            guard let id = string(row["_id"]), let name = string(row["name"]), let type = string(row["type"]) else { return nil }
            return .object(["id": .string(id), "name": .string(name), "type": .string(type), "poster": row["poster"] ?? .null, "releaseInfo": .null])
        }
        return .object(["searchResults": .array(Array(matches))])
    }
    private func stateFields(_ state: VortxJSON) throws -> [String: VortxJSON] {
        // The formatter is local to this complete pass: no mutable formatter crosses threads.
        let formatter = ISO8601DateFormatter()
        let projected = try projectedLibraryItems(state, formatter: formatter)
        let membership = VortxLibraryMembership(projected)
        let descriptors = (lock.withLock { resourceRegistryValid ? registry : [] }).map { addon in VortxJSON.object(["transportUrl": .string(addon.transportUrl), "manifest": addon.manifest ?? .object([:])]) }
        var fields: [String: VortxJSON] = ["native_state": state, "ctx": .object(["profile": .object(["addons": .array(descriptors)])]),
                "native_playback": playback ?? .null,
                "continue_watching_preview": .object(["items": .array((playback?["continueWatching"]?.array ?? []).compactMap { playbackRow($0, formatter: formatter) })]),
                "native_history": .object(["items": .array((playback?["history"]?.array ?? []).compactMap { playbackRow($0, formatter: formatter) })]),
                "library": libraryProjection(state: state, request: libraryRequest, projected: projected) ?? .object(["catalog": .array(projected), "selectable": .object(["types": .array([]), "sorts": .array([])])])]
        if let detail = values["meta_details"] { fields["meta_details"] = metaWithPlayback(detail, library: membership) }
        // Only create-before-exposure and the locked acknowledged-state transaction call this method.
        // Install the same full projection used by the metadata in this transaction.
        metadataLibraryMembership = membership
        return fields
    }
    private func metaWithPlayback(_ detail: VortxJSON, library: VortxLibraryMembership) -> VortxJSON {
        guard case .object(var fields) = detail, let id = string(detail["selected"]?["metaPath"]?["id"]) else { return detail }
        // Saved membership only: a watched-only Library row must leave Detail offering Add to Library.
        fields["libraryItem"] = library.item(for: id) ?? .null
        fields["watchedVideoIds"] = playback?["watchedVideoIdsByTitle"]?[id] ?? .array([])
        return .object(fields)
    }
    private func isoTimestamp(_ value: VortxJSON?, formatter: ISO8601DateFormatter) -> VortxJSON {
        guard let seconds = try? value?.decode(UInt64.self), seconds <= 253_402_300_799 else { return .null }
        return .string(formatter.string(from: Date(timeIntervalSince1970: Double(seconds))))
    }
    private func playbackRow(_ row: VortxJSON, formatter: ISO8601DateFormatter) -> VortxJSON? {
        guard let id = string(row["metaId"]), let type = string(row["type"]), !type.isEmpty,
              let offset = try? row["offsetMs"]?.decode(UInt64.self), let duration = try? row["durationMs"]?.decode(UInt64.self),
              let count = try? row["timesWatched"]?.decode(UInt64.self), case .bool(let watched) = row["watched"] else { return nil }
        return .object(["_id": .string(id), "type": .string(type), "name": row["name"] ?? .string(id), "poster": row["poster"] ?? .null,
                        "state": .object(["timeOffset": .unsigned(offset), "duration": .unsigned(duration),
                                          "video_id": row["videoId"] ?? .null, "lastWatched": isoTimestamp(row["updatedAt"], formatter: formatter),
                                          "flaggedWatched": .integer(watched ? 1 : 0), "timesWatched": .unsigned(count)])])
    }
}

// MARK: - Original read capability to own running FIFO member
extension VortxNativeCoreFacade {
    typealias OriginalReadCapability = VortxNativeFIFOAdmission.ReadCapability

    // Only explicitly prepared titles, bounded to 32 receipts. These are not service states.
    private func externalMetadataFingerprint(_ raw: VortxJSON) -> (value: VortxJSON, bytes: Data)? {
        guard case .string(let id) = raw["id"], !id.isEmpty,
              raw["type"] == .string("series"), let videos = raw["videos"]?.array,
              !videos.isEmpty, videos.count <= 20_000 else { return nil }
        let value = VortxJSON.object(["id": .string(id), "type": .string("series"), "videos": .array(videos.map {
            .object(["id": $0["id"] ?? .null, "season": $0["season"] ?? .null, "episode": $0["episode"] ?? .null])
        })])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(value), bytes.count <= 1_048_576 else { return nil }
        return (value, bytes)
    }
    private func observeExternalMetadata(_ detail: VortxJSON) {
        guard let id = string(detail["selected"]?["metaPath"]?["id"]),
              detail["selected"]?["metaPath"]?["type"] == .string("series"),
              let rows = detail["metaItems"]?.array, !rows.isEmpty,
              rows.allSatisfy({ [.string("Ready"), .string("Err")].contains($0["content"]?["type"] ?? .null) }) else { return }
        externalMetadataObservation = UUID()
        guard let captured = externalMetadataReceipts[Data(("series|" + id).utf8)] else { return }
        let ready = rows.filter { $0["content"]?["type"] == .string("Ready") }
            .compactMap { $0["content"]?["content"] }
        // A conflicting accepted response cannot silently reinterpret an already offered unit.
        // No ready response, wrong title, or any differing provider inventory retires the receipt.
        if ready.isEmpty || ready.contains(where: { externalMetadataFingerprint($0)?.bytes != captured.0 }) {
            externalMetadataReceipts.removeValue(forKey: Data(("series|" + id).utf8))
        }
    }
    func captureExternalCWRead(expected: WatchlistBinding, registry expectedRegistry: RegistryBinding,
                               sourceAuthority: any VortxMutationAuthority) throws -> VortxNativeExternalCW.Read {
        let original = try captureNativeMutationRead(expected: expected, registry: expectedRegistry, sourceAuthority: sourceAuthority)
        var capturedAddons: [VortxResourceAddon] = []
        try original.withActive { capturedAddons = registry }
        let addons = capturedAddons
        return .init(original: original, metadataCurrent: { [weak self] held in
            guard let self else { return false }
            return self.lock.withLock { held.allSatisfy {
                self.externalMetadataReceipts[Data(($0.type + "|" + $0.id).utf8)]?.1 == $0.receipt
            } }
        }, prepare: { [weak self, session] id in
            guard let self else { throw VortxNativeError.closed }
            try Task.checkCancellation()
            var observation: UUID?
            try original.withActive { observation = self.externalMetadataObservation }
            // Existing independent resource-host slot: no visible detail load or synthetic ID.
            let raw = try await session.libraryMetadata(id: id, type: "series", profileID: expected.profileID, addons: addons)
            try Task.checkCancellation()
            var accepted: VortxNativeExternalCW.Metadata?
            try original.withActive {
                guard observation == self.externalMetadataObservation else { throw VortxNativeError.superseded }
                guard case .string(let actualID) = raw["id"], actualID.utf8.elementsEqual(id.utf8),
                      let fingerprint = self.externalMetadataFingerprint(raw),
                      let rows = fingerprint.value["videos"]?.array else { throw VortxNativeError.invalidResponse }
                func coordinate(_ raw: VortxJSON?) throws -> Int? {
                    guard let raw, raw != .null else { return nil }; return try raw.decode(Int.self)
                }
                let videos: [VortxNativeExternalCW.Metadata.Video] = try rows.map { row in
                    guard case .string(let unit) = row["id"], !unit.isEmpty, unit.utf8.count <= 512 else {
                        throw VortxNativeError.invalidResponse
                    }
                    return .init(id: unit, season: try coordinate(row["season"]), episode: try coordinate(row["episode"]))
                }
                let key = Data(("series|" + id).utf8)
                if self.externalMetadataReceipts[key]?.0 != fingerprint.bytes {
                    self.externalMetadataReceipts[key] = (fingerprint.bytes, UUID())
                    self.externalMetadataObservation = UUID()
                }
                while self.externalMetadataReceipts.count > 32 {
                    guard let victim = self.externalMetadataReceipts.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).first(where: { $0 != key }) else { break }
                    self.externalMetadataReceipts.removeValue(forKey: victim)
                }
                guard let receipt = self.externalMetadataReceipts[key]?.1 else { throw VortxNativeError.superseded }
                accepted = .init(id: id, type: "series", videos: videos, receipt: receipt)
            }
            guard let accepted else { throw VortxNativeError.invalidResponse }
            return accepted
        }, resolve: { [session] candidates in
            try await session.externalCWEligibility(candidates, profileID: expected.profileID, original: original)
        })
    }


    /// Call before provider awaits, without holding the Facade lock. Original source authority
    /// owns credential/account/install/cancellation checks; no credential bytes are copied here.
    func captureNativeMutationRead(expected: WatchlistBinding, registry expectedRegistry: RegistryBinding,
                                   sourceAuthority: any VortxMutationAuthority) throws -> OriginalReadCapability {
        let originalSession = ObjectIdentifier(session)
        return try mutationFIFO.capture(source: sourceAuthority) { [weak self] in
            guard let self, !self.closed, !self.checkpointReopenRequired,
                  ObjectIdentifier(self.session) == originalSession, self.resourceRegistryValid,
                  self.heldOwnerProgress == nil,
                  expected.scope == self.session.scope, expectedRegistry.scope == expected.scope,
                  expectedRegistry.profileID == expected.profileID,
                  expected.accountGeneration == self.accountEpoch,
                  expected.profileGeneration == self.watchlistProfileGeneration,
                  expectedRegistry.generation == self.registryGeneration,
                  self.values["native_state"]?["activeProfileId"] == .string(expected.profileID) else {
                throw VortxNativeError.superseded
            }
            // Deliberately no pendingProfileTransitions/latest-enqueued-generation test here:
            // later FIFO intents cannot revoke this earlier member. Actual ACK identity can.
        }
    }

    /// Generic current-Session adapter, not an owner-history import or a source-to-action
    /// converter. The supplied actions still pass the real Session candidate/checkpoint path.
    /// Owner-history requires a separate typed Session method and raw publication integration.
    func dispatchCapturedNativeActions(_ actions: [String], read: OriginalReadCapability,
                                       checkpointValidator: any VortxProspectiveCheckpointValidator) async throws -> VortxJSON {
        guard !actions.isEmpty else { throw VortxNativeError.invalidSnapshot }
        let types = try actions.map { raw -> String in
            let action = try JSONDecoder().decode(VortxJSON.self, from: Data(raw.utf8))
            guard case .string(let type) = action["type"] else { throw VortxNativeError.invalidSnapshot }
            return type
        }
        let transitionTypes: Set<String> = ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"]
        let transition = types.contains { transitionTypes.contains($0) }
        let type = types.allSatisfy { $0 == "get_state" } ? "get_state" : "captured_native_mutation"
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VortxJSON, Error>) in
                do {
                    // Source -> Facade lock. Consume and install the task in the SAME critical
                    // section; competing dispatch cannot slip between validation and insertion.
                    try mutationFIFO.admit(read) { member in
                        guard enqueueMutation(type: type, raw: "", actions: actions,
                            checkpointValidator: checkpointValidator,
                            fifoMember: member, forceProfileTransition: transition,
                            // Captured raw types have no enforced non-owner subset. Drain
                            // without rejecting valid reducer operations or widening the
                            // original profile-pending classifier. Direct progress and
                            // resource paths do not pass through this adapter.
                            forceSubtitleOwnerTransition: true,
                            completion: { continuation.resume(with: $0) }) else {
                            member.finish()
                            continuation.resume(throwing: VortxNativeError.closed)
                            return
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { read.cancel() })
    }
}

// MARK: - Typed owner source import and authenticated raw peer checkpoint
extension VortxNativeCoreFacade {
    /// Called only after the retained login gesture's own add-on ACK. Original credential
    /// selection/token/gesture authority stays external; receipt binds ONLY its own native ACK.
    func captureOwnerHistoryLoginRead(receipt: OwnerAddonImportReceipt, verifiedUID: String,
        sourceAuthority: any VortxMutationAuthority) async throws -> VortxNativeSession.OwnerHistoryAcknowledgedRead {
        let stage = ImportCommitAuthority(source: sourceAuthority)
        let original = try mutationFIFO.capture(source: stage) { [weak self] in
            guard let self, !self.closed, !self.checkpointReopenRequired,
                  self.heldOwnerProgress == nil,
                  receipt.facade == ObjectIdentifier(self),
                  self.watchlistBinding == receipt.binding, self.registryBinding == receipt.registry,
                  self.values["native_state"] == receipt.state else { throw VortxNativeError.superseded }
        }
        do {
            guard let profile = UUID(uuidString: receipt.binding.profileID) else { throw VortxNativeError.invalidSnapshot }
            return try await session.captureOwnerHistoryAcknowledgedRead(
                target: .init(profileID: profile, verifiedUID: verifiedUID), read: original)
        } catch { original.cancel(); throw error }
    }
    func importOwnerHistory(_ prepared: OwnerHistoryLoginPreparation) async throws -> Bool {
        let read = prepared.acknowledged.originalRead
        let pending: Bool
        switch prepared.outcome { case .pending: pending = true; case .prepared: pending = false }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try mutationFIFO.admit(read) { member in
                        guard enqueueMutation(type: "import_owner_history", raw: "", actions: [],
                            fifoMember: member, ownerOperation: { [session] in
                                let result = try await session.applyOwnerHistoryLogin(prepared)
                                guard (result.receipt == nil) == pending else { throw VortxNativeError.invalidResponse }
                            }, completion: { result in continuation.resume(with: result.map { _ in !pending }) }) else {
                            member.finish(); continuation.resume(throwing: VortxNativeError.closed); return
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { read.cancel() })
    }
    func captureOwnerHistoryCheckpointRead(expected: WatchlistBinding, registry: RegistryBinding,
        sourceAuthority: any VortxMutationAuthority) async throws -> VortxNativeSession.OwnerHistoryCheckpointRead {
        let read = try captureNativeMutationRead(expected: expected, registry: registry, sourceAuthority: sourceAuthority)
        do { return try await session.captureOwnerHistoryCheckpointRead(read: read) }
        catch { read.cancel(); throw error }
    }
    struct OwnerHistoryPeerCommit: Sendable {
        let publication: OwnerHistorySessionPublication
        let binding: WatchlistBinding
        let registry: RegistryBinding
        fileprivate let facade: ObjectIdentifier
        fileprivate let generation: UUID
    }
    private final class OwnerHistoryPeerResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: OwnerHistorySessionPublication?
        func set(_ value: OwnerHistorySessionPublication) { lock.withLock { stored = value } }
        var value: OwnerHistorySessionPublication? { lock.withLock { stored } }
    }
    func isCurrentOwnerHistoryPeerCommit(_ receipt: OwnerHistoryPeerCommit) -> Bool {
        lock.withLock {
            !closed && receipt.facade == ObjectIdentifier(self)
                && receipt.generation == ownerHistoryACKGeneration
                && receipt.binding == watchlistBinding && receipt.registry == registryBinding
        }
    }
    func mergeOwnerHistoryPeer(_ prepared: OwnerHistoryPeerPreparation,
        hostEdits: [VortxNativeHostPreferences.Edit] = []) async throws -> OwnerHistoryPeerCommit {
        let read = prepared.acknowledged.originalRead
        let accepted = OwnerHistoryPeerResult()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OwnerHistoryPeerCommit, Error>) in
                do {
                    try mutationFIFO.admit(read) { member in
                        guard enqueueMutation(type: "merge_native_sync", raw: "", actions: [],
                            fifoMember: member, forceProfileTransition: true, ownerOperation: { [session] in
                                accepted.set(try await session.mergeOwnerHistoryPeer(prepared, hostEdits: hostEdits))
                            }, completion: { [weak self] result in
                                do {
                                    _ = try result.get()
                                    guard let self, let publication = accepted.value else { throw VortxNativeError.closed }
                                    let receipt = try self.lock.withLock { () throws -> OwnerHistoryPeerCommit in
                                        guard !self.closed, let binding = self.watchlistBinding,
                                              let registry = self.registryBinding else { throw VortxNativeError.superseded }
                                        return .init(publication: publication, binding: binding, registry: registry,
                                            facade: ObjectIdentifier(self), generation: self.ownerHistoryACKGeneration)
                                    }
                                    continuation.resume(returning: receipt)
                                } catch { continuation.resume(throwing: error) }
                            }) else {
                            member.finish(); continuation.resume(throwing: VortxNativeError.closed); return
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { read.cancel() })
    }
    func ownerHistoryCompleteAccount(read: OriginalReadCapability, writeV2: Bool) async throws -> Data {
        try await session.ownerHistoryCompleteAccount(read: read, writeV2: writeV2)
    }
}

// MARK: - One captured safe host-profile field
extension VortxNativeCoreFacade {
    typealias HostFieldAdmission = @Sendable ([String: VortxJSON]) throws -> Void
    struct CapturedHostProfileSnapshot: Sendable {
        let registers: [String: VortxJSON]
        let registry: [VortxResourceAddon]
    }
    private func capturedHostBindingMatches(_ expected: WatchlistBinding, registry expectedRegistry: RegistryBinding) -> Bool {
        !closed && !checkpointReopenRequired && pendingProfileTransitions == 0
            && watchlistBinding == expected && registryBinding == expectedRegistry && resourceRegistryValid
    }
    /// Called under the facade lock. Missing publication is UNKNOWN, not an empty profile.
    /// Registry rebind intentionally retires this carrier until a real get_state ACK restores it.
    private func capturedHostProfileFields(_ expected: WatchlistBinding) throws -> [String: VortxJSON] {
        guard let carrier = values["native_host_preferences"],
              let document = try? carrier.decode(VortxNativeHostPreferences.Document.self),
              document.schemaVersion == 1, document.scope == expected.scope.account,
              document.ownerProfileId == expected.scope.ownerProfileID,
              case .object(let profiles) = carrier["profiles"] else { throw VortxNativeError.invalidSnapshot }
        // Only an absent profile INSIDE an acknowledged, well-shaped carrier is empty.
        guard let profile = profiles[expected.profileID] else { return [:] }
        guard case .object(let fields) = profile["fields"] else { throw VortxNativeError.invalidSnapshot }
        return fields // Preserve exact original raw registers, never re-encode the validated DTO.
    }
    func capturedHostProfileSnapshot(expected: WatchlistBinding, registry expectedRegistry: RegistryBinding) -> CapturedHostProfileSnapshot? {
        lock.withLock {
            guard capturedHostBindingMatches(expected, registry: expectedRegistry),
                  let fields = try? capturedHostProfileFields(expected) else { return nil }
            return .init(registers: fields, registry: registry)
        }
    }
    private final class CapturedHostFieldAuthority: VortxMutationAuthority, @unchecked Sendable {
        private let facade: VortxNativeCoreFacade
        private let expected: WatchlistBinding
        private let registry: RegistryBinding
        private let edit: VortxNativeHostFieldEdit
        private let source: any VortxMutationAuthority
        private let admission: HostFieldAdmission?
        init(facade: VortxNativeCoreFacade, expected: WatchlistBinding, registry: RegistryBinding,
             edit: VortxNativeHostFieldEdit, source: any VortxMutationAuthority, admission: HostFieldAdmission?) {
            self.facade = facade; self.expected = expected; self.registry = registry; self.edit = edit; self.source = source
            self.admission = admission
        }
        func withActive(_ operation: () throws -> Void) throws {
            // Lock order: export observation -> provider store -> session lease -> publication lease
            // -> Bridge -> original gesture lifetime -> facade -> operation latch -> validate/store.
            // No worker read of MainActor ProfileStore and no broad CoreBridge Sendable conformance.
            try source.withActive {
                try facade.lock.withLock {
                    try facade.validateCapturedHostEdit(edit, expected: expected, registry: registry, admission: admission)
                    try operation()
                }
            }
        }
    }
    private func validateCapturedHostEdit(_ edit: VortxNativeHostFieldEdit, expected: WatchlistBinding,
                                          registry expectedRegistry: RegistryBinding, admission: HostFieldAdmission?) throws {
        guard capturedHostBindingMatches(expected, registry: expectedRegistry) else { throw VortxNativeError.superseded }
        let fields = try capturedHostProfileFields(expected)
        guard edit.baselineMatches(fields[edit.field]) else { throw VortxNativeHostFieldMutationError.staleRegister }
        try admission?(fields)
    }
    /// Unlike a profile patch, this changes no kernel-owned setting, account binding or add-on.
    /// The exact raw register CAS is checked at enqueue, FIFO admission, inside the session's
    /// candidate BEFORE edit, and under the final owner/cancellation authority before checkpoint.
    func setCapturedHostProfileField(_ edit: VortxNativeHostFieldEdit, expected: WatchlistBinding,
                                     registry expectedRegistry: RegistryBinding, sourceAuthority: any VortxMutationAuthority,
                                     checkpointValidator: any VortxProspectiveCheckpointValidator,
                                     admission: HostFieldAdmission? = nil) async throws -> VortxJSON {
        guard !edit.field.isEmpty else { throw VortxNativeError.invalidSnapshot }
        let owner = CapturedHostFieldAuthority(facade: self, expected: expected, registry: expectedRegistry, edit: edit, source: sourceAuthority, admission: admission)
        let operation = VortxNativeHostFieldCommitLatch(source: owner)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VortxJSON, Error>) in
                do {
                    lock.lock(); defer { lock.unlock() }
                    try validateCapturedHostEdit(edit, expected: expected, registry: expectedRegistry, admission: admission)
                    guard enqueueMutation(type: "edit_captured_host_field", raw: "", actions: [],
                        hostEdits: [.init(profileID: expected.profileID, fields: [edit.field: edit.value])],
                        hostFieldCAS: .init(profileID: expected.profileID, field: edit.field, register: edit.expectedRegister),
                        checkpointValidator: checkpointValidator,
                        admission: { [weak self] in
                            guard let self, !operation.isCancelled else { throw VortxNativeHostFieldMutationError.cancelled }
                            return try self.lock.withLock {
                                try self.validateCapturedHostEdit(edit, expected: expected, registry: expectedRegistry, admission: admission); return true
                            }
                        }, sourceAuthority: operation, completion: { [weak self] result in
                            do {
                                _ = try result.get()
                                guard let self else { throw VortxNativeError.closed }
                                let register = try self.lock.withLock { () throws -> VortxJSON in
                                    guard self.capturedHostBindingMatches(expected, registry: expectedRegistry),
                                          let accepted = self.values["native_host_preferences"]?["profiles"]?[expected.profileID]?["fields"]?[edit.field],
                                          VortxNativeHostFieldEvidence.json(accepted["value"], edit.value) else { throw VortxNativeError.superseded }
                                    return accepted
                                }
                                continuation.resume(returning: register)
                            } catch { continuation.resume(throwing: error) }
                        }) else { throw VortxNativeError.closed }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { operation.cancel() })
    }
}
