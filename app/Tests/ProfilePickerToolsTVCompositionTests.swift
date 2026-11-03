import Foundation
import CoreGraphics

// Compile the WHOLE maintained controller, Access, policy and TV transport interface with this file.
// Explicit synthetic account/inspection/transport seams only. No live service or LAN adapter is linked.
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Equatable, Sendable { let generation: UInt64 }
    var generation: UInt64 = 1
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}
enum VortxAccountFileRepairService {
    enum Failure: Error { case fixture; var errorDescription: String? { "Synthetic repair refusal" } }
}
enum VortxAccountFileAccess { enum Failure: Error { case fixture } }

@MainActor private final class TVGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func value() async -> Value {
        await withCheckedContinuation {
            continuation = $0; entered = true; waiter?.resume(); waiter = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func returnValue(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

/// Deliberately inert. Individual callback facts are controlled separately; cancel is not drain.
/// A real production policy creates immutable input so its private Claim initializer is not forged.
@MainActor private final class TVFakeChannel: ProfilePickerToolsTransferChannel {
    typealias P = ProfilePickerToolsTransferPolicy
    let request: ProfilePickerToolsTVTransfer.Request
    let owner: P.Owner
    var publication: ProfilePickerToolsTVTransfer.Publication?
    var stage: P.Stage = .waitingForFile
    var localSendOutcome: P.LocalSendOutcome?
    var outputInfo: P.OutputInfo?
    var failed = false
    var hasOwnedWork = false
    var attemptsAreDrained = true
    var networkIsDrained = false
    var isDrained = false
    private(set) var starts = 0
    private(set) var reviews = 0
    private(set) var closeRequests = 0
    private(set) var retireRequests = 0
    private(set) var retries = 0
    private(set) var inputRetries = 0
    private(set) var installed: [Data] = []
    private(set) var snapshots: [UUID] = []
    private var retired = false
    private var inputTask: Task<Void, Never>?
    private var accepted: P.ImmutableInput?
    private let capability: P.Capability
    private let policy: P.Session
    init(_ request: ProfilePickerToolsTVTransfer.Request) throws {
        self.request = request; owner = request.owner
        let capability = try P.Capability(hex: String(repeating: "a", count: 64))
        self.capability = capability
        policy = try P.Session(owner: request.owner, mode: request.mode, capability: capability, now: 0)
    }
    private func require(_ supplied: P.Owner) throws {
        guard supplied == owner, !retired, request.liveGrant(owner) else { throw P.Refusal.denied }
    }
    func freshGrant(_ supplied: P.Owner? = nil) -> Bool { request.liveGrant(supplied ?? owner) }
    func notify(_ supplied: P.Owner? = nil) { request.changed(supplied ?? owner) }
    func start() throws {
        try require(owner); starts += 1
        if outputInfo == nil { stage = request.mode == .download ? .preparing : .waitingForFile }
        notify()
    }
    func showReview(owner supplied: P.Owner) throws {
        try require(supplied); reviews += 1; stage = .reviewOnTV; notify()
    }
    func installOutput(_ bytes: Data, snapshotID: UUID, owner supplied: P.Owner) throws {
        try require(supplied)
        guard installed.isEmpty, !bytes.isEmpty else { throw P.Refusal.snapshotAlreadySet }
        installed.append(bytes); snapshots.append(snapshotID)
        outputInfo = .init(owner: owner, snapshotID: snapshotID, byteCount: bytes.count,
                           filename: request.mode == .repair ? .repaired : .backup)
        stage = .available; notify()
    }
    func retrySameOutput(owner supplied: P.Owner) throws {
        try require(supplied)
        guard attemptsAreDrained, !hasOwnedWork, outputInfo != nil, localSendOutcome != nil else { throw P.Refusal.busy }
        retries += 1; localSendOutcome = nil; stage = .available; notify()
    }
    func retryInput(owner supplied: P.Owner) throws {
        try require(supplied)
        guard attemptsAreDrained, !hasOwnedWork, accepted == nil, stage == .closed else { throw P.Refusal.busy }
        inputRetries += 1; stage = .waitingForFile; notify()
    }
    func closeNetworkForRestore(owner supplied: P.Owner) throws {
        try require(supplied)
        guard request.mode == .restore, stage == .reviewOnTV else { throw P.Refusal.notReady }
        closeRequests += 1; publication = nil; notify()
    }
    func retire() {
        if retired { return }
        retired = true; retireRequests += 1; stage = .closed; publication = nil
        inputTask?.cancel(); notify()
    }
    func acknowledgeNetworkDrain() { networkIsDrained = true; notify() }
    func acknowledgeFullDrain() {
        precondition(retired && !hasOwnedWork)
        networkIsDrained = true; attemptsAreDrained = true; isDrained = true; notify()
    }
    func setAttemptsDrained(_ drained: Bool) { attemptsAreDrained = drained; notify() }
    func setOwnedWorkForDrainCheck(_ working: Bool) { hasOwnedWork = working; notify() }
    func locallyCompleteOutput(success: Bool) {
        precondition(outputInfo != nil)
        localSendOutcome = success ? .tvFinishedSendingCheckPhone : .failedCheckPhone
        stage = success ? .localSendComplete : .closed; attemptsAreDrained = false; notify()
    }
    func markPartialInputFailure() { stage = .closed; attemptsAreDrained = false; notify() }
    @discardableResult func enqueueInput(_ bytes: Data) throws -> Task<Void, Never> {
        try require(owner)
        guard accepted == nil, let receiver = request.input else { throw P.Refusal.consumed }
        let endpoint = try P.Endpoint(ipv4: "192.0.2.1", port: 25001)
        var parser = try P.HeaderParser(endpoint: endpoint, now: 0)
        let header = Data(("POST /input HTTP/1.1\r\nHost: " + endpoint.authority
            + "\r\nOrigin: " + endpoint.origin + "\r\nAuthorization: Bearer " + capability.qrFragment
            + "\r\nContent-Type: application/octet-stream\r\nContent-Length: " + String(bytes.count) + "\r\n\r\n").utf8)
        guard let head = try parser.consume(header, now: 0).head else { throw P.Refusal.framing }
        let claim = try policy.reserveInput(head, now: 0, liveGrant: request.liveGrant)
        for offset in stride(from: 0, to: bytes.count, by: P.chunkBytes) {
            try policy.appendInput(bytes.subdata(in: offset..<min(bytes.count, offset + P.chunkBytes)),
                                   claim: claim, now: 0, liveGrant: request.liveGrant)
        }
        let input = try policy.commitInput(claim: claim, now: 0, liveGrant: request.liveGrant)
        accepted = input; stage = .preparing; hasOwnedWork = true; attemptsAreDrained = false
        let task = Task { @MainActor [self] in
            await receiver(input)
            hasOwnedWork = false; attemptsAreDrained = true; inputTask = nil; notify()
        }
        inputTask = task; notify(); return task
    }
    func duplicateCommittedCallback() async {
        guard let accepted, let receiver = request.input else { return }
        await receiver(accepted)
    }
}

@MainActor private final class TVHarness {
    typealias Model = ProfilePickerToolsController
    let model = Model()
    var owner: Model.Owner?
    var actionAdmitted = true
    var ownerReads = 0
    var downloads = 0, inspections = 0, preparations = 0, takes = 0
    var localReads = 0, localSaves = 0, localDigests = 0
    var submits = 0, verifies = 0, discoveries = 0
    var submittedBytes: [Data] = []
    var verifiedIDs: [UUID] = [], finishedIDs: [UUID] = [], cancelledPreviews: [UUID] = []
    var channels: [TVFakeChannel] = []
    var downloadGate: TVGate<Data>?
    var inspectGate: TVGate<Bool>?
    var prepareGate: TVGate<Model.Repair>?
    var submitGate: TVGate<ProfilePickerToolsRestoreAction.Outcome>?
    var verifyGate: TVGate<ProfilePickerToolsRestoreAction.Outcome>?
    var statusGate: TVGate<ProfilePickerToolsRestoreAction.StoredStatus>?
    var finishGate: TVGate<ProfilePickerToolsRestoreAction.LocalOutcome>?
    // Explicit synthetic durable manager inventory, keyed by the original service owner.
    // This is not a real encrypted journal or a proof of journal persistence.
    var records: [(owner: Model.Owner, entries: [ProfilePickerToolsRestoreAction.Retained])] = []
    let previewID = UUID()
    nonisolated static let original = Data("synthetic exact encrypted original bytes".utf8)
    nonisolated static let repaired = Data("synthetic exact repaired bytes with original archive".utf8)
    nonisolated static let downloaded = Data("synthetic exact downloaded bytes".utf8)
    init() {
        owner = .init(credential: CredentialScopeRegistry.shared.capture(), accountID: "synthetic-account-A")
    }
    var channel: TVFakeChannel { channels.last! }
    private func inspect(_ bytes: Data) async throws {
        precondition(bytes == Self.original)
        inspections += 1
        if let gate = inspectGate, !(await gate.value()) { throw VortxAccountFileAccess.Failure.fixture }
    }
    private func record(_ outcome: ProfilePickerToolsRestoreAction.Outcome, owner: Model.Owner?) {
        guard let owner else { return }
        let id: UUID, state: ProfilePickerToolsRestoreAction.Retained.State
        switch outcome {
        case .deliveryUnconfirmed(let value), .uploadAccepted(let value): id = value; state = .needsVerification
        case .serverConfirmed(let value): id = value; state = .serverConfirmed
        case .conflict, .notSubmitted: return
        }
        let entries = [ProfilePickerToolsRestoreAction.Retained(operationID: id, state: state)]
        if let index = records.firstIndex(where: { $0.owner == owner }) { records[index].entries = entries }
        else { records.append((owner, entries)) }
    }
    func services() -> Model.Services {
        let originalServiceOwner = owner
        var result = Model.Services(owner: {
            self.ownerReads += 1
            return self.actionAdmitted ? self.owner : nil
        }, isCurrent: { expected in
            self.actionAdmitted && self.owner == expected
                && CredentialScopeRegistry.shared.isCurrent(expected.credential)
        }, download: {
            self.downloads += 1
            if let gate = self.downloadGate { return await gate.value() }
            return Self.downloaded
        }, read: { _ in
            await MainActor.run { self.localReads += 1 }
            return .init(bytes: Self.original, sha256: "synthetic-digest")
        }, digest: { _ in
            await MainActor.run { self.localDigests += 1 }
            return "synthetic-digest"
        }, save: { bytes, _, _, _ in
            await MainActor.run { self.localSaves += 1 }
            return .init(filename: "synthetic.json", bytes: bytes.count, sha256: "synthetic-digest")
        }, prepareRepair: { bytes in
            precondition(bytes == Self.original)
            self.preparations += 1
            if let gate = self.prepareGate { return await gate.value() }
            return .init(id: self.previewID, profiles: 4, bytes: bytes.count)
        }, takeRepair: { id in
            precondition(id == self.previewID)
            self.takes += 1; return Self.repaired
        }, cancelRepair: { self.cancelledPreviews.append($0) }, restore: .init(status: {
            self.discoveries += 1
            if let gate = self.statusGate { return await gate.value() }
            guard let originalServiceOwner else { return .accountChanged }
            return .available(self.records.first(where: { $0.owner == originalServiceOwner })?.entries ?? [])
        }, finish: { id in
            self.finishedIDs.append(id)
            if let gate = self.finishGate { return await gate.value() }
            return .pending(id)
        }, submit: { bytes in
            self.submits += 1; self.submittedBytes.append(bytes)
            let outcome: ProfilePickerToolsRestoreAction.Outcome
            if let gate = self.submitGate { outcome = await gate.value() }
            else { outcome = .notSubmitted("Synthetic refusal before submission") }
            self.record(outcome, owner: originalServiceOwner)
            return outcome
        }, verify: { id in
            self.verifies += 1; self.verifiedIDs.append(id)
            let outcome: ProfilePickerToolsRestoreAction.Outcome
            if let gate = self.verifyGate { outcome = await gate.value() }
            else { outcome = .serverConfirmed(id) }
            self.record(outcome, owner: originalServiceOwner)
            return outcome
        }))
        result.transfer = .init(inspect: { bytes in try await self.inspect(bytes) }, make: { request in
            let channel = try TVFakeChannel(request)
            self.channels.append(channel); return channel
        })
        return result
    }
    func present() -> UUID {
        let route = UUID(); model.present(route, services: services()); return route
    }
    func presentReady() async -> UUID {
        let route = present()
        await ProfilePickerToolsTVCompositionTests.settle { !self.model.isBusy }
        return route
    }
    func replaceAccount(_ id: String) {
        CredentialScopeRegistry.shared.generation += 1
        owner = .init(credential: CredentialScopeRegistry.shared.capture(), accountID: id)
    }
    func cancelAndDrain() async {
        model.cancel()
        if let channel = channels.last {
            await ProfilePickerToolsTVCompositionTests.settle { !channel.hasOwnedWork }
            channel.acknowledgeFullDrain()
        }
        await ProfilePickerToolsTVCompositionTests.settle { !self.model.isBusy }
    }
}

@main @MainActor enum ProfilePickerToolsTVCompositionTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1; print("PASS \(message)")
    }
    static func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "synthetic TV controller schedule did not settle")
    }
    static func main() async throws {
        do {
            let h = TVHarness(), owner = h.owner!
            let fileGrant = ProfilePickerToolsAccountGrant(owner: owner, admission: { h.actionAdmitted })
            let diagnosticGrant = ProfilePickerToolsDiagnosticGrant(allowed: true,
                credential: owner.credential, admission: { true })
            check(fileGrant.permits(owner) && diagnosticGrant.permitsExport,
                  "separate original account and diagnostic grants can each admit their own operation")
            h.actionAdmitted = false
            check(!fileGrant.permits(owner) && diagnosticGrant.permitsExport,
                  "failed-profile diagnostic exception cannot waive current account-file PIN or route admission")
            let refused = ProfilePickerToolsAccountGrant(owner: nil, admission: { true })
            check(!refused.permits(owner), "captured missing account cannot gain file authority from later admission")
            h.actionAdmitted = true; h.replaceAccount("synthetic-account-A")
            check(!fileGrant.permits(owner), "actual captured credential generation revokes the separate account-file grant")
        }
        do {
            let admission = ProfilePickerToolsRouteAdmission(isForeground: true)
            let read: @MainActor () -> Bool = { admission.permits }
            check(read(), "route admission reference initially reflects its foreground permission")
            admission.setForeground(false)
            check(!read(), "captured route admission reads a fresh background revocation")
            admission.setForeground(true)
            check(read(), "a live foreground reference can resume before route retirement")
            admission.retire(); admission.setForeground(true)
            check(!read(), "retired route admission remains denied after a later foreground update")
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            h.model.begin(.download, route: route)
            await settle { h.channel.installed.count == 1 }
            let channel = h.channel
            h.model.admissionDidChange(route: UUID(), revoked: true)
            check(channel.retireRequests == 0 && channel.freshGrant() && h.model.isBusy,
                  "a stale view background event cannot revoke the active replacement route")
            h.model.admissionDidChange(route: route, revoked: true)
            check(channel.retireRequests == 1 && !channel.freshGrant() && h.model.isBusy,
                  "the original active route background event retires only its owned transfer")
            channel.acknowledgeFullDrain(); await settle { !h.model.isBusy }
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            let initialReads = h.ownerReads
            h.replaceAccount("synthetic-account-B")
            h.model.begin(.download, route: route)
            check(h.downloads == 0 && h.channels.isEmpty && h.ownerReads == initialReads,
                  "idle old route refuses a different account without recapturing its owner at click")
            h.replaceAccount("synthetic-account-A")
            h.model.begin(.repair, route: route)
            check(h.channels.isEmpty && !h.model.accountActionsAvailable && h.ownerReads == initialReads,
                  "account ABA cannot revive the original captured route epoch")
        }
        do {
            let h = TVHarness(), worker = TVGate<Data>()
            h.downloadGate = worker
            let route = await h.presentReady(), discoveriesBefore = h.discoveries
            h.model.begin(.download, route: route)
            await worker.waitForEntry(); let original = h.channel
            h.model.cancel(); original.acknowledgeFullDrain()
            let next = h.present()
            let status = TVGate<ProfilePickerToolsRestoreAction.StoredStatus>()
            h.statusGate = status
            worker.returnValue(TVHarness.downloaded)
            // This must observe the actual new status callback, not the transient empty slot
            // between the cancelled worker's return and its queued fresh discovery Task.
            await settle { status.entered }
            await status.waitForEntry()
            check(h.discoveries == discoveriesBefore + 1 && h.model.isBusy
                    && h.model.status.stage == .checkingRestore && original.installed.isEmpty,
                  "cancelled worker return starts real fresh-route discovery after original channel drain")
            h.model.begin(.download, route: next)
            check(h.downloads == 1 && h.channels.count == 1 && h.model.isBusy,
                  "fresh discovery owns its task slot until the actual status callback returns")
            status.returnValue(.available([]))
            await settle { !h.model.isBusy }
            check(h.discoveries == discoveriesBefore + 1 && h.model.accountActionsAvailable
                    && h.model.status.stage == .idle && !h.model.restoreNeedsVerification,
                  "fresh discovery callback settles without leaving a claimed slot whose worker never started")
            h.statusGate = nil; h.downloadGate = nil
            h.model.begin(.download, route: next)
            await settle { h.channels.count == 2 && h.channel.installed.count == 1 }
            check(h.downloads == 2 && h.channel.installed == [TVHarness.downloaded]
                    && !original.freshGrant(),
                  "a new action is admitted only after genuine fresh discovery completes and cannot revive the cancelled transfer")
            await h.cancelAndDrain()
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            let discoveriesBefore = h.discoveries
            h.model.begin(.download, route: route)
            await settle { h.channel.installed.count == 1 }
            let original = h.channel
            h.model.cancel()
            let abandoned = h.present()
            let status = TVGate<ProfilePickerToolsRestoreAction.StoredStatus>()
            h.statusGate = status
            original.acknowledgeFullDrain() // Synchronously queues discovery for abandoned.
            h.replaceAccount("synthetic-account-B")
            let current = h.present() // Replaces that route before either queued task can run.
            let ownerReadsAtCurrent = h.ownerReads
            await settle { status.entered }
            await status.waitForEntry()
            check(h.discoveries == discoveriesBefore + 1 && h.ownerReads == ownerReadsAtCurrent
                    && h.model.isBusy && h.model.status.stage == .checkingRestore,
                  "queued discovery for a replaced route cannot recapture an owner or start a second status worker")
            h.model.begin(.download, route: abandoned)
            original.notify()
            check(h.downloads == 1 && h.channels.count == 1 && h.ownerReads == ownerReadsAtCurrent
                    && h.model.isBusy,
                  "old route actions and drained callbacks cannot replace the current route's actual status task")
            status.returnValue(.available([])); await settle { !h.model.isBusy }
            h.statusGate = nil
            h.model.begin(.download, route: current)
            await settle { h.channels.count == 2 && h.channel.installed.count == 1 }
            check(h.downloads == 2 && h.discoveries == discoveriesBefore + 1
                    && h.ownerReads == ownerReadsAtCurrent && !original.freshGrant(),
                  "only the newly admitted account route can act after its own real discovery callback settles")
            await h.cancelAndDrain()
        }
        do {
            let h = TVHarness(), gate = TVGate<Data>(); h.downloadGate = gate
            let route = await h.presentReady(); h.model.begin(.download, route: route)
            await gate.waitForEntry(); let original = h.channel
            h.model.cancel(); original.acknowledgeFullDrain()
            let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && h.downloads == 1 && h.channels.count == 1,
                  "transport drain cannot release the slot while the original noncooperative download still runs")
            gate.returnValue(TVHarness.downloaded)
            await settle { !h.model.isBusy }
            check(original.installed.isEmpty && h.model.picker == nil,
                  "cancelled download return cannot install bytes or enter the local file-save path")
            h.downloadGate = nil; h.model.begin(.download, route: next)
            await settle { h.channels.count == 2 && h.channel.installed.count == 1 }
            original.notify()
            check(h.downloads == 2 && h.channel.installed == [TVHarness.downloaded],
                  "old drained channel callback cannot replace the successor snapshot")
            await h.cancelAndDrain()
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            h.model.begin(.download, route: route)
            await settle { h.channel.installed.count == 1 }
            let original = h.channel
            h.model.cancel(); let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && h.downloads == 1 && original.retireRequests == 1,
                  "actual account worker return cannot release the slot before original channel drain")
            original.acknowledgeFullDrain(); await settle { !h.model.isBusy }
            check(h.downloads == 1, "a blocked duplicate action is never queued for automatic later execution")
        }
        do {
            let h = TVHarness(), gate = TVGate<Bool>(); h.inspectGate = gate
            let route = await h.presentReady(); h.model.begin(.repair, route: route)
            let original = h.channel; try original.enqueueInput(TVHarness.original)
            await gate.waitForEntry(); h.model.cancel(); original.acknowledgeNetworkDrain()
            let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && original.hasOwnedWork && h.downloads == 0,
                  "network-only drain does not release an owned noncooperative immutable-input callback")
            gate.returnValue(true); await settle { !original.hasOwnedWork }
            check(h.preparations == 0 && h.takes == 0 && h.model.isBusy,
                  "retired inspection cannot prepare a repair and callback return still waits for full channel drain")
            original.acknowledgeFullDrain(); await settle { !h.model.isBusy }
        }
        do {
            let h = TVHarness(), gate = TVGate<ProfilePickerToolsController.Repair>(); h.prepareGate = gate
            let route = await h.presentReady(); h.model.begin(.repair, route: route)
            let original = h.channel; try original.enqueueInput(TVHarness.original)
            await gate.waitForEntry(); h.model.cancel()
            let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && h.downloads == 0, "cancelled noncooperative prepare blocks replacement account work")
            gate.returnValue(.init(id: h.previewID, profiles: 4, bytes: TVHarness.original.count))
            await settle { !original.hasOwnedWork }
            check(h.cancelledPreviews == [h.previewID] && h.takes == 0 && h.model.isBusy,
                  "late prepared preview cancels its exact UUID and never takes an encrypted export")
            original.acknowledgeFullDrain(); await settle { !h.model.isBusy }
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            h.model.begin(.repair, route: route); h.model.begin(.download, route: route)
            let channel = h.channel; try channel.enqueueInput(TVHarness.original)
            await settle { h.model.status.stage == .reviewRepair && !channel.hasOwnedWork }
            check(h.inspections == 1 && h.preparations == 1 && h.takes == 0 && h.downloads == 0,
                  "one immutable phone upload reaches real controller review without taking output or admitting a second action")
            await channel.duplicateCommittedCallback()
            check(h.inspections == 1 && h.preparations == 1,
                  "duplicate committed input callback cannot inspect or prepare a second time")
            h.model.saveRepair(route: route); h.model.saveRepair(route: route)
            await settle { channel.installed.count == 1 }
            check(h.takes == 1 && channel.installed == [TVHarness.repaired] && channel.snapshots.count == 1,
                  "explicit TV approval takes one repair export and installs one exact immutable snapshot")
            channel.locallyCompleteOutput(success: true)
            check(!h.model.canRetryTVOutput && h.model.status.message?.contains("Check the download on your phone") == true,
                  "typed local completion asks owner to check phone and cannot retry before attempt drain")
            h.model.retryTVOutput(route: route)
            check(channel.retries == 0, "undrained local send cannot mint a successor transfer")
            channel.setAttemptsDrained(true); h.model.retryTVOutput(route: route)
            check(channel.retries == 1 && h.takes == 1 && h.downloads == 0
                    && channel.installed == [TVHarness.repaired] && channel.snapshots.count == 1,
                  "explicit retry reuses the same Data and snapshot without GET or second repair take")
            channel.locallyCompleteOutput(success: false); channel.setAttemptsDrained(true)
            h.model.retryTVOutput(route: route)
            check(channel.retries == 2 && h.takes == 1 && channel.installed == [TVHarness.repaired],
                  "failed local send also retries the retained bytes without claiming browser receipt")
            check(h.localReads == 0 && h.localSaves == 0 && h.localDigests == 0 && h.model.picker == nil,
                  "TV transfer never fabricates a file URL or verified local Saved receipt")
            await h.cancelAndDrain()
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            h.model.begin(.download, route: route)
            await settle { h.channel.installed.count == 1 }
            let channel = h.channel
            check(channel.freshGrant(), "original current route grants bounded transfer effects")
            let different = ProfilePickerToolsTransferPolicy.Owner(sessionID: UUID(), routeID: route,
                operationID: channel.owner.operationID, credentialGeneration: channel.owner.credentialGeneration)
            check(!channel.freshGrant(different), "an opaque owner mismatch cannot acquire the original route grant")
            h.actionAdmitted = false
            check(!channel.freshGrant(), "same-account current PIN admission loss synchronously denies another bounded send")
            h.model.admissionDidChange()
            check(channel.retireRequests == 1 && h.model.tvPublication == nil && h.model.isBusy,
                  "admission change immediately retires transport while preserving its drain slot")
            channel.acknowledgeFullDrain(); await settle { !h.model.isBusy }
            h.actionAdmitted = true
            check(!channel.freshGrant(), "restored PIN admission cannot revive a retired operation's old grant callback")
        }
        do {
            let h = TVHarness(), route = await h.presentReady()
            h.model.begin(.repair, route: route); let channel = h.channel
            channel.markPartialInputFailure(); h.model.retryTVInput(route: route)
            check(channel.inputRetries == 0, "partial input cannot retry until the old attempt drains")
            channel.setAttemptsDrained(true); h.model.retryTVInput(route: route)
            check(channel.inputRetries == 1 && h.inspections == 0 && h.preparations == 0,
                  "TV-only input retry remints transfer admission before any immutable input is consumed")
            try channel.enqueueInput(TVHarness.original)
            await settle { h.model.status.stage == .reviewRepair && !channel.hasOwnedWork }
            channel.markPartialInputFailure(); channel.setAttemptsDrained(true)
            h.model.retryTVInput(route: route)
            check(channel.inputRetries == 1 && h.inspections == 1,
                  "consumed complete input cannot be replaced by a new phone upload")
            await h.cancelAndDrain()
        }
        do {
            let h = TVHarness(), gate = TVGate<ProfilePickerToolsRestoreAction.Outcome>(); h.submitGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route)
            let channel = h.channel; try channel.enqueueInput(TVHarness.original)
            await settle { channel.closeRequests == 1 && !channel.hasOwnedWork }
            h.model.confirmRestore(route: route)
            check(h.submits == 0 && h.model.status.stage == .waitingForNetworkDrain,
                  "received restore input cannot submit before listener and network callbacks really drain")
            channel.setOwnedWorkForDrainCheck(true); channel.acknowledgeNetworkDrain()
            h.model.confirmRestore(route: route)
            check(h.submits == 0, "network drain alone cannot confirm while an adapter-owned worker remains")
            channel.setOwnedWorkForDrainCheck(false)
            await settle { h.model.status.stage == .confirmRestore }
            check(h.submits == 0 && channel.closeRequests == 1,
                  "drained input still requires separate explicit TV restore confirmation")
            h.model.confirmRestore(route: route); h.model.confirmRestore(route: route)
            await gate.waitForEntry()
            check(h.submits == 1 && h.submittedBytes == [TVHarness.original],
                  "double TV confirmation admits exactly one submit of the original immutable bytes")
            let original = UUID(); gate.returnValue(.deliveryUnconfirmed(original))
            await settle { h.model.retainedRestoreOperationID == original && channel.retireRequests == 1 }
            check(h.model.isBusy && h.model.restoreNeedsVerification,
                  "possible-send outcome stays in the original operation while its transport drains")
            channel.acknowledgeFullDrain(); await settle { !h.model.isBusy }
            h.model.verifyRestore(route: route); await settle { !h.model.isBusy }
            check(h.submits == 1 && h.verifies == 1 && h.verifiedIDs == [original] && h.model.canFinishRestore,
                  "Verify retains original restore UUID and uses the typed read-only continuation")
            h.model.finishRestore(route: route); await settle { !h.model.isBusy }
            check(h.finishedIDs == [original] && h.submits == 1 && h.model.restoreNeedsVerification,
                  "Finish receives only the original UUID and typed pending cannot claim loaded")
        }
        do {
            let h = TVHarness(), gate = TVGate<ProfilePickerToolsRestoreAction.Outcome>(); h.submitGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route)
            let originalChannel = h.channel; try originalChannel.enqueueInput(TVHarness.original)
            await settle { originalChannel.closeRequests == 1 && !originalChannel.hasOwnedWork }
            originalChannel.acknowledgeNetworkDrain(); h.model.confirmRestore(route: route)
            await gate.waitForEntry(); h.model.dismiss(route)
            h.replaceAccount("synthetic-account-B")
            let discoveriesBeforeReplacement = h.discoveries
            let next = h.present()
            h.model.begin(.download, route: next)
            check(h.model.isBusy && h.downloads == 0, "replacement account cannot queue work behind an original possible-send task")
            let original = UUID(); gate.returnValue(.deliveryUnconfirmed(original))
            await settle { h.model.retainedRestoreOperationID == original }
            check(h.model.isBusy && !h.model.restoreNeedsVerification
                    && h.model.status.message?.contains("delivery is unconfirmed") != true,
                  "late possible-send outcome remains original-owned and cannot publish to the replacement route")
            originalChannel.acknowledgeFullDrain()
            await settle { !h.model.isBusy && h.discoveries == discoveriesBeforeReplacement + 1 }
            check(!h.model.canVerifyRestore && !h.model.canFinishRestore && h.submits == 1,
                  "new account status does not inherit another account's restore uncertainty")
            originalChannel.notify()
            check(!h.model.restoreNeedsVerification && h.downloads == 0,
                  "retired original notification cannot resurrect uncertainty or start successor account work")
        }
        do {
            let h = TVHarness(), gate = TVGate<ProfilePickerToolsRestoreAction.Outcome>(); h.submitGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route)
            let channel = h.channel; try channel.enqueueInput(TVHarness.original)
            await settle { channel.closeRequests == 1 && !channel.hasOwnedWork }
            channel.acknowledgeNetworkDrain(); h.model.confirmRestore(route: route)
            await gate.waitForEntry()
            let discoveriesBeforeReopen = h.discoveries
            let next = h.present() // Same canonical account and Capture; original submit still runs.
            h.model.begin(.restore, route: next)
            check(h.model.isBusy && h.submits == 1 && h.discoveries == discoveriesBeforeReopen,
                  "same-account reopening before submit return retains the original task and cannot queue another restore")
            let original = UUID(); gate.returnValue(.deliveryUnconfirmed(original))
            await settle { h.model.retainedRestoreOperationID == original }
            check(h.model.isBusy && !h.model.restoreNeedsVerification && !h.model.canVerifyRestore
                    && h.discoveries == discoveriesBeforeReopen,
                  "late same-account uncertainty stays in the old draining operation without publishing to the newer route")
            channel.acknowledgeFullDrain()
            await settle { !h.model.isBusy && h.discoveries == discoveriesBeforeReopen + 1 }
            check(h.model.restoreNeedsVerification && h.model.canVerifyRestore
                    && h.discoveries == discoveriesBeforeReopen + 1 && h.submits == 1,
                  "only full original drain admits fresh same-account status discovery and its retained Verify action")
            h.model.verifyRestore(route: next); await settle { !h.model.isBusy }
            check(h.verifiedIDs == [original] && h.submits == 1,
                  "fresh same-account route verifies the original late restore UUID without a second submit")
        }
        do {
            let h = TVHarness(), gate = TVGate<ProfilePickerToolsRestoreAction.Outcome>(); h.submitGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route)
            let channel = h.channel; try channel.enqueueInput(TVHarness.original)
            await settle { channel.closeRequests == 1 && !channel.hasOwnedWork }
            channel.acknowledgeNetworkDrain(); h.model.confirmRestore(route: route)
            await gate.waitForEntry(); h.model.dismiss(route)
            let original = UUID(); gate.returnValue(.uploadAccepted(original))
            await settle { h.model.retainedRestoreOperationID == original }
            channel.acknowledgeFullDrain(); await settle { !h.model.isBusy }
            let next = await h.presentReady()
            check(h.model.restoreNeedsVerification && h.model.canVerifyRestore && h.submits == 1,
                  "reopening same account discovers retained synthetic journal status without resubmitting")
            h.model.verifyRestore(route: next); await settle { !h.model.isBusy }
            check(h.verifiedIDs == [original] && h.submits == 1,
                  "restart verification remains the exact original typed continuation")
        }
        print("\(checks) actual TV composition controller checks passed")
    }
}
