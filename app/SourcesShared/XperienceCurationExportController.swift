import Combine
import Foundation

/// Implemented by the existing ForYouStore adapter. Native admission still owns captured target,
/// exact legacy-register prerequisite, companion CAS, whole-export witness and checkpoint readback.
@MainActor protocol XperienceCurationExportStore: AnyObject {
    func captureXperienceExportEdit(_ collection: SmartCollection) throws -> CurationEditSession
    func xperienceExportEditIsCurrent(_ session: CurationEditSession) -> Bool
    func xperienceExportContextIsCurrent(_ session: CurationEditSession) -> Bool
    func xperienceExportCandidates(_ session: CurationEditSession) throws -> [XperienceAddonBinding.Candidate]
    func saveXperienceExport(_ document: CurationDocument, session: CurationEditSession) async throws
    func retireXperienceExportEdit(_ session: CurationEditSession)
}

@MainActor final class XperienceCurationExportController: ObservableObject {
    struct Ticket: Equatable { fileprivate let id: UUID }
    struct Selection: Identifiable, Equatable { let id: String; let title: String; let folderCount: Int }
    enum Phase: Equatable { case idle, loading, review, saving, saved, savedNeedsConnection, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selections: [Selection] = []
    @Published private(set) var message: String?
    private struct Attempt {
        let ticket: Ticket
        let owner: CredentialScopeRegistry.Capture
        let session: CurationEditSession
        let installed: [XperienceAddonBinding.Candidate]
        let previousCredential: XperienceExportCredentialVault.Record?
        let repair: XperienceExportCredentialVault.RepairTicket?
        let sourceID: String
        var endpoint: XperienceExportEndpoint?
        var projection: XperienceProfileExportAdmission.Projection?
    }
    private let store: any XperienceCurationExportStore
    private let vault: XperienceExportCredentialVault
    private let authority: CredentialScopeRegistry
    private let transport: @Sendable (XperienceExportEndpoint) async throws -> Data
    private var attempt: Attempt?
    private var worker: Task<XperienceProfileExportAdmission.Projection, Error>?
    private var subscriptions = Set<AnyCancellable>()

    init(store: any XperienceCurationExportStore, vault: XperienceExportCredentialVault? = nil,
         authority: CredentialScopeRegistry = .shared,
         contextChanges: AnyPublisher<Void, Never>? = nil,
         authorityContextChanges: AnyPublisher<Void, Never>? = nil,
         transport: @escaping @Sendable (XperienceExportEndpoint) async throws -> Data = { try await XperienceExportHTTP.load($0) }) {
        self.store = store; self.vault = vault ?? XperienceExportCredentialVault()
        self.authority = authority; self.transport = transport
        (contextChanges ?? Self.appContextChanges()).sink { @Sendable [weak self] in
            Self.onMainSynchronously { [weak self] in self?.cancelCurrent() }
        }.store(in: &subscriptions)
        (authorityContextChanges ?? Self.appAuthorityContextChanges()).sink { @Sendable [weak self] in
            Self.onMainSynchronously { [weak self] in self?.cancelIfContextIsLost() }
        }.store(in: &subscriptions)
    }

    private static func appContextChanges() -> AnyPublisher<Void, Never> {
        let profile = ProfileStore.shared.$activeID.dropFirst().map { _ in () }.eraseToAnyPublisher()
        let account = VortXSyncManager.shared.$isSignedIn.dropFirst().map { _ in () }.eraseToAnyPublisher()
        // Published identity changes cancel synchronously, before setters finish; A->B->A cannot revive work.
        // Do not predicate this stream on getters: @Published delivers from willSet, before they change.
        return Publishers.Merge(profile, account).eraseToAnyPublisher()
    }

    private static func appAuthorityContextChanges() -> AnyPublisher<Void, Never> {
        var notes = [VortXSyncManager.credentialScopeDidChangeNote]
        notes.append(CoreBridge.xperienceContextChangedNote)
        return Publishers.MergeMany(notes.map { name in
            NotificationCenter.default.publisher(for: name).map { _ in () }.eraseToAnyPublisher()
        }).eraseToAnyPublisher()
    }

    /// Native/credential notifications are posted after their source locks are released. Deliver the
    /// original-capture check in the posting turn, never receive(on:) or enqueue a later Task. The
    /// @Sendable Combine sink avoids inheriting an unchecked MainActor closure on a worker callback.
    nonisolated private static func onMainSynchronously(_ action: @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.sync { action() }
        }
    }

    private func cancelIfContextIsLost() {
        guard let current = attempt else { return }
        // The save's own ACK emits the same note and intentionally retires its edit lifetime. This
        // receipt predicate ignores only that lifetime; owner/install/profile/registry must still
        // match the ORIGINAL target. No successor target or credential capture is obtained here.
        guard isCurrentContext(current.ticket) else {
            cancelCurrent(); return
        }
    }

