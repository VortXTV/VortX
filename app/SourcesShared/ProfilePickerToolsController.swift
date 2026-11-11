#if os(iOS) || os(macOS) || os(tvOS)
import Combine
import Foundation

/// The restore service supplies this concrete action only after its dedicated CAS path is installed.
/// UI receives fixed outcomes, never keys, account witnesses, arbitrary HTTP bodies or upload callbacks.
@MainActor
struct ProfilePickerToolsRestoreAction {
    enum Outcome: Sendable {
        case notSubmitted(String), conflict
        case deliveryUnconfirmed(UUID), uploadAccepted(UUID), serverConfirmed(UUID)
    }
    enum LocalOutcome: Sendable {
        case loaded(UUID), pending(UUID), providerSettlementUnavailable(UUID), accountChanged, recoveryUnavailable
    }
    struct Retained: Sendable {
        enum State: Equatable, Sendable { case needsVerification, serverConfirmed, loaded }
        let operationID: UUID
        let state: State
        var providerSettlementUnavailable = false
    }
    enum StoredStatus: Sendable {
        case available([Retained]), accountChanged, recoveryUnavailable
    }
    /// Both continuations are required. A file-only adapter cannot expose a no-op Finish button.
    let status: @MainActor () async -> StoredStatus
    let finish: @MainActor (UUID) async -> LocalOutcome
    let submit: @MainActor (Data) async -> Outcome
    /// Explicit verification is read-only; it never repeats the confirmed upload.
    let verify: @MainActor (UUID) async -> Outcome
}

@MainActor
final class ProfilePickerToolsController: ObservableObject {
    static let shared = ProfilePickerToolsController()
    static let maximumFileBytes = 10 * 1024 * 1024

    typealias Owner = ProfilePickerToolsAccountOwner
    struct Selected: Sendable { let bytes: Data; let sha256: String }
    struct Saved: Sendable { let filename: String; let bytes: Int; let sha256: String }
    struct Repair: Identifiable, Sendable { let id: UUID; let profiles: Int; let bytes: Int }
    enum CopyKind: Sendable { case accountBackup, repairedAccount }
    enum Action: Equatable, Sendable { case download, repair, restore, restoreStatus, finishRestore }
    enum PickerPurpose: Equatable, Sendable { case input, destination }
    struct Picker: Identifiable, Sendable {
        let id: UUID
        let operationID: UUID
        let routeID: UUID
        let purpose: PickerPurpose
    }
    enum Stage: Equatable {
        case idle, choosingInput, reading, downloading, preparing
        case waitingForPhone, waitingForNetworkDrain, outputAvailable, localSendComplete
        case reviewRepair, confirmRestore, choosingDestination, saving, restoring, checkingRestore, finishingRestore, draining
    }
    struct Status: Equatable {
        var stage: Stage = .idle
        var message: String?
        var selectedFilename: String?
        var fileBytes: Int?
        var profiles: Int?
    }
    struct Services {
        let owner: @MainActor () -> Owner?
        let isCurrent: @MainActor (Owner) -> Bool
        let download: @MainActor () async throws -> Data
        #if os(iOS) || os(macOS)
        let read: @Sendable (URL) async throws -> Selected
        let digest: @Sendable (Data) async -> String
        let save: @Sendable (Data, String, CopyKind, URL) async throws -> Saved
        #endif
        let prepareRepair: @MainActor (Data) async throws -> Repair
        let takeRepair: @MainActor (UUID) throws -> Data
        let cancelRepair: @MainActor (UUID) -> Void
        let restore: ProfilePickerToolsRestoreAction
        var transfer: ProfilePickerToolsTVTransfer.Configuration? = nil
        // Credential/account continuity outlives a retired presentation; action admission does not.
        var ownerIsCurrent: (@MainActor (Owner) -> Bool)? = nil
    }

