import Combine
import Foundation

/// A profile playlist as read from one exact native register. Unsupported future documents stay visible
/// as read-only placeholders and their raw register is retained for CAS, never rewritten by projection.
struct SavedPlaylistRecord: Identifiable, Equatable, Sendable {
    let field: String
    let register: VortxJSON
    let projection: VortxNativePlaylist.Projection

    var id: String { field }
    var document: VortxNativePlaylist.Document? {
        guard case .supported(let document) = projection else { return nil }
        return document
    }
    var isEditable: Bool { document != nil }
}

private struct SavedPlaylistProjection: Sendable {
    let field: String
    let register: VortxJSON
    let projection: VortxNativePlaylist.Projection

    var sortName: String {
        guard case .supported(let document) = projection else { return "" }
        return document.name
    }
}

/// A single utility actor serializes full-profile projections. Cancellation is checked between records,
/// so a burst of carrier hints or refreshes cannot leave detached whole-profile workers running in parallel.
private actor SavedPlaylistProjectionWorker {
    static let shared = SavedPlaylistProjectionWorker()

    func project(_ registers: [String: VortxJSON]) throws -> [SavedPlaylistProjection] {
        guard !Thread.isMainThread else { throw ProjectionFailure.mainThread }
        var result: [SavedPlaylistProjection] = []
        for field in registers.keys.sorted() {
            try Task.checkCancellation()
            guard let register = registers[field], case .object(let contents) = register,
                  let value = contents["value"] else { continue }
            let projection = VortxNativePlaylist.projection(field: field, value: value)
            if case .deleted = projection { continue }
            result.append(.init(field: field, register: register, projection: projection))
        }
        try Task.checkCancellation()
        let sorted = result.sorted { left, right in
            switch left.sortName.localizedCaseInsensitiveCompare(right.sortName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.field < right.field
            }
        }
        try Task.checkCancellation()
        return sorted
    }

    enum ProjectionFailure: Error { case mainThread }
}

struct SavedPlaylistCloudStatus: Equatable, Sendable {
    let field: String
    let register: VortxJSON
    let fingerprint: NativePlaylistRegisterFingerprint
    let state: NativePlaylistCloudReceiptState
}

/// An in-memory recovery draft is bound to the exact owner generation and raw register observed at edit time.
/// It contains only catalog metadata. It is not written into the synchronized host document.
struct SavedPlaylistDraft: Identifiable, Equatable, Sendable {
    enum Operation: Equatable, Sendable { case save, delete }

    let id: UUID
    let ownerGeneration: UUID
    /// Stable account namespace is held in memory only to keep old drafts hidden from other accounts.
    let accountIdentity: String
    let profileID: UUID
    let field: String
    let expectedRegister: VortxJSON?
    let document: VortxNativePlaylist.Document?
    let value: VortxJSON
    let operation: Operation

    var canSaveAsCopy: Bool { operation == .save && document != nil }
}

/// Immutable operation input captured synchronously by the initiating UI action, before Task creation.
/// It contains the exact target, receipt owner, generation, queue/record snapshot, CAS register and value.
struct SavedPlaylistWriteIntent {
    fileprivate let target: CoreBridge.NativePlaylistTarget
    fileprivate let receiptOwner: NativePlaylistReceiptOwner
    fileprivate let ownerGeneration: UUID
    fileprivate let field: String
    fileprivate let expectedRegister: VortxJSON?
    fileprivate let document: VortxNativePlaylist.Document?
    fileprivate let value: VortxJSON
    fileprivate let operation: SavedPlaylistDraft.Operation
    fileprivate let retainedSourceDraft: UUID?

    fileprivate init(target: CoreBridge.NativePlaylistTarget, receiptOwner: NativePlaylistReceiptOwner,
                     ownerGeneration: UUID, field: String, expectedRegister: VortxJSON?,
                     document: VortxNativePlaylist.Document?, value: VortxJSON,
                     operation: SavedPlaylistDraft.Operation, retainedSourceDraft: UUID?) {
        self.target = target
        self.receiptOwner = receiptOwner
        self.ownerGeneration = ownerGeneration
        self.field = field
        self.expectedRegister = expectedRegister
        self.document = document
        self.value = value
        self.operation = operation
        self.retainedSourceDraft = retainedSourceDraft
    }
}

@MainActor
final class SavedPlaylistStore: ObservableObject {
    static let shared = SavedPlaylistStore()

