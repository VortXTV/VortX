// Original-context lifecycle tests using synthetic profile data, retained in-memory credentials,
// and a suspended fake transport. No runtime Keychain or HTTP request is performed.
import Combine
import Foundation

@main @MainActor enum XperienceLifecycleAmendmentTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        checks += 1
        print("PASS \(message)")
    }

    private static let profileID = "11111111-1111-4111-8111-111111111111"
    private static let collectionID = "22222222-2222-4222-8222-222222222222"
    private static let sourceID = "33333333-3333-4333-8333-333333333333"
    private static let exportKey = "synthetic-lifecycle-key"

    static func endpoint() throws -> XperienceExportEndpoint {
        try XperienceExportEndpoint(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exportKey)")
    }

    static func candidate() throws -> XperienceAddonBinding.Candidate {
        try .init(manifestID: "addon.example", transport: "https://addon.example/manifest.json",
                  catalogs: [.init(type: "movie", id: "catalog", acceptsGenre: true,
                                   requiresGenre: false, supportsSkip: true)])
    }

    static func mappedCollection() -> VortxJSON {
        let source: VortxJSON = .object([
            "provider": .string("addon"), "addonId": .string("addon.example"),
            "type": .string("movie"), "catalogId": .string("catalog")
        ])
        let folder: VortxJSON = .object([
            "id": .string("upstream-folder"), "title": .string("Upstream folder"),
            "tileShape": .string("POSTER"), "sources": .array([source])
        ])
        return .object([
            "id": .string(collectionID), "title": .string("Mapped collection"),
            "viewMode": .string("TABBED_GRID"), "folders": .array([folder])
        ])
    }

    static func payload() throws -> Data {
        let envelope: VortxJSON = .object([
            "exportType": .string("xperienceProfile"), "exportVersion": .integer(1),
            "name": .string("Synthetic lifecycle profile"),
            "config": .object(["collections": .array([mappedCollection()])])
        ])
        return try XperienceCollections.canonicalData(envelope)
    }

    static func sessionFixture() throws -> (SmartCollection, CurationEditSession) {
        let collection = SmartCollection(
            id: "55555555-5555-4555-8555-555555555555", name: "Lifecycle fixture",
            rules: SmartCollectionRules(), home: true, createdAt: 1)
        let legacy: VortxJSON = .object([
            "id": .string(collection.id), "name": .string(collection.name),
            "home": .bool(true), "createdAt": .number(1),
            "rules": .object(["type": .string("all")])
        ])
        let document = try CurationDocument.make(for: collection, legacyValue: legacy)
        let session = CurationEditSession(profileID: UUID(uuidString: profileID)!,
                                          collection: collection, document: document,
                                          legacyRegister: legacy, companionRegister: document.raw, target: nil)
        return (collection, session)
    }

    final class MemoryCredentialBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func store() -> XperienceExportCredentialStore {
            XperienceExportCredentialStore(
                read: { [self] slot in
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.values[slot].map(CredentialDurableReadResult.value) ?? .missing
                },
                write: { [self] value, slot in
                    self.lock.lock(); defer { self.lock.unlock() }
                    if let value { self.values[slot] = value }
                    else { self.values.removeValue(forKey: slot) }
                    return .success
                })
        }
    }

    final class TransportGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancellationObserved = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var released: Data?
        private var releaseWaiters: [CheckedContinuation<Data, Never>] = []

        func markStarted() {
            lock.lock(); started = true
            let waiters = startWaiters; startWaiters.removeAll(); lock.unlock()
            waiters.forEach { $0.resume() }
        }

        func markCancelled() { lock.withLock { cancellationObserved = true } }
        func wasCancelled() -> Bool { lock.withLock { cancellationObserved } }

        func waitUntilStarted() async {
            if lock.withLock({ started }) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if started { lock.unlock(); continuation.resume() }
                else { startWaiters.append(continuation); lock.unlock() }
            }
        }

        func release(_ data: Data) {
            lock.lock()
            if releaseWaiters.isEmpty { released = data; lock.unlock(); return }
            let waiters = releaseWaiters; releaseWaiters.removeAll(); lock.unlock()
            waiters.forEach { $0.resume(returning: data) }
        }

        func waitForRelease() async -> Data {
            let ready: Data? = lock.withLock {
                defer { released = nil }
                return released
            }
            if let ready { return ready }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                lock.lock()
                if let released {
                    self.released = nil; lock.unlock(); continuation.resume(returning: released)
                } else { releaseWaiters.append(continuation); lock.unlock() }
            }
        }
    }

    @MainActor final class StoreFixture: XperienceCurationExportStore {
        let session: CurationEditSession
        let installed: [XperienceAddonBinding.Candidate]
        var editCurrent = true
        var contextCurrent = true
        var saved: CurationDocument?
        var nativeACKs = 0
        var explicitRetirements = 0
        var onNativeACK: (() -> Void)?

        init(session: CurationEditSession,
             installed: [XperienceAddonBinding.Candidate] = []) {
            self.session = session; self.installed = installed
        }

        func captureXperienceExportEdit(_ collection: SmartCollection) throws -> CurationEditSession {
            session
        }

        func xperienceExportEditIsCurrent(_ session: CurationEditSession) -> Bool {
            editCurrent
        }

        func xperienceExportContextIsCurrent(_ session: CurationEditSession) -> Bool {
            contextCurrent
        }

        func xperienceExportCandidates(_ session: CurationEditSession)
            throws -> [XperienceAddonBinding.Candidate] { installed }

        func saveXperienceExport(_ document: CurationDocument,
                                 session: CurationEditSession) async throws {
            saved = document
            // The real native ACK retires this edit lifetime. The amendment must not mistake
            // that normal retirement for account/registry context loss.
            editCurrent = false
            nativeACKs += 1
            onNativeACK?()
        }

        func retireXperienceExportEdit(_ session: CurationEditSession) {
            explicitRetirements += 1
            editCurrent = false
        }
    }

    static func injectedContextPublisher() -> PassthroughSubject<Void, Never> {
        PassthroughSubject<Void, Never>()
    }

    static func contextOnlyLossCancelsSuspendedTransport() async throws {
        let (collection, session) = try sessionFixture()
        let fixture = StoreFixture(session: session, installed: [try candidate()])
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let backend = MemoryCredentialBackend()
        let vault = XperienceExportCredentialVault(store: backend.store(),
                                                    authority: authority)
        let gate = TransportGate()
        let bytes = try payload()
        let controller = XperienceCurationExportController(
            store: fixture, vault: vault, authority: authority,
            contextChanges: PassthroughSubject<Void, Never>().eraseToAnyPublisher(),
            transport: { _ in
                await withTaskCancellationHandler {
                    gate.markStarted()
                    return await gate.waitForRelease()
                } onCancel: { gate.markCancelled() }
            })
        let ticket = try controller.beginLink(collection)
        let pending = Task { try await controller.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exportKey)",
            ticket: ticket) }
        await gate.waitUntilStarted()
        fixture.contextCurrent = false
        NotificationCenter.default.post(name: CoreBridge.xperienceContextChangedNote, object: nil)
        try require(controller.phase == .idle && fixture.explicitRetirements == 1 && gate.wasCancelled(),
                    "native note synchronously retires and cancels while transport remains suspended")
        gate.release(bytes)
        do {
            _ = try await pending.value
            throw Failure.assertion("native context loss admitted a late suspended preview")
        } catch is CancellationError {
            checks += 1
        } catch let failure as XperienceExportFailure {
            try require(failure == .staleContext,
                        "native context loss rejects the suspended original gesture")
        }
        try require(fixture.explicitRetirements == 1 && fixture.saved == nil,
                    "native context loss retires the original gesture without saving")
    }

    static func credentialGenerationLossCancelsSuspendedTransport() async throws {
        let (collection, session) = try sessionFixture()
        let fixture = StoreFixture(session: session, installed: [try candidate()])
        let originalScope = CredentialScope.account(UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
        let authority = CredentialScopeRegistry(initialScope: originalScope)
        let backend = MemoryCredentialBackend()
        let vault = XperienceExportCredentialVault(store: backend.store(),
                                                    authority: authority)
        let gate = TransportGate()
        let bytes = try payload()
        let controller = XperienceCurationExportController(
            store: fixture, vault: vault, authority: authority,
            contextChanges: PassthroughSubject<Void, Never>().eraseToAnyPublisher(),
            transport: { _ in
                await withTaskCancellationHandler {
                    gate.markStarted()
                    return await gate.waitForRelease()
                } onCancel: { gate.markCancelled() }
            })
        let ticket = try controller.beginLink(collection)
        let pending = Task { try await controller.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exportKey)",
            ticket: ticket) }
        await gate.waitUntilStarted()
        _ = authority.bind(originalScope)
        NotificationCenter.default.post(name: VortXSyncManager.credentialScopeDidChangeNote, object: nil)
        try require(controller.phase == .idle && fixture.explicitRetirements == 1 && gate.wasCancelled(),
                    "same-owner credential note cancels suspended work before transport release")
        gate.release(bytes)
        do {
            _ = try await pending.value
            throw Failure.assertion("credential generation loss admitted a late suspended preview")
        } catch is CancellationError {
            checks += 1
        } catch let failure as XperienceExportFailure {
            try require(failure == .staleContext,
                        "credential generation loss rejects the suspended original gesture")
        }
        try require(fixture.explicitRetirements == 1 && fixture.saved == nil,
                    "credential generation loss retires the original gesture without saving")
    }

    static func nativeACKRetirementDoesNotCancelCurrentContext() async throws {
        let (collection, session) = try sessionFixture()
        let fixture = StoreFixture(session: session, installed: [try candidate()])
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let backend = MemoryCredentialBackend()
        let vault = XperienceExportCredentialVault(store: backend.store(),
                                                    authority: authority)
        var noteCount = 0
        fixture.onNativeACK = {
            noteCount += 1
            // Simulates the native Xperience context notification emitted after the ACK. The
            // edit lifetime is already retired, while the original owner/context remain current.
            NotificationCenter.default.post(name: CoreBridge.xperienceContextChangedNote, object: nil)
        }
        let bytes = try payload()
        let controller = XperienceCurationExportController(
            store: fixture, vault: vault, authority: authority,
            contextChanges: PassthroughSubject<Void, Never>().eraseToAnyPublisher(),
            transport: { _ in bytes })
        let ticket = try controller.beginLink(collection)
        _ = try await controller.previewURL(
            "https://xperience-app.com/profile-export/\(profileID).json?key=\(exportKey)",
            ticket: ticket)
        try await controller.selectAndSave(upstreamCollectionID: collectionID, ticket: ticket)
        try require(noteCount == 1 && fixture.nativeACKs == 1,
                    "successful native ACK posts exactly one Xperience context note")
        try require(!fixture.editCurrent && fixture.contextCurrent && fixture.explicitRetirements == 0,
                    "retired native edit lifetime is distinct from current owner/context")
        try require(fixture.saved != nil && controller.phase == .saved &&
                    controller.message?.contains("Linked from Xperience") == true,
                    "current context survives ACK note and completes the local Xperience save")
    }

    static func main() async throws {
        try await contextOnlyLossCancelsSuspendedTransport()
        try await credentialGenerationLossCancelsSuspendedTransport()
        try await nativeACKRetirementDoesNotCancelCurrentContext()
        print("PASS lifecycle amendment checks: \(checks)")
    }
}