    @Published private(set) var status = Status()
    @Published private(set) var picker: Picker?
    @Published private(set) var isBusy = false
    @Published private(set) var restoreNeedsVerification = false
    @Published private var restoreDiscoveryPending = false
    @Published private(set) var tvPublication: ProfilePickerToolsTVTransfer.Publication?
    @Published private(set) var canRetryTVOutput = false
    @Published private(set) var canRetryTVInput = false
    private var routeOwner: Owner?
    private var routeID: UUID?
    private var services: Services?
    private var operation: Operation?
    private var task: Task<Void, Never>?
    private struct OriginalRestore {
        let owner: Owner
        let operationID: UUID
        let confirmed: Bool
        let action: ProfilePickerToolsRestoreAction
        let isCurrent: @MainActor (Owner) -> Bool
    }
    // A real submit result may arrive after its view closes. Keep the original typed observation
    // privately; publish it only when an exact same-owner route is later admitted.
    private var originalRestore: OriginalRestore?
    private var pendingRestoreOwner: Owner?
    private var pendingRestoreID: UUID?
    private var pendingRestoreAction: ProfilePickerToolsRestoreAction?
    private var pendingRestoreIsCurrent: (@MainActor (Owner) -> Bool)?
    @Published private(set) var canVerifyRestore = false
    @Published private(set) var canFinishRestore = false

    @MainActor private final class Operation {
        let id: UUID
        let routeID: UUID
        let owner: Owner
        let action: Action
        let services: Services
        var cancelled = false
        var completed = false
        var repairID: UUID?
        var bytes: Data?
        var digest: String?
        let transferOwner: ProfilePickerToolsTransferPolicy.Owner
        var transfer: (any ProfilePickerToolsTransferChannel)?
        var networkClosedForRestore = false
        var retainedRestoreOutcome: ProfilePickerToolsRestoreAction.Outcome?
        var terminalMessage: String?
        init(routeID: UUID, owner: Owner, action: Action, services: Services) {
            let identifier = UUID()
            self.id = identifier
            self.routeID = routeID; self.owner = owner; self.action = action; self.services = services
            // Opaque transfer fence only. The actual UInt64 epoch remains in owner.credential.
            transferOwner = .init(sessionID: UUID(), routeID: routeID, operationID: identifier, credentialGeneration: UUID())
        }
    }
    private enum Refusal: Error { case stale, tooLarge, invalidSelection }

    /// A singleton retains the sole slot through cancelled provider coordination and view recreation.
    /// Reopening Tools can replace a presentation, never an in-flight worker or its original services.
    func present(_ id: UUID, services: Services) {
        guard routeID != id else { return }
        if routeID != id, let previous = routeID { dismiss(previous) }
        routeID = id
        self.services = services
        routeOwner = services.owner() // Captured once for this route, never at a later action or callback.
        restoreDiscoveryPending = routeOwner != nil
        if let owner = pendingRestoreOwner, !services.isCurrent(owner) {
            pendingRestoreOwner = nil; pendingRestoreID = nil; pendingRestoreAction = nil; pendingRestoreIsCurrent = nil
            restoreNeedsVerification = false; canVerifyRestore = false; canFinishRestore = false
        }
        if let retained = originalRestore, retained.owner == routeOwner,
           services.isCurrent(retained.owner), retained.isCurrent(retained.owner) {
            publishRestoreObservation(retained)
        }
        if operation != nil {
            status = Status(stage: .draining,
                message: "Finishing the previous cancelled file operation. New file actions will be available when it returns.")
        } else {
            if status.stage != .idle { status = Status() }
            discoverRestore(route: id)
        }
    }

    var accountActionsAvailable: Bool {
        guard let owner = routeOwner, let services else { return false }
        return services.isCurrent(owner)
    }
    // Bounded, read-only scheduling seam; immutable identity only, never account material.
    var retainedRestoreOperationID: UUID? {
        guard let value = operation?.retainedRestoreOutcome else { return nil }
        switch value {
        case .deliveryUnconfirmed(let id), .uploadAccepted(let id), .serverConfirmed(let id): return id
        case .notSubmitted, .conflict: return nil
        }
    }
    var canRestore: Bool { accountActionsAvailable && !isBusy && !restoreDiscoveryPending && !restoreNeedsVerification }
    var canCancelFileAction: Bool { isBusy && operation?.action != .restoreStatus }

    func begin(_ action: Action, route id: UUID) {
        guard [.download, .repair, .restore].contains(action),
              routeID == id, operation == nil, task == nil, let services,
              let owner = routeOwner, services.isCurrent(owner),
              action != .restore || canRestore else { return }
        let captured = Operation(routeID: id, owner: owner, action: action, services: services)
        operation = captured; isBusy = true
        status = Status()
        if captured.services.transfer != nil {
            beginTV(captured)
            return
        }
        #if os(iOS) || os(macOS)
        if action == .download {
            start(captured, stage: .downloading) { [self] in
                try require(captured)
                let bytes = try await captured.services.download()
                try require(captured)
                try await prepareDestination(bytes, operation: captured)
            }
        } else {
            status.stage = .choosingInput
            picker = Picker(id: UUID(), operationID: captured.id, routeID: id, purpose: .input)
        }
        #endif
    }

