import Foundation

@main
enum VortxLegacyBootstrapMaterialTests {
    typealias Object = [String: Any]
    static let owner = UserProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, name: "Owner", avatar: "O", isOwner: true)
    static let child = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Child", avatar: "C")

    static func main() throws {
        try fixtureAndRoster()
        try ownAccountSources()
        try savedVersusPlayed()
        try durableHistoryAndClockPolicies()
        try ownerActorTies()
        try descriptorAndRemovalPolicies()
        try watchConsolidation()
        try profilePreferencesAndIdentity()
        try completenessAndClockEvidence()
        try rejectedEvidence()
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func material(_ document: Object, roster: [UserProfile] = [owner, child], modified: Double? = 1720000000.1234,
                         deferProfileEdits: Bool = false,
                         ownAccountSources: [VortxLegacyBootstrapMaterial.OwnAccountSource] = [],
                         retainedOwnAccountBaseline: Data? = nil) throws -> Object {
        let data = try JSONSerialization.data(withJSONObject: document)
        let result = try VortxLegacyBootstrapMaterial.encode(document: data, roster: roster, ownerProfileID: owner.id,
                                                              rosterModifiedSeconds: modified, deferProfileEdits: deferProfileEdits,
                                                              ownAccountSources: ownAccountSources,
                                                              retainedOwnAccountBaseline: retainedOwnAccountBaseline)
        return try JSONSerialization.jsonObject(with: result) as! Object
    }
    static func doc(_ vortx: Object = [:]) -> Object { ["vortx": vortx] }
    static func movie(_ id: String = "tt123", position: Double = 0) -> Object {
        ["id": id, "type": "movie", "name": "Movie", "poster": "https://example.com/movie.jpg", "t": position,
         "d": 100, "lastWatched": "2026-01-01T00:00:00.123456Z"]
    }
    /// Models the producer boundary exactly: independently authenticated Stremio response bodies
    /// are retained byte-for-byte and put behind a small, token-free carrier. The bootstrapper
    /// never accepts a flattened host reconstruction as account proof.
    static func ownSourceEnvelope(libraryRows: [Object], addons: [Object], profileOverlay: Object = [:],
                                  libraryResponseExtra: Object = [:], addonsResponseExtra: Object = [:], extraEnvelope: Object = [:]) throws -> Data {
        var libraryResponseObject: Object = ["result": libraryRows]
        var addonsResponseObject: Object = ["result": ["addons": addons]]
        for (key, value) in libraryResponseExtra { libraryResponseObject[key] = value }
        for (key, value) in addonsResponseExtra { addonsResponseObject[key] = value }
        let libraryResponse = try JSONSerialization.data(withJSONObject: libraryResponseObject, options: [.sortedKeys])
        let addonsResponse = try JSONSerialization.data(withJSONObject: addonsResponseObject, options: [.sortedKeys])
        let overlayResponse = try JSONSerialization.data(withJSONObject: profileOverlay, options: [.sortedKeys])
        var envelope: Object = ["schemaVersion": 1,
                                "libraryResponseBase64": libraryResponse.base64EncodedString(),
                                "addonsResponseBase64": addonsResponse.base64EncodedString(),
                                "profileOverlayBase64": overlayResponse.base64EncodedString()]
        for (key, value) in extraEnvelope { envelope[key] = value }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
    static func watches(_ material: Object, profile: UserProfile = owner) -> [Object] {
        (material["watches"] as! [String: [Object]])[profile.id.uuidString]!
    }
    static func fail(_ document: Object, _ phrase: String, roster: [UserProfile] = [owner, child], modified: Double? = 1720000000.1234) throws {
        do { _ = try material(document, roster: roster, modified: modified); preconditionFailure("Expected failure: " + phrase) }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains(phrase), "Expected \(phrase); got \(error.reason)")
        }
    }
    static func fixtureAndRoster() throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: "app/Tests/Fixtures/legacy-bootstrap-apple.json"))
        var pinned = owner
        pinned.pin = UserProfile.pinHash("1234", profileID: owner.id)
        var kid = child; kid.textScale = 1.15; kid.isKids = true; kid.familyEdit = true
        let data = try VortxLegacyBootstrapMaterial.encode(document: source, roster: [pinned, kid], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234)
        let result = try JSONSerialization.jsonObject(with: data) as! Object
        let roster = result["roster"] as! [Object]
        check(roster[0]["id"] as? String == owner.id.uuidString, "Actual owner UUID must survive historical owner bucket")
        check(roster[0]["pin"] as? String == pinned.pin, "Salted PIN preserved verbatim")
        check((roster[1]["account"] as! Object)["value"] as? String == owner.id.uuidString, "Shared profile binds actual owner")
        check((roster[1]["settings"] as! Object)["textScale"] as? Int == 1150, "Text scale permille")
        check(result["rosterModifiedSeconds"] as? Double == 1720000000.1234, "Fractional roster clock")
        check(result["settings"] == nil && result["futureDocumentField"] == nil && result["activeProfileId"] == nil, "No full host document in projection")
        let retained = try Data(contentsOf: URL(fileURLWithPath: "app/Tests/Fixtures/legacy-bootstrap-apple.json"))
        check(retained == source, "Pure extractor retains source")
        let addons = (result["addons"] as! [String: Object])[owner.id.uuidString]!
        let descriptor = (addons["items"] as! [Object])[0]
        check((descriptor["manifest"] as! Object)["name"] as? String == "App descriptor", "App descriptor wins")
        check(descriptor["transportUrl"] as? String == "https://example.com/Config%2FAbC/manifest.json", "Configured URL case preserved")
        let rewind = watches(result)[0]
        check(rewind["positionMs"] as? Int == 0 && rewind["lastPlayedAtMs"] as? Double == 1767225600123.75, "Genuine history event clock and zero rewind")
        let overlay = watches(result, profile: child)
        check(overlay.count == 2, "All durable watched entries retained")
        let row = overlay.first { $0["videoId"] as? String == "opaque-episode" }!
        check(row["positionMs"] as? Int == 12345 && row["lastPlayedAtMs"] as? Double == 1767225600123.456, "Original Double precision")
        check(row["markedAtMs"] as? Double == 50.125 && row["resetAtMs"] as? Double == 50.875 && row["watched"] == nil, "Complete rail mark/reset clocks override duplicate durable explicit clocks")
        check(row["name"] as? String == "Fixture Series" && row["poster"] != nil, "Watch context retained")
        check((result["libraries"] as! [String: Object])[child.id.uuidString] == nil, "Overlay cache is not saved membership")
    }
    static func ownAccountSources() throws {
        var own = child; own.usesOwnAccount = true
        let ownURL = "https://own.example.invalid/manifest.json"
        let ownAddon: Object = ["transportUrl": ownURL,
                                "manifest": ["id": "own", "name": "Own", "version": "1.0.0"]]
        let ownMovie: Object = ["_id": "tt-own", "type": "movie", "name": "Own Movie",
                                "poster": "https://own.example.invalid/poster.jpg", "removed": false, "temp": false,
                                "_mtime": "2026-01-01T00:00:00.000Z", "_ctime": "2025-12-31T00:00:00.000Z",
                                "state": ["timeOffset": 3500, "duration": 100000,
                                          "lastWatched": "2026-01-01T00:00:00.123456Z", "video_id": "tt-own",
                                          "timesWatched": 1, "flaggedWatched": 0]]
        let sourceBytes = try ownSourceEnvelope(libraryRows: [ownMovie], addons: [ownAddon])
        let receipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: sourceBytes)
        let root = doc(["library": [movie("tt-root", position: 1)]])

        do { _ = try material(root, roster: [owner, own]); preconditionFailure("own account without source imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("exactly one authenticated"), "Missing own receipt remains closed")
        }
        let result = try material(root, roster: [owner, own], ownAccountSources: [receipt])
        check(result["schemaVersion"] as? Int == 2, "Own-account import upgrades only this material to schema 2")
        let roster = result["roster"] as! [Object]
        let projected = roster.first { $0["id"] as? String == own.id.uuidString }!
        check((projected["account"] as? Object)?["kind"] as? String == "own"
              && (projected["account"] as? Object)?["value"] as? String == "verified-own-uid"
              && projected["addons"] as? String == "own", "Own profile is identity-bound and isolated")
        let sources = result["ownAccountSources"] as! [String: Object]
        let exported = sources[own.id.uuidString]!
        let outputBytes = try JSONSerialization.data(withJSONObject: result)
        check(exported["verifiedStreamingUid"] as? String == "verified-own-uid"
              && exported["sourceDocumentSha256"] as? String == receipt.sourceDocumentSHA256
              && !outputBytes.contains(sourceBytes),
              "Only verified UID and exact source digest leave the caller receipt")
        let addons = (result["addons"] as! [String: Object])[own.id.uuidString]!
        let library = (result["libraries"] as! [String: Object])[own.id.uuidString]!
        check((addons["items"] as! [Object])[0]["transportUrl"] as? String == ownURL
              && (library["items"] as! [Object])[0]["id"] as? String == "tt-own"
              && watches(result, profile: own).first?["metaId"] as? String == "tt-own",
              "Own buckets use only independently fetched account carriers")
        check((result["libraries"] as! [String: Object])[owner.id.uuidString] != nil
              && (result["identityLinks"] as! [String: [[String]]])[own.id.uuidString] == [],
              "Primary bucket is retained and own receipt invents no aliases")

        let nullErrorReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [ownMovie], addons: [ownAddon],
                libraryResponseExtra: ["error": NSNull()], addonsResponseExtra: ["error": NSNull()]))
        _ = try material(root, roster: [owner, own], ownAccountSources: [nullErrorReceipt])
        let unknownResponseReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [ownMovie], addons: [ownAddon],
                libraryResponseExtra: ["lastModified": 1]))
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [unknownResponseReceipt]); preconditionFailure("unknown response metadata imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("exact library and add-on responses"), "Only documented null API error metadata is accepted")
        }

        let retainedBaseline = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let coldResult = try material(root, roster: [owner, own], retainedOwnAccountBaseline: retainedBaseline)
        let coldSources = coldResult["ownAccountSources"] as! [String: Object]
        check(NSDictionary(dictionary: coldSources[own.id.uuidString]!).isEqual(to: sources[own.id.uuidString]!)
              && NSDictionary(dictionary: (coldResult["addons"] as! [String: Object])[own.id.uuidString]!).isEqual(to: addons)
              && NSDictionary(dictionary: (coldResult["libraries"] as! [String: Object])[own.id.uuidString]!).isEqual(to: library)
              && NSArray(array: watches(coldResult, profile: own)).isEqual(to: watches(result, profile: own))
              && (coldResult["identityLinks"] as! [String: [[String]]])[own.id.uuidString] == [],
              "Validated retained baseline copies the exact own tuple without raw source fabrication")
        var malformedBaseline = result
        var malformedSourceRows = malformedBaseline["ownAccountSources"] as! [String: Object]
        malformedSourceRows[own.id.uuidString] = ["verifiedStreamingUid": "other-uid", "sourceDocumentSha256": receipt.sourceDocumentSHA256]
        malformedBaseline["ownAccountSources"] = malformedSourceRows
        do { _ = try material(root, roster: [owner, own], retainedOwnAccountBaseline: JSONSerialization.data(withJSONObject: malformedBaseline)); preconditionFailure("mismatched retained UID imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("complete authenticated profile tuple"), "Retained baseline cannot substitute a mismatched own identity")
        }
        var incompleteBaseline = result
        var incompleteWatches = incompleteBaseline["watches"] as! [String: [Object]]
        incompleteWatches.removeValue(forKey: own.id.uuidString); incompleteBaseline["watches"] = incompleteWatches
        do { _ = try material(root, roster: [owner, own], retainedOwnAccountBaseline: JSONSerialization.data(withJSONObject: incompleteBaseline)); preconditionFailure("partial retained tuple imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("complete authenticated profile tuple"), "Retained baseline requires every own typed bucket")
        }

        let overlay: Object = ["vortx": ["byProfile": [own.id.uuidString: ["watched": [
            "tt-own": ["w": ["overlay-video"]]
        ]]]]]
        let overlayReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [ownMovie], addons: [ownAddon], profileOverlay: overlay))
        let overlayResult = try material(root, roster: [owner, own], ownAccountSources: [overlayReceipt])
        check(watches(overlayResult, profile: own).contains { $0["metaId"] as? String == "tt-own" && $0["videoId"] as? String == "overlay-video" && $0["watched"] as? Bool == true },
              "Authenticated UUID-scoped overlay marks survive alongside the independent source")

        var temporary = ownMovie; temporary["_id"] = "tt-temp"; temporary["temp"] = true
        var temporaryState = temporary["state"] as! Object; temporaryState["video_id"] = "tt-temp"; temporary["state"] = temporaryState
        var removed = ownMovie; removed["_id"] = "tt-removed"; removed["removed"] = true
        var removedState = removed["state"] as! Object; removedState["video_id"] = "tt-removed"; removed["state"] = removedState
        let rawLifecycleReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [temporary, removed], addons: [ownAddon]))
        let rawLifecycleResult = try material(root, roster: [owner, own], ownAccountSources: [rawLifecycleReceipt])
        let rawLibrary = (rawLifecycleResult["libraries"] as! [String: Object])[own.id.uuidString]!
        check((rawLibrary["items"] as! [Object]).isEmpty
              && (rawLibrary["intents"] as! [Object]).contains { $0["key"] as? String == "movie:tt-removed" && ($0["removedAtMs"] as? NSNumber)?.doubleValue == 1 },
              "Temporary rows are watch-only and initial removed rows use the explicit weak tombstone")
        check(Set(watches(rawLifecycleResult, profile: own).compactMap { $0["metaId"] as? String }) == ["tt-temp", "tt-removed"],
              "Temporary and removed rows retain independently authenticated watch context")

        let highMilliseconds: Int64 = 9_007_199_254_740_989
        var highState = ownMovie["state"] as! Object
        highState["timeOffset"] = NSNumber(value: highMilliseconds)
        highState["duration"] = NSNumber(value: highMilliseconds)
        var highMovie = ownMovie; highMovie["state"] = highState
        let highReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [highMovie], addons: [ownAddon]))
        let highResult = try material(root, roster: [owner, own], ownAccountSources: [highReceipt])
        let highWatch = watches(highResult, profile: own).first!
        check((highWatch["positionMs"] as? NSNumber)?.int64Value == highMilliseconds
              && (highWatch["durationMs"] as? NSNumber)?.int64Value == highMilliseconds,
              "Own raw millisecond state round-trips exactly at the safe upper bound")

        var sameUID = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "Second", avatar: "S")
        sameUID.usesOwnAccount = true
        let second = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: sameUID.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [], addons: []))
        let sameUIDResult = try material(root, roster: [owner, own, sameUID], ownAccountSources: [receipt, second])
        check((sameUIDResult["ownAccountSources"] as! [String: Object]).count == 2,
              "Distinct profiles may independently prove the same streaming UID")

        do { _ = try material(root, roster: [owner, own], ownAccountSources: [receipt, receipt]); preconditionFailure("duplicate receipt imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("Duplicate own-account"), "Duplicate profile receipt remains ambiguous")
        }
        let invalidUID = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "uid\n", sourceDocument: sourceBytes)
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [invalidUID]); preconditionFailure("control UID imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("verified streaming identity"), "Control-character UID is not an account proof")
        }
        let bytesBefore = Data("[]".utf8)
        let malformed = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: bytesBefore)
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [malformed]); preconditionFailure("array source imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("source envelope"), "Malformed own source is refused")
        }
        check(malformed.sourceDocument == bytesBefore, "Failed own source import preserves caller bytes")
        var credentialRow = ownMovie; credentialRow["authKey"] = "must-reject"
        let credentialReceipt = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [credentialRow], addons: [ownAddon]))
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [credentialReceipt]); preconditionFailure("credential source imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("Credential-bearing"), "Credential-bearing own source cannot be reduced into a proof")
        }
        let overlaySource = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try ownSourceEnvelope(libraryRows: [], addons: [], profileOverlay: ["vortx": ["byProfile": [owner.id.uuidString: Object()]]]))
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [overlaySource]); preconditionFailure("overlay source imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("scoped to its authenticated profile"), "Foreign profile overlay cannot masquerade as an independent source")
        }
        let incompleteEnvelope = VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: own.id,
            verifiedStreamingUID: "verified-own-uid", sourceDocument: try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                                                                                                        "libraryResponseBase64": "e30=", "addonsResponseBase64": "e30=", "profileOverlayBase64": "e30="]))
        do { _ = try material(root, roster: [owner, own], ownAccountSources: [incompleteEnvelope]); preconditionFailure("incomplete source imported") }
        catch let error as VortxLegacyBootstrapMaterial.ReconciliationRequired {
            check(error.reason.contains("exact library and add-on responses"), "Missing authenticated response cannot become an empty account")
        }
    }
    static func savedVersusPlayed() throws {
        let saved = try material(doc(["library": [movie()]]))
        check(watches(saved).isEmpty, "Synthetic saved timestamp must not become viewing")
        for seconds in [2.001, 12.345, 100.0] {
            let result = try material(doc(["library": [movie(position: seconds)]]))
            check(watches(result)[0]["positionMs"] as? Int == Int((seconds * 1000).rounded()), "Exact decimal milliseconds")
        }
        var marked = movie(); marked["currentVideoWatched"] = true
        let markedRows = watches(try material(doc(["library": [marked]])))
        check(markedRows[0]["watched"] as? Bool == true && markedRows[0]["lastPlayedAtMs"] == nil, "Mark does not manufacture viewing history")
    }
    static func durableHistoryAndClockPolicies() throws {
        var durable: Object = [:]
        for index in 0..<125 { durable["title-\(index)"] = ["w": ["opaque-\(index)"]] }
        durable["clocked"] = ["w": ["opaque"], "ma": ["opaque": 50.25], "ua": ["opaque": 50.25]]
        durable["zero"] = ["w": ["zero-episode"], "ma": ["zero-episode": 0], "ua": ["zero-episode": 0]]
        durable["null"] = ["w": ["null-episode"], "ma": ["null-episode": NSNull()]]
        let result = try material(doc(["byProfile": [child.id.uuidString: ["watched": durable]]]))
        let rows = watches(result, profile: child)
        check(rows.count == 128, "No 120-row trimming")
        let tie = rows.first { $0["metaId"] as? String == "clocked" }!
        check(tie["markedAtMs"] as? Double == 50.25 && tie["resetAtMs"] as? Double == 50.25 && tie["watched"] == nil, "Overlay strict mark > reset sent to native")
        let zero = rows.first { $0["metaId"] as? String == "zero" }!
        check(zero["watched"] as? Bool == true && zero["markedAtMs"] == nil, "Doc ingress filters zero sentinel clocks before bare watched membership")
        check(rows.first { $0["metaId"] as? String == "null" }?["watched"] as? Bool == true, "Null operation is absent at doc ingress")
        var current = movie(position: 1); current["w"] = [String]()
        let stale = try material(doc(["byProfile": [child.id.uuidString: ["library": [current], "watched": ["tt123": ["w": ["stale-episode"]]]]]]))
        check(watches(stale, profile: child).count == 1, "Durable unclocked set cannot resurrect omitted rail marker")
    }
    static func ownerActorTies() throws {
        func intent(_ watched: Bool, _ actor: String, _ time: Double = 100.25) -> Object {
            ["t": "tt123", "v": "tt123", "w": watched, "u": time, "a": actor]
        }
        for pair in [[intent(true, "a"), intent(false, "z")], [intent(false, "a"), intent(true, "z")]] {
            let result = try material(doc(["library": [movie()], "ownerWatched": ["a": pair[0], "b": pair[1]]]))
            let row = watches(result)[0]
            let expected = pair[1]["w"] as! Bool ? "markedAtMs" : "resetAtMs"
            check(row[expected] as? Double == 100.25 && row.count >= 3, "Actor order controls owner watched ties")
        }
        try fail(doc(["library": [movie()], "ownerWatched": ["a": intent(true, "a"), "b": intent(false, "a")]]), "Conflicting owner")
    }
    static func descriptorAndRemovalPolicies() throws {
        let url = "https://example.com/Config/manifest.json"
        let addon: Object = ["transportUrl": url, "manifest": ["id": "fixture", "name": "Fixture", "version": "1.0.0"]]
        for (added, removed) in [(1000.75, 1000.5), (1000.25, 1000.75), (1000.5, 1000.5)] {
            let result = try material(doc(["addons": [addon], "deletedAddonsTs": [url.lowercased(): ["addedAt": added, "removedAt": removed]],
                                           "library": [movie()], "deletedLibraryTs": ["tt123": ["addedAt": added, "removedAt": removed]]]))
            let bucket = (result["addons"] as! [String: Object])[owner.id.uuidString]!
            let intent = (bucket["intents"] as! [Object])[0]
            check(intent["transportUrl"] as? String == url && intent["addedAtMs"] as? Double == added && intent["removedAtMs"] as? Double == removed, "Membership clock order unchanged")
            let library = (result["libraries"] as! [String: Object])[owner.id.uuidString]!
            check((library["intents"] as! [Object])[0]["key"] as? String == "movie:tt123", "Typed library key")
        }
        let removed: Object = ["keys": ["movie\u{1f}imdb:tt123"], "removedAt": 1767225700000.75]
        let result = try material(doc(["byProfile": [child.id.uuidString: ["library": [movie(position: 1)], "removed": [removed]]]]))
        check(watches(result, profile: child)[0]["removedAtMs"] as? Double == 1767225700000.75, "Exact matching title removal")
        check((result["identityLinks"] as! [String: [[String]]])[child.id.uuidString]!.isEmpty, "No invented alias links")
        var other = addon; other["transportUrl"] = url.lowercased()
        try fail(doc(["addons": [addon, other], "deletedAddons": [url.lowercased()]]), "Ambiguous legacy add-on")
    }
    static func watchConsolidation() throws {
        var old = movie(position: 12); old["v"] = "tt123"; old["eventEpochMs"] = 1000.125
        var newer = movie(position: 0); newer["v"] = "tt123"; newer["eventEpochMs"] = 1000.875; newer.removeValue(forKey: "d")
        func output(_ rows: [Object]) throws -> Object {
            try material(doc(["byProfile": [UserProfile.ownerID.uuidString: ["ownerHistory": rows]]]))
        }
        let forward = try output([old, newer]), reverse = try output([newer, old])
        let a = watches(forward)[0], b = watches(reverse)[0]
        check(a["positionMs"] as? Int == 0 && a["durationMs"] as? Int == 100000, "Newer zero rewind preserves omitted duration")
        check(NSDictionary(dictionary: a).isEqual(to: b), "Fragment order independence")
        newer["eventEpochMs"] = 1000.125
        try fail(doc(["byProfile": [UserProfile.ownerID.uuidString: ["ownerHistory": [old, newer]]]]), "Equal viewing clocks")
    }
    static func rejectedEvidence() throws {
        var bits = movie(position: 1); bits["watched"] = "opaque-bitfield"
        try fail(doc(["library": [bits]]), "bitfield")
        try fail(doc(["byProfile": [child.id.uuidString: ["library": [movie()]]]]), "Saved-only overlay")
        try fail(doc(["addons": [["transportUrl": "https://example.com/manifest.json"]]]), "manifest reconciliation")
        try fail(doc(["library": [movie(position: 1.00001)]]), "Sub-millisecond")
        try fail(doc(["deletedLibrary": ["tt999"]]), "title-type reconciliation")
        try fail(doc(["library": "not-an-array"]), "Malformed array")
        try fail(doc(["byProfile": ["unknown": ["watched": Object()]]]), "unknown profile")
        try fail(doc(["deletedProfiles": [owner.id.uuidString.lowercased()]]), "Owner profile")
        try fail(doc(), "Duplicate", roster: [owner, child, child])
        try fail(doc(), "Invalid clock", modified: .infinity)
        var own = child; own.usesOwnAccount = true
        try fail(doc(), "authenticated streaming-account", roster: [owner, own])
        var ownerOwn = owner; ownerOwn.usesOwnAccount = true
        try fail(doc(), "Owner profile cannot use", roster: [ownerOwn, child])
        for pin in ["1234", "sha256:bad"] { var bad = child; bad.pin = pin; try fail(doc(), "malformed PIN", roster: [owner, bad]) }
        var boolProgress = movie(); boolProgress["t"] = true
        try fail(doc(["library": [boolProgress]]), "Malformed clock")
        var numericBool = movie(); numericBool["currentVideoWatched"] = 1
        try fail(doc(["library": [numericBool]]), "Malformed boolean")
        var ambiguousSeries = movie(); ambiguousSeries["type"] = "series"; ambiguousSeries["currentVideoWatched"] = true
        try fail(doc(["library": [ambiguousSeries]]), "exact video identity")
        ambiguousSeries["v"] = "tt123"
        try fail(doc(["library": [ambiguousSeries]]), "Whole-series completion")
        let secret: Object = ["transportUrl": "https://example.com/manifest.json", "manifest": ["id": "fixture", "name": "Fixture", "version": "1.0.0", "accessToken": "sanitized-placeholder"]]
        try fail(doc(["addons": [secret]]), "Credential-bearing")
        try fail(doc(["byProfile": [child.id.uuidString: ["watched": ["untyped-title": ["w": ["untyped-title"]]]]]]), "Whole-title")
        let deletedID = "30000000-0000-0000-0000-000000000001"
        let result = try material(doc(["deletedProfiles": [deletedID], "byProfile": [deletedID: ["future": "retained in original"]]]))
        check(result["deletedProfileIds"] as? [String] == [deletedID], "Missing deleted rows remain tombstones")
    }

    static func profilePreferencesAndIdentity() throws {
        var main = owner
        main.addonPreferences = ProfileAddonPreferences(disabledAddonURLsOverride: ["HTTPS://Example.COM/OwnerCase/manifest.json"])
        var kid = child
        kid.playback = UserProfile.PlaybackPrefs(audioLang: "en, JA, en", subtitleLang: "hi", forcedPolicy: "auto", subFont: "system", subSize: "normal", subColor: "white", subBackground: "none")
        kid.playback?.maxResolution = 4000
        kid.playback?.maxFileSizeGB = 12.5
        kid.playback?.sourceTypeOrder = ["debrid", "torrent"]
        kid.playback?.includeKeywords = " Atmos, HDR "
        kid.playback?.excludeKeywords = "Cam"
        let result = try material(doc(), roster: [main, kid])
        let profiles = result["roster"] as! [Object]
        let settings = profiles[1]["settings"] as! Object
        check(settings["disabledAddons"] as? [String] == ["https://example.com/OwnerCase/manifest.json"], "Live owner visibility inheritance")
        let ranking = settings["ranking"] as! Object
        check(ranking["max_resolution"] as? String == "2160p" && ranking["max_filesize_gb"] as? Double == 12.5, "Supported ranking fields")
        check(ranking["source_type_order"] == nil && ranking["keyword_include"] as? [String] == ["atmos", "hdr"], "Transport source classes never cast to native quality classes")
        check(ranking["preferred_languages"] as? [String] == ["en", "ja"], "Canonical audio languages only; subtitle preference must not rank audio streams")
        kid.addonPreferences = ProfileAddonPreferences(disabledAddonURLsOverride: [])
        let empty = try material(doc(), roster: [main, kid])["roster"] as! [Object]
        check((empty[1]["settings"] as! Object)["disabledAddons"] as? [String] == [], "Explicit empty visibility override survives")
        let fixedChild = UserProfile(id: UserProfile.ownerID, name: "Historical collision", avatar: "C", pin: UserProfile.pinHash("5678", profileID: UserProfile.ownerID))
        var history = movie(position: 1); history["v"] = "tt123"; history["eventEpochMs"] = 1000.25
        let collision = try material(doc(["byProfile": [UserProfile.ownerID.uuidString: ["ownerHistory": [history]]]]), roster: [owner, fixedChild])
        check(watches(collision).count == 1 && watches(collision, profile: fixedChild).isEmpty, "Historical history bucket does not rekey or overwrite colliding profile")
        var first = movie(position: 1); first["v"] = "same-unit"; first["eventEpochMs"] = 1000.25
        var second = movie("tt999", position: 1); second["v"] = "same-unit"; second["eventEpochMs"] = 1000.75
        try fail(doc(["byProfile": [UserProfile.ownerID.uuidString: ["ownerHistory": [first, second]]]]), "conflicting title")
        let typed = try material(doc(["deletedLibraryTs": ["series:removed-id": ["removedAt": 1000.125]]]))
        let library = (typed["libraries"] as! [String: Object])[owner.id.uuidString]!
        check((library["intents"] as! [Object])[0]["key"] as? String == "series:removed-id", "Already typed tombstone retained without guessing")
    }

    static func completenessAndClockEvidence() throws {
        var removed = movie(position: 1); removed["removed"] = true; removed["eventEpochMs"] = 1000.25
        try fail(doc(["library": [removed]]), "proven membership tombstone")
        let proven = try material(doc(["library": [removed], "deletedLibraryTs": ["tt123": ["removedAt": 2000.75]]]))
        let library = (proven["libraries"] as! [String: Object])[owner.id.uuidString]!
        check((library["intents"] as! [Object])[0]["removedAtMs"] as? Double == 2000.75, "Removal uses membership clock only")
        var count = movie(); count["timesWatched"] = 2
        let row = watches(try material(doc(["library": [count]])))[0]
        check(row["timesWatched"] as? Int == 2 && row["positionMs"] == nil && row["lastPlayedAtMs"] == nil && row["watched"] == nil, "Count-only metadata remains without fabricated playback")
        let url = "https://example.com/manifest.json"
        var web = doc(["deletedAddonsTs": [url: Object()]])
        web["webAddonRemovals"] = [url]
        try fail(web, "Unclocked web add-on")
        try fail(doc(["deletedAddons": [url], "deletedAddonsTs": [url: ["removedAt": 0]]]), "zero-stamp add-on")
        try fail(doc(["library": [movie()], "deletedLibrary": ["tt123"], "deletedLibraryTs": ["tt123": ["removedAt": 0]]]), "zero-stamp library")
        var old = movie(position: 1); old["w"] = ["stale-episode"]
        var newer = movie(position: 2); newer["w"] = [String](); newer["lastWatched"] = "2026-01-02T00:00:00Z"
        try fail(doc(["byProfile": [child.id.uuidString: ["library": [old, newer]]]]), "Duplicate overlay")
        var edits = doc(["library": [movie()]])
        edits["profileEdits"] = ["editedAt": 1720000000000.0, "roster": [["id": child.id.uuidString]], "libraryAdds": [owner.id.uuidString: [["id": "tt123", "type": "movie"]]]]
        _ = try material(edits)
        try fail(edits, "Pending profile roster", modified: 1710000000)
        edits["profileEdits"] = ["editedAt": 1720000000000.0, "libraryAdds": [owner.id.uuidString: [["id": "tt999", "type": "movie"]]]]
        try fail(edits, "absent from resolved saved")
        let deferred = try material(edits, deferProfileEdits: true)
        check(deferred["profileEdits"] == nil && deferred["libraries"] != nil,
              "Explicit deferred website channel is not acknowledged or copied into native material")
        edits["profileEdits"] = ["editedAt": 1720000000000.0, "libraryAdds": [child.id.uuidString: [["id": "tt123", "type": "movie"]]]]
        try fail(edits, "explicit applied receipt")
        edits["profileEdits"] = ["editedAt": 1000, "roster": [["id": "30000000-0000-0000-0000-000000000001"]]]
        try fail(edits, "absent from resolved roster")
        edits["profileEdits"] = ["editedAt": 1000, "roster": [["id": child.id.uuidString, "deleted": true]]]
        try fail(edits, "permanent tombstone")
    }
}
