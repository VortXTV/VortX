// Standalone synthetic CoreBridge boundary for the REAL Store/ViewModel files. No native ABI,
// checkpoint, credential, account service, file-provider or app/device acceptance is claimed.
import Combine
import Foundation

@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    @Published var activeID: UUID? = UUID()
}

@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    @Published var isSignedIn = true
}

enum LibraryAutoAdd {
    static let watchlistChangedNote = Notification.Name("synthetic.xperience.watchlist")
}

/// The Store never inspects the prepared value. This deliberately has no export-budget or
/// cloud authority: those actual native components have their separate checkpoint/ABI tests.
struct XperiencePreparedExport: Sendable {}

@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    static let xperienceContextChangedNote = Notification.Name("synthetic.xperience.context")
    struct Context: Equatable {
        var credential = UUID()
        var installation = UUID()
        var registry = UUID()
    }
    struct NativeXperienceTarget {
        let id: UUID
        let profile: UUID?
        let context: Context
        let lifetime: XperienceImportLifetime
    }
    private struct HeldSave {
        let edit: XperienceImportNamespace.Edit
        let target: NativeXperienceTarget
        let latch: VortxNativeHostFieldCommitLatch
        let continuation: CheckedContinuation<VortxJSON, Error>
    }
    var context = Context()
    var registers: [String: VortxJSON] = [:]
    var rejectPreparation = false
    var holdPreparation = false
    private(set) var captures: [NativeXperienceTarget] = []
    private(set) var preparationCount = 0
    private(set) var saveIDs: [UUID] = []
    private(set) var syntheticPublications = 0
    private var saves: [UUID: HeldSave] = [:]
    private var saveWaiter: (Int, CheckedContinuation<UUID, Never>)?
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    private var preparationGate: CheckedContinuation<Void, Never>?
    private var snapshotWaiter: CheckedContinuation<Void, Never>?
    private var currentCheckWaiter: CheckedContinuation<Void, Never>?

    func captureNativeXperienceTarget() throws -> NativeXperienceTarget {
        guard VortXSyncManager.shared.isSignedIn else { throw XperiencePersistenceFailure.unavailable }
        let target = NativeXperienceTarget(id: UUID(), profile: ProfileStore.shared.activeID,
            context: context, lifetime: XperienceImportLifetime())
        captures.append(target)
        return target
    }
    func retireNativeXperienceTarget(_ target: NativeXperienceTarget) { target.lifetime.revoke() }
    func nativeXperienceTargetIsCurrent(_ target: NativeXperienceTarget) -> Bool {
        let result = target.lifetime.isActive && target.profile == ProfileStore.shared.activeID
            && target.context == context && VortXSyncManager.shared.isSignedIn
        let waiter = currentCheckWaiter
        currentCheckWaiter = nil
        waiter?.resume()
        return result
    }
    func nativeXperienceSnapshot(target: NativeXperienceTarget) throws
        -> (registers: [String: VortxJSON], candidates: [XperienceAddonBinding.Candidate]) {
        guard nativeXperienceTargetIsCurrent(target) else { throw XperiencePersistenceFailure.staleContext }
        let waiter = snapshotWaiter
        snapshotWaiter = nil
        waiter?.resume()
        return (registers, [])
    }
    func prepareNativeXperienceExportBudget(target: NativeXperienceTarget) async throws -> XperiencePreparedExport {
        preparationCount += 1
        if rejectPreparation { throw XperiencePersistenceFailure.unavailable }
        guard nativeXperienceTargetIsCurrent(target) else { throw XperiencePersistenceFailure.staleContext }
        if holdPreparation {
            await withCheckedContinuation { gate in
                preparationGate = gate
                let waiter = preparationWaiter; preparationWaiter = nil; waiter?.resume()
            }
        }
        try Task.checkCancellation()
        guard nativeXperienceTargetIsCurrent(target) else { throw XperiencePersistenceFailure.staleContext }
        return .init()
    }
    func saveNativeXperienceImport(_ edit: XperienceImportNamespace.Edit, target: NativeXperienceTarget,
                                  validator: XperiencePreparedExport) async throws -> VortxJSON {
        try Task.checkCancellation()
        guard nativeXperienceTargetIsCurrent(target) else { throw XperiencePersistenceFailure.staleContext }
        let id = UUID()
        let latch = VortxNativeHostFieldCommitLatch(source: target.lifetime)
        return try await withTaskCancellationHandler {
            let receipt = try await withCheckedThrowingContinuation { continuation in
                saves[id] = .init(edit: edit, target: target, latch: latch, continuation: continuation)
                saveIDs.append(id)
                if let (index, waiter) = saveWaiter, saveIDs.indices.contains(index) {
                    saveWaiter = nil; waiter.resume(returning: saveIDs[index])
                }
            }
            try Task.checkCancellation()
            guard nativeXperienceTargetIsCurrent(target) else { throw XperiencePersistenceFailure.staleContext }
            return receipt
        } onCancel: { latch.cancel() }
    }

    func waitForSave(at index: Int) async -> UUID {
        if saveIDs.indices.contains(index) { return saveIDs[index] }
        precondition(saveWaiter == nil)
        return await withCheckedContinuation { saveWaiter = (index, $0) }
    }
    func waitForPreparation() async {
        if preparationGate != nil { return }
        precondition(preparationWaiter == nil)
        await withCheckedContinuation { preparationWaiter = $0 }
    }
    func releasePreparation() { let gate = preparationGate; preparationGate = nil; gate?.resume() }

    /// Waits for the real Store notification subscriber to call its real snapshot boundary.
    /// Its continuation resumes on MainActor only after that synchronous subscriber returns.
    func observeNotification(_ action: () -> Void) async {
        precondition(snapshotWaiter == nil)
        await withCheckedContinuation { snapshotWaiter = $0; action() }
    }
    func observeCurrentCheck(_ action: () -> Void) async {
        precondition(currentCheckWaiter == nil)
        await withCheckedContinuation { currentCheckWaiter = $0; action() }
    }
    func notify() { NotificationCenter.default.post(name: XperienceCollectionsStore.changedNote, object: nil) }
    func notifyContext() { NotificationCenter.default.post(name: Self.xperienceContextChangedNote, object: nil) }
    func receipt(for id: UUID) -> VortxJSON {
        guard let held = saves[id] else { preconditionFailure("missing synthetic save") }
        return .object(["clock": .integer(1), "actor": .string("10000000-0000-4000-8000-000000000001"),
                        "value": held.edit.value])
    }
    /// Models publication before the saving continuation, not a native durable transaction.
    func publish(_ id: UUID, extra: [String: VortxJSON] = [:], alterValue: Bool = false) throws {
        guard let held = saves[id] else { preconditionFailure("missing synthetic save") }
        // No await separates the MainActor context check and latch entry. Inside the latch,
        // never re-read lifetime.isActive: its actual source authority already holds that lock.
        guard nativeXperienceTargetIsCurrent(held.target) else { throw XperiencePersistenceFailure.staleContext }
        try held.latch.withActive {
            var receipt = receipt(for: id)
            if alterValue { receipt = .object(["clock": .integer(1), "actor": .string("synthetic"), "value": .null]) }
            registers[held.edit.field] = receipt
            registers.merge(extra) { _, new in new }
            syntheticPublications += 1
        }
    }
    func finish(_ id: UUID, error: Error? = nil) {
        let value = receipt(for: id)
        guard let held = saves.removeValue(forKey: id) else { preconditionFailure("missing synthetic save") }
        if let error { held.continuation.resume(throwing: error) }
        else { held.continuation.resume(returning: value) }
    }
}
