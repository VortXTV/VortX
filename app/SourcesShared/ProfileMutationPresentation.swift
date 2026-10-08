import Combine
import Foundation

/// Keeps a profile editor open until its captured mutation is acknowledged. Cancellation retires the
/// presentation only; a mutation already admitted by the storage layer is not falsely described as rolled back.
@MainActor
final class ProfileMutationPresentation: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    private var generation: UUID?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func start(operation: @escaping @MainActor () async -> Bool,
               failureMessage: @escaping @MainActor () -> String,
               onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !isRunning else { return }
        let owner = UUID()
        generation = owner
        isRunning = true
        errorMessage = nil
        task = Task { @MainActor [weak self] in
            let accepted = await operation()
            guard let self, !Task.isCancelled, self.generation == owner else { return }
            self.task = nil
            self.generation = nil
            self.isRunning = false
            if accepted { onSuccess() }
            else { self.errorMessage = failureMessage() }
        }
    }

    func cancel() {
        generation = nil
        task?.cancel()
        task = nil
        isRunning = false
    }
}
