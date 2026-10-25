// V2 SUCCESSOR: actual sole-writer lifecycle repair; frozen v1 is unchanged.
// RECOVERY PROPOSAL ONLY. UNRUN: no extraction, parse, typecheck, link or test
// execution was performed by the author. Append in the SAME generated fixture
// file as the exact existing SessionABI/SessionStore/SessionTransport declarations
// and the exact extracted Bridge peer + ProfileSelectionRead mirror.
//
// Real decision code: whole current CoreBridge.dispatch and its current owner/
// navigation helpers, real Facade/FIFO/Session/Scope, resource projection/policy.
// Synthetic boundaries: Bridge storage peer, existing RAM ABI/store/transport,
// and deliberate process-local mirror writes. No ProfileStore/Manager/SDK mock.
import Foundation
import os

private struct MetadataCancellationObservation: Sendable {
    let bridgeUnlocked: Bool
    let facadeUnlocked: Bool
    let witnessUnlocked: Bool
    let reentryAccepted: Bool
}

// RAM external transport only. Its first worker call is bounded and deliberately
// ignores cancellation until release, so actual Session/Facade task retirement
// must reject stale completion. No network or native C operation is implemented.
private final class MetadataCancellationTransport: VortxResourceTransport {
    private final class Token: VortxResourceCancellation {
        let onCancel: @Sendable () -> Void
        init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }
    private struct State: Sendable {
        var blockNext = true
        var probe: (@Sendable () -> MetadataCancellationObservation)?
        var observations: [MetadataCancellationObservation] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fallback = SessionTransport()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let firstReturned = DispatchSemaphore(value: 0)
    func setProbe(_ probe: @escaping @Sendable () -> MetadataCancellationObservation) {
        state.withLock { $0.probe = probe }
    }
    func clearProbe() { state.withLock { $0.probe = nil } }
    func makeCancellation() throws -> any VortxResourceCancellation {
        Token { [self] in
            let probe = state.withLock { $0.probe }
            if let observation = probe?() { state.withLock { $0.observations.append(observation) } }
        }
    }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let block = state.withLock { value in
            let block = value.blockNext
            value.blockNext = false
            return block
        }
        if block {
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success, "unreleased RAM resource worker")
        }
        defer { if block { firstReturned.signal() } }
        return try fallback.load(requestJSON, cancellation: cancellation)
    }
    var observations: [MetadataCancellationObservation] { state.withLock { $0.observations } }
}

