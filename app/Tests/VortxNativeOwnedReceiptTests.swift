// Maintained fixture source for the proposed native-owned-receipts lane.
// The runner prepends exact, unchanged SessionABI/SessionStore/SessionTransport
// declarations from actual VortxNativeSessionTests.swift into THIS SAME FILE.
// Those existing external boundaries are synthetic; the Facade/Session/FIFO,
// Runtime, resource bridge and native module/library are real current inputs.
import Foundation
import CryptoKit
import os

private final class OwnedReceiptRecorder: Sendable {
    struct Owned: Sendable {
        let receipt: VortxNativeCoreFacade.ChangeReceipt
        let registryProfile: String?
        let watchlistProfile: String?
    }
    private struct State: Sendable {
        weak var facade: VortxNativeCoreFacade?
        var owned: [Owned] = []
        var legacy: [[String]] = []
        var events: [String] = []
        var lockProbes: [Bool] = []
        var mutations = 0
        var preparations = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func attach(_ facade: VortxNativeCoreFacade?) { state.withLock { $0.facade = facade } }
    private func probe(_ facade: VortxNativeCoreFacade?) -> Bool {
        guard let facade else { return false }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = facade.captureHostChange(fields: ["library"])
            finished.signal()
        }
        return finished.wait(timeout: .now() + 2) == .success
    }
    func owned(_ receipt: VortxNativeCoreFacade.ChangeReceipt) {
        // Never enter actual Facade or wait while this recorder's mutex is held.
        let facade = state.withLock { $0.facade }
        let binding = Owned(receipt: receipt, registryProfile: facade?.registryBinding?.profileID,
            watchlistProfile: facade?.watchlistBinding?.profileID)
        let acquired = probe(facade)
        state.withLock {
            $0.owned.append(binding); $0.events.append("owned"); $0.lockProbes.append(acquired)
        }
    }
    func legacy(_ fields: [String]) {
        let acquired = probe(state.withLock { $0.facade })
        state.withLock {
            $0.legacy.append(fields); $0.events.append("legacy"); $0.lockProbes.append(acquired)
        }
    }
    func mutation() { state.withLock { $0.mutations += 1; $0.events.append("mutation") } }
    func unexpectedPreparation() { state.withLock { $0.preparations += 1 } }
    var preparations: Int { state.withLock { $0.preparations } }
    var owned: [Owned] { state.withLock { $0.owned } }
    var events: [String] { state.withLock { $0.events } }
    var lockProbes: [Bool] { state.withLock { $0.lockProbes } }
    var mutations: Int { state.withLock { $0.mutations } }
    var counts: (owned: Int, legacy: Int) { state.withLock { ($0.owned.count, $0.legacy.count) } }
}

