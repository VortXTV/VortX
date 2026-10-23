import Foundation

/// Required whole-account authority. The companion PreparedExport proposal supplies the real
/// serializer/witness composition, but the current Session/Facade do not construct or admit it.
/// There is no default authority and no local-test substitute for the encrypted-account gate.
/// Implementations must preserve the ORIGINAL account/credential/install/registry authority;
/// validate is invoked while that authority encloses the actual checkpoint and native accept.
protocol OwnerHistoryCompleteCheckpointAuthority: VortxMutationAuthority {
    func validateCompleteAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws
    func completeAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws -> Data
}

/// Actor-owned implementation component for VortxNativeSession, not an independently scheduled
/// writer. Its synchronous methods must run inside the existing native_state FIFO. It deliberately
/// has no autonomous queue, provider fetch, profile recapture, or account-reset fallback.
final class OwnerHistorySessionCoordinator {
    typealias Exact = OwnerHistoryExactJSON
    typealias Prepared = VortxNativeOwnerHistoryPreparation.Prepared
    typealias Pending = VortxNativeOwnerHistoryPreparation.Pending

    struct Target: Sendable {
        let profileID: UUID
        let verifiedUID: String
    }
    struct Capture: VortxMutationAuthority, Sendable {
        let target: Target
        let fence: Data
        fileprivate let coordinator: UUID
        fileprivate let runtime: UUID
        /// Original credential/account/install/registry authority, NOT a later fresh capture.
        fileprivate let sourceAuthority: any VortxMutationAuthority
        fileprivate let queueAuthority: any VortxMutationAuthority
        fileprivate var readAuthority: OwnerHistoryCaptureAuthority {
            .init(source: sourceAuthority, queue: queueAuthority)
        }
        /// The provider and prepared replay use this original capture. Facade integration must
        /// prove an atomic read-head-to-own-FIFO-ticket handoff; the current app has no such path.
        /// Do not replace a retired read head with a fresh queue lease to make replay succeed.
        func withReadAuthority(_ operation: () throws -> Void) throws {
            try readAuthority.withActive(operation)
        }
        func withActive(_ operation: () throws -> Void) throws { try withReadAuthority(operation) }