    #if os(iOS) || os(macOS)
    /// The picker host captures this immutable request. A delayed callback cannot use today's picker ID.
    func picked(_ request: Picker, result: Result<[URL], Error>) {
        guard let captured = operation, picker?.id == request.id,
              captured.id == request.operationID, captured.routeID == request.routeID,
              isCurrent(captured) else { return }
        picker = nil
        guard case .success(let urls) = result, urls.count == 1 else {
            cancel(operationID: captured.id)
            return
        }
        let url = urls[0]
        guard url.isFileURL else { fail(captured, message: "Choose a file or folder on this device or its file provider."); return }
        if request.purpose == .input {
            start(captured, stage: .reading) { [self] in
                try require(captured)
                let selected = try await captured.services.read(url)
                try require(captured)
                guard !selected.bytes.isEmpty, selected.bytes.count <= Self.maximumFileBytes else { throw Refusal.tooLarge }
                status.selectedFilename = url.lastPathComponent
                status.fileBytes = selected.bytes.count
                if captured.action == .repair {
                    status.stage = .preparing
                    let preview = try await captured.services.prepareRepair(selected.bytes)
                    captured.repairID = preview.id // Exact late result is cancelled even if presentation retired.
                    try require(captured)
                    status.stage = .reviewRepair
                    status.profiles = preview.profiles
                    status.fileBytes = preview.bytes
                    status.message = "The repaired copy is ready. Save it as a new file; your original stays unchanged."
                } else {
                    captured.bytes = selected.bytes
                    status.stage = .confirmRestore
                    status.message = "Restore replaces the backup stored for your signed-in account. Review the selected file, then confirm."
                }
            }
        } else {
            guard let bytes = captured.bytes, let digest = captured.digest else { cancel(operationID: captured.id); return }
            let kind: CopyKind = captured.action == .repair ? .repairedAccount : .accountBackup
            start(captured, stage: .saving) { [self] in
                try require(captured)
                let saved = try await captured.services.save(bytes, digest, kind, url)
                try require(captured)
                guard saved.bytes == bytes.count, saved.sha256 == digest else { throw Refusal.invalidSelection }
                finish(captured, message: "Saved \(saved.filename) and verified its local contents. Cloud-provider synchronization may finish later.")
            }
        }
    }

    #endif

    func saveRepair(route id: UUID) {
        guard routeID == id, let captured = operation, status.stage == .reviewRepair,
              let previewID = captured.repairID, isCurrent(captured), task == nil,
              captured.transfer?.hasOwnedWork != true else { return }
        start(captured, stage: .preparing) { [self] in
            try require(captured)
            let bytes = try captured.services.takeRepair(previewID)
            captured.repairID = nil
            try require(captured)
            if let transfer = captured.transfer {
                try installTVOutput(bytes, operation: captured, transfer: transfer)
            } else {
                #if os(iOS) || os(macOS)
                try await prepareDestination(bytes, operation: captured)
                #endif
            }
        }
    }

    /// Only this explicit confirmation admits the dedicated restore action. There is no retry/PUT loop.
    func confirmRestore(route id: UUID) {
        guard routeID == id, let captured = operation, status.stage == .confirmRestore,
              isCurrent(captured), task == nil, let bytes = captured.bytes,
              captured.transfer == nil || (captured.networkClosedForRestore
                && captured.transfer?.networkIsDrained == true && captured.transfer?.hasOwnedWork == false) else { return }
        start(captured, stage: .restoring) { [self] in
            try require(captured)
            let outcome = await captured.services.restore.submit(bytes)
            // Retain known delivery state for the original account even if its presentation was
            // cancelled after a possible send. No stale route receives a result or another upload.
            retainRestoreOutcome(outcome, operation: captured)
            try require(captured)
            reportRestore(outcome, operation: captured)

        }
    }