    @Published private var records: [SavedPlaylistRecord] = []
    @Published private var drafts: [UUID: SavedPlaylistDraft] = [:]
    @Published private(set) var isLoading = false
    @Published private var savingDraftIDs: Set<UUID> = []
    @Published private(set) var message: String?
    @Published private var latestReceipt: SavedPlaylistCloudStatus?
    @Published private var receiptStates: [String: NativePlaylistCloudReceiptState] = [:]

    /// Receipt states come from the existing exact cloud-candidate matcher. Local register readback alone
    /// never changes an item to saved; no receipt or a retired volatile receipt remains unknown.
    var canBrowseCurrentProfile: Bool {
        guard let target, let receiptOwner, target.profileID == ProfileStore.shared.activeID else { return false }
        return core.nativePlaylistTargetIsCurrent(target) && core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner)
    }

    var cloudStatusText: String {
        guard canBrowseCurrentProfile else { return "Cloud status is unknown until this profile is opened." }
        if let latestReceipt { return "Last profile change: \(receiptLabel(latestReceipt.state))." }
        return "Cloud status is unknown until checked; receipts do not survive relaunch."
    }

    private let core = CoreBridge.shared
    private let sync = VortXSyncManager.shared
    private let queue = PlaybackTitleQueue.shared
    private var target: CoreBridge.NativePlaylistTarget?
    private var receiptOwner: NativePlaylistReceiptOwner?
    private var ownerGeneration = UUID()
    private var loadGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var observedReceiptFields = Set<String>()
    private var observedReceiptRegister: VortxJSON?
    private var observedReceiptFingerprint: NativePlaylistRegisterFingerprint?
    private var observedReceiptOwnerGeneration: UUID?
    private var observedReceiptToken: UUID?
    private var receiptProjectionGeneration = UUID()
    private var refreshAfterCurrentLoad = false
    private let maximumRetainedDrafts = 32

    private init() {}

    /// Called when the user opens Saved Playlists. The target is captured before the first async operation.
    func open() {
        guard let captured = targetForNewGesture() else { return }
        readRegisters(using: captured)
    }

    /// Explicit user refresh. It does not recapture an owner for an in-flight request.
    func reloadFromUserGesture() {
        guard let captured = targetForNewGesture() else { return }
        readRegisters(using: captured)
    }

    var currentOwnerGeneration: UUID? {
        canBrowseCurrentProfile ? ownerGeneration : nil
    }

    var visibleRecords: [SavedPlaylistRecord] {
        canBrowseCurrentProfile ? records : []
    }

    func record(field: String) -> SavedPlaylistRecord? {
        guard canBrowseCurrentProfile else { return nil }
        return records.first { $0.field == field }
    }

    func record(field: String, ownerGeneration expectedGeneration: UUID) -> SavedPlaylistRecord? {
        guard ownerGeneration == expectedGeneration else { return nil }
        return record(field: field)
    }

    func receiptState(field: String, ownerGeneration expectedGeneration: UUID) -> NativePlaylistCloudReceiptState {
        guard ownerGeneration == expectedGeneration, canBrowseCurrentProfile else { return .unknown }
        if observedReceiptFields.contains(field),
           observedReceiptOwnerGeneration == expectedGeneration,
           record(field: field)?.register == observedReceiptRegister {
            return receiptStates[field] ?? .unknown
        }
        if latestReceipt?.field == field { return latestReceipt?.state ?? .unknown }
        return receiptStates[field] ?? .unknown
    }

    @discardableResult
    func beginReceiptObservation(field: String, ownerGeneration expectedGeneration: UUID) -> UUID? {
        guard ownerGeneration == expectedGeneration,
              let record = record(field: field, ownerGeneration: expectedGeneration), let owner = receiptOwner,
              let target, core.nativePlaylistTargetIsCurrent(target),
              core.nativePlaylistReceiptOwnerIsCurrent(owner) else { return nil }
        let observerToken = UUID()
        observedReceiptFields = [field]
        observedReceiptOwnerGeneration = expectedGeneration
        observedReceiptToken = observerToken
        startReceiptProjection(field: field, record: record, owner: owner, target: target,
                               ownerGeneration: expectedGeneration, observerToken: observerToken)
        return observerToken
    }

    private func startReceiptProjection(field: String, record: SavedPlaylistRecord,
                                        owner: NativePlaylistReceiptOwner,
                                        target: CoreBridge.NativePlaylistTarget,
                                        ownerGeneration expectedGeneration: UUID,
                                        observerToken: UUID) {
        observedReceiptRegister = record.register
        observedReceiptFingerprint = nil
        receiptStates[field] = .unknown
        let projectionID = UUID()
        receiptProjectionGeneration = projectionID
        Task { [weak self] in
            let fingerprint = try? await NativePlaylistCloudReceiptProjectionWorker.shared.fingerprint(record.register)
            guard let self, self.receiptProjectionGeneration == projectionID,
                  self.ownerGeneration == expectedGeneration,
                  self.observedReceiptToken == observerToken,
                  self.observedReceiptOwnerGeneration == expectedGeneration,
                  self.observedReceiptFields.contains(field), self.observedReceiptRegister == record.register,
                  self.record(field: field, ownerGeneration: expectedGeneration)?.register == record.register,
                  self.core.nativePlaylistTargetIsCurrent(target),
                  self.core.nativePlaylistReceiptOwnerIsCurrent(owner) else { return }
            self.observedReceiptFingerprint = fingerprint
            let state = fingerprint.map {
                self.sync.nativePlaylistCloudReceipt(owner: owner, field: field, fingerprint: $0)
            } ?? .unknown
            self.receiptStates[field] = state
            if let latest = self.latestReceipt, latest.field == field, latest.register == record.register {
                if let fingerprint {
                    self.latestReceipt = .init(field: field, register: record.register,
                        fingerprint: fingerprint, state: state)
                } else {
                    self.latestReceipt = nil
                }
            }
        }
    }

    private func refreshReceiptProjectionForCurrentObserver() {
        guard let field = observedReceiptFields.first, let observerToken = observedReceiptToken,
              let expectedGeneration = observedReceiptOwnerGeneration,
              let record = record(field: field, ownerGeneration: expectedGeneration),
              let owner = receiptOwner, let target,
              core.nativePlaylistTargetIsCurrent(target), core.nativePlaylistReceiptOwnerIsCurrent(owner) else { return }
        startReceiptProjection(field: field, record: record, owner: owner, target: target,
                               ownerGeneration: expectedGeneration, observerToken: observerToken)
    }

    func endReceiptObservation(field: String, ownerGeneration expectedGeneration: UUID, token: UUID) {
        guard observedReceiptOwnerGeneration == expectedGeneration,
              observedReceiptToken == token,
              observedReceiptFields.contains(field) else { return }
        observedReceiptFields.remove(field)
        observedReceiptOwnerGeneration = nil
        observedReceiptToken = nil
        observedReceiptRegister = nil
        observedReceiptFingerprint = nil
        receiptStates.removeValue(forKey: field)
        receiptProjectionGeneration = UUID()
    }

    func receiptLabel(_ state: NativePlaylistCloudReceiptState) -> String {
        switch state {
        case .unknown: return "cloud save not confirmed"
        case .pending: return "waiting to save in cloud"
        case .saved: return "saved in cloud"
        }
    }

    var visibleDrafts: [SavedPlaylistDraft] {
        guard let target, let receiptOwner, core.nativePlaylistTargetIsCurrent(target),
              core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner) else { return [] }
        return drafts.values.filter {
            $0.accountIdentity == receiptOwner.credentialNamespace && $0.profileID == target.profileID
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func draft(_ id: UUID) -> SavedPlaylistDraft? {
        guard let draft = drafts[id], let target, let receiptOwner,
              core.nativePlaylistTargetIsCurrent(target), core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner),
              draft.accountIdentity == receiptOwner.credentialNamespace, draft.profileID == target.profileID else { return nil }
        return draft
    }

    func canContinueDraft(_ id: UUID) -> Bool {
        guard let draft = draft(id), draft.ownerGeneration == ownerGeneration,
              let target, target.profileID == draft.profileID else { return false }
        return core.nativePlaylistTargetIsCurrent(target)
    }

    func isDraftSaving(_ id: UUID) -> Bool { savingDraftIDs.contains(id) }

    func discardDraft(_ id: UUID) {
        guard draft(id) != nil else { return }
        guard !savingDraftIDs.contains(id) else {
            message = "This edit is being saved. Wait for that attempt to finish before discarding it."
            return
        }
        drafts.removeValue(forKey: id)
        message = "This local draft was discarded. No saved playlist was changed."
    }

    /// Capture the queue, owner and profile target synchronously from the Save Queue button action.
    func prepareSaveCurrentQueue(named rawName: String) -> SavedPlaylistWriteIntent? {
        guard let name = Self.validName(rawName) else {
            message = "Enter a playlist name of up to 160 UTF-8 bytes."
            return nil
        }
        guard let context = capturedWriteContext(),
              let queueTarget = queue.capturePlaylistImportTarget(),
              let snapshot = queue.playlistSnapshot(for: queueTarget),
              context.target.profileID == ProfileStore.shared.activeID else {
            message = "The current profile or saved queue is not ready. Nothing changed."
            return nil
        }
        let document = VortxNativePlaylist.Document(
            id: UUID(), name: name,
            entries: snapshot.candidates.map { .init(id: UUID(), candidate: $0) }
        )
        return makeWriteIntent(document: document, field: VortxNativePlaylist.field(document.id),
            expectedRegister: nil, operation: .save, context: context)
    }

    /// Add is one synchronous admitted queue transaction. The originating detail view's generation is
    /// required so an old detail cannot switch to a successor profile that happens to share this field.
    func addToQueue(record observedRecord: SavedPlaylistRecord, ownerGeneration expectedGeneration: UUID) {
        guard let context = capturedWriteContext(observedRecord: observedRecord, expectedGeneration: expectedGeneration) else { return }
        guard let document = observedRecord.document, let queueTarget = queue.capturePlaylistImportTarget() else {
            message = "This playlist or queue is not available for the original profile. Nothing changed."
            return
        }
        let currentRegister = try? core.nativePlaylistRegisters(target: context.target)[observedRecord.field]
        guard core.nativePlaylistTargetIsCurrent(context.target), currentRegister == observedRecord.register else {
            message = "This playlist changed. Refresh it before adding it to the queue."
            return
        }
        guard queue.appendCandidates(document.entries.map(\.candidate), target: queueTarget) else {
            message = queue.admissionProblem
            return
        }
        message = "Added to the queue. Choose Play queue when you’re ready."
    }

    func prepareRename(record observedRecord: SavedPlaylistRecord, to rawName: String,
                       ownerGeneration expectedGeneration: UUID) -> SavedPlaylistWriteIntent? {
        guard let context = capturedWriteContext(observedRecord: observedRecord, expectedGeneration: expectedGeneration) else { return nil }
        guard let document = observedRecord.document else { return nil }
        guard let name = Self.validName(rawName) else {
            message = "Enter a playlist name of up to 160 UTF-8 bytes."
            return nil
        }
        let replacement = VortxNativePlaylist.Document(id: document.id, name: name, entries: document.entries)
        return makeWriteIntent(document: replacement, field: observedRecord.field, expectedRegister: observedRecord.register,
            operation: .save, context: context)
    }

    func prepareReplaceFromCurrentQueue(record observedRecord: SavedPlaylistRecord,
                                        ownerGeneration expectedGeneration: UUID) -> SavedPlaylistWriteIntent? {
        guard let context = capturedWriteContext(observedRecord: observedRecord, expectedGeneration: expectedGeneration) else { return nil }
        guard let document = observedRecord.document,
              let queueTarget = queue.capturePlaylistImportTarget(),
              let snapshot = queue.playlistSnapshot(for: queueTarget),
              context.target.profileID == ProfileStore.shared.activeID else {
            message = "The current profile or saved queue changed. Nothing changed."
            return nil
        }
        let replacement = VortxNativePlaylist.Document(
            id: document.id, name: document.name,
            entries: snapshot.candidates.map { .init(id: UUID(), candidate: $0) }
        )
        return makeWriteIntent(document: replacement, field: observedRecord.field, expectedRegister: observedRecord.register,
            operation: .save, context: context)
    }

    func prepareDelete(record observedRecord: SavedPlaylistRecord,
                       ownerGeneration expectedGeneration: UUID) -> SavedPlaylistWriteIntent? {
        guard let context = capturedWriteContext(observedRecord: observedRecord, expectedGeneration: expectedGeneration) else { return nil }
        guard let document = observedRecord.document else { return nil }
        return SavedPlaylistWriteIntent(target: context.target, receiptOwner: context.receiptOwner,
            ownerGeneration: context.ownerGeneration, field: observedRecord.field, expectedRegister: observedRecord.register,
            document: document, value: .null, operation: .delete, retainedSourceDraft: nil)
    }

    /// The confirmation action passes the already prepared immutable intent to this async method.
    /// It never captures or substitutes a target after Task starts.
    func perform(_ intent: SavedPlaylistWriteIntent) async {
        let draft = SavedPlaylistDraft(
            id: UUID(), ownerGeneration: intent.ownerGeneration,
            accountIdentity: intent.receiptOwner.credentialNamespace,
            profileID: intent.target.profileID, field: intent.field,
            expectedRegister: intent.expectedRegister, document: intent.document,
            value: intent.value, operation: intent.operation
        )
        await persist(draft, using: intent.target, receiptOwner: intent.receiptOwner,
                      retainedSourceDraft: intent.retainedSourceDraft)
    }

    /// Save-as-copy is prepared from the visible same-scope draft and current original generation.
    func prepareSaveAsCopy(draftID: UUID, ownerGeneration expectedGeneration: UUID) -> SavedPlaylistWriteIntent? {
        guard let context = capturedWriteContext(expectedGeneration: expectedGeneration),
              let draft = draft(draftID), draft.canSaveAsCopy,
              draft.ownerGeneration == context.ownerGeneration,
              let original = draft.document else {
            message = "This draft is retained, but its original profile session is no longer active."
            return nil
        }
        let copy = VortxNativePlaylist.Document(
            id: UUID(), name: original.name,
            entries: original.entries.map { .init(id: UUID(), candidate: $0.candidate) }
        )
        return makeWriteIntent(document: copy, field: VortxNativePlaylist.field(copy.id),
            expectedRegister: nil, operation: .save, context: context, retainedSourceDraft: draftID)
    }

    /// Refresh a conflict without discarding the in-memory original edit. Reload never commits or overwrites.
    func reloadKeepingDraft(_ draftID: UUID) {
        guard let draft = drafts[draftID] else { return }
        guard draft.ownerGeneration == ownerGeneration,
              let target, core.nativePlaylistTargetIsCurrent(target) else {
            message = "The original profile session is no longer active; the draft remains retained."
            return
        }
        readRegisters(using: target)
    }

    /// A change to the selected profile or credential boundary retires the exact old target immediately.
    /// Drafts stay in memory, tagged with their captured owner generation, and cannot follow a new owner.
    func profileBoundaryWillChange() {
        invalidateTarget(preserveDrafts: true)
        message = drafts.isEmpty
            ? "The saved playlist profile changed. Open the library again to load its playlists."
            : "The profile changed. Your local edit draft is retained; it cannot be written under another profile."
    }

    func activeProfileWillChange(to profileID: UUID?) {
        guard let target, target.profileID != profileID else { return }
        profileBoundaryWillChange()
    }

    /// A host-carrier change refreshes only this screen's originally captured target. If that target
    /// has retired, clear it and require an explicit reopen rather than following a successor profile.
    func nativePlaylistChangeDidOccur() {
        guard let captured = target,
              core.nativePlaylistTargetIsCurrent(captured),
              captured.profileID == ProfileStore.shared.activeID,
              let owner = receiptOwner,
              core.nativePlaylistReceiptOwnerIsCurrent(owner) else {
            contextDidChange()
            return
        }
        if isLoading {
            refreshAfterCurrentLoad = true
            return
        }
        readRegisters(using: captured)
    }

    /// Refresh receipt badges from the exact volatile same-owner/register receipt cache only.
    func cloudReceiptRevisionDidChange() {
        guard let target, let receiptOwner,
              core.nativePlaylistTargetIsCurrent(target),
              core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner) else {
            contextDidChange()
            return
        }
        if let latestReceipt {
            self.latestReceipt = .init(field: latestReceipt.field, register: latestReceipt.register,
                fingerprint: latestReceipt.fingerprint,
                state: sync.nativePlaylistCloudReceipt(owner: receiptOwner,
                    field: latestReceipt.field, fingerprint: latestReceipt.fingerprint))
        }
        if let field = observedReceiptFields.first, let fingerprint = observedReceiptFingerprint,
           let record = record(field: field), record.register == observedReceiptRegister {
            let state = sync.nativePlaylistCloudReceipt(owner: receiptOwner, field: field, fingerprint: fingerprint)
            receiptStates[field] = state
            if let latestReceipt, latestReceipt.field == field,
               latestReceipt.register == record.register, latestReceipt.fingerprint == fingerprint {
                self.latestReceipt = .init(field: field, register: record.register,
                    fingerprint: fingerprint, state: state)
            }
        }
    }

    /// Called after non-selection profile publications. Pending operations remain bound to their original
    /// target and will fail its context fence; no successor owner is sampled inside the old task.
    func contextDidChange() {
        guard let target else { return }
        let ownerIsCurrent = receiptOwner.map { core.nativePlaylistReceiptOwnerIsCurrent($0) } ?? false
        guard core.nativePlaylistTargetIsCurrent(target), ownerIsCurrent,
              target.profileID == ProfileStore.shared.activeID else {
            invalidateTarget(preserveDrafts: true)
            message = drafts.isEmpty
                ? "The saved playlist profile changed. Open the library again to load its playlists."
                : "The profile changed. Your local edit draft is retained; it cannot be written under another profile."
            return
        }
    }

    private func capturedWriteContext(expectedGeneration: UUID? = nil)
        -> (target: CoreBridge.NativePlaylistTarget, receiptOwner: NativePlaylistReceiptOwner, ownerGeneration: UUID)? {
        if let expectedGeneration {
            guard ownerGeneration == expectedGeneration,
                  let target, let receiptOwner,
                  target.profileID == ProfileStore.shared.activeID,
                  core.nativePlaylistTargetIsCurrent(target),
                  core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner) else {
                message = "The original playlist profile changed. No write was started."
                return nil
            }
            return (target, receiptOwner, ownerGeneration)
        }
        guard let target = targetForNewGesture(), let receiptOwner,
              target.profileID == ProfileStore.shared.activeID,
              receiptOwner.profileID == target.profileID,
              core.nativePlaylistTargetIsCurrent(target),
              core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner) else {
            message = "Saved playlists aren’t available for the current profile session."
            return nil
        }
        return (target, receiptOwner, ownerGeneration)
    }

    private func makeWriteIntent(document: VortxNativePlaylist.Document, field: String,
                                 expectedRegister: VortxJSON?, operation: SavedPlaylistDraft.Operation,
                                 context: (target: CoreBridge.NativePlaylistTarget,
                                           receiptOwner: NativePlaylistReceiptOwner,
                                           ownerGeneration: UUID),
                                 retainedSourceDraft: UUID? = nil) -> SavedPlaylistWriteIntent? {
        do {
            let value = try VortxNativePlaylist.encodedValue(document)
            return SavedPlaylistWriteIntent(target: context.target, receiptOwner: context.receiptOwner,
                ownerGeneration: context.ownerGeneration, field: field, expectedRegister: expectedRegister,
                document: document, value: value, operation: operation,
                retainedSourceDraft: retainedSourceDraft)
        } catch {
            message = "The playlist could not be prepared. The current saved version is unchanged."
            return nil
        }
    }

    /// Detail gestures are valid only for the exact row snapshot shown when the view was opened.
    /// A refreshed same-owner row is adopted only by an explicit reopen, never by an old detail action.
    private func capturedWriteContext(observedRecord: SavedPlaylistRecord,
                                      expectedGeneration: UUID)
        -> (target: CoreBridge.NativePlaylistTarget, receiptOwner: NativePlaylistReceiptOwner, ownerGeneration: UUID)? {
        guard let context = capturedWriteContext(expectedGeneration: expectedGeneration) else { return nil }
        guard record(field: observedRecord.field, ownerGeneration: expectedGeneration) == observedRecord else {
            message = "This playlist changed after it was opened. Refresh the library and reopen it before editing."
            return nil
        }
        return context
    }

    private func targetForNewGesture() -> CoreBridge.NativePlaylistTarget? {
        if let target {
            let ownerIsCurrent = receiptOwner.map { core.nativePlaylistReceiptOwnerIsCurrent($0) } ?? false
            guard core.nativePlaylistTargetIsCurrent(target), ownerIsCurrent,
                  target.profileID == ProfileStore.shared.activeID else {
                invalidateTarget(preserveDrafts: true)
                return captureTargetForThisGesture()
            }
            return target
        }
        return captureTargetForThisGesture()
    }

    private func captureTargetForThisGesture() -> CoreBridge.NativePlaylistTarget? {
        do {
            let captured = try core.captureNativePlaylistTarget()
            guard let receiptOwner = core.captureNativePlaylistReceiptOwner(),
                  receiptOwner.profileID == captured.profileID,
                  captured.profileID == ProfileStore.shared.activeID,
                  core.nativePlaylistTargetIsCurrent(captured),
                  core.nativePlaylistReceiptOwnerIsCurrent(receiptOwner) else {
                core.retireNativePlaylistTarget(captured)
                message = "Saved playlist sync status is unavailable for this profile session."
                return nil
            }
            target = captured
            self.receiptOwner = receiptOwner
            ownerGeneration = UUID()
            return captured
        } catch {
            message = "Saved playlists aren’t available for the current profile session."
            return nil
        }
    }

    private func readRegisters(using captured: CoreBridge.NativePlaylistTarget) {
        guard core.nativePlaylistTargetIsCurrent(captured) else {
            contextDidChange()
            return
        }
        loadTask?.cancel()
        refreshAfterCurrentLoad = false
        let generation = UUID()
        let capturedOwnerGeneration = ownerGeneration
        guard let capturedReceiptOwner = receiptOwner else {
            isLoading = false
            message = "The original playlist receipt owner is unavailable."
            return
        }
        loadGeneration = generation
        isLoading = true
        do {
            let registers = try core.nativePlaylistRegisters(target: captured)
            if let latestReceipt, registers[latestReceipt.field] != latestReceipt.register {
                self.latestReceipt = nil
            }
            loadTask = Task { [weak self] in
                do {
                    let projected = try await SavedPlaylistProjectionWorker.shared.project(registers)
                    guard let self, !Task.isCancelled, self.loadGeneration == generation,
                          self.ownerGeneration == capturedOwnerGeneration,
                          self.receiptOwner == capturedReceiptOwner,
                          self.core.nativePlaylistTargetIsCurrent(captured),
                          self.core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else { return }
                    self.records = projected.map { item in
                        SavedPlaylistRecord(field: item.field, register: item.register,
                            projection: item.projection)
                    }
                    let currentFields = Set(self.records.map(\.field))
                    self.receiptStates = self.receiptStates.filter { currentFields.contains($0.key) }
                    self.observedReceiptFields.formIntersection(currentFields)
                    if self.observedReceiptFields.isEmpty {
                        self.observedReceiptOwnerGeneration = nil
                        self.observedReceiptToken = nil
                        self.observedReceiptRegister = nil
                        self.observedReceiptFingerprint = nil
                        self.receiptStates.removeAll()
                        self.receiptProjectionGeneration = UUID()
                    }
                    if let field = self.observedReceiptFields.first,
                       let current = self.record(field: field),
                       self.observedReceiptRegister != current.register {
                        self.refreshReceiptProjectionForCurrentObserver()
                    }
                    self.isLoading = false
                    if self.refreshAfterCurrentLoad {
                        self.refreshAfterCurrentLoad = false
                        self.readRegisters(using: captured)
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.loadGeneration == generation,
                          self.ownerGeneration == capturedOwnerGeneration,
                          self.core.nativePlaylistTargetIsCurrent(captured) else { return }
                    self.isLoading = false
                    self.message = "Saved playlists couldn’t be loaded. Your edits remain untouched."
                }
            }
        } catch {
            isLoading = false
            message = "Saved playlists couldn’t be loaded. Your edits remain untouched."
        }
    }

    private func persist(_ draft: SavedPlaylistDraft, using captured: CoreBridge.NativePlaylistTarget,
                         receiptOwner capturedReceiptOwner: NativePlaylistReceiptOwner,
                         retainedSourceDraft: UUID? = nil) async {
        guard draft.accountIdentity == capturedReceiptOwner.credentialNamespace,
              draft.profileID == captured.profileID,
              draft.ownerGeneration == ownerGeneration,
              self.receiptOwner == capturedReceiptOwner,
              core.nativePlaylistTargetIsCurrent(captured),
              core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else {
            if retainDraftWithinLimit(draft) {
                message = "The original profile session changed. No write was attempted; the draft remains retained."
            } else {
                message = "The in-memory edit limit is full. No write was attempted and this new edit could not be retained."
            }
            return
        }
        guard drafts[draft.id] != nil || drafts.count < maximumRetainedDrafts else {
            message = visibleDrafts.isEmpty
                ? "The in-memory edit limit is full, and there are no drafts in this account and profile to discard here. No write was attempted. Restart the app to clear unsaved in-memory drafts."
                : "The in-memory edit limit is full. Discard a retained edit in this account and profile, or restart the app to clear unsaved in-memory drafts."
            return
        }
        guard !savingDraftIDs.contains(draft.id) else { return }
        drafts[draft.id] = draft
        savingDraftIDs.insert(draft.id)
        defer { savingDraftIDs.remove(draft.id) }
        do {
            try Task.checkCancellation()
            let budget = try await core.prepareNativePlaylistExportBudget(target: captured)
            try Task.checkCancellation()
            guard draft.ownerGeneration == ownerGeneration, self.receiptOwner == capturedReceiptOwner,
                  core.nativePlaylistTargetIsCurrent(captured),
                  core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else {
                throw VortxNativeError.superseded
            }
            let edit = VortxNativeHostFieldEdit(field: draft.field,
                expectedRegister: draft.expectedRegister, value: draft.value)
            let acceptedRegister = try await core.saveNativePlaylist(edit, target: captured, validator: budget)
            try Task.checkCancellation()
            guard draft.ownerGeneration == ownerGeneration, self.receiptOwner == capturedReceiptOwner,
                  core.nativePlaylistTargetIsCurrent(captured),
                  core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else {
                throw VortxNativeError.superseded
            }
            guard self.receiptOwner == capturedReceiptOwner,
                  core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else {
                throw VortxNativeError.superseded
            }
            let readback = try core.nativePlaylistRegisters(target: captured)
            guard readback[draft.field] == acceptedRegister else {
                throw StoreFailure.localReadbackMismatch
            }
            guard let fingerprint = try await NativePlaylistCloudReceiptProjectionWorker.shared.fingerprint(acceptedRegister) else {
                throw StoreFailure.localReadbackMismatch
            }
            try Task.checkCancellation()
            guard draft.ownerGeneration == ownerGeneration, self.receiptOwner == capturedReceiptOwner,
                  core.nativePlaylistTargetIsCurrent(captured),
                  core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner) else { throw VortxNativeError.superseded }
            let receiptState = sync.nativePlaylistCloudReceipt(owner: capturedReceiptOwner,
                field: draft.field, fingerprint: fingerprint)
            latestReceipt = .init(field: draft.field, register: acceptedRegister,
                fingerprint: fingerprint, state: receiptState)
            if observedReceiptFields.contains(draft.field) {
                observedReceiptRegister = acceptedRegister
                observedReceiptFingerprint = fingerprint
                receiptStates = [draft.field: receiptState]
            }
            drafts.removeValue(forKey: draft.id)
            if let retainedSourceDraft { drafts.removeValue(forKey: retainedSourceDraft) }
            message = "Saved to this profile. Cloud acceptance is not confirmed."
            readRegisters(using: captured)
        } catch {
            // Keep the exact draft and expected raw register. Offer recovery actions only when their original
            // captured session is still current; never imply that a retired generation can write or reload.
            let retained = retainDraftWithinLimit(draft)
            let originalSessionCurrent = draft.ownerGeneration == ownerGeneration
                && self.receiptOwner == capturedReceiptOwner
                && core.nativePlaylistTargetIsCurrent(captured)
                && core.nativePlaylistReceiptOwnerIsCurrent(capturedReceiptOwner)
            message = retained
                ? (originalSessionCurrent
                    ? "The save could not be confirmed. Your draft is retained; reload or Save as copy are available."
                    : "The save could not be confirmed. Your draft is retained for its original account and profile; reopen that session to review or discard it.")
                : "The save could not be confirmed, and the in-memory edit limit prevented retaining this draft. No other draft was removed."
        }
    }

    @discardableResult
    private func retainDraftWithinLimit(_ draft: SavedPlaylistDraft) -> Bool {
        if drafts[draft.id] != nil {
            drafts[draft.id] = draft
            return true
        }
        guard drafts.count < maximumRetainedDrafts else { return false }
        drafts[draft.id] = draft
        return true
    }

    private func invalidateTarget(preserveDrafts: Bool) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        isLoading = false
        refreshAfterCurrentLoad = false
        records = []
        latestReceipt = nil
        receiptStates = [:]
        observedReceiptFields = []
        observedReceiptOwnerGeneration = nil
        observedReceiptToken = nil
        observedReceiptRegister = nil
        observedReceiptFingerprint = nil
        receiptProjectionGeneration = UUID()
        if let target { core.retireNativePlaylistTarget(target) }
        target = nil
        receiptOwner = nil
        ownerGeneration = UUID()
        if !preserveDrafts { drafts.removeAll() }
    }

    private static func validName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 160,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private enum StoreFailure: Error { case localReadbackMismatch }
}
