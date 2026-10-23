import Combine
import Foundation

struct XperienceImportLease {
    fileprivate let identity = UUID()
    fileprivate let target: CoreBridge.NativeXperienceTarget
}

/// Manual JSON/file import only. No account login, collections URL fetching, local plaintext
/// fallback, automatic refresh or hidden mutation of installed add-ons occurs here.
@MainActor final class XperienceCollectionsStore: ObservableObject {
    static let changedNote = Notification.Name("vortx.xperienceCollectionsChanged")
    @Published private(set) var revision = UUID()
    private let core: CoreBridge
    private var subscriptions = Set<AnyCancellable>()
    private var observedLease: XperienceImportLease?
    private var observedRegisters: [String: VortxJSON]?
    private struct PendingSave {
        let id = UUID()
        let leaseID: UUID
        let edit: XperienceImportNamespace.Edit
        var nativeSubmitted = false
    }
    private var pendingSave: PendingSave?

    init(core: CoreBridge = .shared) {
        self.core = core
        // These events are hints only. Actual captured epochs and exact register snapshots decide
        // retirement, so an unrelated position update does not continually erase an open preview.
        for name in [Self.changedNote, LibraryAutoAdd.watchlistChangedNote, CoreBridge.xperienceContextChangedNote] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.checkObservation() }.store(in: &subscriptions)
        }
        // Published selection fires before its setter completes: erase immediately, never recapture
        // an A->B->A sequence from the latest UUID.
        ProfileStore.shared.$activeID.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        VortXSyncManager.shared.$isSignedIn.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
    }
    private func invalidate() {
        // Revoke synchronously BEFORE presentation retirement. The Core method only flips the
        // original lifetime lock; it performs no Bridge/facade reads or publication under it.
        if let lease = observedLease { core.retireNativeXperienceTarget(lease.target) }
        observedLease = nil; observedRegisters = nil; pendingSave = nil; revision = UUID()
    }
    private func checkObservation() {
        guard let lease = observedLease else { return }
        guard isCurrent(lease) else { invalidate(); return }
        guard let current = try? core.nativeXperienceSnapshot(target: lease.target).registers else { invalidate(); return }
        if XperienceExactEvidence.registers(current, observedRegisters) { return }
        if let pending = pendingSave, pending.nativeSubmitted, pending.leaseID == lease.identity,
           let baseline = observedRegisters,
           XperienceExactEvidence.acknowledges(pending.edit, baseline: baseline, current: current) {
            // The facade publishes only checkpoint-acknowledged host state. Do not revoke this
            // original gesture merely because its OWN durable publication beat the continuation.
            observedRegisters = current
            return
        }
        invalidate()
    }
    func capture() throws -> XperienceImportLease {
        if observedLease != nil { invalidate() } // A superseding gesture retires the old worker authority too.
        let lease = XperienceImportLease(target: try core.captureNativeXperienceTarget())
        observedLease = lease
        observedRegisters = try core.nativeXperienceSnapshot(target: lease.target).registers
        return lease
    }
    func isCurrent(_ lease: XperienceImportLease) -> Bool {
        return observedLease?.identity == lease.identity && core.nativeXperienceTargetIsCurrent(lease.target)
    }
    func candidates(_ lease: XperienceImportLease) throws -> [XperienceAddonBinding.Candidate] {
        guard isCurrent(lease) else { throw XperiencePersistenceFailure.staleContext }
        return try core.nativeXperienceSnapshot(target: lease.target).candidates
    }
    func namespaces(_ lease: XperienceImportLease) throws -> [XperienceSavedNamespace] {
        guard isCurrent(lease) else { throw XperiencePersistenceFailure.staleContext }
        return try XperienceSavedNamespace.readAll(core.nativeXperienceSnapshot(target: lease.target).registers)
    }
    func append(document: XperienceCollections.Document, label: String,
                bindings: [String: XperienceAddonBinding.Mapping], lease: XperienceImportLease) async throws -> XperienceSavedNamespace {
        guard !(try namespaces(lease)).contains(where: { $0.document.fingerprint == document.fingerprint }) else {
            throw XperiencePersistenceFailure.alreadyImported
        }
        let edit = try XperienceImportNamespace.append(document: document, label: label, bindings: bindings)
        return try await commit(edit, lease: lease)
    }
    func replace(namespace: XperienceSavedNamespace, document: XperienceCollections.Document, label: String,
                 bindings: [String: XperienceAddonBinding.Mapping], lease: XperienceImportLease) async throws -> XperienceSavedNamespace {
        try await commit(namespace.replacement(document: document, label: label, bindings: bindings), lease: lease)
    }
    private func commit(_ edit: XperienceImportNamespace.Edit, lease: XperienceImportLease) async throws -> XperienceSavedNamespace {
        try Task.checkCancellation()
        guard isCurrent(lease) else { throw XperiencePersistenceFailure.staleContext }
        guard pendingSave == nil else { throw XperiencePersistenceFailure.busy }
        let pending = PendingSave(leaseID: lease.identity, edit: edit)
        pendingSave = pending
        defer { if pendingSave?.id == pending.id { pendingSave = nil } }
        // This uses the original gesture's owner; it NEVER captures current ownership at Save.
        let register: VortxJSON
        do {
            let budget = try await core.prepareNativeXperienceExportBudget(target: lease.target)
            guard isCurrent(lease), pendingSave?.id == pending.id else { throw XperiencePersistenceFailure.staleContext }
            pendingSave?.nativeSubmitted = true
            register = try await core.saveNativeXperienceImport(edit, target: lease.target, validator: budget)
        } catch let failure as XperiencePersistenceFailure { throw failure }
        catch VortxNativeHostFieldMutationError.staleRegister { throw XperiencePersistenceFailure.staleRegister }
        catch VortxNativeHostFieldMutationError.cancelled { throw XperiencePersistenceFailure.cancelled }
        catch let failure as XperienceCollections.Failure { throw failure }
        catch VortxNativeError.checkpointUncertain { throw XperiencePersistenceFailure.persistenceUncertain }
        catch is CancellationError { throw XperiencePersistenceFailure.cancelled }
        catch VortxNativeError.superseded { throw XperiencePersistenceFailure.staleContext }
        catch { throw XperiencePersistenceFailure.unavailable }
        guard isCurrent(lease) else { throw XperiencePersistenceFailure.staleContext }
        let saved = try XperienceSavedNamespace.read(field: edit.field, register: register)
        // The facade's continuation is a durable acknowledgement/readback, not enqueue success.
        observedRegisters = try core.nativeXperienceSnapshot(target: lease.target).registers
        revision = UUID()
        NotificationCenter.default.post(name: Self.changedNote, object: nil)
        return saved
    }
}
