// Original-ticket prompt-state tests with synthetic stores, credentials and context events.
// The portable runner invokes run() explicitly with actual PromptState and dispatcher source.
import Combine
import Foundation

@MainActor enum XperienceCurationExportPromptLifecycleTests {
    typealias Fixture = XperienceLifecycleAmendmentTests
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.assertion(message) }
        checks += 1
    }
    final class Notes: @unchecked Sendable {
        let subject = PassthroughSubject<Void, Never>()
        func send() { subject.send(()) }
    }

    final class PostingReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var retired = false
        func markRetired() { lock.withLock { retired = true } }
        func snapshot() -> Bool { lock.withLock { retired } }
    }

    /// The receipt is sampled on the posting queue BEFORE resuming MainActor. An enqueue-only
    /// implementation cannot pass by processing the invalidation after this background post returns.
    static func postDefault(_ name: Notification.Name, receipt: PostingReceipt) async -> (Bool, Bool) {
        let rawName = name.rawValue
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { @Sendable in
                NotificationCenter.default.post(name: .init(rawValue: rawName), object: nil)
                continuation.resume(returning: (!Thread.isMainThread, receipt.snapshot()))
            }
        }
    }

    static func defaultBackgroundNotificationsRevokeBeforePostReturns() async throws {
        for note in [VortXSyncManager.credentialScopeDidChangeNote, CoreBridge.xperienceContextChangedNote] {
            let (collection, session) = try Fixture.sessionFixture()
            let store = Fixture.StoreFixture(session: session)
            let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
            let backend = Fixture.MemoryCredentialBackend()
            // No injected publisher: both actual controller and prompt build their default maps on MainActor.
            let controller = XperienceCurationExportController(store: store,
                vault: .init(store: backend.store(), authority: authority), authority: authority,
                transport: { _ in throw Failure.assertion("unexpected transport") })
            let ticket = try controller.beginLink(collection)
            let input = XperienceCurationExportPromptState(controller: controller, ticket: ticket)
            input.privateURL = "synthetic input"; input.selectedID = "synthetic selection"
            let receipt = PostingReceipt()
            let observer = input.$retired.sink { @Sendable value in if value { receipt.markRetired() } }
            defer { observer.cancel() }
            store.contextCurrent = false
            let (background, revokedAtReturn) = await postDefault(note, receipt: receipt)
            try require(background && revokedAtReturn,
                        "default notification maps revoke the actual prompt before background post returns")
            try require(input.retired && input.privateURL.isEmpty && input.selectedID == nil
                        && !controller.isCurrentContext(ticket) && store.explicitRetirements == 1,
                        "default controller and prompt retire the same original attempt and clear sensitive input")
            store.contextCurrent = true; store.editCurrent = true
            _ = await postDefault(note, receipt: receipt)
            try require(input.retired && !controller.isCurrentContext(ticket) && store.captureCount == 1
                        && store.explicitRetirements == 1,
                        "default notification context ABA cannot revive or recapture the original attempt")
        }
    }

    static func defaultUnchangedBackgroundHintsAndIdentityABA() async throws {
        let priorProfile = ProfileStore.shared.activeID
        let priorSignIn = VortXSyncManager.shared.isSignedIn
        defer { ProfileStore.shared.activeID = priorProfile; VortXSyncManager.shared.isSignedIn = priorSignIn }
        for identity in ["profile", "account"] {
            let (collection, session) = try Fixture.sessionFixture()
            ProfileStore.shared.activeID = session.profileID
            VortXSyncManager.shared.isSignedIn = false
            let store = Fixture.StoreFixture(session: session)
            let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
            let backend = Fixture.MemoryCredentialBackend()
            let controller = XperienceCurationExportController(store: store,
                vault: .init(store: backend.store(), authority: authority), authority: authority,
                transport: { _ in throw Failure.assertion("unexpected transport") })
            let ticket = try controller.beginLink(collection)
            let input = XperienceCurationExportPromptState(controller: controller, ticket: ticket)
            input.privateURL = "unchanged original input"
            let receipt = PostingReceipt()
            let observer = input.$retired.sink { @Sendable value in if value { receipt.markRetired() } }
            defer { observer.cancel() }
            let (background, retiredAtReturn) = await postDefault(CoreBridge.xperienceContextChangedNote, receipt: receipt)
            try require(background && !retiredAtReturn && !input.retired && controller.isCurrentContext(ticket)
                        && input.privateURL == "unchanged original input" && store.captureCount == 1,
                        "unchanged default background hint conserves the actual original prompt")
            if identity == "profile" { ProfileStore.shared.activeID = UUID() }
            else { VortXSyncManager.shared.isSignedIn = true }
            try require(input.retired && !controller.isCurrentContext(ticket) && receipt.snapshot(),
                        "default Published identity pipeline revokes synchronously during the setter")
            ProfileStore.shared.activeID = session.profileID; VortXSyncManager.shared.isSignedIn = false
            try require(input.retired && !controller.isCurrentContext(ticket) && store.captureCount == 1
                        && store.explicitRetirements == 1,
                        "default Published identity ABA does not revive or recapture an old ticket")
        }
    }

    static func contextLossClearsSameProfilePrompt() async throws {
        for cause in ["credential", "native"] {
            let (collection, session) = try Fixture.sessionFixture()
            let store = Fixture.StoreFixture(session: session, installed: [try Fixture.candidate()])
            let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
            let backend = Fixture.MemoryCredentialBackend(), notes = Notes(), identity = Notes()
            let controller = XperienceCurationExportController(
                store: store, vault: .init(store: backend.store(), authority: authority), authority: authority,
                contextChanges: identity.subject.eraseToAnyPublisher(),
                authorityContextChanges: notes.subject.eraseToAnyPublisher(),
                transport: { _ in throw Failure.assertion("unexpected transport") })
            let ticket = try controller.beginLink(collection)
            let input = XperienceCurationExportPromptState(controller: controller, ticket: ticket,
                identityChanges: identity.subject.eraseToAnyPublisher(),
                authorityChanges: notes.subject.eraseToAnyPublisher())
            input.privateURL = "synthetic sensitive input"; input.selectedID = "synthetic selection"
            if cause == "native" { store.contextCurrent = false }
            else { _ = authority.bind(.signedOutDevice) }
            await Task.detached { notes.send() }.value
            try require(input.privateURL.isEmpty && input.selectedID == nil && input.retired,
                        "\(cause) same-profile loss synchronously clears original prompt fields")
            try require(!controller.isCurrentContext(ticket) && store.explicitRetirements == 1,
                        "\(cause) same-profile loss retires only the original controller attempt")
        }
    }

    static func unchangedACKKeepsOriginalPrompt() throws {
        let (collection, session) = try Fixture.sessionFixture()
        let store = Fixture.StoreFixture(session: session)
        let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
        let backend = Fixture.MemoryCredentialBackend(), notes = Notes(), identity = Notes()
        let controller = XperienceCurationExportController(
            store: store, vault: .init(store: backend.store(), authority: authority), authority: authority,
            contextChanges: identity.subject.eraseToAnyPublisher(),
            authorityContextChanges: notes.subject.eraseToAnyPublisher(),
            transport: { _ in throw Failure.assertion("unexpected transport") })
        let ticket = try controller.beginLink(collection)
        let input = XperienceCurationExportPromptState(controller: controller, ticket: ticket,
            identityChanges: identity.subject.eraseToAnyPublisher(),
            authorityChanges: notes.subject.eraseToAnyPublisher())
        input.privateURL = "synthetic input"
        notes.send()
        try require(input.privateURL == "synthetic input" && !input.retired
                    && controller.isCurrentContext(ticket) && store.explicitRetirements == 0,
                    "unchanged genuine host ACK preserves the original prompt without recapture")
        input.cancel()
    }

    static func completedSaveReceiptsSurviveAuthorityHints() async throws {
        for secureWriteSucceeds in [true, false] {
            let (collection, session) = try Fixture.sessionFixture()
            let store = Fixture.StoreFixture(session: session, installed: [try Fixture.candidate()])
            let authority = CredentialScopeRegistry(initialScope: .signedOutDevice)
            let backend = Fixture.MemoryCredentialBackend(), notes = Notes(), identity = Notes()
            let credentialStore = secureWriteSucceeds ? backend.store() : XperienceExportCredentialStore(
                read: { _ in .missing }, write: { _, _ in .failure })
            let bytes = try Fixture.payload()
            let controller = XperienceCurationExportController(
                store: store, vault: .init(store: credentialStore, authority: authority), authority: authority,
                contextChanges: identity.subject.eraseToAnyPublisher(),
                authorityContextChanges: notes.subject.eraseToAnyPublisher(), transport: { _ in bytes })
            let ticket = try controller.beginLink(collection)
            let input = XperienceCurationExportPromptState(controller: controller, ticket: ticket,
                identityChanges: identity.subject.eraseToAnyPublisher(),
                authorityChanges: notes.subject.eraseToAnyPublisher())
            // This is the controller's own original-target durable ACK, before its continuation.
            store.onNativeACK = { notes.send() }
            let choices = try await controller.previewURL(try Fixture.endpoint().url.absoluteString, ticket: ticket)
            guard let selected = choices.first else { throw Failure.assertion("synthetic choice missing") }
            do { try await controller.selectAndSave(upstreamCollectionID: selected.id, ticket: ticket) }
            catch let failure as XperienceExportFailure {
                guard !secureWriteSucceeds && failure == .savedNeedsConnection else { throw failure }
            }
            let expected = controller.phase
            try require(secureWriteSucceeds ? expected == .saved : expected == .savedNeedsConnection,
                        "original native ACK retains the precise completed save receipt")
            input.privateURL = "clear after receipt"; input.selectedID = selected.id
            notes.send()
            try require(controller.phase == expected && input.privateURL.isEmpty && input.selectedID == nil
                        && !input.retired && store.nativeACKs == 1,
                        "authority hint clears leftover prompt input and preserves saved/savedNeedsConnection")
            input.cancel()
            try require(controller.phase == expected, "prompt dismissal does not overwrite a completed receipt")
        }
    }

    static func run() async throws {
        try await defaultBackgroundNotificationsRevokeBeforePostReturns()
        try await defaultUnchangedBackgroundHintsAndIdentityABA()
        try await contextLossClearsSameProfilePrompt()
        try unchangedACKKeepsOriginalPrompt()
        try await completedSaveReceiptsSurviveAuthorityHints()
    }
}
