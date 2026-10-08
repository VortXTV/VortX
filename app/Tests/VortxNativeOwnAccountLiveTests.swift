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
}