    /// Original operation ID only. A readback action cannot become an upload or a latest-owner retry.
    func verifyRestore(route id: UUID) {
        guard routeID == id, operation == nil, task == nil, let services,
              let owner = pendingRestoreOwner, services.isCurrent(owner),
              let operationID = pendingRestoreID, let action = pendingRestoreAction,
              canVerifyRestore else { return }
        let captured = Operation(routeID: id, owner: owner, action: .restore, services: services)
        operation = captured; isBusy = true
        start(captured, stage: .restoring) { [self] in
            try require(captured)
            let outcome = await action.verify(operationID)
            retainRestoreOutcome(outcome, operation: captured)
            try require(captured)
            reportRestore(outcome, operation: captured)
        }
    }

    /// Restart discovery uses the same retained task/owner/route slot as every other Tools action.
    private func discoverRestore(route id: UUID) {
        guard !Task.isCancelled, routeID == id, operation == nil, task == nil, let services,
              let owner = routeOwner, services.isCurrent(owner) else { return }
        let captured = Operation(routeID: id, owner: owner, action: .restoreStatus, services: services)
        operation = captured; isBusy = true
        restoreDiscoveryPending = false
        start(captured, stage: .checkingRestore) { [self] in
            let discovered = await captured.services.restore.status()
            try require(captured)
            switch discovered {
            case .available(let records):
                if let pending = records.first(where: { $0.state != .loaded }) {
                    pendingRestoreOwner = captured.owner; pendingRestoreID = pending.operationID
                    pendingRestoreAction = captured.services.restore; pendingRestoreIsCurrent = captured.services.ownerIsCurrent ?? captured.services.isCurrent
                    restoreNeedsVerification = true
                    canVerifyRestore = pending.state == .needsVerification
                    canFinishRestore = pending.state == .serverConfirmed
                    finish(captured, message: pending.providerSettlementUnavailable ? Self.providerSettlementMessage : canFinishRestore
                        ? "The restored backup is confirmed on the server. Use Finish loading backup to receive it on this device."
                        : "A previous restore is retained. Verify the stored backup before continuing; do not upload it again.")
                } else if let loaded = records.first(where: { $0.state == .loaded && (pendingRestoreID == nil || $0.operationID == pendingRestoreID) }) {
                    reportLocalRestore(.loaded(loaded.operationID), originalID: loaded.operationID, operation: captured)
                } else {
                    // An authenticated empty inventory cannot erase another in-memory operation.
                    if pendingRestoreID == nil {
                        restoreNeedsVerification = false; canVerifyRestore = false; canFinishRestore = false
                    }
                    finish(captured, message: pendingRestoreID == nil ? "Backup tools are ready." : Self.pendingRestoreMessage)
                }
            case .accountChanged, .recoveryUnavailable:
                restoreNeedsVerification = true; canVerifyRestore = false; canFinishRestore = false
                finish(captured, message: "The retained restore could not be verified. Its recovery files have been kept. Reopen Tools after account recovery is available.")
            }
        }
    }

    func finishRestore(route id: UUID) {
        guard routeID == id, operation == nil, task == nil, let services,
              let owner = pendingRestoreOwner, services.isCurrent(owner),
              let originalID = pendingRestoreID, let action = pendingRestoreAction, canFinishRestore else { return }
        let captured = Operation(routeID: id, owner: owner, action: .finishRestore, services: services)
        operation = captured; isBusy = true
        start(captured, stage: .finishingRestore) { [self] in
            let result = await action.finish(originalID)
            try require(captured)
            reportLocalRestore(result, originalID: originalID, operation: captured)
        }
    }

    private static let providerSettlementMessage = "This backup’s media-server or IPTV data is still awaiting verified local recovery. After server verification, use Finish loading backup to retry. The encrypted recovery copy has been kept; loading is confirmed only after the local stores finish successfully."
    private static let pendingRestoreMessage = "The backup has not yet been confirmed as loaded on this device. Local changes or account work may still be pending, or the stored backup may have changed. The original encrypted recovery copy is retained. This action does not upload it again."
    private func reportLocalRestore(_ result: ProfilePickerToolsRestoreAction.LocalOutcome,
                                    originalID: UUID, operation captured: Operation) {
        guard isCurrent(captured) else { return }
        switch result {
        case .loaded(let id) where id == originalID:
            guard pendingRestoreID == nil || (pendingRestoreID == id && pendingRestoreOwner == captured.owner) else {
                finish(captured, message: Self.pendingRestoreMessage)
                return
            }
            pendingRestoreOwner = nil; pendingRestoreID = nil; pendingRestoreAction = nil; pendingRestoreIsCurrent = nil
            if originalRestore?.operationID == id, originalRestore?.owner == captured.owner { originalRestore = nil }
            restoreNeedsVerification = false; canVerifyRestore = false; canFinishRestore = false
            finish(captured, message: "The restored backup was loaded on this device. Its encrypted recovery copy has been kept. Opening the current profile may still be in progress.")
        case .pending(let id) where id == originalID:
            finish(captured, message: Self.pendingRestoreMessage)
        case .providerSettlementUnavailable(let id) where id == originalID:
            finish(captured, message: Self.providerSettlementMessage)
        case .accountChanged:
            finish(captured, message: "The account changed before loading could be confirmed. Reopen Tools for the current account.")
        case .recoveryUnavailable:
            finish(captured, message: "Local completion could not be verified. The encrypted recovery copy has been kept; no restore was uploaded again.")
        default:
            finish(captured, message: Self.pendingRestoreMessage)
        }
    }

