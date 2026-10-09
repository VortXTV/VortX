import Foundation
import CryptoKit

private final class OwnSourceCommitGate: VortxMutationAuthority, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    var isStarted: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func withActive(_ operation: () throws -> Void) throws {
        condition.lock(); started = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock(); try operation()
    }
}

@main struct VortxNativeOwnAccountLiveTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "own account live fixture line \(line)") }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func phase(_ value: String) { FileHandle.standardError.write(Data(("Own-account live phase: " + value + "\n").utf8)) }
    static func main() async throws {
        try await watchedMigrationCheckpoint()
        try await historicalWatchedRetryCheckpoint()
        let owner = UserProfile(id: UserProfile.ownerID, name: "Owner", avatar: "🍿", isOwner: true)
        let own = UserProfile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B22C")!, name: "Independent", avatar: "🍿", usesOwnAccount: true)
        let scope = VortxAccountScope(account: "account.own-source-fixture", ownerProfileID: owner.id.uuidString)
        let rootDocument = try JSONSerialization.data(withJSONObject: ["library": [["id": "owner-only", "name": "Owner only", "type": "movie"]], "addons": []])
        let library = try JSONSerialization.data(withJSONObject: ["result": [["_id": "independent-only", "name": "Independent only", "type": "movie",
            "state": ["timeOffset": 12000, "duration": 120000, "lastWatched": "2026-01-01T00:00:00.000Z", "video_id": "independent-only", "timesWatched": 1, "flaggedWatched": 0]]]])
        let addons = try JSONSerialization.data(withJSONObject: ["result": ["addons": [["transportUrl": "https://independent.invalid/manifest.json",
            "manifest": ["id": "independent", "name": "Independent", "version": "1.0.0"]]]]])
        let slot = "fixture.own." + own.id.uuidString
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [VortxNativeOwnAccountProducer.capture(slot: slot)], validate: { true })
        let source = try await VortxNativeOwnAccountProducer.fetch(profileID: own.id, authKey: "fixture-only", authority: authority,
            verify: { _ in "verified-own-uid" }, send: { request in .init(data: request.url!.lastPathComponent == "datastoreGet" ? library : addons, statusCode: 200) })
        let material = try VortxLegacyBootstrapMaterial.encode(document: rootDocument, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, ownAccountSources: [source])
        let sourceDocument = VortxJSON.object(["ownAccountSources": .object([own.id.uuidString: .object([
            "verifiedStreamingUid": .string(source.verifiedStreamingUID), "sourceDocumentBase64": .string(source.sourceDocument.base64EncodedString())])])])
        let sourceArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(sourceDocument))
        let bootstrap = try VortxNativeBootstrapArchive.encode(document: rootDocument, material: material, authenticatedSourceArchive: sourceArchive)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256), bootstrap: bootstrap, bootstrapScope: scope)
        let action = VortxJSON.object(["type": .string("import_legacy_sync"), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID),
            "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        phase("initial material import")
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)],
            sourceAuthority: authority, authenticatedSourceArchive: sourceArchive)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        phase("cold retained material")
        let retained = try VortxNativeSession.authenticatedOwnAccountBaseline(scope: scope, ownerName: owner.name,
            snapshot: nil, nativeSync: state["nativeSync"], abi: VortxCABI())
        check(retained != nil)
        let coldMaterial = try VortxLegacyBootstrapMaterial.encode(document: rootDocument, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, retainedOwnAccountBaseline: retained)
        let coldTyped = try JSONDecoder().decode(VortxJSON.self, from: coldMaterial)
        let retainedTyped = try JSONDecoder().decode(VortxJSON.self, from: retained!)
        for field in ["addons", "libraries", "watches", "identityLinks", "ownAccountSources"] {
            check(coldTyped[field]?[own.id.uuidString] == retainedTyped[field]?[own.id.uuidString])
        }
        try VortxNativeSession.validateLegacyCompatibility(scope: scope, ownerName: owner.name,
            snapshot: nil, nativeSync: state["nativeSync"], material: coldMaterial, abi: VortxCABI())
        guard case .object(var foreign) = state["nativeSync"] else { fatalError("missing native state") }
        foreign["scope"] = .string("account.foreign")
        do {
            _ = try VortxNativeSession.authenticatedOwnAccountBaseline(scope: scope, ownerName: owner.name,
                snapshot: nil, nativeSync: .object(foreign), abi: VortxCABI()); fatalError("foreign own baseline admitted")
        } catch VortxNativeError.invalidResponse {}
        check(state["nativeSync"]?["schemaVersion"] == .integer(3))
        check(state["nativeSync"]?["legacyImport"]?["schemaVersion"] == .integer(2))
        check(state["nativeSync"]?["legacyImport"]?["ownAccountImports"]?[own.id.uuidString]?["verifiedStreamingUid"] == .string("verified-own-uid"))
        check(state["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("independent-only"))
        check(state["libraries"]?[owner.id.uuidString]?["items"]?.array?.first?["id"] == .string("owner-only"))
        let saved = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: store.readHostPreferences(scope: scope)!)
        check(saved.authenticatedSourceArchive != nil)
        try store.rememberAuthenticatedScope(scope)
        let original = try JSONDecoder().decode(VortxJSON.self, from: store.recovery(account: scope.account)!.bootstrap)
        check(original["authenticatedSourceArchive"] == sourceDocument)
        let pendingSlice = try JSONEncoder().encode(VortxJSON.object(["vortx": .object(["byProfile": .object([
            own.id.uuidString: .object(["watched": .object(["unverified-change": .object(["ma": .integer(42)])])])])])]))
        let pendingRecord: VortxJSON = .object(["verifiedStreamingUid": .string(source.verifiedStreamingUID), "sourceDocumentSha256": .string(source.sourceDocumentSHA256),
            "profileOverlayBase64": .string(pendingSlice.base64EncodedString()), "reason": .string("changed_witness")])
        let pendingArchive = try VortxNativeOwnAccountProducer.archive([], pendingOverlays: [own.id.uuidString: pendingRecord])
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000000, authenticatedSourceArchive: pendingArchive)
        check(try await session.pendingOwnAccountOverlays() == .object([own.id.uuidString: pendingRecord]))
        let pendingNative = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        check(pendingNative["nativeSync"] == state["nativeSync"]) // No native ACK/source proof for deferred raw input.
        let pendingHost = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: store.readHostPreferences(scope: scope)!)
        let retainedPending = try JSONDecoder().decode(VortxJSON.self, from: pendingHost.authenticatedSourceArchive!)
        check(retainedPending["hostDocument"]?["ownAccountOverlayPending"]?[own.id.uuidString] == pendingRecord)
        let prior = try await session.stateJSON(), priorHost = try store.readHostPreferences(scope: scope)
        let mismatchedSource = VortxJSON.object(["ownAccountSources": .object([own.id.uuidString: .object([
            "verifiedStreamingUid": .string(source.verifiedStreamingUID), "sourceDocumentBase64": .string(Data("{}".utf8).base64EncodedString())])])])
        let mismatchedArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(mismatchedSource))
        do {
            _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000000, legacyMaterial: material,
                sourceAuthority: authority, authenticatedSourceArchive: mismatchedArchive)
            fatalError("unpaired raw source archive committed")
        } catch VortxNativeError.invalidSnapshot {}
        check(try await session.stateJSON() == prior && store.read(scope: scope) == prior && store.readHostPreferences(scope: scope) == priorHost)
        VortxNativeOwnAccountProducer.invalidate(slot: slot)
        do {
            _ = try await session.dispatch([#"{"type":"patch_profile","id":"00000000-0000-0000-0000-00000000B22C","edits":[{"field":"name","value":"Stale external source"}]}"#],
                now: 1800000000, legacyMaterial: material, sourceAuthority: authority, authenticatedSourceArchive: sourceArchive)
            fatalError("retired source wrote checkpoint")
        } catch VortxNativeError.superseded {}
        check(try await session.stateJSON() == prior && store.read(scope: scope) == prior && store.readHostPreferences(scope: scope) == priorHost)
        await session.close()
        // Cold peer has no streaming token, source archive or token generation. The authenticated
        // native receipt/buckets are enough to retain prior independent state without fabricating data.
        let peerStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("peer"), key: SymmetricKey(size: .bits256))
        let merge = VortxJSON.object(["type": .string("merge_native_sync"), "document": state["nativeSync"]!])
        phase("credentialless native peer")
        let peer = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: peerStore,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(merge)])
        _ = try await peer.dispatch([#"{"type":"get_state"}"#], now: 1800000001, legacyMaterial: coldMaterial)
        let adopted = try JSONDecoder().decode(VortxJSON.self, from: Data(try await peer.stateJSON().utf8))
        check(adopted["nativeSync"] == state["nativeSync"])
        check(adopted["libraries"]?[own.id.uuidString] == state["libraries"]?[own.id.uuidString])
        await peer.close()
        // A cold peer's first durable checkpoint must pair a newly authenticated source with
        // the reconciled native baseline, not seal it beside the older downloaded source proof.
        let refreshed = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id, verifiedStreamingUID: source.verifiedStreamingUID,
            sourceDocument: Data(" ".utf8) + source.sourceDocument, profileOverlaySHA256: source.profileOverlaySHA256)
        let refreshedMaterial = try VortxLegacyBootstrapMaterial.encode(document: rootDocument, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, ownAccountSources: [refreshed])
        let refreshedSources = VortxJSON.object(["ownAccountSources": .object([own.id.uuidString: .object([
            "verifiedStreamingUid": .string(refreshed.verifiedStreamingUID), "sourceDocumentBase64": .string(refreshed.sourceDocument.base64EncodedString())])])])
        let refreshedArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(refreshedSources))
        let refreshedBootstrap = try VortxNativeBootstrapArchive.encode(document: rootDocument, material: refreshedMaterial, authenticatedSourceArchive: refreshedArchive)
        let refreshedStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("refreshed-peer"), key: SymmetricKey(size: .bits256),
            bootstrap: refreshedBootstrap, bootstrapScope: scope)
        let newAuthority = VortxNativeOwnAccountProducer.Authority(generations: [VortxNativeOwnAccountProducer.capture(slot: slot)], validate: { true })
        phase("fresh source first checkpoint")
        let refreshedPeer = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: refreshedStore,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(merge)], sourceAuthority: newAuthority,
            authenticatedSourceArchive: refreshedArchive, initialLegacyMaterial: refreshedMaterial)
        let firstCheckpoint = try JSONDecoder().decode(VortxJSON.self, from: Data(refreshedStore.read(scope: scope)!.utf8))
        check(firstCheckpoint["nativeSync"]?["legacyImport"]?["baseline"]?["ownAccountSources"]?[own.id.uuidString]?["sourceDocumentSha256"] == .string(refreshed.sourceDocumentSHA256))
        await refreshedPeer.close()
        let failedStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("retired-first-peer"), key: SymmetricKey(size: .bits256),
            bootstrap: refreshedBootstrap, bootstrapScope: scope)
        VortxNativeOwnAccountProducer.invalidate(slot: slot)
        do {
            _ = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: failedStore,
                transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(merge)], sourceAuthority: newAuthority,
                authenticatedSourceArchive: refreshedArchive, initialLegacyMaterial: refreshedMaterial)
            fatalError("retired first peer committed bootstrap")
        } catch VortxNativeError.superseded {}
        check(try failedStore.read(scope: scope) == nil)
        phase("account rebind")
        try await rebindFixtures(scope: scope, owner: owner, own: own, native: state["nativeSync"]!, material: material,
                                 source: source, directory: directory.appendingPathComponent("rebind"))
        try await coldPendingRepair(scope: scope, owner: owner, own: own, native: state["nativeSync"]!,
                                    source: source, directory: directory.appendingPathComponent("pending-repair"))
        try await unattributedColdPeer(scope: scope, owner: owner, own: own, directory: directory.appendingPathComponent("unknown-overlay"))
        print("Own-account actual C: authenticated raw producer→material2/schema3, isolated buckets, original/latest sealed source, retired-source checkpoint fence and token-free native cold peer passed")
    }

    static func coldPendingRepair(scope: VortxAccountScope, owner: UserProfile, own: UserProfile, native: VortxJSON,
                                  source: VortxLegacyBootstrapMaterial.OwnAccountSource, directory: URL) async throws {
        phase("cold pending overlay repair")
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true,
            initialActions: [raw(.object(["type": .string("merge_native_sync"), "document": native]))])
        let slice: VortxJSON = .object(["vortx": .object(["byProfile": .object([own.id.uuidString: .object([
            "progress": .object(["independent-only": .object(["t": .integer(24), "d": .integer(120), "u": .integer(1800000000)])])])])])])
        let sliceData = try JSONEncoder().encode(slice)
        var root = try VortxProfileOverlayWitness.decodeObject(json: sliceData)
        root["library"] = [["id": "owner-only", "name": "Owner only", "type": "movie"]]; root["addons"] = []
        let document = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let baseline = try JSONEncoder().encode(native["legacyImport"]!["baseline"]!)
        let deferred = try VortxLegacyBootstrapMaterial.classifyDeferredOwnAccountOverlays(document: document,
            roster: [owner, own], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234, retainedOwnAccountBaseline: baseline)
        check(deferred.count == 1 && deferred[0].status == .changedWitness)
        let retained = try VortxLegacyBootstrapMaterial.encode(document: document, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, retainedOwnAccountBaseline: baseline, deferredOwnAccountOverlays: deferred)
        let pending: VortxJSON = .object(["verifiedStreamingUid": .string(source.verifiedStreamingUID), "sourceDocumentSha256": .string(source.sourceDocumentSHA256),
            "profileOverlayBase64": .string(sliceData.base64EncodedString()), "reason": .string("changed_witness")])
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000001, legacyMaterial: retained,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([], pendingOverlays: [own.id.uuidString: pending]))
        let before = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        check(before["nativeSync"] == native && before["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("independent-only"))
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        check(try VortxNativeOwnAccountProducer.pendingOverlay(profileID: own.id, verifiedUID: "foreign-uid", state: before,
            pending: .object([own.id.uuidString: pending])) == nil)
        let proven = try VortxNativeOwnAccountProducer.pendingOverlay(profileID: own.id, verifiedUID: source.verifiedStreamingUID,
            state: before, pending: .object([own.id.uuidString: pending]))!
        let original = try VortxProfileOverlayWitness.decodeObject(json: source.sourceDocument)
        let libraryResponse = Data(base64Encoded: original["libraryResponseBase64"] as! String)!
        let addonsResponse = Data(base64Encoded: original["addonsResponseBase64"] as! String)!
        let repair = try await VortxNativeOwnAccountProducer.fetch(profileID: own.id, authKey: "fixture-repair", authority: authority,
            profileOverlay: proven, verify: { _ in source.verifiedStreamingUID }, send: { request in
                .init(data: request.url!.lastPathComponent == "datastoreGet" ? libraryResponse : addonsResponse, statusCode: 200)
            })
        let repairMaterial = try VortxLegacyBootstrapMaterial.encode(document: sliceData, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, ownAccountSources: [repair])
        let target = try VortxNativeProfiles.ownTarget(material: JSONDecoder().decode(VortxJSON.self, from: repairMaterial), profileID: own.id)
        let request = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-pending-repair", expected: VortxNativeProfiles.expectedBinding(state: before, profileID: own.id), target: .own(target))
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], changed: { _ in })
        let staleAuthority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: facade.captureSourceFence())
        let gate = OwnSourceCommitGate()
        let rebindTask = Task {
            try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: request)], hostEdits: [],
                expectedProfileID: owner.id.uuidString, expectedAccountGeneration: facade.accountGeneration, sourceAuthority: gate,
                authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([repair], pendingOverlays: [:]))
        }
        while !gate.isStarted { await Task.yield() }
        let staleMerge = Task {
            try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: retained, sourceAuthority: staleAuthority,
                authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([], pendingOverlays: [own.id.uuidString: pending]))
        }
        for _ in 0..<10 { await Task.yield() }
        gate.release()
        try await rebindTask.value
        do { _ = try await staleMerge.value; fatalError("stale credentialless preparation restored cleared pending") }
        catch VortxNativeError.superseded {}
        // No MainActor context invalidation is performed here: accepted FIFO publication itself
        // must retire the old source/pending fence before its queued successor can commit.
        check(try await session.pendingOwnAccountOverlays() == .object([:]))
        let repaired = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        let slots = try VortxNativeProfiles.activeOwnAccountSlotBaselines(nativeSync: repaired["nativeSync"]!)
        let matched = try VortxLegacyBootstrapMaterial.classifyDeferredOwnAccountOverlays(document: document,
            roster: [owner, own], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234,
            retainedOwnAccountBaseline: baseline, retainedOwnAccountSlotBaselines: slots)
        check(matched.count == 1 && matched[0].status == .matchedWitness)
        let next = try VortxLegacyBootstrapMaterial.encode(document: document, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, retainedOwnAccountBaseline: baseline,
            retainedOwnAccountSlotBaselines: slots, deferredOwnAccountOverlays: matched)
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000003, legacyMaterial: next)
        check(try await session.pendingOwnAccountOverlays() == .object([:]))
        await facade.shutdown()
        print("Own-account actual C: changed cold overlay stays pending beside visible data; verified same-UID repair checkpoints source/witness and clears exactly its pending record")
    }

    static func unattributedColdPeer(scope: VortxAccountScope, owner: UserProfile, own: UserProfile, directory: URL) async throws {
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        let source = try await VortxNativeOwnAccountProducer.fetch(profileID: own.id, authKey: "fixture-B", authority: authority,
            framing: .independentNetworkOnly, verify: { _ in "network-only-B" }, send: { request in
                .init(data: Data((request.url!.lastPathComponent == "datastoreGet"
                    ? #"{"result":[{"_id":"B-only","name":"B","type":"movie","state":{}}]}"# : #"{"result":{"addons":[]}}"#).utf8), statusCode: 200)
            })
        let material = try VortxLegacyBootstrapMaterial.encode(document: Data("{}".utf8), roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, ownAccountSources: [source])
        let typed = try JSONDecoder().decode(VortxJSON.self, from: material)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(.object([
                "type": .string("import_legacy_sync"), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID), "material": typed]))])
        let overlay = try JSONEncoder().encode(VortxJSON.object(["vortx": .object(["byProfile": .object([
            own.id.uuidString: .object(["watched": .object(["unknown-A-only": .object(["ma": .integer(42)])])])])])]))
        let deferred = try VortxLegacyBootstrapMaterial.classifyDeferredOwnAccountOverlays(document: overlay,
            roster: [owner, own], ownerProfileID: owner.id, retainedOwnAccountBaseline: material)
        check(deferred.first?.status == .missingWitness)
        let proof = typed["ownAccountSources"]?[own.id.uuidString]
        check(try !VortxNativeOwnAccountProducer.hasOverlayAttribution(proof: proof, sealedEnvelope: nil))
        check(try !VortxNativeOwnAccountProducer.hasOverlayAttribution(proof: proof, sealedEnvelope: source.sourceDocument))
        let pending = try VortxNativeOwnAccountProducer.pendingRecord(disposition: deferred[0], verifiedUID: source.verifiedStreamingUID,
            overlay: overlay, attributed: false, previous: nil)
        check(pending["verifiedStreamingUid"] == nil && pending["sourceDocumentSha256"] == nil)
        let cannotPromote = try VortxNativeOwnAccountProducer.pendingRecord(disposition: deferred[0], verifiedUID: source.verifiedStreamingUID,
            overlay: overlay, attributed: true, previous: pending)
        check(cannotPromote["verifiedStreamingUid"] == nil) // A later source never retroactively attributes an unknown old intent.
        let retained = try VortxLegacyBootstrapMaterial.encode(document: overlay, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, retainedOwnAccountBaseline: material, deferredOwnAccountOverlays: deferred)
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000000, legacyMaterial: retained,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([], pendingOverlays: [own.id.uuidString: pending]))
        let before = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        let currentPending = try await session.pendingOwnAccountOverlays()
        check(try VortxNativeOwnAccountProducer.pendingOverlay(profileID: own.id, verifiedUID: source.verifiedStreamingUID,
            state: before, pending: currentPending) == nil)
        let reconnect = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "unattributed-B-reconnect", expected: VortxNativeProfiles.expectedBinding(state: before, profileID: own.id),
            target: .own(VortxNativeProfiles.ownTarget(material: typed, profileID: own.id)))
        _ = try await session.dispatch([raw(VortxNativeProfiles.rebindAction(profileID: own.id, request: reconnect))], now: 1800000001,
            sourceAuthority: authority, authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([source]))
        check(try await session.pendingOwnAccountOverlays() == .object([own.id.uuidString: pending]))
        let after = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        check(after["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("B-only"))
        check(try !raw(after["nativeSync"]!).contains("unknown-A-only"))
        await session.close()
        print("Own-account actual C: cold network-only B never attributes or consumes unknown historical A overlay; reconnect keeps raw pending and B data separate")
    }

    static func rebindFixtures(scope: VortxAccountScope, owner: UserProfile, own: UserProfile, native: VortxJSON,
                               material: Data, source: VortxLegacyBootstrapMaterial.OwnAccountSource, directory: URL) async throws {
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true,
            initialActions: [raw(.object(["type": .string("merge_native_sync"), "document": native])),
                             raw(.object(["type": .string("switch_profile"), "id": .string(own.id.uuidString)]))])
        phase("rebind facade")
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], changed: { _ in })
        phase("rebind facade created")
        func state() throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!) }
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        let original = try VortxNativeProfiles.ownTarget(material: JSONDecoder().decode(VortxJSON.self, from: material), profileID: own.id)
        var tokens: [String: String] = [:]
        func stage(_ uid: String, _ transaction: String?, _ token: String) throws -> String {
            try VortxNativeAccountCredentials.stage(token: token, scope: scope.account, profileID: own.id, uid: uid,
                transactionID: transaction, authority: authority, read: { tokens[$0] }, write: { tokens[$0] = $1; return true })
        }
        let oldSlot = try stage(source.verifiedStreamingUID, nil, "fixture-token-A")
        let oldEpoch = facade.accountGeneration
        let initial = try VortxNativeProfiles.expectedBinding(state: state(), profileID: own.id)
        let shared = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-shared", expected: initial, target: .shared)
        phase("shared CAS")
        try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: shared)], hostEdits: [],
            expectedProfileID: own.id.uuidString, expectedAccountGeneration: oldEpoch)
        check(facade.accountGeneration != oldEpoch)
        check(try state()["nativeSync"]?["schemaVersion"] == .integer(4))
        check(!facade.dispatchForProfile(.object(["type": .string("mark_watched"), "metaId": .string("stale-A")]),
            profileID: own.id.uuidString, expectedAccountGeneration: oldEpoch))
        let sharedState = try state(), sharedDisk = try store.read(scope: scope)
        let inactive = try stage(source.verifiedStreamingUID, "stale-intent", "fixture-inactive")
        do {
            try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: shared)], hostEdits: [],
                expectedProfileID: own.id.uuidString, expectedAccountGeneration: oldEpoch)
            fatalError("retired same-profile native epoch admitted")
        } catch VortxNativeError.superseded {}
        check(try state() == sharedState && store.read(scope: scope) == sharedDisk && tokens[inactive] != nil)
        let expected = try VortxNativeProfiles.expectedBinding(state: state(), profileID: own.id)
        check(try VortxNativeAccountCredentials.selectedSlot(scope: scope.account, profileID: own.id, binding: expected.document) == nil)
        let ownRequest = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-return-A", expected: expected, target: .own(original))
        let returnedSlot = try stage(source.verifiedStreamingUID, ownRequest.transactionID, "fixture-token-A2")
        let sharedEpoch = facade.accountGeneration
        try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: ownRequest)], hostEdits: [],
            expectedProfileID: own.id.uuidString, expectedAccountGeneration: sharedEpoch,
            sourceAuthority: authority, authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([source]))
        var returned = try state()
        check(facade.accountGeneration != sharedEpoch && facade.accountGeneration != oldEpoch)
        check(returned["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("independent-only"))
        let active = try VortxNativeProfiles.expectedBinding(state: returned, profileID: own.id)
        check(try VortxNativeAccountCredentials.selectedSlot(scope: scope.account, profileID: own.id, binding: active.document) == returnedSlot)
        check(returnedSlot != oldSlot && tokens[oldSlot] == "fixture-token-A")
        let sourceB = try await VortxNativeOwnAccountProducer.fetch(profileID: own.id, authKey: "fixture-only-B", authority: authority,
            framing: .independentNetworkOnly, verify: { _ in "verified-B" }, send: { request in
                let body = request.url!.lastPathComponent == "datastoreGet"
                    ? #"{"result":[{"_id":"only-B","name":"Only B","type":"movie","state":{}}]}"#
                    : #"{"result":{"addons":[]}}"#
                return .init(data: Data(body.utf8), statusCode: 200)
            })
        let materialB = try VortxLegacyBootstrapMaterial.encode(document: Data("{}".utf8), roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, ownAccountSources: [sourceB])
        let targetB = try VortxNativeProfiles.ownTarget(material: JSONDecoder().decode(VortxJSON.self, from: materialB), profileID: own.id)
        let beforeB = try VortxNativeProfiles.expectedBinding(state: returned, profileID: own.id)
        let requestB = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-B", expected: beforeB, target: .own(targetB))
        let credentialB = try stage(sourceB.verifiedStreamingUID, requestB.transactionID, "fixture-token-B")
        let epochA = facade.accountGeneration
        try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: requestB)], hostEdits: [],
            expectedProfileID: own.id.uuidString, expectedAccountGeneration: epochA, sourceAuthority: authority,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([sourceB]))
        let stateB = try state(), diskB = try store.read(scope: scope)
        check(stateB["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("only-B"))
        // A UI gesture can remain queued until after a same-profile A→B rebind has completed.
        // Its captured epoch must fail before either resident inventory or a fresh B lookup can
        // turn that old gesture into a watched mutation in B's bucket.
        check(!facade.setWatchedVideos(metaID: "stale-A-series", videoIDs: ["opaque-A-episode"], name: "Old A", type: "series", poster: nil,
                                      watched: true, profileID: own.id.uuidString, expectedAccountGeneration: epochA))
        check(facade.lastFailure == "stale_watched_account")
        check(await !facade.resolveAndSetWatchedVideos(metaID: "stale-A-series", type: "series", name: "Old A", poster: nil,
                                                      watched: true, profileID: own.id.uuidString, expectedAccountGeneration: epochA))
        check(facade.lastFailure == "stale_watched_resolution")
        await facade.settled()
        check(try state() == stateB && store.read(scope: scope) == diskB)
        check(try VortxNativeAccountCredentials.selectedSlot(scope: scope.account, profileID: own.id,
            binding: VortxNativeProfiles.expectedBinding(state: stateB, profileID: own.id).document) == credentialB)
        let staleCAS = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-stale-native-CAS", expected: beforeB, target: .shared)
        do {
            try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: staleCAS)], hostEdits: [],
                expectedProfileID: own.id.uuidString, expectedAccountGeneration: facade.accountGeneration)
            fatalError("stale kernel CAS changed the active account")
        } catch VortxNativeError.invalidResponse {}
        check(try state() == stateB && store.read(scope: scope) == diskB)
        let backA = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-A-again", expected: VortxNativeProfiles.expectedBinding(state: stateB, profileID: own.id), target: .own(original))
        _ = try stage(source.verifiedStreamingUID, backA.transactionID, "fixture-token-A3")
        try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: backA)], hostEdits: [],
            expectedProfileID: own.id.uuidString, expectedAccountGeneration: facade.accountGeneration, sourceAuthority: authority,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([source]))
        returned = try state()
        check(returned["libraries"]?[own.id.uuidString]?["items"]?.array?.first?["id"] == .string("independent-only"))
        check(tokens[credentialB] == "fixture-token-B" && tokens[returnedSlot] == "fixture-token-A2")
        check(!facade.dispatchForProfile(.object(["type": .string("mark_watched"), "metaId": .string("ABA-stale")]),
            profileID: own.id.uuidString, expectedAccountGeneration: epochA))
        var emptyDigest: String?
        for uid in ["verified-empty-X", "verified-empty-Y"] {
            let empty = try await VortxNativeOwnAccountProducer.fetch(profileID: own.id, authKey: "fixture-empty", authority: authority,
                framing: .independentNetworkOnly, verify: { _ in uid }, send: { request in
                    .init(data: Data((request.url!.lastPathComponent == "datastoreGet" ? #"{"result":[]}"# : #"{"result":{"addons":[]}}"#).utf8), statusCode: 200)
                })
            check(empty.profileOverlaySHA256 == nil)
            if let emptyDigest { check(emptyDigest == empty.sourceDocumentSHA256) } else { emptyDigest = empty.sourceDocumentSHA256 }
            let emptyMaterial = try VortxLegacyBootstrapMaterial.encode(document: Data("{}".utf8), roster: [owner, own], ownerProfileID: owner.id,
                rosterModifiedSeconds: nil, ownAccountSources: [empty])
            let emptyTarget = try VortxNativeProfiles.ownTarget(material: JSONDecoder().decode(VortxJSON.self, from: emptyMaterial), profileID: own.id)
            let request = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
                transactionID: "fixture-" + uid, expected: VortxNativeProfiles.expectedBinding(state: state(), profileID: own.id), target: .own(emptyTarget))
            _ = try stage(uid, request.transactionID, "fixture-token-" + uid)
            try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: request)], hostEdits: [],
                expectedProfileID: own.id.uuidString, expectedAccountGeneration: facade.accountGeneration, sourceAuthority: authority,
                authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([empty]))
            check(try state()["libraries"]?[own.id.uuidString]?["items"] == .array([]))
        }
        let ambiguousSlice = try JSONEncoder().encode(VortxJSON.object(["vortx": .object(["byProfile": .object([
            own.id.uuidString: .object(["watched": .object(["X-only": .object(["ma": .integer(42)])])])])])]))
        let pinnedPending: VortxJSON = .object(["verifiedStreamingUid": .string("verified-empty-X"),
            "sourceDocumentSha256": .string(emptyDigest!), "profileOverlayBase64": .string(ambiguousSlice.base64EncodedString()),
            "reason": .string("missing_witness")])
        _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([], pendingOverlays: [own.id.uuidString: pinnedPending]))
        let exactPending = facade.profileSnapshot()!.pending
        check(try VortxNativeOwnAccountProducer.pendingOverlay(profileID: own.id, verifiedUID: "verified-empty-Y", state: state(), pending: exactPending) == nil)
        check(try VortxNativeOwnAccountProducer.pendingOverlay(profileID: own.id, verifiedUID: "verified-empty-X", state: state(), pending: exactPending) == ambiguousSlice)
        let restoreA = try VortxNativeProfiles.AccountRebindRequest(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-restore-A-final", expected: VortxNativeProfiles.expectedBinding(state: state(), profileID: own.id), target: .own(original))
        _ = try stage(source.verifiedStreamingUID, restoreA.transactionID, "fixture-token-A-final")
        try await facade.mutateProfiles([VortxNativeProfiles.rebindAction(profileID: own.id, request: restoreA)], hostEdits: [],
            expectedProfileID: own.id.uuidString, expectedAccountGeneration: facade.accountGeneration, sourceAuthority: authority,
            authenticatedSourceArchive: VortxNativeOwnAccountProducer.archive([source]))
        returned = try state()
        let pendingProfile = UserProfile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C33D")!, name: "Pending", avatar: "🍿", usesOwnAccount: true)
        let pendingRequest = try VortxNativeProfiles.AccountRebindRequest.initial(scope: scope.account, ownerProfileID: scope.ownerProfileID,
            transactionID: "fixture-create-pending", target: .pendingOwn)
        let pendingMutation = try VortxNativeProfiles.mutation(pendingProfile, previous: nil, ownerID: scope.ownerProfileID, rebind: pendingRequest)
        var invalidBatch = pendingMutation.0
        guard case .object(var badRebind) = invalidBatch.last! else { fatalError("missing staged rebind") }
        badRebind["scope"] = .string("foreign-scope"); invalidBatch[invalidBatch.count - 1] = .object(badRebind)
        let beforeCreation = try store.read(scope: scope)
        do {
            try await facade.mutateProfiles(invalidBatch, hostEdits: [pendingMutation.1], expectedProfileID: own.id.uuidString,
                expectedAccountGeneration: facade.accountGeneration)
            fatalError("partially created independent profile")
        } catch VortxNativeError.invalidResponse {}
        check(try store.read(scope: scope) == beforeCreation && state()["roster"]?["profiles"]?[pendingProfile.id.uuidString] == nil)
        try await facade.mutateProfiles(pendingMutation.0, hostEdits: [pendingMutation.1], expectedProfileID: own.id.uuidString,
            expectedAccountGeneration: facade.accountGeneration)
        returned = try state()
        check(returned["roster"]?["profiles"]?[pendingProfile.id.uuidString]?["account"]?["kind"] == .string("pending_own"))
        check(returned["roster"]?["profiles"]?[pendingProfile.id.uuidString]?["addons"] == .string("own"))
        check(returned["libraries"]?[pendingProfile.id.uuidString]?["items"] == .array([]))
        await facade.shutdown() // A cold peer must not create a second live writer for this scope.
        let peerStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("cold"), key: SymmetricKey(size: .bits256))
        let cold = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: peerStore,
            transport: VortxCResourceTransport(), allowNewAccount: true,
            initialActions: [raw(.object(["type": .string("merge_native_sync"), "document": returned["nativeSync"]!]))])
        let coldState = try JSONDecoder().decode(VortxJSON.self, from: Data(try await cold.stateJSON().utf8))
        check(coldState["libraries"]?[own.id.uuidString]?["items"] == returned["libraries"]?[own.id.uuidString]?["items"])
        check(coldState["nativeSync"]?["accountSlots"] == returned["nativeSync"]?["accountSlots"])
        await cold.close()
        print("Own-account schema4 actual C: atomic shared/own CAS, retained buckets, same-profile epoch retirement, inactive failed-CAS credential and credentialless cold slot passed")
    }
    static func historicalWatchedRetryCheckpoint() async throws {
        phase("historical watched retry preserves removed rows and distinct own UID evidence")
        let owner = UserProfile(id: UUID(uuidString: "90000000-0000-0000-0000-000000000109")!, name: "Owner", avatar: "O", isOwner: true)
        let ownID = UUID(uuidString: "90000000-0000-0000-0000-000000000110")!
        let scope = VortxAccountScope(account: "account.historical-watched", ownerProfileID: owner.id.uuidString)
        let addon: [String: Any] = ["transportUrl": "https://historical.invalid/manifest.json",
            "manifest": ["id": "historical", "name": "Historical", "version": "1.0.0", "resources": ["meta"], "types": ["series"]]]
        let bitmap = "tt2934286:1:5:5:eJyTZwAAAEAAIA=="
        let sourceA = try JSONSerialization.data(withJSONObject: ["vortx": ["library": [["id": "tt2934286", "type": "series", "watched": bitmap]], "addons": [addon]]])
        let sourceB = try JSONSerialization.data(withJSONObject: ["unrelatedSetting": "changed", "vortx": ["library": [], "addons": [addon]]])
        let metadata = try JSONSerialization.data(withJSONObject: ["meta": ["id": "tt2934286", "type": "series", "videos": (1...5).map {
            ["id": "tt2934286:1:\($0)", "season": 1, "episode": $0, "released": "2020-01-0\($0)T00:00:00.000Z"] as [String: Any]
        }]])
        let pendingA = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: sourceA, profileIDs: [owner.id], isCurrent: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let libraryBody = try JSONSerialization.data(withJSONObject: ["result": [["_id": "tt2934286", "type": "series", "state": ["watched": bitmap]]]])
        let addonBody = try JSONSerialization.data(withJSONObject: ["result": ["addons": [addon]]])
        let envelope = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "libraryResponseBase64": libraryBody.base64EncodedString(), "addonsResponseBase64": addonBody.base64EncodedString(),
            "profileOverlayBase64": Data("{}".utf8).base64EncodedString()])
        let ownA = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: ownID, verifiedStreamingUID: "historical-A", sourceDocument: envelope)
        let ownB = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: ownID, verifiedStreamingUID: "current-B", sourceDocument: envelope)
        check(ownA.sourceDocumentSHA256 == ownB.sourceDocumentSHA256)
        let ownPendingA = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: Data("{}".utf8), profileIDs: [owner.id], ownAccountSources: [ownA], isCurrent: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let ownCompleteB = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: Data("{}".utf8), profileIDs: [owner.id], ownAccountSources: [ownB], isCurrent: { true }, fetch: { .init(request: $0, raw: metadata) })
        let originalPending = try pendingA.pendingArchives + ownPendingA.pendingArchives
        let prior = try VortxNativeWatchedArchive.retaining(VortxNativeOwnAccountProducer.archive([]),
            evidence: ownCompleteB.archives, pending: originalPending, scope: scope)
        let resolved = try await VortxNativeWatchedArchive.retryHistorical(prior, scope: scope, isCurrent: { true }, fetch: {
            check($0.scope.verifiedStreamingUID == nil || $0.scope.verifiedStreamingUID == "historical-A")
            return .init(request: $0, raw: metadata)
        })!
        check(try VortxNativeWatchedArchive.pendingProfileIDs(resolved).isEmpty)
        check(Set(try VortxNativeWatchedArchive.entries(resolved, key: VortxNativeWatchedArchive.pendingKey)) == Set(originalPending))
        check(try VortxNativeWatchedArchive.entries(resolved, key: VortxNativeWatchedArchive.evidenceKey).count == 3)
        let replayed = try await VortxNativeWatchedArchive.retryHistorical(resolved, scope: scope, isCurrent: { true }, fetch: { _ in
            check(false); throw URLError(.unsupportedURL)
        })
        check(replayed == resolved)
        // Current B removed the row. Historical A evidence stays archived but cannot manufacture
        // a current validated row or native watch entry, even though the pending UI is resolved.
        let current = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: sourceB, profileIDs: [owner.id], archivedEvidence: VortxNativeWatchedArchive.entries(resolved, key: VortxNativeWatchedArchive.evidenceKey),
            isCurrent: { true }, fetch: { _ in check(false); throw URLError(.unsupportedURL) })
        check(current.rows.isEmpty && current.unresolved.isEmpty)
        let material = try VortxLegacyBootstrapMaterial.encode(document: sourceB, roster: [owner], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, accountID: scope.account, watchedEvidence: current.rows)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("historical-watched")
        let bootstrap = try VortxNativeBootstrapArchive.encode(document: sourceB, material: material, authenticatedSourceArchive: resolved)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256), bootstrap: bootstrap, bootstrapScope: scope)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID),
            "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)], authenticatedSourceArchive: resolved)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        check(state["libraries"]?[owner.id.uuidString]?["items"] == .array([]))
        check(!String(decoding: try JSONEncoder().encode(state["watches"]), as: UTF8.self).contains("tt2934286"))
        check(try await session.authenticatedSourceArchive() == resolved)
        await session.close()
        let cold = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store, transport: VortxCResourceTransport(), allowNewAccount: false)
        check(try await cold.authenticatedSourceArchive() == resolved)
        await cold.close()
        print("Watched historical host actual C: source-A/removed-current-B retry, distinct UID same-byte evidence union, zero-network replay, no imported historical rows and durable cold sidecar passed")
    }
    static func watchedMigrationCheckpoint() async throws {
        phase("watched preflight draft, retry and atomic source sidecars")
        let owner = UserProfile(id: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!, name: "Owner", avatar: "O", isOwner: true)
        let scope = VortxAccountScope(account: "account.watched-host", ownerProfileID: owner.id.uuidString)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("watched")
        let key = SymmetricKey(size: .bits256)
        let document = try VortxNativeBootstrapArchive.credentialFreeDocument(["apiKeys": ["tmdb": "fixture-never-archived"], "vortx": [
            "library": [["id": "tt2934286", "type": "series", "name": "Fixture", "watched": "tt2934286:1:5:5:eJyTZwAAAEAAIA==",
                         "ua": ["tt2934286:1:4": 4321.5]]],
            "addons": [["transportUrl": "https://catalog.invalid/manifest.json", "manifest": ["id": "catalog", "name": "Catalog", "version": "1.0.0", "resources": ["meta"], "types": ["series"]]]]]])
        check(!String(decoding: document, as: UTF8.self).contains("fixture-never-archived"))
        let authority = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        let pending = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: document, profileIDs: [owner.id], isCurrent: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        check(pending.unresolved.count == 1 && pending.rows.isEmpty)
        let empty = try VortxNativeOwnAccountProducer.archive([])
        let draft = try VortxNativeWatchedArchive.retaining(empty, evidence: pending.archives, pending: pending.pendingArchives, scope: scope)
        let probe = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        try probe.retainMigrationDraft(draft, scope: scope, authority: authority)
        check(try probe.authenticatedCheckpoint(scope: scope) == nil)
        let reopened = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        check(try reopened.readMigrationDraft(scope: scope) == draft)
        let accepted = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        do { try probe.retainMigrationDraft(draft, scope: scope, authority: accepted); check(false) } catch VortxNativeError.superseded {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try probe.retainMigrationDraft(draft, scope: scope, expected: draft, authority: accepted)
        }
        do { try await cancelled.value; check(false) } catch is CancellationError {}
        check(try reopened.readMigrationDraft(scope: scope) == draft)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(draft) == [owner.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(!files.contains { $0.hasPrefix("native-state-") || $0.hasPrefix("native-account-") })
        let retired = VortxNativeOwnAccountProducer.Authority(generations: [], validate: { true })
        VortxNativeOwnAccountProducer.invalidateContext()
        do { try probe.retainMigrationDraft(draft, scope: scope, authority: retired); check(false) } catch VortxNativeError.superseded {}
        check(try reopened.readMigrationDraft(scope: scope) == draft)
        do { try VortxNativeWatchedArchive.validate(draft, scope: .init(account: "account.foreign", ownerProfileID: owner.id.uuidString)); check(false) } catch {}
        let metadata = try JSONSerialization.data(withJSONObject: ["meta": ["id": "tt2934286", "type": "series", "videos": (1...5).map {
            ["id": "tt2934286:1:\($0)", "season": 1, "episode": $0, "released": "2020-01-0\($0)T00:00:00.000Z"] as [String: Any]
        }]])
        let complete = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: document, profileIDs: [owner.id], isCurrent: { true }, fetch: { .init(request: $0, raw: metadata) })
        check(complete.rows.count == 1 && complete.unresolved.isEmpty)
        let archive = try VortxNativeWatchedArchive.retaining(empty, prior: draft, evidence: complete.archives, scope: scope)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(archive).isEmpty)
        check(try VortxNativeWatchedArchive.entries(archive, key: VortxNativeWatchedArchive.pendingKey) == pending.pendingArchives)
        let replay = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: document, profileIDs: [owner.id], archivedEvidence: VortxNativeWatchedArchive.entries(archive, key: VortxNativeWatchedArchive.evidenceKey),
            isCurrent: { true }, fetch: { _ in check(false); throw URLError(.unsupportedURL) })
        let material = try VortxLegacyBootstrapMaterial.encode(document: document, roster: [owner], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil, accountID: scope.account, watchedEvidence: replay.rows)
        let bootstrap = try VortxNativeBootstrapArchive.encode(document: document, material: material, authenticatedSourceArchive: archive)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: key, bootstrap: bootstrap, bootstrapScope: scope)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID),
            "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)], authenticatedSourceArchive: archive)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        check(state["nativeSync"]?["legacyImport"] != nil)
        let persisted = try await session.authenticatedSourceArchive()
        check(try VortxNativeWatchedArchive.entries(persisted, key: VortxNativeWatchedArchive.evidenceKey) == complete.archives)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(persisted).isEmpty)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: []) { _ in }
        let watch = VortxNativeWatchlist.Entry(id: "tt987", type: "movie", name: "Watch later", poster: nil, addedAt: 10.125)
        let watchKey = try VortxNativeWatchlist.field(id: watch.id, type: watch.type)
        _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil, legacyWatchlists: [owner.id: [watch]])
        check(try VortxNativeWatchlist.entries(host: facade.profileSnapshot()!.host, profileID: owner.id) == [watch])
        let seededDisk = try store.readHostPreferences(scope: scope)
        check(seededDisk != nil)
        let coldSeed = try VortxNativeHostPreferences(scope: scope, actor: "00000000-0000-0000-0000-000000000002", sealed: seededDisk)
        check(try VortxNativeWatchlist.entries(host: coldSeed.document, profileID: owner.id) == [watch])
        let libraryBeforeWatch = facade.profileSnapshot()!.state["libraries"]
        try await facade.mutateProfiles([], hostEdits: [.init(profileID: owner.id.uuidString, fields: [watchKey: .null])],
            expectedProfileID: owner.id.uuidString, expectedAccountGeneration: facade.accountGeneration)
        _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil, legacyWatchlists: [owner.id: [watch]])
        check(try VortxNativeWatchlist.entries(host: facade.profileSnapshot()!.host, profileID: owner.id).isEmpty)
        check(facade.profileSnapshot()!.state["libraries"] == libraryBeforeWatch)
        let historicalProfile = UUID(uuidString: "90000000-0000-0000-0000-000000000099")!
        _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil, legacyWatchlists: [historicalProfile: [watch]])
        check(facade.profileSnapshot()!.host["profiles"]?[historicalProfile.uuidString] == nil)
        check(facade.profileSnapshot()!.state["roster"]?["profiles"]?[historicalProfile.uuidString] == nil)
        let watchHostBeforeFailure = try store.readHostPreferences(scope: scope)
        do { try await facade.mutateProfiles([], hostEdits: [.init(profileID: owner.id.uuidString, fields: [watchKey: VortxNativeWatchlist.value(watch)])],
            expectedProfileID: owner.id.uuidString, expectedAccountGeneration: UUID()); check(false) } catch VortxNativeError.superseded {}
        check(try store.readHostPreferences(scope: scope) == watchHostBeforeFailure)
        print("Watchlist actual C: authenticated absent-register seed, durable per-item removal, stale legacy replay refusal, untouched engine library and stale-epoch checkpoint rejection passed")
        let fence = facade.captureSourceFence()
        let stale = VortxNativeOwnAccountProducer.Authority(generations: [], validate: fence)
        let otherDocument = try VortxNativeBootstrapArchive.credentialFreeDocument(["vortx": ["library": [["id": "tt2934286", "type": "series", "watched": "tt2934286:1:5:5:eJyTZwAAAEAAIA=="]], "addons": []]])
        let otherPending = try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner.id,
            document: otherDocument, profileIDs: [owner.id], isCurrent: { true }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let sidecar = try VortxNativeWatchedArchive.retaining(empty, pending: otherPending.pendingArchives, scope: scope)
        _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil, authenticatedSourceArchive: sidecar)
        let before = try store.readHostPreferences(scope: scope)
        do { _ = try await facade.mergeAccountDocument(nil, hostRemote: nil, legacyMaterial: nil, sourceAuthority: stale, authenticatedSourceArchive: archive); check(false) }
        catch VortxNativeError.superseded {}
        check(try store.readHostPreferences(scope: scope) == before)
        check(try VortxNativeWatchedArchive.entries(facade.authenticatedSourceArchive, key: VortxNativeWatchedArchive.evidenceKey) == complete.archives)
        await facade.shutdown()
        print("Watched host actual C: encrypted first-run draft, no empty checkpoint, retired capture refusal, source-exact offline replay, immutable pending/evidence retention and FIFO stale sidecar rejection passed")
    }
}
