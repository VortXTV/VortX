import Foundation
import VortxEngine

@MainActor @main enum NativeOwnSourceReopenRegression {
    // Public adapter + shipped static C ABI. Entire fixture is synthetic and offline.
    typealias Object = [String: Any]
    static func check(_ condition: Bool, _ message: String = "synthetic assertion failed") { precondition(condition, message) }
    static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    static func raw(_ object: Any) throws -> String { String(decoding: try bytes(object), as: UTF8.self) }
    static func object(_ bytes: Data) throws -> Object { try JSONSerialization.jsonObject(with: bytes) as! Object }
    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String { precondition(p != nil); defer { vortx_string_free(p) }; return String(cString: p!) }
    static func state(_ e: OpaquePointer) throws -> Object { try object(Data(take(vortx_get_state_json(e)).utf8)) }
    static func apply(_ e: OpaquePointer, _ action: Object, expected: Bool = true) throws -> Object {
        let result = try object(Data(take(vortx_dispatch_json(e, try raw(action), 100)).utf8))
        check(result["ok"] as? Bool == expected, "unexpected ABI result: \(result["error"] ?? "none")")
        return result
    }
    static let owner = UserProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Owner", avatar: "O", isOwner: true)
    static let child = UserProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Child", avatar: "C", usesOwnAccount: true)
    static let oid = owner.id.uuidString, cid = child.id.uuidString
    static let scope = "synthetic-public-adapter-sameuid"
    static let rootData = Data(#"{"vortx":{}}"#.utf8)
    static let uid = "synthetic-own-uid"
    static func producedMaterial(second: Int, position: Int) throws -> Object {
        let library = try bytes(["result": [["_id": "synthetic-movie", "name": "Synthetic movie", "type": "movie",
            "state": ["timeOffset": position, "duration": 1000000,
                      "lastWatched": "2026-01-01T00:00:\(String(format: "%02d", second)).000Z", "video_id": "synthetic-movie"]]]])
        let addons = try bytes(["result": ["addons": []]])
        let overlay = Data("{}".utf8)
        let envelope = try bytes(["schemaVersion": 2, "libraryResponseBase64": library.base64EncodedString(),
            "addonsResponseBase64": addons.base64EncodedString(), "profileOverlayBase64": overlay.base64EncodedString()])
        let source = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: child.id, verifiedStreamingUID: uid,
            sourceDocument: envelope, profileOverlaySHA256: try VortxProfileOverlayWitness.digest(json: overlay))
        return try object(VortxLegacyBootstrapMaterial.encode(document: rootData, roster: [owner, child], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1700000000, ownAccountSources: [source]))
    }
    static func carrier(_ material: Object) -> Object {
        ["source": (material["ownAccountSources"] as! Object)[cid]!,
         "addons": (material["addons"] as! Object)[cid]!, "library": (material["libraries"] as! Object)[cid]!,
         "watches": (material["watches"] as! Object)[cid]!, "identityLinks": (material["identityLinks"] as! Object)[cid]!]
    }
    static func action(_ name: String, _ material: Object) -> Object { ["type": name, "scope": scope, "ownerProfileId": oid, "material": material] }
    
    static func main() throws {
        let m0 = try producedMaterial(second: 10, position: 1000)
        let m1 = try producedMaterial(second: 20, position: 2000)
        let e = vortx_init_runtime(oid, "Owner")!
        defer { vortx_engine_free(e) }
        _ = try apply(e, ["type": "bind_sync_scope", "scope": scope])
        _ = try apply(e, action("import_legacy_sync", m0))
        let original = try state(e)
        let originalReceipt = (original["nativeSync"] as! Object)["legacyImport"]!
        _ = try apply(e, ["type": "rebind_profile_account", "scope": scope, "ownerProfileId": oid, "profileId": cid,
            "transactionId": "synthetic-refresh",
            "expectedBinding": ["account": ["kind": "own", "value": uid], "revision": 0, "transactionId": NSNull()],
            "target": ["kind": "own", "carrier": carrier(m1)]])
        let refreshed = try state(e), native = refreshed["nativeSync"] as! Object
        let receipt = native["legacyImport"] as! Object
        check(try raw(receipt) == raw(originalReceipt), "refresh altered global receipt")
        let accountSlots = ((native["accountSlots"] as! Object)[cid] as! Object)["slots"] as! Object
        let active = accountSlots.values.compactMap { $0 as? Object }.first { ($0["account"] as? Object)?["value"] as? String == uid }!
        let slot = VortxLegacyBootstrapMaterial.RetainedOwnAccountSlotBaseline(profileID: child.id, sourceBaseline: try bytes(active["sourceBaseline"]!))
        let baseline = try bytes(receipt["baseline"]!)
        // This is the real production Adapter call shape from startup, with an unchanged outer document.
        let prepared = try VortxLegacyBootstrapMaterial.prepare(document: rootData, roster: [owner, child], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1700000000, deferProfileEdits: true, retainedOwnAccountBaseline: baseline,
            retainedOwnAccountSlotBaselines: [slot], accountID: scope)
        let current = try object(prepared.material)
        let expectGreen = CommandLine.arguments.contains("--expect-green")
        let before = try raw(refreshed)
        if expectGreen {
            _ = try apply(e, action("import_legacy_sync", current))
            check(try raw(state(e)) == before)
            print("GREEN: patched production adapter preserves current acknowledged legacy source; newer own slot/watch byte-equivalent")
        } else {
            _ = try apply(e, action("import_legacy_sync", current), expected: false)
            let red = try apply(e, action("reconcile_legacy_sync", current), expected: false)
            check(red["error"] as? String == "legacy watch event conflicts with equal native clock")
            check(try raw(state(e)) == before)
            print("RED: unmodified production adapter + shipped C ABI reproducibly rejects same-UID watch refresh on unchanged outer document")
        }
        // Existing historical-only policy is causal replay and must leave newer native state untouched.
        let historicalOnly = try VortxLegacyBootstrapMaterial.encode(document: rootData, roster: [owner, child], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1700000000, retainedOwnAccountBaseline: baseline)
        _ = try apply(e, action("import_legacy_sync", object(historicalOnly)))
        check(try raw(state(e)) == before)
        print("GREEN control: acknowledged baseline alone is accepted; newer own slot/watch retained")
        
    }
}