    private func retainRestoreOutcome(_ outcome: ProfilePickerToolsRestoreAction.Outcome, operation captured: Operation) {
        captured.retainedRestoreOutcome = outcome // Original immutable result survives cancelled/stale UI.
        let id: UUID, confirmed: Bool
        switch outcome {
        case .deliveryUnconfirmed(let value), .uploadAccepted(let value): id = value; confirmed = false
        case .serverConfirmed(let value): id = value; confirmed = true
        case .notSubmitted, .conflict: return
        }
        let retained = OriginalRestore(owner: captured.owner, operationID: id, confirmed: confirmed,
            action: captured.services.restore, isCurrent: captured.services.ownerIsCurrent ?? captured.services.isCurrent)
        originalRestore = retained
        guard operation === captured, routeID == captured.routeID, routeOwner == captured.owner,
              captured.services.isCurrent(captured.owner) else { return }
        publishRestoreObservation(retained)
    }
    private func publishRestoreObservation(_ retained: OriginalRestore) {
        pendingRestoreOwner = retained.owner; pendingRestoreID = retained.operationID
        pendingRestoreAction = retained.action; pendingRestoreIsCurrent = retained.isCurrent
        canVerifyRestore = !retained.confirmed; canFinishRestore = retained.confirmed
        restoreNeedsVerification = true
    }

    private func reportRestore(_ outcome: ProfilePickerToolsRestoreAction.Outcome, operation captured: Operation) {
        retainRestoreOutcome(outcome, operation: captured)
        let message: String
        switch outcome {
        case .notSubmitted(let reason):
            message = reason
        case .conflict:
            message = "The stored account backup changed. This tool will not repeat the restore. Download the latest backup before considering another restore."
        case .deliveryUnconfirmed:
            message = "Restore delivery is unconfirmed. Do not upload it again. Check the stored backup with Verify restore."
        case .uploadAccepted:
            message = "The server accepted the backup upload. Verification and local profile recovery are still pending. Verify restore before continuing."
        case .serverConfirmed:
            message = "The restored backup is confirmed on the server. Use Finish loading backup to receive it on this device. This does not upload the file again."
        }
        finish(captured, message: message)
    }

    func cancel(operationID: UUID? = nil) {
        guard let captured = operation, operationID == nil || captured.id == operationID else { return }
        if captured.action == .restoreStatus, !restoreDiscoveryPending {
            // A cancelled inventory is not evidence that there is no retained restore.
            restoreNeedsVerification = true
            canVerifyRestore = false
            canFinishRestore = false
        }
        captured.cancelled = true
        picker = nil; tvPublication = nil; canRetryTVInput = false; canRetryTVOutput = false
        // Keep exact input/output and possible-send state inside the original operation until drain.
        if let id = captured.repairID { captured.services.cancelRepair(id); captured.repairID = nil }
        task?.cancel()
        status = Status(stage: .draining,
            message: captured.terminalMessage ?? "Cancellation requested. Waiting for the original file, account and phone-transfer work to return.")
        captured.transfer?.retire()
        releaseIfDrained(captured)
    }

    func dismiss(_ id: UUID) {
        guard routeID == id else { return }
        cancel()
        routeID = nil
        services = nil; routeOwner = nil
        restoreDiscoveryPending = false
        if operation == nil { status = Status() }
    }

    /// Foreground/PIN/route changes revoke the original operation without recapturing authority.
    func admissionDidChange(route id: UUID? = nil, revoked: Bool = false) {
        guard id == nil || routeID == id else { return }
        if let captured = operation {
            if revoked || !isCurrent(captured) {
                if captured.routeID == routeID, captured.action == .restoreStatus {
                    restoreDiscoveryPending = true
                }
                cancel(operationID: captured.id)
            }
        } else if !revoked, restoreDiscoveryPending, let routeID {
            discoverRestore(route: routeID)
        }
    }