        /// Only this capture-owned pipeline constructs a new bound outcome. A fresh same-UID
        /// capture cannot be supplied alongside an old Prepared value at the import boundary.
        func prepare(source: VortxNativeOwnerHistorySource.Capture, authKey: String,
            verify: VortxNativeOwnerHistorySource.Verify = { try await LinkAuthService.authenticatedIdentity(authKey: $0).uid },
            send: VortxNativeOwnerHistorySource.Send = { try await AuthenticatedHTTPTransport.shared.send($0,
                allowedHosts: ["api.strem.io"], maxResponseBytes: VortxNativeOwnerHistorySource.maximumBytes) },
            fetchMetadata: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher = {
                try await VortxLegacyWatchedMetadataTransport.fetch($0)
            }) async throws -> BoundOutcome {
            try withReadAuthority {}
            let native = try Exact.Object(fence)
            guard source.profileID == target.profileID,
                  try Exact.sameText(source.scope, native.text("scope")),
                  try source.ownerProfileID.uuidString == native.text("ownerProfileId"),
                  Exact.sameText(source.verifiedUID, target.verifiedUID),
                  try OwnerHistorySessionCoordinator.equal(source.accountBindingBytes, native.required("binding")) else {
                throw VortxNativeError.superseded
            }
            let frame = try await VortxNativeOwnerHistoryPreparation.fetch(capture: source, authKey: authKey,
                authority: self, verify: verify, send: send)
            try withReadAuthority {}
            let outcome = try await VortxNativeOwnerHistoryPreparation.prepare(frame: frame, authority: self,
                fetchMetadata: fetchMetadata)
            try withReadAuthority {}
            return BoundOutcome(capture: self, outcome: outcome)
        }
    }
    struct BoundOutcome: Sendable {
        fileprivate let capture: Capture
        fileprivate let outcome: VortxNativeOwnerHistoryPreparation.Outcome
        fileprivate init(capture: Capture, outcome: VortxNativeOwnerHistoryPreparation.Outcome) {
            self.capture = capture; self.outcome = outcome
        }
        var isPending: Bool { if case .pending = outcome { return true }; return false }
        func withReadAuthority(_ operation: () throws -> Void) throws { try capture.withReadAuthority(operation) }
    }
    struct PendingResume: Sendable {
        fileprivate let capture: Capture
        fileprivate let archive: Data
        fileprivate let scope: VortxAccountScope
        fileprivate init(capture: Capture, archive: Data, scope: VortxAccountScope) {
            self.capture = capture; self.archive = archive; self.scope = scope
        }
        func resume(fetchMetadata: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher = {
            try await VortxLegacyWatchedMetadataTransport.fetch($0)
        }) async throws -> BoundOutcome {
            try capture.withReadAuthority {}
            guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw VortxNativeError.invalidSnapshot }
            let outcome = try await VortxNativeOwnerHistoryPreparation.resumePending(archive: archive,
                scope: scope.account, ownerProfileID: owner, profileID: capture.target.profileID,
                verifiedUID: capture.target.verifiedUID, authority: capture, fetchMetadata: fetchMetadata)
            try capture.withReadAuthority {}
            return BoundOutcome(capture: capture, outcome: outcome)
        }
    }
    /// Constructible only by this coordinator after full replay or exact immutable delta restore.
    /// The store checks the original encrypted envelope CAS before installing these exact bytes.
    struct Checkpoint: Sendable {
        let snapshot: Data
        let hostPreferences: Data
        let ownerHistoryLocal: Data
        let scope: VortxAccountScope
        let nativeSync: Data
        let nativeHostPreferences: Data
        let profileEditResults: Data
        let ownerHistorySources: Data
        /// Same-envelope authenticated full raw account base, never a presentation DTO.
        let accountBase: Data?
        let preservedOwnerUID: String
        fileprivate init(snapshot: Data, hostPreferences: Data, ownerHistoryLocal: Data,
                         scope: VortxAccountScope, nativeSync: Data, hostProjection: (document: Data, profileEditResults: Data),
                         ownerHistorySources: Data, preservedOwnerUID: String, accountBase: Data? = nil) {
            self.snapshot = snapshot; self.hostPreferences = hostPreferences
            self.ownerHistoryLocal = ownerHistoryLocal
            self.scope = scope; self.nativeSync = nativeSync
            self.nativeHostPreferences = hostProjection.document; self.profileEditResults = hostProjection.profileEditResults
            self.ownerHistorySources = ownerHistorySources; self.accountBase = accountBase
            self.preservedOwnerUID = preservedOwnerUID
        }
    }
    private func bindingAccountBase(_ checkpoint: Checkpoint,
        transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Checkpoint {
        let base = try transaction.completeAccount(checkpoint)
        return Checkpoint(snapshot: checkpoint.snapshot, hostPreferences: checkpoint.hostPreferences,
            ownerHistoryLocal: checkpoint.ownerHistoryLocal, scope: checkpoint.scope,
            nativeSync: checkpoint.nativeSync,
            hostProjection: (checkpoint.nativeHostPreferences, checkpoint.profileEditResults),
            ownerHistorySources: checkpoint.ownerHistorySources,
            preservedOwnerUID: checkpoint.preservedOwnerUID, accountBase: base)
    }
    struct DurableImport: Sendable {
        let receipt: Data
        let fence: Data
        let checkpoint: Checkpoint
        fileprivate init(receipt: Data, fence: Data, checkpoint: Checkpoint) {
            self.receipt = receipt; self.fence = fence; self.checkpoint = checkpoint
        }
    }
    fileprivate struct Local {
        typealias PendingRecord = OwnerHistoryPendingRecord
        var journal: VortxNativeOwnerHistoryJournal
        // Immutable exact pending archives, including superseded metadata attempts. Nothing is
        // pruned to satisfy budget and no source is acknowledged merely because it is retained.
        var pending: [String: PendingRecord]
        init(scope: VortxAccountScope, bytes: Data?) throws {
            guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw VortxNativeError.invalidSnapshot }
            guard let bytes else {
                journal = try .init(scope: scope.account, ownerProfileID: owner); pending = [:]; return
            }
            let object = try Exact.Object(bytes)
            guard Set(object.fields.keys) == ["kind", "journalBase64", "pending"],
                  try object.text("kind") == "vortx.owner-history.local/1" else { throw VortxNativeError.invalidSnapshot }
            let journalBytes = try Self.base64(object.required("journalBase64"))
            journal = try .init(bytes: journalBytes, scope: scope.account, ownerProfileID: owner)
            pending = [:]
            for (key, encoded) in try Exact.Object(object.required("pending")).fields {
                let record = try PendingRecord(encoded: encoded, expectedDigest: key)
                let archive = record.archive
                // Pending source is not replayed as Prepared: incomplete metadata is a real hold.
                // The exact frame is independently checked on read; the resumed producer owns
                // complete archive-candidate decoding under its original registry evidence.
                let candidate = try Exact.Object(archive)
                let frame = try Self.base64(candidate.required("sourceDocumentBase64"))
                let frameObject = try Exact.Object(frame)
                guard let profile = UUID(uuidString: try frameObject.text("profileId")) else {
                    throw VortxNativeError.invalidSnapshot
                }
                _ = try VortxNativeOwnerHistoryPreparation.decodeFrame(frame, scope: scope.account,
                    ownerProfileID: owner, profileID: profile,
                    verifiedUID: frameObject.text("verifiedStreamingUid"))
                pending[key] = record
            }
        }
        func encoded() throws -> Data {
            var values = try Exact.Object(Data("{}".utf8))
            for (key, value) in pending {
                values.set(key, try value.encoded())
            }
            var root = try Exact.Object(Data("{}".utf8))
            root.set("kind", try Exact.string("vortx.owner-history.local/1"))
            root.set("journalBase64", try Exact.string(journal.encoded().base64EncodedString()))
            root.set("pending", try values.encoded())
            return try root.encoded()
        }
        static func base64(_ value: Data) throws -> Data {
            let text = try JSONDecoder().decode(String.self, from: value)
            guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else {
                throw VortxNativeError.invalidSnapshot
            }
            return bytes
        }
    }

    private let identity = UUID()
    private let scope: VortxAccountScope
    private let store: VortxEncryptedCheckpointStore
    private let abi: any OwnerHistorySessionABI
    private let validation: OwnerHistoryExactSourceValidation
    private var installed: VortxEncryptedCheckpointStore.OwnerHistoryRead
    private var local: Local
    private var localBytes: Data
    private var localWireSources: Data
    private var hostProjection: (document: Data, profileEditResults: Data)
    private var snapshot: Exact.Snapshot
    private var runtime: OwnerHistorySessionRuntime
    private var uncertain = false
    private var closed = false
    private var unconfirmedRetirement = false
    private var retirementResult: Bool?
    private let preservedOwnerUID: String
    var preservedReadUID: String { preservedOwnerUID }

    /// A new coordinator is the ONLY reopen path. A failed writer never clears its own uncertain
    /// flag. Read state, old host fields and journal come from one authenticated encrypted envelope.
    init(scope: VortxAccountScope, target: Target, store: VortxEncryptedCheckpointStore,
         abi: any OwnerHistorySessionABI, canonicalABI: any VortxRuntimeABI,
         sourceAuthority: any VortxMutationAuthority,
         originalRead: VortxEncryptedCheckpointStore.OwnerHistoryRead? = nil,
         initialOwnerReadUID: String? = nil) throws {
        try sourceAuthority.withActive {}
        guard let read = try originalRead ?? store.readOwnerHistory(scope: scope), let host = read.hostPreferences else {
            // Existing native bootstrap owns creating the initial authenticated checkpoint.
            throw VortxNativeError.unavailable
        }
        try sourceAuthority.withActive { try store.requireCurrentOwnerHistory(read, scope: scope) }
        try VortxNativeHostPreferences.validateSealed(host, scope: scope)
        let local = try Local(scope: scope, bytes: read.ownerHistoryLocal)
        let ownerReadUID = try Self.initialReadOwnerUID(stored: read.preservedOwnerUID,
            supplied: initialOwnerReadUID, target: target, scope: scope)
        let validation = OwnerHistoryExactSourceValidation(abi: canonicalABI)
        let verifier = Verifier(scope: scope, target: target, authority: sourceAuthority,
            validation: validation, journal: local.journal, preservedOwnerUID: ownerReadUID, mode: .opening)
        let runtime = try OwnerHistorySessionRuntime(snapshot: read.snapshot, abi: abi, verify: verifier.callback)
        do {
            let fence = try Self.capture(runtime, target: target, verifier: verifier)
            guard let normalized = verifier.normalized else { throw VortxNativeError.invalidSnapshot }
            let original = try Exact.Snapshot(bytes: read.snapshot,
                witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
            let complete = try original.replacingNativeState(normalized,
                witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
            // This component does not silently publish a cold normalization repair that has
            // not been checkpointed. A materially different normalized legacy snapshot needs
            // the real initial-migration transaction and whole-account gate first.
            guard try Exact.canonical(read.snapshot) == Exact.canonical(complete.bytes) else {
                throw VortxNativeError.unavailable
            }
            self.snapshot = complete
            try sourceAuthority.withActive { try store.requireCurrentOwnerHistory(read, scope: scope) }
            self.scope = scope; self.store = store; self.abi = abi; self.validation = validation
            self.installed = read; self.local = local; self.runtime = runtime
            preservedOwnerUID = ownerReadUID
            let encodedLocal = try read.ownerHistoryLocal ?? local.encoded()
            self.localBytes = encodedLocal
            self.localWireSources = try OwnerHistoryAccountExport.sourceCarrier(local: encodedLocal, scope: scope,
                readOwnerUID: ownerReadUID)
            self.hostProjection = try OwnerHistoryAccountExport.hostProjection(host, scope: scope)
        } catch {
            if !runtime.close() {
                FailedRetirements.shared.retain(runtime)
                throw VortxNativeError.checkpointUncertain
            }
            throw error
        }
    }
    /// First typed mount of one authenticated peer. This is pure candidate preparation:
    /// no store/runtime activation or current-clock action. The Session constructor reserves
    /// the existing account writer before the corresponding create-only durable install.
    static func prepareColdPeer(scope: VortxAccountScope, target: Target,
        nativeDocument: Data, localArchive: Data, hostPreferences: Data, preservedOwnerUID: String,
        transaction: OwnerHistoryPreparedExport, canonicalABI: any VortxRuntimeABI,
        sessionABI: any OwnerHistorySessionABI, sourceAuthority: any VortxMutationAuthority) throws -> Checkpoint {
        try scope.validate()
        try sourceAuthority.withActive {}
        // The explicit selector, raw native document and archive must be siblings of
        // this SAME authenticated full-account transaction, not separately supplied data.
        guard Exact.sameText(transaction.scope.account, scope.account),
              Exact.sameText(transaction.scope.ownerProfileID, scope.ownerProfileID),
              let accountNative = transaction.completeAccount.raw("nativeSync"),
              let accountCarrier = transaction.completeAccount.raw(OwnerHistoryAccountExport.archiveKey),
              accountNative == nativeDocument,
              try Self.equal(OwnerHistoryAccountExport.localArchive(from: accountCarrier, scope: scope), localArchive),
              try Exact.sameText(OwnerHistoryAccountExport.readOwnerUID(from: accountCarrier, scope: scope),
                                 preservedOwnerUID) else { throw VortxNativeError.superseded }
        let local = try Local(scope: scope, bytes: localArchive)
        let validator = OwnerHistoryExactSourceValidation(abi: canonicalABI)
        let input = try coldSnapshot(nativeDocument: nativeDocument, scope: scope,
            target: target, preservedOwnerUID: preservedOwnerUID)
        // Full raw replay before the native decoder and inside both native open callbacks.
        try validator.validate(snapshot: input, journal: local.journal,
            scope: scope, authority: sourceAuthority)
        let verifier = Verifier(scope: scope, target: target, authority: sourceAuthority,
            validation: validator, journal: local.journal, preservedOwnerUID: preservedOwnerUID,
            mode: .opening, openingNative: nativeDocument)
        let runtime = try OwnerHistorySessionRuntime(snapshot: input, abi: sessionABI, verify: verifier.callback)
        var retirementAttempted = false
        do {
            let fence = try capture(runtime, target: target, verifier: verifier)
            guard let full = verifier.normalized else { throw VortxNativeError.invalidSnapshot }
            let snapshot = try Exact.Snapshot.conservingColdNativeState(originalNative: nativeDocument, normalizedState: full,
                witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
            let localBytes = try local.encoded()
            let host = try OwnerHistoryAccountExport.hostProjection(hostPreferences, scope: scope)
            var checkpoint = Checkpoint(snapshot: snapshot.bytes, hostPreferences: hostPreferences,
                ownerHistoryLocal: localBytes, scope: scope, nativeSync: try snapshot.nativeSyncBytes,
                hostProjection: host, ownerHistorySources: try OwnerHistoryAccountExport.sourceCarrier(local: localBytes, scope: scope, readOwnerUID: preservedOwnerUID),
                preservedOwnerUID: preservedOwnerUID)
            try transaction.withActive {
                try sourceAuthority.withActive {
                    try transaction.validateCompleteAccount(checkpoint)
                    let base = try transaction.completeAccount(checkpoint)
                    checkpoint = Checkpoint(snapshot: checkpoint.snapshot, hostPreferences: checkpoint.hostPreferences,
                        ownerHistoryLocal: checkpoint.ownerHistoryLocal, scope: scope, nativeSync: checkpoint.nativeSync,
                        hostProjection: host, ownerHistorySources: checkpoint.ownerHistorySources,
                        preservedOwnerUID: preservedOwnerUID, accountBase: base)
                }
            }
            // free() is outside every nonrecursive source/transaction scope. A busy free
            // quarantines the handle and returns no installable checkpoint.
            retirementAttempted = true
            guard runtime.close() else {
                FailedRetirements.shared.retain(runtime)
                throw VortxNativeError.checkpointUncertain
            }
            try transaction.withActive { try sourceAuthority.withActive {} }
            return checkpoint
        } catch {
            if !retirementAttempted {
                retirementAttempted = true
                if !runtime.close() {
                    FailedRetirements.shared.retain(runtime)
                    throw VortxNativeError.checkpointUncertain
                }
            }
            throw error
        }
    }

    /// Pure construction of the actual kernel snapshot shape, not a replacement runtime.
    /// Native open validates the owner roster BEFORE it applies nativeSync. Preserve each
    /// exact encrypted-account profile and the whole native document; do not invent an owner.
    /// A cloud first mount starts at that explicit owner. Later profile selection is Session-owned.
    static func coldSnapshot(nativeDocument: Data, scope: VortxAccountScope, target: Target,
                             preservedOwnerUID: String) throws -> Data {
        try scope.validate()
        try OwnerHistoryAccountExport.validateReadOwnerUID(preservedOwnerUID)
        guard target.profileID.uuidString == scope.ownerProfileID,
              Exact.sameText(target.verifiedUID, preservedOwnerUID) else { throw VortxNativeError.superseded }
        let native = try Exact.Object(nativeDocument)
        guard try Exact.sameText(native.text("scope"), scope.account),
              try Exact.sameText(native.text("ownerProfileId"), scope.ownerProfileID),
              try native.required("schemaVersion") == Data("6".utf8),
              native["ownerHistory"] != nil else { throw VortxNativeError.invalidSnapshot }
        let profiles = try Exact.Object(native.required("profiles"))
        var rosterProfiles = try Exact.Object(Data("{}".utf8))
        for (id, record) in profiles.fields {
            let profileBytes = try Exact.Object(record).required("profile")
            let profile = try Exact.Object(profileBytes)
            guard try Exact.sameText(profile.text("id"), id) else { throw VortxNativeError.invalidSnapshot }
            rosterProfiles.set(id, profileBytes)
        }
        let owner = try Exact.Object(rosterProfiles.required(scope.ownerProfileID))
        guard try owner.required("owner") == Data("true".utf8),
              owner["deleted"] == nil || owner["deleted"] == Data("false".utf8) else {
            throw VortxNativeError.invalidSnapshot
        }
        var roster = try Exact.Object(Data("{}".utf8))
        roster.set("profiles", try rosterProfiles.encoded())
        var input = try Exact.Object(Data("{}".utf8))
        input.set("roster", try roster.encoded())
        input.set("activeProfileId", try Exact.string(target.profileID.uuidString))
        input.set("nativeSync", nativeDocument)
        return try input.encoded()
    }

    /// An encrypted installed selector wins; a warm caller may supply only its original
    /// authenticated owner source. A child Own credential is never an owner-UID fallback.
    static func initialReadOwnerUID(stored: String?, supplied: String?, target: Target,
                                    scope: VortxAccountScope) throws -> String {
        try scope.validate()
        if let stored, let supplied, !Exact.sameText(stored, supplied) {
            throw VortxNativeError.superseded
        }
        let value: String
        if let retained = stored ?? supplied { value = retained }
        else {
            guard target.profileID.uuidString == scope.ownerProfileID else { throw VortxNativeError.unavailable }
            value = target.verifiedUID
        }
        try OwnerHistoryAccountExport.validateReadOwnerUID(value)
        return value
    }

    @discardableResult func close() -> Bool {
        if let retirementResult { return retirementResult && !unconfirmedRetirement }
        closed = true
        let retiredCurrent = retireOwnedRuntime(runtime)
        let result = retiredCurrent && !unconfirmedRetirement
        retirementResult = result
        return result
    }
    /// Session-owned health only; does not capture authority, retry free or reopen.
    var requiresAuthenticatedReopen: Bool {
        closed || uncertain || unconfirmedRetirement
    }
    /// Any orphaned predecessor/fork belongs to this account writer, not just the
    /// currently installed handle. A later successful current free cannot clear it.
    @discardableResult private func retireOwnedRuntime(_ value: OwnerHistorySessionRuntime) -> Bool {
        let result = value.close()
        if !result {
            unconfirmedRetirement = true
            uncertain = true
            FailedRetirements.shared.retain(value)
        }
        return result
    }
    private final class FailedRetirements: @unchecked Sendable {
        static let shared = FailedRetirements()
        private let lock = NSLock()
        private var values: [OwnerHistorySessionRuntime] = []
        func retain(_ value: OwnerHistorySessionRuntime) { lock.withLock { values.append(value) } }
    }
    func acknowledgedLocalSource(capture: Capture) throws -> Data? {
        var value: Data?
        try withCurrentCheckpoint(capture: capture) { value = installed.ownerHistoryLocal }
        return value
    }
    /// UI copies are disposable; their decoder must never become a checkpoint writer.
    func acknowledgedSnapshot() throws -> Data { try requireUsable(); return snapshot.bytes }
    func presentationSnapshot() throws -> Data { try requireUsable(); return try snapshot.presentationBytes }
    func acknowledgedHost() throws -> Data {
        try requireUsable()
        guard let host = installed.hostPreferences else { throw VortxNativeError.invalidSnapshot }
        return host
    }
    func acknowledgedAccountBase(capture: Capture) throws -> Data {
        try requireCapture(capture)
        guard let base = installed.ownerHistoryAccountBase else { throw VortxNativeError.unavailable }
        return base
    }

    /// Only the owning Session exposes this immutable raw value. It is not a VortxJSON
    /// persistence carrier and must not be reconstructed from a presentation DTO.
    func checkpoint(capture: Capture) throws -> Checkpoint {
        try requireCapture(capture)
        try capture.withReadAuthority {}
        let value = try Checkpoint(snapshot: snapshot.bytes, hostPreferences: installed.hostPreferences!,
            ownerHistoryLocal: localBytes, scope: scope, nativeSync: snapshot.nativeSyncBytes,
            hostProjection: hostProjection, ownerHistorySources: localWireSources,
            preservedOwnerUID: preservedOwnerUID, accountBase: installed.ownerHistoryAccountBase)
        try capture.withReadAuthority {}
        return value
    }
    /// Used only for the Session's final warm ownership transfer. The caller's real
    /// complete-account witness encloses this original-source/CAS boundary.
    func withCurrentCheckpoint(capture: Capture, _ operation: () throws -> Void) throws {
        try capture.sourceAuthority.withActive {
            try requireCaptureWithoutAuthority(capture)
            try store.requireCurrentOwnerHistory(installed, scope: scope)
            try operation()
        }
    }
    private func requireUsable() throws {
        guard !closed else { throw VortxNativeError.closed }
        guard !uncertain, !unconfirmedRetirement else { throw VortxNativeError.checkpointUncertain }
        try Task.checkCancellation()
    }
    private func requireCapture(_ capture: Capture) throws {
        try requireUsable()
        guard capture.coordinator == identity, capture.runtime == runtime.identity,
              try Self.sameRuntimeFence(capture.fence, snapshot.fence) else { throw VortxNativeError.superseded }
        try capture.sourceAuthority.withActive {}
    }

    /// Facade calls under its ORIGINAL read queue head before any provider await. Every later
    /// mutation method also requires the admitted transaction's own queue-head authority.
    func capture(target: Target, sourceAuthority: any VortxMutationAuthority,
                 queueAuthority: any VortxMutationAuthority) throws -> Capture {
        try requireUsable()
        let combined = PairAuthority(first: sourceAuthority, second: queueAuthority)
        let verifier = Verifier(scope: scope, target: target, authority: combined,
            validation: validation, journal: local.journal, preservedOwnerUID: preservedOwnerUID, mode: .retarget(snapshot.fence))
        let fence = try Self.capture(runtime, target: target, verifier: verifier)
        try combined.withActive {}
        snapshot = try snapshot.retargeting(fence: fence)
        return Capture(target: target, fence: fence, coordinator: identity, runtime: runtime.identity,
                       sourceAuthority: sourceAuthority, queueAuthority: queueAuthority)
    }

    /// Retains the original complete pending candidate without importing or issuing a native
    /// receipt. This is an actual same-envelope checkpoint, with the same budget/CAS/final guards.
    func retainPending(_ bound: BoundOutcome,
                       transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Checkpoint {
        let capture = bound.capture
        guard case .pending(let pending) = bound.outcome else { throw VortxNativeError.invalidResponse }
        try requireCapture(capture)
        try match(pending.frame, capture: capture)
        var next = local
        let key = OwnerHistoryPendingRecord.digest(pending.archiveCandidate)
        let binding = try Exact.Object(capture.fence).required("binding")
        let record = try Local.PendingRecord(archive: pending.archiveCandidate, binding: binding)
        if let retained = next.pending[key] {
            try retained.requireSame(as: record)
        } else {
            next.pending[key] = record
        }
        let nextBytes = try next.encoded()
        let nextWire = try OwnerHistoryAccountExport.sourceCarrier(local: nextBytes, scope: scope, readOwnerUID: preservedOwnerUID)
        var candidate = Checkpoint(snapshot: snapshot.bytes,
            hostPreferences: installed.hostPreferences!, ownerHistoryLocal: nextBytes, scope: scope,
            nativeSync: try snapshot.nativeSyncBytes, hostProjection: hostProjection, ownerHistorySources: nextWire, preservedOwnerUID: preservedOwnerUID)
        var started = false
        do {
            try transaction.withActive {
                try capture.sourceAuthority.withActive {
                    try requireCaptureWithoutAuthority(capture)
                    try transaction.validateCompleteAccount(candidate)
                    candidate = try bindingAccountBase(candidate, transaction: transaction)
                    try Task.checkCancellation()
                    started = true
                    installed = try store.commitOwnerHistory(candidate, expected: installed, scope: scope)
                    local = next; localBytes = candidate.ownerHistoryLocal
                    localWireSources = nextWire
                }
            }
            return candidate
        } catch {
            if started { uncertain = true; throw VortxNativeError.checkpointUncertain }
            throw error
        }
    }

    /// Cold source change: replay exact archive -> Rust receipt -> isolated import -> full native
    /// checkpoint -> same encrypted envelope -> native accept. No historical actions use `now`.
    func importPrepared(_ bound: BoundOutcome,
                        transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> DurableImport {
        let capture = bound.capture
        guard case .prepared(let prepared) = bound.outcome else { throw VortxNativeError.invalidResponse }
        try requireCapture(capture); try match(prepared.frame, capture: capture)
        let replay = try capture.readAuthority.replay(archive: prepared.archive,
            scope: scope.account, ownerProfileID: prepared.frame.ownerProfileID,
            profileID: capture.target.profileID, verifiedUID: capture.target.verifiedUID)
        let canonical = try validation.canonicalize(replay.evidence)
        var next = local
        next.journal = try local.journal.retaining(replay,
            nativeReceipt: JSONDecoder().decode(VortxJSON.self, from: canonical.receipt),
            capturedBinding: JSONDecoder().decode(VortxJSON.self, from: Exact.Object(capture.fence).required("binding")))
        let authority = PairAuthority(first: capture.sourceAuthority, second: transaction)
        let parentVerifier = Verifier(scope: scope, target: capture.target, authority: authority,
            validation: validation, journal: local.journal, preservedOwnerUID: preservedOwnerUID, mode: .fixed(capture.fence, nil))
        let candidate = try runtime.fork(fence: capture.fence, verify: parentVerifier.callback)
        var published = false
        defer { if !published { retireOwnedRuntime(candidate) } }
        let verifier = Verifier(scope: scope, target: capture.target, authority: authority,
            validation: validation, journal: next.journal, preservedOwnerUID: preservedOwnerUID, mode: .fork(capture.fence))
        var fence = try Self.capture(candidate, target: verifier.boundTarget, verifier: verifier)
        let result = try candidate.request(Self.request("import", fence: fence, extra: ["evidence": replay.evidence]),
            verify: verifier.callback)
        let imported = try Exact.Object(result)
        guard try imported.text("kind") == "source_candidate",
              try Self.equal(imported.required("receipt"), canonical.receipt) else { throw VortxNativeError.invalidResponse }
        try verifier.advance(imported, from: fence, requiresFull: true)
        fence = try Self.capture(candidate, target: verifier.boundTarget, verifier: verifier)
        let response = try Exact.Object(candidate.request(Self.request("checkpoint", fence: fence), verify: verifier.callback))
        guard try response.text("kind") == "checkpoint",
              try Self.equal(response.required("fence"), fence),
              try response.required("durableAck") == Data("false".utf8),
              try response.required("requiresCompleteArchiveEnvelope") == Data("true".utf8) else {
            throw VortxNativeError.invalidResponse
        }
        let complete = try snapshot.replacingNativeState(response.required("state"),
            witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
        // Full correspondence was validated inside this import's own callback. The checkpoint
        // must be the exact full candidate from that callback, not another source generation.
        guard let full = verifier.normalized, try Self.equal(full, response.required("state")) else {
            throw VortxNativeError.invalidSnapshot
        }
        let nextBytes = try next.encoded()
        let checkpoint = try persistAndAccept(candidate, snapshot: complete, local: next, capture: capture, localBytes: nextBytes,
            wireSources: OwnerHistoryAccountExport.sourceCarrier(local: nextBytes, scope: scope, readOwnerUID: preservedOwnerUID),
            transaction: transaction, verifier: verifier)
        published = true
        return .init(receipt: canonical.receipt, fence: fence, checkpoint: checkpoint)
    }

    /// Actual normal actions use delta checkpoints. Native-identified cold source/binding
    /// transitions use full checkpoints. Generic native merge is not a peer route.
    func dispatch(_ actions: [Data], nowUnixSeconds: UInt64, capture: Capture,
                  hostPreferences: Data? = nil,
                  transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Data {
        try requireCapture(capture)
        let authority = PairAuthority(first: capture.sourceAuthority, second: transaction)
        let parentVerifier = Verifier(scope: scope, target: capture.target, authority: authority,
            validation: validation, journal: local.journal, preservedOwnerUID: preservedOwnerUID, mode: .fixed(capture.fence, nil))
        let candidate = try runtime.fork(fence: capture.fence, verify: parentVerifier.callback)
        var published = false
        defer { if !published { retireOwnedRuntime(candidate) } }
        let verifier = Verifier(scope: scope, target: capture.target, authority: authority,
            validation: validation, journal: local.journal, preservedOwnerUID: preservedOwnerUID, mode: .fork(capture.fence))
        var fence = try Self.capture(candidate, target: verifier.boundTarget, verifier: verifier)
        var array = Data("[".utf8)
        for (i, action) in actions.enumerated() {
            _ = try Exact.Object(action)
            if i != 0 { array.append(44) }; array.append(action)
        }
        array.append(93)
        let response = try candidate.request(Self.request("dispatch", fence: fence, extra: ["actions": array]),
            now: nowUnixSeconds, verify: verifier.callback)
        let result = try Exact.Object(response)
        guard try result.text("kind") == "dispatched" else { throw VortxNativeError.invalidResponse }
        let cold = verifier.normalized != nil
        try verifier.advance(result, from: fence, requiresFull: cold)
        fence = try Self.capture(candidate, target: verifier.boundTarget, verifier: verifier)
        let complete: Exact.Snapshot
        if cold {
            let response = try Exact.Object(candidate.request(Self.request("checkpoint", fence: fence), verify: verifier.callback))
            guard try response.text("kind") == "checkpoint",
                  try Self.equal(response.required("fence"), fence),
                  try response.required("durableAck") == Data("false".utf8),
                  try response.required("requiresCompleteArchiveEnvelope") == Data("true".utf8),
                  let full = verifier.normalized,
                  try Self.equal(full, response.required("state")) else { throw VortxNativeError.invalidSnapshot }
            complete = try snapshot.replacingNativeState(full,
                witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
        } else {
            let delta = try candidate.request(Self.request("checkpoint_delta", fence: fence), verify: verifier.callback)
            complete = try snapshot.applying(checkpoint: delta)
        }
        _ = try persistAndAccept(candidate, snapshot: complete, local: local, capture: capture,
            localBytes: localBytes, wireSources: localWireSources, hostPreferences: hostPreferences,
            transaction: transaction, verifier: verifier)
        published = true
        return try result.required("events")
    }

    /// Rebinds only a producer value already paired with this exact original acknowledged
    /// read. The Session validates its private bundle/CAS before invoking this method.
    func bind(_ outcome: VortxNativeOwnerHistoryPreparation.Outcome,
              source: VortxNativeOwnerHistorySource.Capture, capture: Capture) throws -> BoundOutcome {
        try requireCapture(capture)
        guard source.matches(snapshotData: snapshot.bytes) else { throw VortxNativeError.superseded }
        let frame: VortxNativeOwnerHistoryPreparation.Frame
        switch outcome { case .prepared(let value): frame = value.frame; case .pending(let value): frame = value.frame }
        try match(frame, capture: capture)
        let fields = try Exact.Object(capture.fence)
        guard source.profileID == capture.target.profileID,
              Exact.sameText(source.verifiedUID, capture.target.verifiedUID),
              try Self.equal(source.accountBindingBytes, fields.required("binding")) else {
            throw VortxNativeError.superseded
        }
        return BoundOutcome(capture: capture, outcome: outcome)
    }

    /// Host-only edits do not forge a native no-op, generation, receipt, fork or accept.
    /// Same real member/source/full-account/provider/CAS ordering; runtime stays accepted.
    func commitHost(_ host: Data, capture: Capture,
                    transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Checkpoint {
        try requireCapture(capture)
        let projection = try OwnerHistoryAccountExport.hostProjection(host, scope: scope)
        var checkpoint = Checkpoint(snapshot: snapshot.bytes, hostPreferences: host,
            ownerHistoryLocal: localBytes, scope: scope, nativeSync: try snapshot.nativeSyncBytes,
            hostProjection: projection, ownerHistorySources: localWireSources,
            preservedOwnerUID: preservedOwnerUID, accountBase: installed.ownerHistoryAccountBase)
        var started = false
        do {
            try transaction.withActive {
                try capture.sourceAuthority.withActive {
                    try requireCaptureWithoutAuthority(capture)
                    try transaction.validateCompleteAccount(checkpoint)
                    checkpoint = try bindingAccountBase(checkpoint, transaction: transaction)
                    try Task.checkCancellation()
                    started = true
                    installed = try store.commitOwnerHistory(checkpoint, expected: installed, scope: scope)
                    hostProjection = projection
                }
            }
            return checkpoint
        } catch {
            if started { uncertain = true; throw VortxNativeError.checkpointUncertain }
            throw error
        }
    }

    /// Stage authenticated raw peer+immutable archive union for the SAME existing host
    /// policy transaction. No disk/native accept occurs until Session also stages host/events.
    func peerCandidate(nativeDocument: Data, localArchive: Data, peerCapabilities: Data,
        capture: Capture, transaction: OwnerHistoryPreparedExport) throws -> Candidate {
        try requireCapture(capture)
        let peerLocal = try Local(scope: scope, bytes: localArchive)
        var next = local
        next.journal = try local.journal.joining(peerLocal.journal)
        for (digest, record) in peerLocal.pending {
            if let existing = next.pending[digest] { try existing.requireSame(as: record) }
            else { next.pending[digest] = record }
        }
        let authority = PairAuthority(first: capture.sourceAuthority, second: transaction)
        var peerSnapshot = try Exact.Object(Data("{}".utf8)); peerSnapshot.set("nativeSync", nativeDocument)
        try validation.validate(snapshot: peerSnapshot.encoded(), journal: peerLocal.journal,
            scope: scope, authority: authority)
        let candidate = try Candidate(owner: self, capture: capture, transaction: transaction,
            local: next, peer: .init(document: nativeDocument, capabilities: peerCapabilities))
        let result = try Exact.Object(candidate.native.request(Self.request("merge", fence: candidate.fence,
            extra: ["document": nativeDocument, "peer": peerCapabilities]), verify: candidate.verifier.callback))
        guard try result.text("kind") == "source_candidate" else { throw VortxNativeError.invalidResponse }
        try candidate.verifier.advance(result, from: candidate.fence, requiresFull: true)
        candidate.fence = try Self.capture(candidate.native, target: candidate.verifier.boundTarget, verifier: candidate.verifier)
        let response = try Exact.Object(candidate.native.request(Self.request("checkpoint", fence: candidate.fence),
            verify: candidate.verifier.callback))
        guard try response.text("kind") == "checkpoint",
              try Self.equal(response.required("fence"), candidate.fence),
              try response.required("durableAck") == Data("false".utf8),
              try response.required("requiresCompleteArchiveEnvelope") == Data("true".utf8),
              let full = candidate.verifier.normalized, try Self.equal(full, response.required("state")) else {
            throw VortxNativeError.invalidSnapshot
        }
        candidate.snapshot = try snapshot.replacingNativeState(full,
            witnessID: Exact.Object(candidate.fence).text("sourceSetWitnessId"), fence: candidate.fence)
        candidate.sourceChanged = true; candidate.peer = .init(document: nativeDocument, capabilities: peerCapabilities)
        candidate.peerArchive = localArchive
        return candidate
    }

    /// A real isolated native candidate owned by the existing Session actor. This adapter
    /// exists so the SAME current host/website policy can stage trials, not to create a writer.
    /// Copies re-fork the actual accepted parent and replay only this transaction's current
    /// actions with their original supplied times; never historical owner-source actions.
    final class Candidate {
        fileprivate unowned let owner: OwnerHistorySessionCoordinator
        fileprivate let capture: Capture
        fileprivate let transaction: any OwnerHistoryCompleteCheckpointAuthority
        fileprivate let native: OwnerHistorySessionRuntime
        fileprivate let verifier: Verifier
        fileprivate let base: Exact.Snapshot
        fileprivate var snapshot: Exact.Snapshot
        fileprivate var fence: Data
        fileprivate var actions: [(String, UInt64)] = []
        fileprivate var sourceChanged = false
        fileprivate var accepted = false
        private var retirementResult: Bool?
        fileprivate let nextLocal: Local
        fileprivate var peer: Verifier.Peer?
        fileprivate var peerArchive: Data?
        fileprivate init(owner: OwnerHistorySessionCoordinator, capture: Capture,
                         transaction: any OwnerHistoryCompleteCheckpointAuthority,
                         local: Local? = nil, peer: Verifier.Peer? = nil) throws {
            try owner.requireCapture(capture)
            self.owner = owner; self.capture = capture; self.transaction = transaction
            nextLocal = local ?? owner.local; self.peer = peer
            base = try owner.snapshot.retargeting(fence: capture.fence); snapshot = base
            let authority = PairAuthority(first: capture.sourceAuthority, second: transaction)
            let parent = Verifier(scope: owner.scope, target: capture.target, authority: authority,
                validation: owner.validation, journal: owner.local.journal, preservedOwnerUID: owner.preservedOwnerUID, mode: .fixed(capture.fence, nil))
            native = try owner.runtime.fork(fence: capture.fence, verify: parent.callback)
            verifier = Verifier(scope: owner.scope, target: capture.target, authority: authority,
                validation: owner.validation, journal: nextLocal.journal, preservedOwnerUID: owner.preservedOwnerUID, mode: .fork(capture.fence), peer: peer)
            do {
                fence = try OwnerHistorySessionCoordinator.capture(native, target: verifier.boundTarget, verifier: verifier)
            } catch {
                guard owner.retireOwnedRuntime(native) else { throw VortxNativeError.checkpointUncertain }
                throw error
            }
        }
        deinit { _ = close() }
        @discardableResult func close() -> Bool {
            guard !accepted else { return true }
            if let retirementResult { return retirementResult }
            let closed = owner.retireOwnedRuntime(native)
            retirementResult = closed
            return closed
        }
        func copy() throws -> Candidate {
            let next: Candidate
            if let peer {
                guard let transaction = transaction as? OwnerHistoryPreparedExport, let peerArchive else { throw VortxNativeError.invalidResponse }
                next = try owner.peerCandidate(nativeDocument: peer.document,
                    localArchive: peerArchive, peerCapabilities: peer.capabilities,
                    capture: capture, transaction: transaction)
            } else { next = try Candidate(owner: owner, capture: capture, transaction: transaction) }
            for (action, time) in actions { _ = try next.dispatch(action, now: time) }
            return next
        }
        func stateJSON() throws -> String {
            guard let text = String(data: try snapshot.presentationBytes, encoding: .utf8) else { throw VortxNativeError.invalidSnapshot }
            return text
        }
        /// Native emits complete dirty-since-parent deltas, so each refresh applies to the
        /// retained original base, not a freshly parsed full snapshot or the preceding delta.
        func dispatch(_ action: String, now: UInt64) throws -> String {
            try owner.requireCapture(capture)
            guard actions.isEmpty || verifier.boundTarget.profileID == capture.target.profileID else {
                throw VortxNativeError.superseded
            }
            let raw = Data(action.utf8); _ = try Exact.Object(raw)
            var array = Data("[".utf8); array.append(raw); array.append(93)
            let beforeFull = verifier.fullVersion
            let reply = try Exact.Object(native.request(OwnerHistorySessionCoordinator.request("dispatch",
                fence: fence, extra: ["actions": array]), now: now, verify: verifier.callback))
            if try reply.text("kind") == "action_rejected" {
                // Only the native reducer's explicit atomic rejection is compatible with
                // import -> reconcile -> held. Parse/fence/authority errors remain throws.
                guard Set(reply.fields.keys) == ["kind", "fence", "preparedAgainst", "reason", "durableAck", "advertise"],
                      try reply.text("reason") == "native_action_rejected",
                      try OwnerHistorySessionCoordinator.equal(reply.required("fence"), fence),
                      try OwnerHistorySessionCoordinator.equal(reply.required("preparedAgainst"), capture.fence),
                      try reply.required("durableAck") == Data("false".utf8),
                      try reply.required("advertise") == Data("false".utf8),
                      verifier.fullVersion == beforeFull else { throw VortxNativeError.invalidResponse }
                try owner.requireCapture(capture)
                var rejected = try Exact.Object(Data("{}".utf8))
                rejected.set("ok", Data("false".utf8))
                rejected.set("error", try Exact.string("native action rejected"))
                // Do not advance verifier/fence, checkpoint, snapshot or accepted actions.
                return String(decoding: try rejected.encoded(), as: UTF8.self)
            }
            guard try reply.text("kind") == "dispatched" else { throw VortxNativeError.invalidResponse }
            let cold = verifier.fullVersion != beforeFull
            try verifier.advance(reply, from: fence, requiresFull: cold)
            fence = try OwnerHistorySessionCoordinator.capture(native, target: verifier.boundTarget, verifier: verifier)
            sourceChanged = sourceChanged || cold
            if sourceChanged {
                let full = try Exact.Object(native.request(OwnerHistorySessionCoordinator.request("checkpoint",
                    fence: fence), verify: verifier.callback))
                guard try full.text("kind") == "checkpoint",
                      try OwnerHistorySessionCoordinator.equal(full.required("fence"), fence),
                      try full.required("requiresCompleteArchiveEnvelope") == Data("true".utf8),
                      try full.required("durableAck") == Data("false".utf8),
                      let validated = verifier.normalized else { throw VortxNativeError.invalidSnapshot }
                if cold {
                    guard try OwnerHistorySessionCoordinator.equal(validated, full.required("state")) else {
                        throw VortxNativeError.invalidSnapshot
                    }
                } else {
                    let expected = try Exact.Object(Exact.Object(validated).required("nativeSync"))
                    let actual = try Exact.Object(Exact.Object(full.required("state")).required("nativeSync"))
                    guard expected["ownerHistory"] == actual["ownerHistory"] else { throw VortxNativeError.invalidSnapshot }
                }
                snapshot = try base.replacingNativeState(full.required("state"),
                    witnessID: Exact.Object(fence).text("sourceSetWitnessId"), fence: fence)
            } else {
                let delta = try native.request(OwnerHistorySessionCoordinator.request("checkpoint_delta",
                    fence: fence), verify: verifier.callback)
                snapshot = try base.applying(checkpoint: delta)
            }
            actions.append((action, now))
            var response = try Exact.Object(Data("{}".utf8))
            response.set("ok", Data("true".utf8)); response.set("events", try reply.required("events"))
            return String(decoding: try response.encoded(), as: UTF8.self)
        }
        /// Only the private staged add-on-inventory inspection API; never a public read.
        func resolve(_ query: String) throws -> String {
            let input = Data(query.utf8), fields = try Exact.Object(input)
            guard try fields.text("kind") == "installed_addons" else { throw VortxNativeError.invalidResponse }
            let reply = try Exact.Object(native.request(OwnerHistorySessionCoordinator.request("resolve_candidate",
                fence: fence, extra: ["request": input]), verify: verifier.callback))
            guard try reply.text("kind") == "resolved_candidate",
                  try reply.required("advertise") == Data("false".utf8),
                  try reply.required("durableAck") == Data("false".utf8),
                  try OwnerHistorySessionCoordinator.equal(reply.required("fence"), fence) else {
                throw VortxNativeError.invalidResponse
            }
            return String(decoding: try reply.required("result"), as: UTF8.self)
        }
    }
    func candidate(capture: Capture, transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Candidate {
        try Candidate(owner: self, capture: capture, transaction: transaction)
    }
    func commit(_ candidate: Candidate, hostPreferences: Data,
                transaction: any OwnerHistoryCompleteCheckpointAuthority) throws -> Checkpoint {
        guard candidate.owner === self else { throw VortxNativeError.superseded }
        try requireCapture(candidate.capture)
        if candidate.actions.isEmpty && candidate.peer == nil {
            return try commitHost(hostPreferences, capture: candidate.capture, transaction: transaction)
        }
        let nextBytes = try candidate.peer == nil ? localBytes : candidate.nextLocal.encoded()
        let nextWire = try candidate.peer == nil ? localWireSources
            : OwnerHistoryAccountExport.sourceCarrier(local: nextBytes, scope: scope, readOwnerUID: preservedOwnerUID)
        let result = try persistAndAccept(candidate.native, snapshot: candidate.snapshot, local: candidate.nextLocal,
            capture: candidate.capture, localBytes: nextBytes, wireSources: nextWire,
            hostPreferences: hostPreferences, transaction: transaction, verifier: candidate.verifier)
        candidate.accepted = true
        return result
    }

    func read(kind: String, capture: Capture,
              extra: [String: Data] = [:]) throws -> Data {
        try requireCapture(capture)
        try capture.withReadAuthority {}
        guard ["lookup", "view", "resolve"].contains(kind) else { throw VortxNativeError.invalidResponse }
        let authority = PairAuthority(first: capture.sourceAuthority, second: capture.queueAuthority)
        let verifier = Verifier(scope: scope, target: capture.target, authority: authority,
            validation: validation, journal: local.journal, preservedOwnerUID: preservedOwnerUID, mode: .fixed(capture.fence, nil))
        let result = try runtime.request(Self.request(kind, fence: capture.fence, extra: extra), verify: verifier.callback)
        try authority.withActive {}
        try capture.withReadAuthority {}
        return result
    }

    /// The actual #269 authority encloses lease -> original read/FIFO -> draft -> generation.
    /// Do not re-enter those nonrecursive locks from native's synchronous lease callback.
    /// This lexical verifier is constructed here only around that real authority operation.
    func atomicResolve(_ request: Data, capture: Capture,
                       authority: any VortxMutationAuthority) throws -> Data {
        try requireCapture(capture)
        var result: Data?
        try authority.withActive {
            try requireCaptureWithoutAuthority(capture)
            let fence = capture.fence
            let verify: OwnerHistorySessionRuntime.Verify = { bytes in
                let wrapper = try Exact.Object(bytes), check = try Exact.Object(wrapper.required("check"))
                guard try wrapper.text("kind") == "lease",
                      try check.text("contract") == "vortx.owner-history-session-lease/1",
                      try check.text("purpose") == "resolve",
                      try check.required("preparedAgainst") == Data("null".utf8),
                      try OwnerHistorySessionCoordinator.equal(check.required("fence"), fence) else {
                    throw VortxNativeError.superseded
                }
            }
            let reply = try Exact.Object(runtime.request(Self.request("resolve", fence: fence,
                extra: ["request": request]), verify: verify))
            guard try reply.text("kind") == "resolved", try Self.equal(reply.required("fence"), fence) else {
                throw VortxNativeError.invalidResponse
            }
            result = try reply.required("result")
        }
        try capture.withReadAuthority {}
        guard let result else { throw VortxNativeError.invalidResponse }
        return result
    }

    /// Explicit recovery query, not an ordinary progress/render path. Returning these bytes does
    /// not make them Prepared; the producer must resume them using the original archived registry
    /// locators and perform its full synchronous/async validation before submitting an import.
    func pendingArchives(capture: Capture) throws -> [PendingResume] {
        try requireCapture(capture)
        try capture.withReadAuthority {}
        let binding = try Exact.Object(capture.fence).required("binding")
        let archives = try local.pending.keys.sorted().compactMap { key -> PendingResume? in
            let record = local.pending[key]!
            // Rebind-away-and-back to the same UID still has a different typed revision/tx.
            // Keep the original bytes in the journal, but never expose them for that new binding.
            guard try record.matches(binding: binding) else { return nil }
            let archive = record.archive
            let object = try Exact.Object(archive)
            let frame = try Exact.Object(Local.base64(object.required("sourceDocumentBase64")))
            guard try frame.text("profileId") == capture.target.profileID.uuidString,
                  try Exact.sameText(frame.text("verifiedStreamingUid"), capture.target.verifiedUID) else { return nil }
            return PendingResume(capture: capture, archive: archive, scope: scope)
        }
        try capture.withReadAuthority {}
        return archives
    }

    private func persistAndAccept(_ candidate: OwnerHistorySessionRuntime, snapshot next: Exact.Snapshot,
                                  local nextLocal: Local, capture: Capture,
                                  localBytes nextLocalBytes: Data,
                                  wireSources nextWireSources: Data, hostPreferences nextHost: Data? = nil,
                                  transaction: any OwnerHistoryCompleteCheckpointAuthority,
                                  verifier: Verifier) throws -> Checkpoint {
        let host = try nextHost ?? acknowledgedHost()
        let projection = try nextHost.map { try OwnerHistoryAccountExport.hostProjection($0, scope: scope) } ?? hostProjection
        var checkpoint = Checkpoint(snapshot: next.bytes, hostPreferences: host,
            ownerHistoryLocal: nextLocalBytes, scope: scope, nativeSync: try next.nativeSyncBytes,
            hostProjection: projection, ownerHistorySources: nextWireSources, preservedOwnerUID: preservedOwnerUID)
        var started = false
        var retired: OwnerHistorySessionRuntime?
        do {
            try transaction.withActive {
                try capture.sourceAuthority.withActive {
                    try requireCaptureWithoutAuthority(capture)
                    try transaction.validateCompleteAccount(checkpoint)
                    checkpoint = try bindingAccountBase(checkpoint, transaction: transaction)
                    try Task.checkCancellation()
                    started = true
                    let readback = try store.commitOwnerHistory(checkpoint, expected: installed, scope: scope)
                    // This lexical, private final verifier is created ONLY after real readback.
                    // It does not re-enter the already-held authority locks. The enclosing
                    // transaction and original-source locks remain held through accept + swap.
                    let finalVerifier = verifier.durableAccept(fence: next.fence, parent: capture.fence)
                    let accepted = try Exact.Object(candidate.request(Self.request("accept", fence: next.fence),
                        verify: finalVerifier))
                    guard try accepted.text("kind") == "accepted",
                          try Self.equal(accepted.required("fence"), next.fence),
                          try accepted.required("durableAck") == Data("false".utf8) else {
                        throw VortxNativeError.invalidResponse
                    }
                    retired = runtime
                    runtime = candidate; snapshot = next; local = nextLocal
                    localBytes = nextLocalBytes; installed = readback
                    localWireSources = nextWireSources; hostProjection = projection
                }
            }
            // free() can re-enter the original source; all nonrecursive authority scopes
            // have exited. Busy retirement is quarantined for process lifetime, never retried.
            let previous = retired; retired = nil
            if let previous, !retireOwnedRuntime(previous) {
                throw VortxNativeError.checkpointUncertain
            }
            try capture.sourceAuthority.withActive {}
            return checkpoint
        } catch {
            if let retired { retireOwnedRuntime(retired) }
            if started { uncertain = true; throw VortxNativeError.checkpointUncertain }
            throw error
        }
    }
    private func requireCaptureWithoutAuthority(_ capture: Capture) throws {
        try requireUsable()
        guard capture.coordinator == identity, capture.runtime == runtime.identity,
              try Self.sameRuntimeFence(capture.fence, snapshot.fence) else { throw VortxNativeError.superseded }
    }
    private func match(_ frame: VortxNativeOwnerHistoryPreparation.Frame, capture: Capture) throws {
        guard Exact.sameText(frame.scope, scope.account), frame.ownerProfileID.uuidString == scope.ownerProfileID,
              frame.profileID == capture.target.profileID,
              Exact.sameText(frame.verifiedUID, capture.target.verifiedUID) else { throw VortxNativeError.superseded }
    }
    private static func capture(_ runtime: OwnerHistorySessionRuntime, target: Target, verifier: Verifier) throws -> Data {
        let reply = try Exact.Object(runtime.request(request("capture", extra: [
            "profileId": Exact.string(target.profileID.uuidString), "authenticatedUid": Exact.string(target.verifiedUID)
        ]), verify: verifier.callback))
        let fence = try reply.required("fence")
        guard try reply.text("kind") == "capture", try reply.required("advertise") == Data("false".utf8),
              let bound = verifier.boundFence, try equal(bound, fence) else { throw VortxNativeError.invalidResponse }
        return fence
    }
    private static func request(_ kind: String, fence: Data? = nil, extra: [String: Data] = [:]) throws -> Data {
        var object = try Exact.Object(Data("{}".utf8))
        object.set("kind", try Exact.string(kind))
        if let fence { object.set("fence", fence) }
        guard extra["kind"] == nil, extra["fence"] == nil else { throw VortxNativeError.invalidResponse }
        for (key, value) in extra { object.set(key, value) }
        return try object.encoded()
    }
    private static func sameRuntimeFence(_ left: Data, _ right: Data) throws -> Bool {
        var lhs = try Exact.Object(left), rhs = try Exact.Object(right)
        for key in ["profileId", "verifiedStreamingUid", "binding"] { lhs.remove(key); rhs.remove(key) }
        return try equal(lhs.encoded(), rhs.encoded())
    }
    private static func equal(_ a: Data, _ b: Data) throws -> Bool {
        try Exact.canonical(a) == Exact.canonical(b)
    }
    private struct PairAuthority: VortxMutationAuthority {
        let first: any VortxMutationAuthority
        let second: any VortxMutationAuthority
        func withActive(_ operation: () throws -> Void) throws {
            // Short checks only outside final commit. Do NOT acquire these two authorities in
            // the reverse nested order of the actual whole-export -> original-source commit.
            try first.withActive {}
            try second.withActive(operation)
            try first.withActive {}
        }
    }

    fileprivate final class Verifier: @unchecked Sendable {
        enum Mode { case opening, fork(Data), fixed(Data, Data?), retarget(Data) }
        struct Peer: Sendable { let document: Data; let capabilities: Data }
        private let peer: Peer?
        private let openingNative: Data?
        private let scope: VortxAccountScope
        private var target: Target
        private let ownerReadUID: String
        private let authority: any VortxMutationAuthority
        private let validation: OwnerHistoryExactSourceValidation
        private let journal: VortxNativeOwnerHistoryJournal
        private let lock = NSLock()
        private var mode: Mode
        private var current: Data?
        private var parent: Data?
        private var full: Data?
        private var fullCount = 0
        init(scope: VortxAccountScope, target: Target, authority: any VortxMutationAuthority,
             validation: OwnerHistoryExactSourceValidation, journal: VortxNativeOwnerHistoryJournal,
             preservedOwnerUID: String? = nil, mode: Mode, peer: Peer? = nil, openingNative: Data? = nil) {
            self.scope = scope; self.target = target; self.authority = authority
            ownerReadUID = preservedOwnerUID ?? target.verifiedUID
            self.validation = validation; self.journal = journal; self.mode = mode; self.peer = peer; self.openingNative = openingNative
            if case .fixed(let fence, let parent) = mode { current = fence; self.parent = parent }
            if case .fork(let parent) = mode { self.parent = parent }
        }
        var callback: OwnerHistorySessionRuntime.Verify { { [self] in try verify($0) } }
        var normalized: Data? { lock.withLock { full } }
        var fullVersion: Int { lock.withLock { fullCount } }
        var boundFence: Data? { lock.withLock { current } }
        var boundTarget: Target { lock.withLock { target } }
        private func verify(_ bytes: Data) throws {
            try authority.withActive {}
            let wrapper = try Exact.Object(bytes), check = try Exact.Object(wrapper.required("check"))
            switch try wrapper.text("kind") {
            case "full":
                let purpose = try check.text("purpose")
                let opening = lock.withLock { if case .opening = mode { return true }; return false }
                guard try check.text("contract") == "vortx.owner-history-complete-archive/1",
                      (opening && ["session_open_input", "session_open_normalized"].contains(purpose))
                        || (!opening && ["session_import", "session_source_transition"].contains(purpose))
                        || (!opening && peer != nil && ["session_merge_peer", "session_merge"].contains(purpose))
                        else { throw VortxNativeError.invalidSnapshot }
                if purpose == "session_merge_peer" {
                    guard let peer,
                          try OwnerHistorySessionCoordinator.equal(check.required("peer"), peer.capabilities),
                          try OwnerHistorySessionCoordinator.equal(check.required("incomingNative"), peer.document) else {
                        // Any incoming raw field the pinned native serializer would strip is
                        // incompatible, not permission to silently normalize a new peer format.
                        throw VortxNativeError.invalidSnapshot
                    }
                }
                let candidate = try check.required("candidateState")
                if let openingNative {
                    let native = try Exact.Object(candidate).required("nativeSync")
                    try Exact.Snapshot.requireColdNativeConservation(original: openingNative, candidate: native)
                }
                try validation.validate(snapshot: candidate, journal: journal, scope: scope, authority: authority)
                lock.withLock { full = candidate; fullCount += 1 }
            case "lease":
                guard try check.text("contract") == "vortx.owner-history-session-lease/1",
                      try check.text("purpose") != "checkpoint_accepted" else { throw VortxNativeError.superseded }
                let fence = try check.required("fence"), fields = try Exact.Object(fence)
                let target = lock.withLock { self.target }
                guard try Exact.sameText(fields.text("scope"), scope.account),
                      try fields.text("ownerProfileId") == scope.ownerProfileID,
                      try fields.text("profileId") == target.profileID.uuidString,
                      try Exact.sameText(fields.text("verifiedStreamingUid"), target.verifiedUID) else {
                    throw VortxNativeError.superseded
                }
                try lock.withLock {
                    if let parent {
                        guard try OwnerHistorySessionCoordinator.equal(check.required("preparedAgainst"), parent) else { throw VortxNativeError.superseded }
                    } else {
                        guard try check.required("preparedAgainst") == Data("null".utf8) else { throw VortxNativeError.superseded }
                    }
                    if let current {
                        guard try OwnerHistorySessionCoordinator.equal(current, fence) else { throw VortxNativeError.superseded }
                    } else {
                        guard try check.text("purpose") == "capture" else { throw VortxNativeError.superseded }
                        switch mode {
                        case .opening:
                            guard fullCount == 2 else { throw VortxNativeError.invalidSnapshot }
                        case .fork(let parent):
                            var old = try Exact.Object(parent), new = try Exact.Object(fence)
                            guard try old.text("instanceId") != new.text("instanceId") else { throw VortxNativeError.superseded }
                            old.remove("instanceId"); new.remove("instanceId")
                            guard try OwnerHistorySessionCoordinator.equal(old.encoded(), new.encoded()) else { throw VortxNativeError.superseded }
                        case .retarget(let previous):
                            var old = try Exact.Object(previous), new = try Exact.Object(fence)
                            for key in ["profileId", "verifiedStreamingUid", "binding"] {
                                _ = try old.required(key); _ = try new.required(key)
                                old.remove(key); new.remove(key)
                            }
                            guard try OwnerHistorySessionCoordinator.equal(old.encoded(), new.encoded()) else {
                                throw VortxNativeError.superseded
                            }
                        case .fixed: throw VortxNativeError.superseded
                        }
                        current = fence
                    }
                }
            default: throw VortxNativeError.invalidResponse
            }
            try authority.withActive {}
        }
        func advance(_ response: Exact.Object, from fence: Data, requiresFull: Bool) throws {
            try lock.withLock {
                guard let current, try OwnerHistorySessionCoordinator.equal(current, fence),
                      !requiresFull || fullCount > 0 else { throw VortxNativeError.invalidResponse }
                var next = try Exact.Object(fence)
                guard try response.text("instanceId") == next.text("instanceId") else { throw VortxNativeError.superseded }
                let witness = try response.text("sourceSetWitnessId")
                if !requiresFull {
                    guard try witness == next.text("sourceSetWitnessId") else { throw VortxNativeError.unavailable }
                }
                if requiresFull {
                    guard let full else { throw VortxNativeError.invalidSnapshot }
                    let root = try Exact.Object(full), native = try Exact.Object(root.required("nativeSync"))
                    let profileID = try next.text("profileId")
                    let profiles = try Exact.Object(Exact.Object(root.required("roster")).required("profiles"))
                    let profile = try Exact.Object(profiles.required(profileID))
                    if let slots = native["accountSlots"], let slot = try Exact.Object(slots)[profileID] {
                        next.set("binding", try Exact.Object(slot).required("activeBinding"))
                    } else {
                        var binding = try Exact.Object(Data("{}".utf8))
                        binding.set("account", try profile.required("account"))
                        binding.set("revision", Data("0".utf8)); binding.set("transactionId", Data("null".utf8))
                        next.set("binding", try binding.encoded())
                    }
                }
                // This tuple is returned by the native transition we just performed under
                // the original parent lease, never supplied by a host caller or guessed clock.
                let active = try Exact.Object(response.required("activeTarget"))
                guard Set(active.fields.keys) == ["profileId", "binding"],
                      let profile = UUID(uuidString: try active.text("profileId")),
                      profile.uuidString == (try active.text("profileId")) else { throw VortxNativeError.invalidResponse }
                let binding = try active.required("binding"), account = try Exact.Object(Exact.Object(binding).required("account"))
                let uid: String
                if try account.text("kind") == "own" { uid = try account.text("value") }
                else {
                    let oldAccount = try Exact.Object(Exact.Object(next.required("binding")).required("account"))
                    if profile == target.profileID, try oldAccount.text("kind") != "own" {
                        uid = target.verifiedUID
                    } else { uid = ownerReadUID }
                }
                guard !uid.isEmpty else { throw VortxNativeError.invalidSnapshot }
                next.set("profileId", try Exact.string(profile.uuidString))
                next.set("binding", binding); next.set("verifiedStreamingUid", try Exact.string(uid))
                target = Target(profileID: profile, verifiedUID: uid)
                next.set("mutationGeneration", try response.required("mutationGeneration"))
                next.set("sourceSetWitnessId", try response.required("sourceSetWitnessId"))
                self.current = try next.encoded()
            }
        }
        func durableAccept(fence: Data, parent: Data) -> OwnerHistorySessionRuntime.Verify {
            // The method is private to the coordinator's nested verifier and is called only in
            // the lexical post-readback phase above. No caller can construct a durable flag.
            return { bytes in
                let wrapper = try Exact.Object(bytes), check = try Exact.Object(wrapper.required("check"))
                guard try wrapper.text("kind") == "lease",
                      try check.text("contract") == "vortx.owner-history-session-lease/1",
                      try check.text("purpose") == "checkpoint_accepted",
                      try OwnerHistorySessionCoordinator.equal(check.required("fence"), fence),
                      try OwnerHistorySessionCoordinator.equal(check.required("preparedAgainst"), parent) else { throw VortxNativeError.superseded }
            }
        }
    }
}