private final class MetadataDispatchRecorder: Sendable {
    private struct Reentry: Sendable {
        let facade: VortxNativeCoreFacade
        let navigation: VortxNativeCoreFacade.AcceptedNavigationReceipt
        let action: VortxJSON
    }
    private struct State: Sendable {
        var receipts: [VortxNativeCoreFacade.ChangeReceipt] = []
        var facades: [UUID: VortxNativeCoreFacade] = [:]
        var bridgeProbe: (@Sendable () -> Bool)?
        var witness: VortxNativeMetadataAdmissionFence?
        var bridgeUnlocked: [Bool] = []
        var facadeUnlocked: [Bool] = []
        var witnessUnlocked: [Bool] = []
        var reentry: Reentry?
        var reentryResult: VortxNativeCoreFacade.MetadataSelectionReceipt?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func attach(_ facade: VortxNativeCoreFacade) {
        state.withLock { $0.facades[facade.sourceID] = facade }
    }
    func setBridgeProbe(_ probe: @escaping @Sendable () -> Bool) {
        state.withLock { $0.bridgeProbe = probe }
    }
    func setWitness(_ witness: VortxNativeMetadataAdmissionFence) { state.withLock { $0.witness = witness } }
    func armReentry(facade: VortxNativeCoreFacade,
                    navigation: VortxNativeCoreFacade.AcceptedNavigationReceipt,
                    action: VortxJSON) {
        state.withLock {
            precondition($0.reentry == nil)
            $0.reentryResult = nil
            $0.reentry = .init(facade: facade, navigation: navigation, action: action)
        }
    }
    func record(_ receipt: VortxNativeCoreFacade.ChangeReceipt) {
        guard receipt.fields.contains("meta_details") else { return }
        let captured = state.withLock { value in
            let pending = value.reentry.flatMap { $0.facade.sourceID == receipt.sourceID ? $0 : nil }
            if pending != nil { value.reentry = nil } // Consume before a nested synchronous callback.
            value.receipts.append(receipt)
            return (value.facades[receipt.sourceID], value.bridgeProbe, pending, value.witness)
        }
        // These are outside this recorder's lock. A same-thread NSLock try is
        // enough to detect B being held; the cross-thread F probe detects the
        // actual Facade's recursive outer lock still being held at delivery.
        let bridgeUnlocked = captured.1?() ?? false
        let finished = DispatchSemaphore(value: 0)
        if let facade = captured.0 {
            DispatchQueue.global().async {
                _ = facade.captureHostChange(fields: ["meta_details"])
                finished.signal()
            }
        }
        let facadeUnlocked = finished.wait(timeout: .now() + 2) == .success
        let witnessFinished = DispatchSemaphore(value: 0)
        if let witness = captured.3 {
            DispatchQueue.global().async {
                _ = witness.captureInstallation()
                witnessFinished.signal()
            }
        }
        let witnessUnlocked = witnessFinished.wait(timeout: .now() + 2) == .success
        state.withLock {
            $0.bridgeUnlocked.append(bridgeUnlocked)
            $0.facadeUnlocked.append(facadeUnlocked)
            $0.witnessUnlocked.append(witnessUnlocked)
        }
        if let pending = captured.2 {
            let result = pending.facade.dispatchMetadata(pending.action, expected: pending.navigation)
            state.withLock { $0.reentryResult = result }
        }
    }
    func metadataCount(_ facade: VortxNativeCoreFacade) -> Int {
        state.withLock { $0.receipts.filter { $0.sourceID == facade.sourceID }.count }
    }
    var reentryResult: VortxNativeCoreFacade.MetadataSelectionReceipt? { state.withLock { $0.reentryResult } }
    var allDeliveryLocksReleased: Bool {
        state.withLock {
            !$0.bridgeUnlocked.isEmpty && $0.bridgeUnlocked.allSatisfy { $0 }
                && $0.facadeUnlocked.count == $0.bridgeUnlocked.count && $0.facadeUnlocked.allSatisfy { $0 }
                && $0.witnessUnlocked.count == $0.bridgeUnlocked.count && $0.witnessUnlocked.allSatisfy { $0 }
        }
    }
    func releaseFacades() { state.withLock { $0.facades.removeAll() } }
}

@MainActor enum VortxNativeMetadataDispatchTests {
    private static var checks = 0
    private static func check(_ value: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(value, "metadata-dispatch assertion at line \(line): \(message)")
    }
    private static func setProfile(_ id: UUID) {
        // RAM fixture writes the ACTUAL scalar mirror; not ProfileStore, durable
        // selection, authentication, playback or UI ownership proof.
        ProfileSelectionRead.beginMutation()
        ProfileSelectionRead.endMutation(.init(activeID: id,
            activeProfile: .init(id: id, isOwner: true, usesOwnAccount: false,
                                 continueWatchingSource: nil, continueWatchingWindow: nil)))
    }
    private static func load(_ title: String, _ episode: String) throws -> VortxJSON {
        let meta = try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: title))
        let stream = try VortxResourceProjection.path(.init(resource: .stream, type: "series", id: episode))
        return .object(["action": .string("Load"), "args": .object(["model": .string("MetaDetails"),
            "args": .object(["metaPath": meta, "streamPath": stream])])])
    }
    private static func wire(_ action: VortxJSON) throws -> [String: Any] {
        let bytes = try JSONEncoder().encode(action)
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    private static func metadata(_ facade: VortxNativeCoreFacade) -> VortxJSON? {
        facade.stateData("meta_details").flatMap { try? JSONDecoder().decode(VortxJSON.self, from: $0) }
    }
    private static func requestJSON(_ request: CoreBridge.FixtureRequest) -> VortxJSON? {
        request.action.flatMap { try? JSONDecoder().decode(VortxJSON.self, from: $0) }
    }

    static func run() async throws -> Int {
        checks = 0
        let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let otherOwner = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let account = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let otherAccount = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        ProfileSelectionRead.publishInitial(.init(activeID: owner,
            activeProfile: .init(id: owner, isOwner: true, usesOwnAccount: false,
                                 continueWatchingSource: nil, continueWatchingWindow: nil)))
        // Standalone process-local authority only. This calls the real registry
        // and real publication boundary, with no account service/Keychain writes.
        guard let initialCapture = CredentialScopeRegistry.shared.tryBind(.account(account)) else {
            preconditionFailure("fixture real credential boundary unexpectedly busy")
        }
        let recorder = MetadataDispatchRecorder(), bridge = CoreBridge()
        recorder.setBridgeProbe(bridge.fixtureBridgeLockProbe())
        recorder.setWitness(bridge.fixtureAdmissionFence())
        // Match the REAL account-wide writer key; never invent per-test namespaces.
        var liveFacades: [String: VortxNativeCoreFacade] = [:]
        @MainActor func make(_ scope: CredentialScope, _ profile: UUID,
                            transport: any VortxResourceTransport = SessionTransport(),
                            registry: [VortxResourceAddon] = []) async throws
            -> (VortxNativeCoreFacade, SessionStore) {
            let namespace = scope.storageNamespace
            precondition(liveFacades[namespace] == nil, "fixture must await predecessor shutdown before same-scope open")
            let store = SessionStore()
            let session = try VortxNativeSession(
                scope: .init(account: scope.storageNamespace, ownerProfileID: profile.uuidString.lowercased()),
                ownerName: "Metadata dispatch fixture", abi: SessionABI(), store: store,
                transport: transport, allowNewAccount: true)
            let facade = try await VortxNativeCoreFacade.create(session: session, registry: registry,
                ownedChange: { recorder.record($0) }, changed: { _ in })
            recorder.attach(facade)
            liveFacades[namespace] = facade
            return (facade, store)
        }
        @MainActor func install(_ facade: VortxNativeCoreFacade?, _ capture: CredentialScopeRegistry.Capture,
                     published: Bool = true) {
            bridge.fixtureInstall(facade, capture: capture,
                publishedAccount: published ? facade?.watchlistBinding?.accountGeneration : nil)
        }
        @MainActor func retire(_ facade: VortxNativeCoreFacade, namespace: String) async {
            precondition(liveFacades[namespace] === facade, "retire only the tracked original RAM facade")
            // close()/revoke alone do not release VortxScopeWriter. This await
            // reaches real Session.close, which alone may release the live slot.
            await facade.shutdown()
            check(!facade.isAvailable, "genuine predecessor shutdown made facade unavailable")
            precondition(liveFacades[namespace] === facade, "no replacement may race awaited retirement")
            liveFacades.removeValue(forKey: namespace)
        }
        let (first, _) = try await make(initialCapture.scope, owner)
        install(first, initialCapture)
        let a = try load("title-a", "title-a:1:1"), b = try load("title-b", "title-b:1:2")
        let aw = try wire(a), bw = try wire(b)

        // Ordinary current-owner acceptance uses the full unchanged extracted
        // dispatch body and actual Facade resource dispatcher, not a toy model.
        var hookCalls = 0
        check(bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: { hookCalls += 1 }),
              "ordinary same-owner metadata admitted")
        await first.settled()
        check(hookCalls == 1 && metadata(first)?["selected"] == a["args"]?["args"],
              "ordinary hook once and real selected payload")
        let ordinary = bridge.fixtureRequest()
        check(ordinary.credential == initialCapture && ordinary.profileID == owner
            && ordinary.target == .init(metaID: "title-a", streamID: "title-a:1:1")
            && requestJSON(ordinary) == a, "request owns original scope and wire action")

        // The finite branch rejects a Load without metaPath.id before the
        // synchronous hook or any request/fence write. Preserve a valid A.
        var missingID = aw
        missingID["args"] = ["model": "MetaDetails", "args": [
            "metaPath": ["resource": "meta", "type": "series"],
            "streamPath": ["resource": "stream", "type": "series", "id": "title-a:1:1"]]]
        var malformedHook = false
        let beforeMissingID = recorder.metadataCount(first)
        check(!bridge.dispatch(action: missingID, field: "meta_details",
            beforeDispatch: { malformedHook = true }), "missing metaPath.id rejected before hook")
        let afterMissingID = bridge.fixtureRequest()
        check(!malformedHook && afterMissingID.generation == ordinary.generation
            && afterMissingID.action == ordinary.action && afterMissingID.target == ordinary.target
            && afterMissingID.credential == ordinary.credential && afterMissingID.profileID == ordinary.profileID
            && recorder.metadataCount(first) == beforeMissingID,
              "missing-id Load preserves valid A request, scope and callback count")

        check(bridge.dispatch(action: ["action": "Unload"], field: "meta_details"), "explicit metadata unload admitted")
        let explicitUnload = bridge.fixtureRequest()
        check(explicitUnload.target == nil && explicitUnload.action == nil
            && explicitUnload.generation != ordinary.generation
            && explicitUnload.credential == ordinary.credential && explicitUnload.profileID == ordinary.profileID
            && metadata(first)?["selected"] == .null, "metadata unload clears request without replacing its original scope")

        // B takes request ownership during A's synchronous external hook. A may
        // not overwrite B's wire/generation or dispatch through a later facade.
        var nestedAccepted = false
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: {
            nestedAccepted = bridge.dispatch(action: bw, field: "meta_details")
        }), "outer metadata rejected after nested newer metadata")
        await first.settled()
        check(nestedAccepted && requestJSON(bridge.fixtureRequest()) == b
            && bridge.fixtureRequest().target == .init(metaID: "title-b", streamID: "title-b:1:2")
            && metadata(first)?["selected"] == b["args"]?["args"],
              "nested B retains request and actual Facade selection")

        // Deterministic scalar admission -> insertion race without adding a
        // production hook. The test-only accessor calls the ACTUAL original
        // admission/currentness helpers and reads the request already recorded
        // by actual dispatch. The final insertion is the REAL fenced overload.
        check(bridge.dispatch(action: aw, field: "meta_details"), "record A for fenced insertion boundary")
        let precheckedA = bridge.fixturePrecheckedInsertion()!
        check(bridge.dispatch(action: bw, field: "meta_details"), "same-install B records and inserts after A precheck")
        let beforeStaleInsert = recorder.metadataCount(first)
        check(bridge.fixtureInsert(a, original: precheckedA) == nil,
              "same-install old A stamp cannot insert after B request replacement")
        check(recorder.metadataCount(first) == beforeStaleInsert
            && metadata(first)?["selected"] == b["args"]?["args"],
              "stale fenced insertion does not overwrite actual B selection")

        // A -> B -> A reuses the same original facade, credential and accepted
        // navigation receipt; only the actual installation witness retires it.
        let precheckedInstall = bridge.fixturePrecheckedInsertion()!
        install(nil, initialCapture)
        install(first, initialCapture)
        let beforeABA = recorder.metadataCount(first)
        check(first.acceptedNavigationIsCurrent(precheckedInstall.navigation)
            && bridge.fixtureInsert(a, original: precheckedInstall) == nil,
              "same-facade install ABA rejects original installation stamp")
        check(recorder.metadataCount(first) == beforeABA && requestJSON(bridge.fixtureRequest()) == b,
              "install ABA neither inserts A nor manufactures a new request")

        // A second live same-account Session is forbidden by the REAL
        // VortxScopeWriter, even with a different RAM store. Detach during the
        // synchronous hook, await genuine predecessor shutdown, then reopen.
        // This is honest close/reopen boundary coverage, not a claim that an
        // async Session open occurred inside the synchronous hook.
        let heldBeforeReopen = bridge.fixturePrecheckedInsertion()!
        let oldCount = recorder.metadataCount(first)
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: {
            install(nil, initialCapture)
        }), "same-credential detach retires original full dispatch admission")
        check(recorder.metadataCount(first) == oldCount, "detached original source receives no A callback")
        await retire(first, namespace: initialCapture.scope.storageNamespace)
        let (replacement, _) = try await make(initialCapture.scope, owner)
        install(replacement, initialCapture)
        let replacementCount = recorder.metadataCount(replacement)
        check(CredentialScopeRegistry.shared.isCurrent(initialCapture)
            && first.sourceID != replacement.sourceID && !first.isAvailable,
              "same credential reopened genuinely after original Session retirement")
        check(bridge.fixtureInsert(a, original: heldBeforeReopen) == nil
            && recorder.metadataCount(first) == oldCount
            && recorder.metadataCount(replacement) == replacementCount
            && metadata(replacement) == nil,
              "retained old admission neither reaches old source nor upgrades to reopened source")
        check(bridge.dispatch(action: bw, field: "meta_details"), "explicit fresh request may use reopened same-credential source")
        await replacement.settled()

        // A -> A still rotates a real credential epoch; it is not a string-only
        // owner match. This is a RAM registry transition, not an account login.
        var sameAccountCapture: CredentialScopeRegistry.Capture?
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: {
            sameAccountCapture = CredentialScopeRegistry.shared.tryBind(.account(account))
        }), "same-account credential epoch replacement rejects admitted A")
        let currentCapture = sameAccountCapture!
        check(currentCapture != initialCapture && !CredentialScopeRegistry.shared.isCurrent(initialCapture),
              "actual original credential epoch retired")
        install(nil, currentCapture)
        await retire(replacement, namespace: initialCapture.scope.storageNamespace)
        let (current, _) = try await make(currentCapture.scope, owner)
        install(current, currentCapture)
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: { setProfile(otherOwner) }),
              "profile mirror replacement rejects original profile")
        check(recorder.metadataCount(current) == 0, "profile replacement has no resource dispatch")
        setProfile(owner)

        // A pending request exists with no installed facade. B installed inside
        // the hook must not become an authority that A never captured.
        install(nil, currentCapture)
        await retire(current, namespace: currentCapture.scope.storageNamespace)
        var pendingCapture: CredentialScopeRegistry.Capture?
        var pendingFacade: VortxNativeCoreFacade?
        // Pre-create the peer; the hook itself is synchronous, with no async hop.
        // Creating a RAM session for a desired scope is not a credential
        // capability: no Capture is fabricated or anticipated here. Only the
        // real tryBind result inside the hook can populate Bridge authority.
        let (other, _) = try await make(.account(otherAccount), otherOwner)
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: {
            pendingCapture = CredentialScopeRegistry.shared.tryBind(.account(otherAccount))
            setProfile(otherOwner)
            pendingFacade = other
            install(other, pendingCapture!)
        }), "request captured with no facade cannot upgrade to hook-installed B")
        let pending = bridge.fixtureRequest(), installedCapture = pendingCapture!
        check(pendingFacade === other && pending.credential == currentCapture && pending.profileID == owner
            && requestJSON(pending) == a && recorder.metadataCount(other) == 0,
              "pending request retains original A scope and wire bytes")
        check(bridge.dispatch(action: bw, field: "meta_details"), "explicit new B request may be admitted")
        await other.settled()
        check(bridge.fixtureRequest().credential == installedCapture
            && bridge.fixtureRequest().profileID == otherOwner, "only new request captures B")

        // Missing publication authority at admission cannot be repaired after
        // the hook to authorize this same action.
        install(other, installedCapture, published: false)
        let beforeRepair = recorder.metadataCount(other)
        check(!bridge.dispatch(action: aw, field: "meta_details", beforeDispatch: {
            install(other, installedCapture)
        }), "missing initial publication authority is not upgraded")
        check(recorder.metadataCount(other) == beforeRepair, "late authority repair dispatches nothing")

        // Malformed projection is rejected by the REAL Facade; no admission or
        // pending wire identity is a substitute for accepted resource selection.
        var malformed = aw
        malformed["args"] = ["model": "MetaDetails", "args": [
            "metaPath": ["resource": "invalid-resource", "type": "series", "id": "bad"],
            "streamPath": ["resource": "stream", "type": "series", "id": "bad:1:1"]]]
        let beforeMalformed = recorder.metadataCount(other), priorSelection = metadata(other)?["selected"]
        check(!bridge.dispatch(action: malformed, field: "meta_details"), "actual Facade rejects invalid resource path")
        check(recorder.metadataCount(other) == beforeMalformed && metadata(other)?["selected"] == priorSelection,
              "rejected metadata cannot publish or replace selection")
        let beforeMutation = bridge.fixtureRequest()
        bridge.fixtureSetLogoutPending(true)
        var rejectedHook = false
        check(!bridge.dispatch(action: ["action": "MetaDetails", "args": ["action": "MarkAsWatched", "args": true]],
            field: "meta_details", beforeDispatch: { rejectedHook = true }), "original rejected-mutation prefix preserved")
        bridge.fixtureSetLogoutPending(false)
        check(!rejectedHook && bridge.fixtureRequest().generation == beforeMutation.generation,
              "rejected mutation does not become metadata request")

        // field=nil Unload stays on the generic continuation. It must not become
        // field=meta_details Unload, even though legacy request tracking clears.
        check(bridge.dispatch(action: bw, field: "meta_details"), "seed before whole-model unload")
        await other.settled()
        let beforeWhole = recorder.metadataCount(other), selectedBeforeWhole = metadata(other)
        let scopeBeforeWhole = bridge.fixtureRequest()
        var wholeHook = 0
        check(!bridge.dispatch(action: ["action": "Unload"], field: nil, beforeDispatch: { wholeHook += 1 }),
              "actual current generic Facade rejects whole-model Unload")
        let whole = bridge.fixtureRequest()
        check(wholeHook == 1 && whole.target == nil && whole.action == nil
            && whole.generation != scopeBeforeWhole.generation && whole.credential == scopeBeforeWhole.credential
            && whole.profileID == scopeBeforeWhole.profileID, "whole-model request clear retains original legacy scope semantics")
        check(recorder.metadataCount(other) == beforeWhole && metadata(other) == selectedBeforeWhole,
              "whole-model unload did not unload metadata resource")

        // Callback drain can synchronously replace A's resource task after F is
        // released but before Bridge resumes its post-dispatch return checks.
        let navigation = other.captureAcceptedNavigation(expected: other.watchlistBinding!)!
        recorder.armReentry(facade: other, navigation: navigation, action: b)
        check(!bridge.dispatch(action: aw, field: "meta_details"), "post-drain newer resource rejects original selection receipt")
        await other.settled()
        check(recorder.reentryResult.map { other.metadataSelectionIsCurrent($0) } == true
            && metadata(other)?["selected"] == b["args"]?["args"], "actual synchronous drain installed newer B")
        check(requestJSON(bridge.fixtureRequest()) == a,
              "direct Facade reentry does not manufacture a newer Bridge request")

        // Real cancellation path: actual Facade task -> actual Session task
        // group -> actual ResourceBridge cancellation handler -> RAM token.
        // The token reenters real Facade reads and the scalar witness only after
        // bounded cross-thread probes show both were released. A former inline
        // begin.cancel would fail the F/witness probes, not silently pass.
        install(nil, installedCapture)
        await retire(other, namespace: installedCapture.scope.storageNamespace)
        let cancellationTransport = MetadataCancellationTransport()
        let cancellationAddon = VortxResourceAddon(id: "cancel-fixture",
            transportUrl: "https://cancel-fixture.invalid/manifest.json",
            manifest: .object(["id": .string("cancel-fixture"), "resources": .array([.string("meta")]),
                "types": .array([.string("series")]), "catalogs": .array([])]))
        let (cancellationFacade, _) = try await make(installedCapture.scope, otherOwner,
            transport: cancellationTransport, registry: [cancellationAddon])
        install(cancellationFacade, installedCapture)
        let cancelA: VortxJSON = .object(["action": .string("Load"), "args": .object([
            "model": .string("MetaDetails"), "args": .object([
                "metaPath": try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: "cancel-a")),
                "streamPath": .null])])])
        let cancelB: VortxJSON = .object(["action": .string("Load"), "args": .object([
            "model": .string("MetaDetails"), "args": .object([
                "metaPath": try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: "cancel-b")),
                "streamPath": .null])])])
        check(bridge.dispatch(action: try wire(cancelA), field: "meta_details"), "real resource A admitted before cancellation")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(cancellationTransport.entered.wait(timeout: .now() + 5) == .success,
                             "RAM cancellation resource did not reach actual worker boundary")
                continuation.resume()
            }
        }
        let cancellationFence = bridge.fixtureAdmissionFence()
        let cancellationBinding = cancellationFacade.watchlistBinding!
        let cancellationNavigation = cancellationFacade.captureAcceptedNavigation(expected: cancellationBinding)!
        let cancelledSelection = cancellationFacade.captureMetadataSelection(expected: cancellationNavigation)!
        let cancellationBridgeProbe = bridge.fixtureBridgeLockProbe()
        cancellationTransport.setProbe {
            let bridgeUnlocked = cancellationBridgeProbe()
            let facadeFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = cancellationFacade.captureHostChange(fields: ["meta_details"])
                facadeFinished.signal()
            }
            let facadeUnlocked = facadeFinished.wait(timeout: .now() + 2) == .success
            let witnessFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = cancellationFence.captureInstallation()
                witnessFinished.signal()
            }
            let witnessUnlocked = witnessFinished.wait(timeout: .now() + 2) == .success
            let reentryAccepted: Bool
            if bridgeUnlocked && facadeUnlocked && witnessUnlocked {
                // Deliberate synchronous client reentry after the probes. These
                // are actual APIs, not a fake lock/currentness implementation.
                _ = cancellationFence.captureInstallation()
                reentryAccepted = cancellationFacade.captureAcceptedNavigation(expected: cancellationBinding) != nil
            } else { reentryAccepted = false }
            return .init(bridgeUnlocked: bridgeUnlocked, facadeUnlocked: facadeUnlocked,
                         witnessUnlocked: witnessUnlocked, reentryAccepted: reentryAccepted)
        }
        check(bridge.dispatch(action: try wire(cancelB), field: "meta_details"), "replacement B admitted through actual fenced overload")
        // Release even if a cancellation callback failed its probes; the retained
        // actual stale task must finish without becoming the accepted producer.
        cancellationTransport.release.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(cancellationTransport.firstReturned.wait(timeout: .now() + 5) == .success,
                             "cancelled RAM resource response did not return")
                continuation.resume()
            }
        }
        await cancellationFacade.settled()
        let cancelled = cancellationTransport.observations
        check(!cancelled.isEmpty && cancelled.allSatisfy {
            $0.bridgeUnlocked && $0.facadeUnlocked && $0.witnessUnlocked && $0.reentryAccepted
        }, "real cancellation handler/reentry sees neither B nor F nor scalar witness held")
        check(!cancellationFacade.metadataSelectionIsCurrent(cancelledSelection)
            && metadata(cancellationFacade)?["selected"] == cancelB["args"]?["args"],
              "old A receipt retired and B current after A transport return/new task settlement")

        // A real FIFO profile transaction blocks metadata insertion, even while
        // the acknowledged watchlist binding still names the original profile.
        cancellationTransport.clearProbe()
        install(nil, installedCapture)
        await retire(cancellationFacade, namespace: installedCapture.scope.storageNamespace)
        let (transition, transitionStore) = try await make(installedCapture.scope, otherOwner)
        install(transition, installedCapture)
        transitionStore.blockNextWrite()
        let switchKid: VortxJSON = .object(["action": .string("Vortx"),
            "args": .object(["type": .string("switch_profile"), "id": .string("kid")])])
        check(transition.dispatch(data: try JSONEncoder().encode(switchKid), field: nil), "real FIFO profile transaction admitted")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(transitionStore.entered.wait(timeout: .now() + 5) == .success,
                             "real profile checkpoint barrier missing")
                continuation.resume()
            }
        }
        check(transition.registryBinding == nil
            && transition.watchlistBinding?.profileID == otherOwner.uuidString.lowercased(),
              "real pending versus acknowledged fences distinct")
        let pendingCount = recorder.metadataCount(transition)
        check(!bridge.dispatch(action: aw, field: "meta_details"), "pending profile cannot insert metadata selection")
        check(recorder.metadataCount(transition) == pendingCount, "pending profile publishes no metadata")
        transitionStore.release.signal()
        await transition.settleNativeMutations()
        check(transition.watchlistBinding?.profileID == "kid"
            && !bridge.dispatch(action: aw, field: "meta_details"), "ACK never upgrades captured original profile authority")
        check(recorder.allDeliveryLocksReleased, "actual callback drain holds neither Bridge B nor outer Facade F nor witness")

        // Only still-live entries remain. No closed predecessor is shut down
        // again at the final sweep, and no writer slot is bypassed or reset.
        for (namespace, facade) in Array(liveFacades) { await retire(facade, namespace: namespace) }
        check(liveFacades.isEmpty, "every tracked real RAM Session retired exactly once")
        recorder.releaseFacades()
        print("Native metadata dispatch: \(checks) checks PASS; exact dispatch/helpers and real Facade/FIFO/Session/Scope; RAM storage/mirror/ABI boundaries; no CoreBridge lifecycle, Manager, UI or app proof")
        return checks
    }
}
