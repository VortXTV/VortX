import Combine
import Foundation

/// Original-ticket prompt state. Sensitive text is cleared in the notification's posting turn,
/// before SwiftUI dismissal/recomputation. The controller owns account/native write admission.
@MainActor final class XperienceCurationExportPromptState: ObservableObject {
    @Published var privateURL = ""
    @Published var selectedID: String?
    @Published private(set) var localMessage: String?
    @Published private(set) var retired = false
    private let controller: XperienceCurationExportController
    private let ticket: XperienceCurationExportController.Ticket
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var didRetire = false
    private var subscriptions = Set<AnyCancellable>()

    init(controller: XperienceCurationExportController,
         ticket: XperienceCurationExportController.Ticket,
         identityChanges: AnyPublisher<Void, Never>? = nil,
         authorityChanges: AnyPublisher<Void, Never>? = nil) {
        self.controller = controller; self.ticket = ticket
        (identityChanges ?? Self.appIdentityChanges()).sink { @Sendable [weak self] in
            CurationReadContextDelivery.perform { [weak self] in self?.cancel() }
        }.store(in: &subscriptions)
        (authorityChanges ?? Self.appAuthorityChanges()).sink { @Sendable [weak self] in
            CurationReadContextDelivery.perform { [weak self] in self?.retireIfContextLost() }
        }.store(in: &subscriptions)
    }

    private static func appIdentityChanges() -> AnyPublisher<Void, Never> {
        Publishers.Merge(ProfileStore.shared.$activeID.dropFirst().map { _ in () },
                         VortXSyncManager.shared.$isSignedIn.dropFirst().map { _ in () })
            .eraseToAnyPublisher()
    }

    private static func appAuthorityChanges() -> AnyPublisher<Void, Never> {
        var notes = [VortXSyncManager.credentialScopeDidChangeNote]
        notes.append(CoreBridge.xperienceContextChangedNote)
        return Publishers.MergeMany(notes.map { name in
            NotificationCenter.default.publisher(for: name).map { _ in () }.eraseToAnyPublisher()
        }).eraseToAnyPublisher()
    }

    private var hasSavedReceipt: Bool {
        controller.phase == .saved || controller.phase == .savedNeedsConnection
    }

    private func retireIfContextLost() {
        // Completed saves no longer have an attempt. Do not turn their nil attempt into a
        // cancellation or overwrite the existing saved/savedNeedsConnection receipt.
        if hasSavedReceipt { privateURL = ""; selectedID = nil; return }
        if !controller.isCurrentContext(ticket) { cancel() }
    }

    func preview() {
        guard !retired, controller.isCurrentContext(ticket) else { cancel(); return }
        let original = privateURL
        privateURL = ""; selectedID = nil
        start {
            let choices = try await self.controller.previewURL(original, ticket: self.ticket)
            guard !Task.isCancelled, !self.retired else { return }
            if choices.count == 1 { self.selectedID = choices.first?.id }
        }
    }

    func apply(onFinish: @escaping @MainActor () -> Void) {
        guard !retired, controller.isCurrentContext(ticket), let selectedID else { return }
        start {
            try await self.controller.selectAndSave(upstreamCollectionID: selectedID, ticket: self.ticket)
            guard !Task.isCancelled, !self.retired else { return }
            onFinish()
        }
    }

    func refresh(onFinish: @escaping @MainActor () -> Void) {
        guard !retired, controller.isCurrentContext(ticket) else { cancel(); return }
        start {
            try await self.controller.refreshNow(ticket: self.ticket)
            guard !Task.isCancelled, !self.retired else { return }
            onFinish()
        }
    }

    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !retired, controller.phase != .loading, controller.phase != .saving, task == nil else { return }
        let id = UUID(); requestID = id
        localMessage = nil
        task = Task { @MainActor in
            defer { if self.requestID == id { self.task = nil } }
            guard !Task.isCancelled, self.requestID == id, !self.retired else { return }
            do { try await operation() }
            catch {
                guard !Task.isCancelled, self.requestID == id, !self.retired else { return }
                self.localMessage = self.controller.phase == .savedNeedsConnection
                    ? String(localized: "The VortX collection was saved. Reconnect this device to save its private Xperience connection.")
                    : String(localized: "The connection attempt ended without saving. Close this panel and start a fresh attempt.")
            }
        }
    }

    func cancel() {
        guard !didRetire else { return }
        didRetire = true
        privateURL = ""; selectedID = nil; localMessage = nil
        requestID = UUID()
        task?.cancel(); task = nil
        // cancel(ticket) leaves a completed save receipt alone and cannot cancel a successor.
        controller.cancel(ticket)
        retired = true
    }
}