    func credentialDidChange() {
        if let captured = operation, !captured.services.isCurrent(captured.owner) { cancel(operationID: captured.id) }
        if let owner = pendingRestoreOwner, pendingRestoreIsCurrent?(owner) != true {
            pendingRestoreOwner = nil; pendingRestoreID = nil; pendingRestoreAction = nil; pendingRestoreIsCurrent = nil
            restoreNeedsVerification = false; canVerifyRestore = false; canFinishRestore = false
        }
        if operation == nil, task == nil {
            status = Status()
            if let id = routeID { discoverRestore(route: id) }
        }
    }

    private func isCurrent(_ captured: Operation) -> Bool {
        operation === captured && routeID == captured.routeID && !captured.cancelled
            && !Task.isCancelled && routeOwner == captured.owner && captured.services.isCurrent(captured.owner)
    }
    private func require(_ captured: Operation) throws {
        guard isCurrent(captured) else { throw Refusal.stale }
    }
    #if os(iOS) || os(macOS)
    private func prepareDestination(_ bytes: Data, operation captured: Operation) async throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumFileBytes else { throw Refusal.tooLarge }
        try require(captured)
        let digest = await captured.services.digest(bytes)
        try require(captured)
        captured.bytes = bytes; captured.digest = digest
        status.stage = .choosingDestination
        status.fileBytes = bytes.count
        picker = Picker(id: UUID(), operationID: captured.id, routeID: captured.routeID, purpose: .destination)
    }
    #endif
    private func start(_ captured: Operation, stage: Stage,
                       body: @escaping @MainActor () async throws -> Void) {
        guard task == nil, isCurrent(captured) else { return }
        status.stage = stage
        task = Task { @MainActor [self] in
            defer { returned(captured) }
            do { try require(captured); try await body() }
            catch {
                if let id = captured.repairID { captured.services.cancelRepair(id); captured.repairID = nil }
                guard isCurrent(captured) else { return }
                if error is CancellationError { cancel(operationID: captured.id) }
                else { fail(captured, message: Self.message(error)) }
            }
        }
    }
    private func returned(_ captured: Operation) {
        guard operation === captured else { return }
        task = nil
        if captured.transfer != nil { tvChanged(captured) }
        releaseIfDrained(captured)
    }
    private func releaseIfDrained(_ captured: Operation) {
        guard operation === captured, task == nil,
              captured.transfer == nil || captured.transfer?.isDrained == true else { return }
        if captured.cancelled || captured.completed || routeID != captured.routeID
            || !captured.services.isCurrent(captured.owner) {
            if let id = captured.repairID { captured.services.cancelRepair(id) }
            captured.bytes = nil; captured.digest = nil; captured.transfer = nil
            operation = nil; isBusy = false; picker = nil
            tvPublication = nil; canRetryTVOutput = false; canRetryTVInput = false
            if routeID != captured.routeID { status = Status() }
            else if captured.cancelled { status = Status(message: captured.terminalMessage ?? "Cancelled.") }
            if let currentRoute = routeID,
               currentRoute != captured.routeID || restoreDiscoveryPending || !captured.services.isCurrent(captured.owner) {
                // This may still be the original cancelled controller worker. Claim discovery
                // only in a fresh task, after checking the exact route and empty owned slot.
                Task { @MainActor [weak self] in
                    guard let self, self.routeID == currentRoute,
                          self.operation == nil, self.task == nil else { return }
                    self.discoverRestore(route: currentRoute)
                }
            }
        }
    }
    private func finish(_ captured: Operation, message: String) {
        guard isCurrent(captured) else { return }
        captured.bytes = nil; captured.digest = nil
        // Task remains retained until its actual closure returns; returned() releases the slot.
        captured.completed = true
        captured.transfer?.retire()
        tvPublication = nil; canRetryTVOutput = false; canRetryTVInput = false
        status = Status(message: message)
        releaseIfDrained(captured)
    }
    private func fail(_ captured: Operation, message: String) {
        guard operation === captured else { return }
        captured.bytes = nil; captured.digest = nil; picker = nil
        captured.completed = true
        status = Status(message: message)
        captured.transfer?.retire()
        tvPublication = nil; canRetryTVOutput = false; canRetryTVInput = false
        releaseIfDrained(captured)
    }
    private func beginTV(_ captured: Operation) {
        guard let configuration = captured.services.transfer else { return }
        let mode: ProfilePickerToolsTransferPolicy.Mode
        switch captured.action { case .download: mode = .download; case .repair: mode = .repair; default: mode = .restore }
        let input: ProfilePickerToolsTVTransfer.Receiver?
        if captured.action == .download {
            input = nil
        } else {
            input = { @MainActor @Sendable [weak self, weak captured] value in
                guard let self, let captured else { return }
                await self.receiveTVInput(value, operation: captured)
            }
        }
        do {
            try require(captured)
            let transfer = try configuration.make(.init(owner: captured.transferOwner, mode: mode,
                liveGrant: { [weak self, weak captured] supplied in
                    guard let self, let captured, supplied == captured.transferOwner else { return false }
                    return self.isCurrent(captured)
                }, input: input, changed: { [weak self, weak captured] supplied in
                    guard let self, let captured, supplied == captured.transferOwner else { return }
                    self.tvChanged(captured)
                }))
            captured.transfer = transfer
            if captured.action == .download {
                start(captured, stage: .downloading) { [self] in
                    let bytes = try await captured.services.download()
                    try require(captured)
                    // One immutable GET snapshot. A phone retry never enters this closure again.
                    try installTVOutput(bytes, operation: captured, transfer: transfer)
                    try transfer.start()
                    tvChanged(captured)
                }
            } else {
                status = Status(stage: .waitingForPhone,
                    message: "Scan the QR with a phone on the same trusted Wi-Fi, then choose one encrypted backup file.")
                try transfer.start()
                tvChanged(captured)
            }
        } catch { fail(captured, message: "Phone transfer could not start. Check this TV's local-network permission and trusted Wi-Fi, then start a new action.") }
    }

    private func receiveTVInput(_ input: ProfilePickerToolsTransferPolicy.ImmutableInput,
                                operation captured: Operation) async {
        guard input.owner == captured.transferOwner, !captured.completed, captured.bytes == nil,
              let configuration = captured.services.transfer, let transfer = captured.transfer else { return }
        do {
            try require(captured)
            guard !input.bytes.isEmpty, input.bytes.count <= Self.maximumFileBytes else { throw Refusal.tooLarge }
            // Original Data only; no JSON reconstruction, filename, URL or browser-provided authority.
            captured.bytes = input.bytes
            status = Status(stage: .reading, fileBytes: input.bytes.count)
            try await configuration.inspect(input.bytes)
            try require(captured)
            if captured.action == .repair {
                status.stage = .preparing
                let preview = try await captured.services.prepareRepair(input.bytes)
                captured.repairID = preview.id
                try require(captured)
                try transfer.showReview(owner: captured.transferOwner)
                status = Status(stage: .reviewRepair,
                    message: "Review this supported repair on the TV. Your original file stays unchanged.",
                    fileBytes: preview.bytes, profiles: preview.profiles)
            } else {
                try transfer.showReview(owner: captured.transferOwner)
                captured.networkClosedForRestore = true
                status = Status(stage: .waitingForNetworkDrain,
                    message: "The encrypted file is received. Closing and draining the phone connection before TV confirmation.",
                    fileBytes: input.bytes.count)
                try transfer.closeNetworkForRestore(owner: captured.transferOwner)
            }
        } catch {
            if let id = captured.repairID { captured.services.cancelRepair(id); captured.repairID = nil }
            if isCurrent(captured) { fail(captured, message: Self.message(error)) }
            else { cancel(operationID: captured.id) }
        }
        // The adapter still owns this exact callback until its actual return is acknowledged.
    }

    private func installTVOutput(_ bytes: Data, operation captured: Operation,
                                 transfer: any ProfilePickerToolsTransferChannel) throws {
        try require(captured)
        guard !bytes.isEmpty, bytes.count <= Self.maximumFileBytes else { throw Refusal.tooLarge }
        captured.bytes = bytes
        try transfer.installOutput(bytes, snapshotID: UUID(), owner: captured.transferOwner)
        status = Status(stage: .outputAvailable,
            message: "Scan the QR and download this encrypted copy on your phone. Keep this screen open.", fileBytes: bytes.count)
    }

    private func tvChanged(_ captured: Operation) {
        guard operation === captured, let transfer = captured.transfer,
              transfer.owner == captured.transferOwner else { return }
        if !isCurrent(captured) {
            if !captured.cancelled && !captured.completed { cancel(operationID: captured.id) }
            releaseIfDrained(captured)
            return
        }
        if captured.completed { releaseIfDrained(captured); return }
        // A retired adapter cannot admit another action while an external account worker returns.
        if transfer.failed || transfer.isDrained {
            captured.terminalMessage = transfer.failed
                ? "Phone transfer failed. Check trusted Wi-Fi and this TV's local-network permission before starting another action."
                : "The phone transfer closed or expired. Any possible restore remains subject to its retained verification; it will not be uploaded again automatically."
            cancel(operationID: captured.id)
            return
        }
        tvPublication = transfer.publication
        canRetryTVOutput = task == nil && !transfer.hasOwnedWork && transfer.attemptsAreDrained
            && transfer.outputInfo != nil && transfer.localSendOutcome != nil
        canRetryTVInput = task == nil && !transfer.hasOwnedWork && transfer.attemptsAreDrained
            && captured.action != .download && captured.bytes == nil && transfer.stage == .closed
        if captured.networkClosedForRestore, task == nil, !transfer.hasOwnedWork, transfer.networkIsDrained {
            status.stage = .confirmRestore
            status.message = "Phone transfer is closed. Confirm on this TV to replace the backup stored for your signed-in account."
        }
        if let outcome = transfer.localSendOutcome {
            status.stage = .localSendComplete
            switch outcome {
            case .tvFinishedSendingCheckPhone:
                status.message = "TV finished sending. Check the download on your phone and save it there."
            case .failedCheckPhone:
                status.message = "TV could not confirm its complete send. Check your phone; after this attempt drains, Retry same file uses this exact copy."
            }
        } else if canRetryTVInput {
            status.message = "The upload stopped before a complete file was accepted. Retry phone upload, then rescan the new QR."
        }
    }

    func retryTVOutput(route id: UUID) {
        guard routeID == id, let captured = operation, isCurrent(captured),
              task == nil, canRetryTVOutput, let transfer = captured.transfer,
              !transfer.hasOwnedWork, transfer.attemptsAreDrained else { return }
        do {
            // No GET, conversion, takeRepair, new snapshot, owner or deadline here.
            try transfer.retrySameOutput(owner: captured.transferOwner)
            status.stage = .outputAvailable
            status.message = "Rescan the new QR to download the same encrypted copy. Check and save the file on your phone."
            tvChanged(captured)
        } catch { status.message = "This phone transfer can no longer be retried. Close this action before starting another." }
    }

    func retryTVInput(route id: UUID) {
        guard routeID == id, let captured = operation, isCurrent(captured),
              task == nil, canRetryTVInput, captured.bytes == nil, let transfer = captured.transfer,
              !transfer.hasOwnedWork, transfer.attemptsAreDrained else { return }
        do {
            try transfer.retryInput(owner: captured.transferOwner)
            status.stage = .waitingForPhone
            status.message = "Rescan the new QR and choose the encrypted backup file on your phone."
            tvChanged(captured)
        } catch { status.message = "This upload can no longer be retried. Close this action before starting another." }
    }

    private static func message(_ error: Error) -> String {
        if let failure = error as? VortxAccountFileRepairService.Failure { return failure.errorDescription ?? "The backup could not be prepared." }
        #if os(iOS) || os(macOS)
        if error is VortxAccountFileAccess.Failure {
            return "The file operation could not be completed or verified. Your selected original was not overwritten. If saving had started, check the destination for a partial copy."
        }
        #endif
        if let refusal = error as? Refusal, case .tooLarge = refusal { return "Choose a nonempty backup of 10 MiB or less." }
        return "The backup operation could not be completed. Check your sign-in, connection and selected file, then try again."
    }
}

/// Lifetime follows the actual Tools presentation, not onDisappear fired by a system picker/share cover.
/// A stale lease can dismiss only its original route; the shared task slot survives until its worker returns.
@MainActor
final class ProfilePickerToolsLease: ObservableObject {
    let routeID: UUID
    private let controller: ProfilePickerToolsController
    init(routeID: UUID, controller: ProfilePickerToolsController) { self.routeID = routeID; self.controller = controller }
    deinit {
        let original = routeID, controller = controller
        Task { @MainActor in controller.dismiss(original) }
    }
}
#endif
