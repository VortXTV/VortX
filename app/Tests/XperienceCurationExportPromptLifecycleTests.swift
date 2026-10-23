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
        try await contextLossClearsSameProfilePrompt()
        try unchangedACKKeepsOriginalPrompt()
        try await completedSaveReceiptsSurviveAuthorityHints()
    }
}