@MainActor @main enum VortxNativeOwnedReceiptTests {
    private static var checks = 0
    private static func check(_ value: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(value, "owned-receipt assertion at line \(line): \(message)")
    }
    static func main() async throws {
        let recorder = OwnedReceiptRecorder(), store = SessionStore()
        let session = try VortxNativeSession(
            scope: .init(account: "owned-receipt.ram.fixture", ownerProfileID: "owner"),
            ownerName: "Fixture", abi: SessionABI(), store: store,
            transport: SessionTransport(), allowNewAccount: true,
            ownerHistoryLocalCheckpointPreparation: { _, _, _ in
                recorder.unexpectedPreparation()
                throw VortxNativeError.unavailable
            })
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [],
            mutationAccepted: { recorder.mutation() }, ownedChange: { recorder.owned($0) },
            changed: { recorder.legacy($0) })
        recorder.attach(facade)
        func encoded(_ action: VortxJSON) throws -> Data { try JSONEncoder().encode(action) }
        func latestMetadata() -> VortxNativeCoreFacade.ChangeReceipt {
            guard let receipt = recorder.owned.last(where: { $0.receipt.fields.contains("meta_details") })?.receipt else {
                preconditionFailure("missing actual metadata receipt")
            }
            return receipt
        }
        func load(_ episode: String) throws -> VortxJSON {
            let meta = try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: "same-title"))
            let stream = try VortxResourceProjection.path(.init(resource: .stream, type: "series", id: episode))
            return .object(["action": .string("Load"), "args": .object(["model": .string("MetaDetails"),
                "args": .object(["metaPath": meta, "streamPath": stream])])])
        }
        let unload = VortxJSON.object(["action": .string("Unload")])
        check(facade.dispatch(data: try encoded(unload), field: "meta_details"), "first unload admitted")
        let first = latestMetadata(), firstCounts = recorder.counts
        check(firstCounts.owned == 1 && firstCounts.legacy == 1, "first changed value notifies both")
        check(recorder.events == ["owned", "legacy"], "owned precedes legacy in captured closure")
        check(first.sourceID == facade.sourceID && first.values["meta_details"]?["selected"] == .null,
            "original source and unload value")
        check(facade.acceptsChange(first, field: "meta_details", settlingResource: true), "first producer current")
        check(facade.dispatch(data: try encoded(unload), field: "meta_details"), "equal new unload admitted")
        let second = latestMetadata(), secondCounts = recorder.counts
        check(secondCounts.owned == firstCounts.owned + 1 && secondCounts.legacy == firstCounts.legacy,
            "equal new task notifies owned only")
        check(second.sequence > first.sequence && second.resources["meta_details"] != first.resources["meta_details"],
            "selection lifetime rotates")
        check(second.resourceValues["meta_details"] != first.resourceValues["meta_details"], "producer rotates")
        check(!facade.acceptsChange(first, field: "meta_details") && facade.acceptsChange(second, field: "meta_details"),
            "old field receipt retired")
        let beforeHost = recorder.counts
        let host = facade.captureHostChange(fields: ["meta_details", "native_state"])!
        check(recorder.counts.owned == beforeHost.owned && recorder.counts.legacy == beforeHost.legacy,
            "host snapshot stages no callback")
        check(host.fields.contains("native_state") && host.values["native_state"] == nil, "control marker not payload")
        check(facade.acceptsChange(host, field: "meta_details", settlingResource: true), "host keeps original producer")

        let binding = facade.watchlistBinding!, navigation = facade.captureAcceptedNavigation(expected: binding)!
        let beforeA = recorder.counts
        let a = facade.dispatchMetadata(try load("same-title:1:1"), expected: navigation)!
        await facade.settled()
        let aCallback = latestMetadata(), frozenA = aCallback.values["meta_details"]!
        check(recorder.counts.owned == beforeA.owned + 1 && recorder.counts.legacy == beforeA.legacy + 1,
            "empty registry publishes once per new metadata task")
        check(frozenA["metaItems"] == .array([]) && frozenA["streams"] == .array([])
            && frozenA["metaStreams"] == .array([]), "all terminal metadata arrays retained")
        check(facade.metadataSelectionIsCurrent(a) && facade.acceptsChange(aCallback, field: "meta_details", settlingResource: true),
            "original task and composite producer current")
        check(facade.metadataSnapshot(expected: a)?["selected"]?["streamPath"]?["id"] == .string("same-title:1:1"),
            "original episode selected")
        let beforeB = recorder.counts
        let b = facade.dispatchMetadata(try load("same-title:1:2"), expected: navigation)!
        await facade.settled()
        check(recorder.counts.owned == beforeB.owned + 1 && recorder.counts.legacy == beforeB.legacy + 1,
            "replacement episode publishes once")
        check(!facade.metadataSelectionIsCurrent(a) && facade.metadataSnapshot(expected: a) == nil,
            "replaced direct metadata task cannot refresh")
        check(facade.metadataSelectionIsCurrent(b) && !facade.acceptsChange(aCallback, field: "meta_details", settlingResource: true),
            "original callback not upgraded to replacement task")
        check(frozenA["selected"]?["streamPath"]?["id"] == .string("same-title:1:1")
            && aCallback.values["meta_details"] == frozenA, "original payload remains immutable")
        for action in [VortxJSON.object(["action": .string("Ctx"), "args": .object(["action": .string("Authenticate")])]),
                       .object(["action": .string("Vortx"), "args": .object(["type": .string("mark_watched")])]),
                       .object(["action": .string("Load"), "args": .object(["model": .string("LibraryWithFilters")])])] {
            let before = recorder.counts
            check(facade.dispatchMetadata(action, expected: navigation) == nil, "nonmetadata action rejected")
            check(recorder.counts.owned == before.owned && recorder.counts.legacy == before.legacy,
                "rejected action has no callbacks")
        }
        let beforeACK = recorder.counts, beforeACKOrder = recorder.events.count
        check(facade.dispatchForProfile(.object(["type": .string("mark_watched"),
            "metaId": .string("synthetic-title"), "name": .string("Synthetic")]),
            profileID: binding.profileID, expectedAccountGeneration: binding.accountGeneration), "actual FIFO mutation admitted")
        await facade.settleNativeMutations()
        check(recorder.mutations == 1, "mutation ACK once")
        check(recorder.counts.owned == beforeACK.owned + 1 && recorder.counts.legacy == beforeACK.legacy + 1,
            "actual ACK callbacks once")
        check(Array(recorder.events.dropFirst(beforeACKOrder)) == ["owned", "legacy", "mutation"], "ACK callback order")

        let beforeSwitch = recorder.counts, beforeSwitchOrder = recorder.events.count
        store.blockNextWrite()
        let switchKid = VortxJSON.object(["action": .string("Vortx"),
            "args": .object(["type": .string("switch_profile"), "id": .string("kid")])])
        check(facade.dispatch(data: try encoded(switchKid), field: nil), "actual profile transition admitted")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(store.entered.wait(timeout: .now() + 5) == .success, "profile checkpoint barrier missing")
                continuation.resume()
            }
        }
        check(facade.registryBinding == nil && facade.watchlistBinding?.profileID == "owner", "pending vs acknowledged fences distinct")
        check(recorder.counts.owned == beforeSwitch.owned && recorder.counts.legacy == beforeSwitch.legacy, "unacknowledged value not published")
        store.release.signal()
        await facade.settleNativeMutations()
        check(recorder.mutations == 2, "profile ACK once")
        check(recorder.counts.owned == beforeSwitch.owned + 1 && recorder.counts.legacy == beforeSwitch.legacy + 1,
            "profile callbacks once")
        check(Array(recorder.events.dropFirst(beforeSwitchOrder)) == ["owned", "legacy", "mutation"], "profile callback order")
        let switched = recorder.owned.last!
        check(switched.receipt.fields.contains("native_state") && switched.receipt.profileID == "kid"
            && switched.registryProfile == "kid" && switched.watchlistProfile == "kid", "pending released before owned ACK callback")
        check(facade.acceptsChange(switched.receipt) && !facade.acceptsChange(host), "profile transition retires old host")
        check(!facade.metadataSelectionIsCurrent(b) && facade.metadataSnapshot(expected: b) == nil, "profile retires direct metadata task")
        let allowed: Set<String> = ["ctx", "board", "search", "discover", "library", "meta_details", "local_search", "continue_watching_preview"]
        check(recorder.owned.allSatisfy { Set($0.receipt.values.keys).isSubset(of: allowed) }, "exact eight-field allowlist")
        check(recorder.lockProbes.count == recorder.counts.owned + recorder.counts.legacy
            && recorder.lockProbes.allSatisfy { $0 }, "owned AND legacy callbacks release actual outer F")

        let otherSession = try VortxNativeSession(scope: .init(account: "owned-receipt.other.ram.fixture", ownerProfileID: "owner"),
            ownerName: "Fixture", abi: SessionABI(), store: SessionStore(), transport: SessionTransport(), allowNewAccount: true)
        let other = try await VortxNativeCoreFacade.create(session: otherSession, registry: [], changed: { _ in })
        check(other.sourceID != facade.sourceID && !other.acceptsChange(host) && !other.acceptsChange(host, field: "meta_details"),
            "foreign source plus generations rejected")
        await other.shutdown()
        let beforeClose = facade.captureHostChange(fields: ["library"])!
        await facade.shutdown()
        recorder.attach(nil)
        check(!facade.acceptsChange(beforeClose) && !facade.metadataSelectionIsCurrent(b), "close retires receipts")
        check(facade.captureHostChange(fields: ["library"]) == nil, "closed facade has no host snapshot")
        check(recorder.preparations == 0, "generic dispatch/resource/ACK/profile/close never invokes owner preparation")
        _ = try await VortxNativeMetadataDispatchTests.run()
        print("Native owned receipts: \(checks) checks PASS; real Facade/Session/FIFO, RAM external boundaries; no global FIFO, Bridge actor, native C execution or app proof")
    }
}
