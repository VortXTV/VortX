import Foundation

// Disposable account/file-provider collaborators. The maintained controller and grant are unchanged.
// No filesystem, URL session, native ABI, account store or live singleton service is used by this harness.
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Equatable, Sendable { let generation: Int }
    var generation = 1
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ value: Capture) -> Bool { generation == value.generation }
}
enum VortxAccountFileRepairService {
    enum Failure: Error { case fixture; var errorDescription: String? { "Fixture repair refusal" } }
}
enum VortxAccountFileAccess { enum Failure: Error { case fixture } }

@MainActor private final class Gate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started = true
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor private final class Harness {
    typealias Model = ProfilePickerToolsController
    let model = Model()
    var owner: Model.Owner? = .init(credential: CredentialScopeRegistry.shared.capture(), accountID: "fixture-account")
    var downloadGate: Gate<Data>?
    var readGate: Gate<Model.Selected>?
    var repairGate: Gate<Model.Repair>?
    var saveGate: Gate<Model.Saved>?
    var restoreGate: Gate<ProfilePickerToolsRestoreAction.Outcome>?
    var verifyGate: Gate<ProfilePickerToolsRestoreAction.Outcome>?
    var statusGate: Gate<ProfilePickerToolsRestoreAction.StoredStatus>?
    var finishGate: Gate<ProfilePickerToolsRestoreAction.LocalOutcome>?
    var retained: [ProfilePickerToolsRestoreAction.Retained] = []
    var finishedIDs: [UUID] = []
    var discoveries = 0
    var downloads = 0, reads = 0, preparations = 0, takes = 0, saves = 0, restores = 0, verifies = 0
    var cancelledRepairs: [UUID] = []
    var verifiedIDs: [UUID] = []
    let repairID = UUID()
    nonisolated static let data = Data("fixture immutable backup".utf8)
    nonisolated static let digest = "fixture-exact-digest"
    func services() -> Model.Services {
        .init(owner: { self.owner }, isCurrent: { self.owner == $0 }, download: {
            self.downloads += 1
            if let gate = self.downloadGate { return await gate.value() }
            return Self.data
        }, read: { _ in await self.read() }, digest: { _ in Self.digest }, save: { bytes, digest, _, _ in
            await self.save(bytes: bytes, digest: digest)
        }, prepareRepair: { _ in
            self.preparations += 1
            if let gate = self.repairGate { return await gate.value() }
            return .init(id: self.repairID, profiles: 3, bytes: Self.data.count)
        }, takeRepair: { id in
            precondition(id == self.repairID)
            self.takes += 1; return Self.data
        }, cancelRepair: { self.cancelledRepairs.append($0) }, restore: .init(status: {
            self.discoveries += 1
            if let gate = self.statusGate { return await gate.value() }
            return .available(self.retained)
        }, finish: { id in
            self.finishedIDs.append(id)
            if let gate = self.finishGate { return await gate.value() }
            return .pending(id)
        }, submit: { _ in
            self.restores += 1
            if let gate = self.restoreGate { return await gate.value() }
            return .notSubmitted("Fixture refused before upload")
        }, verify: { id in
            self.verifies += 1; self.verifiedIDs.append(id)
            if let gate = self.verifyGate { return await gate.value() }
            return .serverConfirmed(id)
        }))
    }
    private func read() async -> Model.Selected {
        reads += 1
        if let gate = readGate { return await gate.value() }
        return .init(bytes: Self.data, sha256: Self.digest)
    }
    private func save(bytes: Data, digest: String) async -> Model.Saved {
        saves += 1; precondition(bytes == Self.data && digest == Self.digest)
        if let gate = saveGate { return await gate.value() }
        return .init(filename: "fixture-new-copy.json", bytes: bytes.count, sha256: digest)
    }
    func present() -> UUID { let id = UUID(); model.present(id, services: services()); return id }
    func presentReady() async -> UUID {
        let id = present()
        await ProfilePickerToolsLifecycleTests.settle { !self.model.isBusy }
        return id
    }
    func choose(_ request: Model.Picker) {
        model.picked(request, result: .success([URL(fileURLWithPath: request.purpose == .input ? "/fixture/selected.json" : "/fixture/folder")]))
    }
}