    /// Synchronous UI retirement check for its original prompt ticket. No credential bytes are read.
    /// A completed save has no live attempt; callers preserve saved/savedNeedsConnection receipts.
    func isCurrentContext(_ ticket: Ticket) -> Bool {
        guard let current = attempt, current.ticket == ticket else { return false }
        return authority.isCurrent(current.owner) && store.xperienceExportContextIsCurrent(current.session)
    }

    /// Original user gesture, before a URL prompt/network await. Never recaptured by a continuation.
    private enum BeginMode: Equatable { case link, reconnect, refresh }
    func beginLink(_ collection: SmartCollection) throws -> Ticket { try begin(collection, mode: .link) }
    /// Explicitly replace/provide this device's URL while retaining the shared upstream selection.
    func beginReconnect(_ collection: SmartCollection) throws -> Ticket { try begin(collection, mode: .reconnect) }
    func beginRefresh(_ collection: SmartCollection) throws -> Ticket { try begin(collection, mode: .refresh) }
    private func begin(_ collection: SmartCollection, mode: BeginMode) throws -> Ticket {
        cancelCurrent()
        let owner = authority.capture()
        let session = try store.captureXperienceExportEdit(collection)
        do {
            let credential: XperienceExportCredentialVault.Record?
            var repair: XperienceExportCredentialVault.RepairTicket?
            do { credential = try vault.read(owner: owner, profileID: session.profileID, collectionID: collection.id) }
            catch let failure as XperienceExportFailure {
                guard mode == .reconnect, failure == .credentialUnavailable else { throw failure }
                repair = try vault.prepareRepair(owner: owner, profileID: session.profileID, collectionID: collection.id)
                credential = nil
            }
            let origin = session.document.raw["origin"]
            let sourceID: String
            if mode != .link {
                guard origin?["provider"] == .string(XperienceCurationExportMapper.provider),
                      case .string(let existingID) = origin?["sourceID"],
                      UUID(uuidString: existingID)?.uuidString.lowercased() == existingID,
                      case .string(let upstreamID) = origin?["upstreamCollectionID"],
                      UUID(uuidString: upstreamID) != nil else { throw XperienceExportFailure.notLinked }
                if mode == .refresh, credential?.sourceID != existingID { throw XperienceExportFailure.notLinked }
                sourceID = existingID
            } else {
                guard origin == nil else { throw XperienceExportFailure.alreadyLinked }
                sourceID = UUID().uuidString.lowercased()
            }
            let installed = try store.xperienceExportCandidates(session)
            guard authority.isCurrent(owner), store.xperienceExportEditIsCurrent(session) else {
                throw XperienceExportFailure.staleContext
            }
            let ticket = Ticket(id: UUID())
            attempt = .init(ticket: ticket, owner: owner, session: session, installed: installed,
                previousCredential: credential, repair: repair, sourceID: sourceID)
            phase = .idle; message = nil; selections = []
            return ticket
        } catch { store.retireXperienceExportEdit(session); throw controlled(error) }
    }

