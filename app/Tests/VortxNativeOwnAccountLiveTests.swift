import Foundation
import CryptoKit

@main struct VortxNativeOwnAccountLiveTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "own account live fixture line \(line)") }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
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
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)],
            sourceAuthority: authority, authenticatedSourceArchive: sourceArchive)
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
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
            sourceDocument: Data(" ".utf8) + source.sourceDocument)
        let refreshedMaterial = try VortxLegacyBootstrapMaterial.encode(document: rootDocument, roster: [owner, own], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, ownAccountSources: [refreshed])
        let refreshedSources = VortxJSON.object(["ownAccountSources": .object([own.id.uuidString: .object([
            "verifiedStreamingUid": .string(refreshed.verifiedStreamingUID), "sourceDocumentBase64": .string(refreshed.sourceDocument.base64EncodedString())])])])
        let refreshedArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(refreshedSources))
        let refreshedBootstrap = try VortxNativeBootstrapArchive.encode(document: rootDocument, material: refreshedMaterial, authenticatedSourceArchive: refreshedArchive)
        let refreshedStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("refreshed-peer"), key: SymmetricKey(size: .bits256),
            bootstrap: refreshedBootstrap, bootstrapScope: scope)
        let newAuthority = VortxNativeOwnAccountProducer.Authority(generations: [VortxNativeOwnAccountProducer.capture(slot: slot)], validate: { true })
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
        print("Own-account actual C: authenticated raw producer→material2/schema3, isolated buckets, original/latest sealed source, retired-source checkpoint fence and token-free native cold peer passed")
    }
}