@MainActor private final class DiagnosticPolicy { var allowed = true }

@main @MainActor enum ProfilePickerToolsLifecycleTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1; print("PASS \(message)")
    }
    static func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "owned fixture operation did not settle")
    }
    static func main() async throws {
        do {
            let h = Harness(), route = UUID()
            h.model.present(route, services: h.services()); await settle { !h.model.isBusy }; h.model.begin(.repair, route: route)
            let oldPicker = h.model.picker!
            h.model.cancel(); h.choose(oldPicker)
            check(h.reads == 0 && !h.model.isBusy, "cancelled input picker cannot start a late provider read")
        }
        do {
            let h = Harness(); let gate = Gate<ProfilePickerToolsController.Selected>(); h.readGate = gate
            let route = await h.presentReady(); h.model.begin(.repair, route: route); h.choose(h.model.picker!)
            await gate.waitForStart(); h.model.cancel()
            let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && h.reads == 1 && h.downloads == 0,
                  "cancelled uncooperative provider retains the only slot across Tools recreation")
            gate.finish(.init(bytes: Harness.data, sha256: Harness.digest))
            await settle { !h.model.isBusy }
            check(h.preparations == 0 && h.model.picker == nil, "retired read cannot prepare or prompt a successor route")
            h.model.begin(.download, route: next)
            await settle { h.model.picker != nil }
            check(h.downloads == 1, "actual provider return releases the slot for one new action")
            h.model.cancel()
        }
        do {
            let h = Harness(), gate = Gate<ProfilePickerToolsController.Repair>(); h.repairGate = gate
            let route = await h.presentReady(); h.model.begin(.repair, route: route); h.choose(h.model.picker!)
            await gate.waitForStart(); h.model.dismiss(route)
            gate.finish(.init(id: h.repairID, profiles: 3, bytes: Harness.data.count))
            await settle { !h.model.isBusy }
            check(h.cancelledRepairs == [h.repairID] && h.takes == 0,
                  "late repair preview cancels its exact service UUID without taking encrypted output")
        }
        do {
            let h = Harness(), gate = Gate<Data>(); h.downloadGate = gate
            let route = await h.presentReady(); h.model.begin(.download, route: route)
            await gate.waitForStart(); h.owner = nil; h.model.credentialDidChange()
            gate.finish(Harness.data); await settle { !h.model.isBusy }
            check(h.model.picker == nil && h.saves == 0, "credential replacement denies late download before destination or save")
        }
        do {
            let h = Harness(); let route = await h.presentReady(); h.model.begin(.download, route: route)
            await settle { h.model.picker != nil }; let firstFolder = h.model.picker!
            h.model.cancel(); h.model.begin(.download, route: route)
            await settle { h.model.picker != nil }; let currentFolder = h.model.picker!
            h.choose(firstFolder)
            check(h.saves == 0 && h.model.picker?.id == currentFolder.id,
                  "late same-route folder callback cannot use a successor operation's bytes")
            h.choose(currentFolder); await settle { !h.model.isBusy }
            check(h.saves == 1 && h.model.status.message?.contains("verified its local contents") == true,
                  "success is published only after matching save length and digest receipt")
        }
        do {
            let h = Harness(), gate = Gate<ProfilePickerToolsController.Saved>(); h.saveGate = gate
            let route = await h.presentReady(); h.model.begin(.download, route: route)
            await settle { h.model.picker != nil }; h.choose(h.model.picker!)
            await gate.waitForStart(); h.model.cancel()
            check(h.model.isBusy && h.model.status.stage == .draining,
                  "save cancellation cannot free the slot before file-provider return")
            gate.finish(.init(filename: "late-copy.json", bytes: Harness.data.count, sha256: Harness.digest))
            await settle { !h.model.isBusy }
            check(h.model.status.message?.contains("Saved") != true, "cancelled save receipt cannot report stale success")
        }
        do {
            let h = Harness(), gate = Gate<ProfilePickerToolsController.Saved>(); h.saveGate = gate
            let route = await h.presentReady(); h.model.begin(.download, route: route)
            await settle { h.model.picker != nil }; h.choose(h.model.picker!)
            await gate.waitForStart()
            gate.finish(.init(filename: "unverified.json", bytes: Harness.data.count, sha256: "wrong-digest"))
            await settle { !h.model.isBusy }
            check(h.model.status.message?.contains("verified its local contents") != true,
                  "mismatched provider receipt cannot publish a verified saved copy")
        }
        do {
            let h = Harness(); let route = await h.presentReady(); h.model.begin(.repair, route: route); h.choose(h.model.picker!)
            await settle { h.model.status.stage == .reviewRepair }
            h.model.present(route, services: h.services())
            check(h.model.status.stage == .reviewRepair, "system picker return does not reset an existing presentation")
            h.model.saveRepair(route: route); await settle { h.model.picker != nil }
            check(h.takes == 1 && h.model.picker?.purpose == .destination, "review releases exactly one service export into folder selection")
            h.model.cancel(); h.model.saveRepair(route: route)
            check(h.takes == 1, "cancelled repair export cannot be consumed twice")
        }
        do {
            let h = Harness(), gate = Gate<ProfilePickerToolsRestoreAction.Outcome>(); h.restoreGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route); h.choose(h.model.picker!)
            await settle { h.model.status.stage == .confirmRestore }
            check(h.restores == 0, "selected immutable bytes never upload before explicit restore confirmation")
            h.model.confirmRestore(route: route); h.model.confirmRestore(route: route)
            await gate.waitForStart(); check(h.restores == 1, "duplicate confirmation cannot queue another restore")
            let original = UUID(); gate.finish(.deliveryUnconfirmed(original)); await settle { !h.model.isBusy }
            check(h.model.restoreNeedsVerification && !h.model.canRestore, "unconfirmed upload blocks another restore")
            h.model.verifyRestore(route: route); await settle { !h.model.isBusy }
            check(h.restores == 1 && h.verifies == 1 && h.verifiedIDs == [original],
                  "explicit verification names the original operation and never resubmits bytes")
            check(!h.model.canVerifyRestore && h.model.restoreNeedsVerification,
                  "server readback does not claim local profile adoption or unlock another upload")
        }
        do {
            let h = Harness(), gate = Gate<ProfilePickerToolsRestoreAction.Outcome>(); h.restoreGate = gate
            let route = await h.presentReady(); h.model.begin(.restore, route: route); h.choose(h.model.picker!)
            await settle { h.model.status.stage == .confirmRestore }
            h.model.confirmRestore(route: route); await gate.waitForStart(); h.model.dismiss(route)
            let original = UUID(); gate.finish(.deliveryUnconfirmed(original)); await settle { !h.model.isBusy }
            h.model.credentialDidChange() // A closed presentation is not a credential replacement.
            let next = await h.presentReady()
            check(h.model.restoreNeedsVerification && !h.model.canRestore,
                  "cancel after possible send retains original-account delivery uncertainty across reopening")
            h.model.verifyRestore(route: next); await settle { !h.model.isBusy }
            check(h.verifiedIDs == [original] && h.restores == 1,
                  "late delivery state permits original GET verification without repeating upload")
        }
        do {
            let h = Harness(); let old = await h.presentReady()
            var lease: ProfilePickerToolsLease? = .init(routeID: old, controller: h.model)
            check(lease?.routeID == old, "presentation lease records its original route")
            let current = await h.presentReady(); h.model.begin(.download, route: current)
            lease = nil; await settle { h.model.picker != nil }
            check(h.model.picker?.routeID == current, "old presentation teardown cannot cancel a newer Tools route")
            h.model.cancel()
        }
        do {
            let authority = CredentialScopeRegistry.shared
            let policy = DiagnosticPolicy()
            let capture = authority.capture()
            let grant = ProfilePickerToolsDiagnosticGrant(allowed: true, credential: capture, admission: { policy.allowed })
            try await grant.requireForExport(); check(grant.permitsExport, "current captured diagnostic admission permits staging")
            policy.allowed = false
            do { try await grant.requireForExport(); preconditionFailure("revoked PIN/failure admission accepted") }
            catch { check(true, "same credential with revoked PIN/failure policy denies staged export") }
            policy.allowed = true; authority.generation += 1
            check(!grant.permitsExport, "credential ABA cannot revive a prior diagnostic grant")
            let denied = ProfilePickerToolsDiagnosticGrant(allowed: false, credential: authority.capture(), admission: { true })
            check(!denied.permitsExport, "captured refusal cannot become a diagnostic grant after navigation")
        }
        do {
            let h = Harness(), original = UUID()
            h.retained = [.init(operationID: original, state: .serverConfirmed)]
            let route = await h.presentReady()
            check(h.model.canFinishRestore && !h.model.canRestore && h.model.restoreNeedsVerification,
                  "restart status exposes real Finish after server confirmation")
            h.model.finishRestore(route: route); await settle { !h.model.isBusy }
            check(h.finishedIDs == [original] && h.restores == 0 && h.verifies == 0 && h.model.restoreNeedsVerification,
                  "Finish passes retained UUID only and pending does not unlock another restore")
            let gate = Gate<ProfilePickerToolsRestoreAction.LocalOutcome>(); h.finishGate = gate
            h.model.finishRestore(route: route); await gate.waitForStart()
            gate.finish(.loaded(original)); await settle { !h.model.isBusy }
            check(!h.model.restoreNeedsVerification && h.model.canRestore && h.model.status.message?.contains("was loaded on this device") == true,
                  "typed completion of same operation clears pending UI only after true finish return")
        }
        do {
            let h = Harness(), original = UUID(), gate = Gate<ProfilePickerToolsRestoreAction.LocalOutcome>()
            h.retained = [.init(operationID: original, state: .serverConfirmed)]; h.finishGate = gate
            let route = await h.presentReady()
            h.model.finishRestore(route: route); await gate.waitForStart(); h.model.cancel()
            let next = h.present(); h.model.begin(.download, route: next)
            check(h.model.isBusy && h.downloads == 0, "cancelled noncooperative Finish retains sole slot across route replacement")
            gate.finish(.loaded(original)); await settle { !h.model.isBusy }
            check(h.model.restoreNeedsVerification && h.model.status.message?.contains("was loaded") != true,
                  "late historical completion cannot publish into replacement route")
        }
        do {
            let h = Harness(), original = UUID(), gate = Gate<ProfilePickerToolsRestoreAction.LocalOutcome>()
            h.retained = [.init(operationID: original, state: .serverConfirmed)]; h.finishGate = gate
            let route = await h.presentReady()
            h.model.finishRestore(route: route); await gate.waitForStart()
            gate.finish(.loaded(UUID())); await settle { !h.model.isBusy }
            check(h.model.restoreNeedsVerification && !h.model.canRestore, "another operation's loaded result cannot clear this retained operation")
        }
        do {
            let h = Harness(), original = UUID(), gate = Gate<ProfilePickerToolsRestoreAction.StoredStatus>()
            h.statusGate = gate
            let route = h.present(); await gate.waitForStart(); h.model.dismiss(route)
            h.statusGate = nil; let next = h.present(); h.model.begin(.restore, route: next)
            check(h.model.isBusy && h.restores == 0, "status discovery owns the same noncooperative task slot as restore")
            gate.finish(.available([.init(operationID: original, state: .serverConfirmed)]))
            await settle { !h.model.isBusy && h.discoveries == 2 }
            check(!h.model.canFinishRestore && h.discoveries == 2, "retired discovery cannot publish old operation and successor discovers afresh")
        }
        do {
            let h = Harness(), original = UUID(), gate = Gate<ProfilePickerToolsRestoreAction.LocalOutcome>()
            h.retained = [.init(operationID: original, state: .serverConfirmed)]; h.finishGate = gate
            let route = await h.presentReady()
            h.model.finishRestore(route: route); await gate.waitForStart()
            h.owner = nil; h.model.credentialDidChange(); gate.finish(.loaded(original)); await settle { !h.model.isBusy }
            check(!h.model.restoreNeedsVerification && h.model.status.message?.contains("was loaded") != true,
                  "replacement owner never sees prior account's completion publication")
        }
        do {
            let h = Harness(), original = UUID()
            h.retained = [.init(operationID: original, state: .serverConfirmed, providerSettlementUnavailable: true)]
            _ = await h.presentReady()
            check(h.model.restoreNeedsVerification && h.model.status.message?.contains("cannot yet be verified") == true,
                  "interim provider restriction remains explicit pending history without false loaded copy")
        }
        print("\(checks) actual Tools controller/access checks passed")
    }
}