    /// Returns a layout choice. The untrusted profile config and private URL never enter UI state.
    func previewURL(_ text: String, ticket: Ticket) async throws -> [Selection] {
        do {
            let endpoint = try XperienceExportEndpoint(text)
            try await prepare(endpoint, ticket: ticket)
            return selections
        } catch { fail(error, ticket: ticket); throw controlled(error) }
    }
    /// Explicit Refresh now. Updates the existing connection and keeps its original selection.
    func refreshNow(ticket: Ticket) async throws {
        do {
            let current = try require(ticket)
            guard let credential = current.previousCredential,
                  case .string(let upstreamID) = current.session.document.raw["origin"]?["upstreamCollectionID"] else {
                throw XperienceExportFailure.notLinked
            }
            try await prepare(credential.endpoint, ticket: ticket)
            try await selectAndSave(upstreamCollectionID: upstreamID, ticket: ticket)
        } catch { fail(error, ticket: ticket); throw controlled(error) }
    }
    private func prepare(_ endpoint: XperienceExportEndpoint, ticket: Ticket) async throws {
        _ = try require(ticket)
        guard worker == nil else { throw XperienceExportFailure.staleContext }
        phase = .loading; message = nil
        let load = transport
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let bytes = try await load(endpoint)
            try Task.checkCancellation()
            let value = try XperienceProfileExportAdmission.parse(bytes)
            try Task.checkCancellation()
            return value
        }
        worker = work
        defer { if attempt?.ticket == ticket { worker = nil } }
        let projection = try await withTaskCancellationHandler { try await work.value }
            onCancel: { work.cancel() }
        try Task.checkCancellation()
        _ = try require(ticket)
        attempt?.endpoint = endpoint; attempt?.projection = projection
        let expectedSelection = attempt?.session.document.raw["origin"]?["upstreamCollectionID"]
        selections = projection.collections.collections.filter {
            expectedSelection == nil || expectedSelection == .string($0.id)
        }.map {
            Selection(id: $0.id, title: $0.title, folderCount: $0.folders.count)
        }
        guard !selections.isEmpty else { throw XperienceExportFailure.missingCollection }
        phase = .review
    }
    func selectAndSave(upstreamCollectionID: String, ticket: Ticket) async throws {
        do {
            let current = try require(ticket)
            guard phase == .review, let endpoint = current.endpoint, let projection = current.projection else {
                throw XperienceExportFailure.staleContext
            }
            let mapped = try XperienceCurationExportMapper.map(projection,
                upstreamCollectionID: upstreamCollectionID, sourceID: current.sourceID,
                into: current.session.document, installed: current.installed)
            _ = try require(ticket)
            let record = XperienceExportCredentialVault.Record(endpoint: endpoint,
                sourceID: current.sourceID, sessionID: UUID())
            phase = .saving
            try await store.saveXperienceExport(mapped, session: current.session)
            try Task.checkCancellation()
            // Successful save retires its own session. Do not re-require that retired session or
            // capture a successor; exact store ACK plus current owner/gesture/credential is the receipt.
            guard attempt?.ticket == ticket, authority.isCurrent(current.owner),
                  store.xperienceExportContextIsCurrent(current.session) else {
                throw XperienceExportFailure.staleContext
            }
            // Failed native CAS never replaces the previous private URL. These stores are not
            // one atomic transaction: a secure-store failure AFTER native ACK is explicit below.
            do {
                guard try vault.matches(current.previousCredential, owner: current.owner,
                    profileID: current.session.profileID, collectionID: current.session.collection.id,
                    repair: current.repair) else {
                    throw XperienceExportFailure.staleContext
                }
                try vault.save(record, replacing: current.previousCredential, owner: current.owner,
                    profileID: current.session.profileID, collectionID: current.session.collection.id,
                    repair: current.repair)
                guard try vault.read(owner: current.owner, profileID: current.session.profileID,
                    collectionID: current.session.collection.id) == record else {
                    throw XperienceExportFailure.credentialUnavailable
                }
            } catch {
                if error as? XperienceExportFailure == .staleContext { throw error }
                guard attempt?.ticket == ticket, authority.isCurrent(current.owner),
                      store.xperienceExportContextIsCurrent(current.session) else {
                    throw XperienceExportFailure.staleContext
                }
                attempt = nil; selections = []; phase = .savedNeedsConnection
                message = XperienceExportFailure.savedNeedsConnection.errorDescription
                throw XperienceExportFailure.savedNeedsConnection
            }
            guard attempt?.ticket == ticket, authority.isCurrent(current.owner),
                  store.xperienceExportContextIsCurrent(current.session) else {
                throw XperienceExportFailure.staleContext
            }
            attempt = nil; selections = []; phase = .saved
            message = current.session.document.raw["origin"] == nil
                ? "Linked from Xperience. Saved in this VortX profile; account sync runs separately."
                : "Refreshed from Xperience. Saved in this VortX profile; account sync runs separately."
        } catch { fail(error, ticket: ticket); throw controlled(error) }
    }
    func cancel(_ ticket: Ticket) { if attempt?.ticket == ticket { cancelCurrent() } }
    /// UI calls synchronously on profile/account change, sheet dismissal or controller replacement.
    func cancelCurrent() {
        worker?.cancel(); worker = nil
        if let current = attempt { store.retireXperienceExportEdit(current.session) }
        attempt = nil; selections = []; phase = .idle; message = nil
    }
    private func require(_ ticket: Ticket) throws -> Attempt {
        try Task.checkCancellation()
        guard let current = attempt, current.ticket == ticket, authority.isCurrent(current.owner),
              store.xperienceExportEditIsCurrent(current.session),
              try vault.matches(current.previousCredential, owner: current.owner,
                profileID: current.session.profileID, collectionID: current.session.collection.id,
                repair: current.repair) else {
            throw XperienceExportFailure.staleContext
        }
        return current
    }
    private func fail(_ error: Error, ticket: Ticket) {
        guard attempt?.ticket == ticket else { return }
        cancelCurrent()
        guard !(error is CancellationError) else { return }
        phase = .failed; message = controlled(error).localizedDescription
    }
    private func controlled(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? XperienceExportFailure { return error }
        if let error = error as? XperienceProfileExportAdmission.Failure {
            return error == .unsupportedVersion ? XperienceExportFailure.unsupportedVersion : XperienceExportFailure.invalidResponse
        }
        if let error = error as? CurationFailure {
            switch error {
            case .staleRevision: return XperienceExportFailure.staleRevision
            case .staleContext, .staleCollection: return XperienceExportFailure.staleContext
            case .tooLarge: return XperienceExportFailure.tooLarge
            default: return XperienceExportFailure.unsafeContent
            }
        }
        if let error = error as? XperienceCollections.Failure, error == .tooLarge { return XperienceExportFailure.tooLarge }
        return XperienceExportFailure.invalidResponse
    }
}
