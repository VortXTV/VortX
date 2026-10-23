import Foundation
import CryptoKit

private final class OwnerPreparationAuthority: VortxMutationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func revoke() { lock.withLock { active = false } }
    func withActive(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw VortxNativeError.superseded }
            try operation()
        }
    }
}

/// Synthetic responses enter the actual metadata decoder and pure converter.
/// No network, checkpoint, playback mutation or wall-clock fixture is necessary.
@main enum VortxNativeOwnerHistoryPreparationTests {
    typealias Preparation = VortxNativeOwnerHistoryPreparation
    static let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let child = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let scope = "synthetic.owner-preparation"
    static let uid = "synthetic-owner"
    static let raw = Data(#"{"result":[{"_id":"ttMovie","type":"movie","name":"Movie","future":{"original":1e3},"state":{"timeOffset":1234,"duration":9000,"lastWatched":"2024-01-01T00:00:00.000Z","timesWatched":2,"flaggedWatched":1}},{"_id":"ttRemoved","type":"movie","removed":true,"state":{"timeOffset":800,"lastWatched":"2023-01-01T00:00:00.000Z"}},{"_id":"ttTemporary","type":"movie","temp":true,"state":{"timeOffset":900,"lastWatched":"2023-01-02T00:00:00.000Z"}},{"_id":"tt2934286","type":"series","state":{"watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}}],"futureTop":{"unknown":"preserve"}}"#.utf8)
    static let addons = Data(#"{"result":{"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":{"id":"catalog","name":"Original catalog","version":"1.0.0","resources":["meta"],"types":["series"]}}]},"futureAddon":17}"#.utf8)
    static let metadata = Data(#"{"meta":{"id":"tt2934286","type":"series","videos":[{"id":"tt2934286:1:5","season":1,"episode":5,"released":"2005-01-05T00:00:00Z"},{"id":"tt2934286:1:1","season":1,"episode":1,"released":"2005-01-01T00:00:00Z"},{"id":"tt2934286:1:2","season":1,"episode":2,"released":"2005-01-02T00:00:00Z"},{"id":"tt2934286:1:3","season":1,"episode":3,"released":"2005-01-03T00:00:00Z"},{"id":"tt2934286:1:4","season":1,"episode":4,"released":"2005-01-04T00:00:00Z"}],"futureMetadata":{"original":1e2}}}"#.utf8)
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "owner preparation fixture line \(line)") }
    static func object(_ bytes: Data) throws -> [String: Any] { try VortxProfileOverlayWitness.decodeObject(json: bytes) }
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func frame(profile: UUID = owner, library: Data = raw, registry: Data = addons) throws -> Preparation.Frame {
        try Preparation.decodeFrame(encode([
            "schemaVersion": 1, "kind": "vortx.owner-history.source/1", "scope": scope,
            "ownerProfileId": owner.uuidString, "profileId": profile.uuidString, "verifiedStreamingUid": uid,
            "libraryResponseBase64": library.base64EncodedString(), "addonsResponseBase64": registry.base64EncodedString()
        ]), scope: scope, ownerProfileID: owner, profileID: profile, verifiedUID: uid)
    }
    /// Raw unknown numbers are evidence, not legacy binary64 projection values.
    /// Keep the production converter and every original source byte; do not edit the real-ABI
    /// fixture to make its wide-number provenance disappear.
    static func rawNumericProjectionTests() async throws {
        let base = Data(#"{"result":[{"_id":"numeric-source","type":"movie","name":"Numeric","state":{"timeOffset":1234,"duration":9000,"lastWatched":"2024-01-01T00:00:00.000Z","flaggedWatched":0}}]}"#.utf8)
        let original = Data(#"{"result":[{"_id":"numeric-source","type":"movie","name":"Numeric","future":{"original":1e3,"negativeZero":-0.0,"wide":9007199254740993},"state":{"timeOffset":1234,"duration":9000,"lastWatched":"2024-01-01T00:00:00.000Z","flaggedWatched":0,"futureState":[-0.0,9007199254740993,1e3]}}],"futureTop":{"wide":9007199254740993}}"#.utf8)
        let registry = Data(#"{"result":{"addons":[]}}"#.utf8)
        let authority = OwnerPreparationAuthority()
        func prepared(_ bytes: Data) async throws -> Preparation.Prepared {
            let input = try frame(library: bytes, registry: registry)
            guard case .prepared(let value) = try await Preparation.prepare(frame: input, authority: authority,
                fetchMetadata: { _ in fatalError("movie projection must not fetch metadata") })
            else { fatalError("safe unknown numeric source became pending") }
            return value
        }
        let expected = try await prepared(base)
        let actual = try await prepared(original)
        let expectedEvidence = try object(expected.evidence), actualEvidence = try object(actual.evidence)
        for key in ["library", "watches", "identityLinks"] {
            check((try encode(["value": actualEvidence[key]!])) == (try encode(["value": expectedEvidence[key]!])))
        }
        check(actual.frame.sourceDocument != expected.frame.sourceDocument)
        let originalFrame = try object(actual.frame.sourceDocument)
        check(Data(base64Encoded: originalFrame["libraryResponseBase64"] as! String) == original)
        let reopened = try Preparation.replay(archive: actual.archive, scope: scope, ownerProfileID: owner,
            profileID: owner, verifiedUID: uid, authority: authority)
        check(reopened.archive == actual.archive && reopened.frame.sourceDocument == actual.frame.sourceDocument)
        check(reopened.evidence == actual.evidence)
        // The binary64 guard STILL applies to fields the existing typed converter consumes.
        let invalidOwned = Data(#"{"result":[{"_id":"bad","type":"movie","state":{"timeOffset":9007199254740993}}]}"#.utf8)
        var rejectedOwned = false
        do { _ = try await prepared(invalidOwned) } catch { rejectedOwned = true }
        check(rejectedOwned)
        // Projection is not a privacy or duplicate-key sanitization escape hatch.
        for hostile in [
            #"{"result":[{"_id":"bad","type":"movie","future":{"authKey":"synthetic-private"}}]}"#,
            #"{"result":[{"_id":"bad","type":"movie","future":{"duplicate":1,"duplicate":2}}]}"#
        ] {
            var rejected = false
            do { _ = try frame(library: Data(hostile.utf8), registry: registry) } catch { rejected = true }
            check(rejected)
        }
        let scopeBinding = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: scope,
            profileID: owner, verifiedStreamingUID: uid, ownerProfileID: owner)
        let excessive = Data(("{\"result\":[],\"future\":[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]}").utf8)
        for hostile in [
            Data(#"{"result":[],"future":{"\u00e9":1,"e\u0301":2}}"#.utf8),
            excessive
        ] {
            let envelope = try encode([
                "schemaVersion": 1, "kind": "vortx.owner-history.source/1", "scope": scope,
                "ownerProfileId": owner.uuidString, "profileId": owner.uuidString,
                "verifiedStreamingUid": uid, "libraryResponseBase64": hostile.base64EncodedString(),
                "addonsResponseBase64": registry.base64EncodedString()
            ])
            var rejected = false
            do { _ = try LegacyWatchedBitfieldMigrationEvidence.ownerHistoryLibraryProjection(
                scope: scopeBinding, source: envelope) } catch { rejected = true }
            check(rejected)
        }
    }

    static func main() async throws {
        try await rawNumericProjectionTests()
        let captured = try frame()
        let authority = OwnerPreparationAuthority()
        let outcome = try await Preparation.prepare(frame: captured, authority: authority, fetchMetadata: { request in
            check(request.scope.profileID == owner && request.scope.ownerProfileID == owner)
            check(request.scope.verifiedStreamingUID == uid && request.addon.transportURL == "https://catalog.example/manifest.json")
            return .init(request: request, raw: metadata)
        })
        guard case .prepared(let first) = outcome else { fatalError("complete original metadata remained pending") }
        let evidence = try object(first.evidence)
        check(Set(evidence.keys) == ["schemaVersion", "scope", "ownerProfileId", "profileId", "verifiedStreamingUid",
                                    "sourceDocumentSha256", "sourceArchiveSha256", "library", "watches", "identityLinks"])
        check(evidence["profileId"] as? String == owner.uuidString)
        let library = evidence["library"] as! [String: Any]
        let items = library["items"] as! [[String: Any]]
        check(Set(items.compactMap { $0["id"] as? String }) == ["ttMovie", "tt2934286"])
        check((library["intents"] as! [Any]).isEmpty) // No invented remove or weak membership epoch.
        let watches = evidence["watches"] as! [[String: Any]]
        let movie = watches.first { $0["metaId"] as? String == "ttMovie" }!
        check((movie["positionMs"] as? NSNumber)?.int64Value == 1234)
        check((movie["lastPlayedAtMs"] as? NSNumber)?.int64Value == 1_704_067_200_000)
        check((movie["durationMs"] as? NSNumber)?.int64Value == 9000 && movie["watched"] as? Bool == true)
        check(watches.contains { $0["metaId"] as? String == "ttRemoved" })
        check(watches.contains { $0["metaId"] as? String == "ttTemporary" })
        let episodes = watches.filter { $0["metaId"] as? String == "tt2934286" }
        check(Set(episodes.compactMap { $0["videoId"] as? String }) == Set((1...5).map { "tt2934286:1:\($0)" }))
        check(episodes.allSatisfy { $0["watched"] as? Bool == true && $0["lastPlayedAtMs"] == nil && $0["markedAtMs"] == nil })
        let reopened = try Preparation.replay(archive: first.archive, scope: scope, ownerProfileID: owner,
            profileID: owner, verifiedUID: uid, authority: authority)
        check(reopened.archive == first.archive && reopened.evidence == first.evidence)
        let sourceFrame = try object(reopened.frame.sourceDocument)
        check(Data(base64Encoded: sourceFrame["libraryResponseBase64"] as! String) == raw)
        check(Data(base64Encoded: sourceFrame["addonsResponseBase64"] as! String) == addons)
        let archive = try object(first.archive)
        let metadataRecords = archive["metadataEvidenceBase64"] as! [String]
        check(metadataRecords.count == 1)
        let receipt = try object(Data(base64Encoded: metadataRecords[0])!)
        check(Data(base64Encoded: receipt["metadataResponseBase64"] as! String) == metadata)
        check((receipt["row"] as? [String: Any])?["kind"] as? String == "owner_account_library")
        do {
            _ = try Preparation.replay(archive: first.archive, scope: scope, ownerProfileID: owner,
                profileID: child, verifiedUID: uid, authority: authority)
            fatalError("owner archive silently retargeted")
        } catch {}
        var missing = archive; missing["metadataEvidenceBase64"] = []
        do {
            _ = try Preparation.replay(archive: encode(missing), scope: scope, ownerProfileID: owner,
                profileID: owner, verifiedUID: uid, authority: authority)
            fatalError("missing exact metadata admitted")
        } catch {}
        var duplicate = archive; duplicate["metadataEvidenceBase64"] = metadataRecords + metadataRecords
        do {
            _ = try Preparation.replay(archive: encode(duplicate), scope: scope, ownerProfileID: owner,
                profileID: owner, verifiedUID: uid, authority: authority)
            fatalError("duplicated metadata admitted")
        } catch {}
        let noRegistry = try frame(registry: Data(#"{"result":{"addons":[]}}"#.utf8))
        let pending = try await Preparation.prepare(frame: noRegistry, authority: authority, fetchMetadata: { _ in
            fatalError("current registry used in place of original source registry")
        })
        guard case .pending(let unresolved) = pending else { fatalError("opaque bitmap acknowledged without metadata") }
        check(unresolved.unresolvedMetadataCount == 1 && unresolved.heldProjectionCount > 0)
        check(unresolved.frame.sourceDocument == noRegistry.sourceDocument)
        let invalidRegistry = try frame(registry: Data(#"{"result":{"addons":[{"transportUrl":"https://catalog.example/manifest.json"}]}}"#.utf8))
        let invalidRegistryOutcome = try await Preparation.prepare(frame: invalidRegistry, authority: authority,
            fetchMetadata: { _ in fatalError("invalid original descriptor authorized metadata") })
        guard case .pending(let invalidRegistryPending) = invalidRegistryOutcome
        else { fatalError("invalid original descriptor acknowledged opaque bitmap") }
        check(invalidRegistryPending.unresolvedMetadataCount == 1 && invalidRegistryPending.heldProjectionCount > 0)
        check(invalidRegistryPending.frame.sourceDocument == invalidRegistry.sourceDocument)
        let stillPending = try await Preparation.resumePending(archive: invalidRegistryPending.archiveCandidate,
            scope: scope, ownerProfileID: owner, profileID: owner, verifiedUID: uid, authority: authority,
            fetchMetadata: { _ in fatalError("retry replaced invalid original descriptor") })
        guard case .pending(let retriedRegistry) = stillPending
        else { fatalError("invalid original descriptor retry acknowledged opaque bitmap") }
        check(retriedRegistry.unresolvedMetadataCount == 1 && retriedRegistry.heldProjectionCount > 0)
        check(retriedRegistry.archiveCandidate == invalidRegistryPending.archiveCandidate)
        check(retriedRegistry.frame.sourceDocument == invalidRegistry.sourceDocument)
        let pendingArchive = try object(unresolved.archiveCandidate)
        check(Data(base64Encoded: pendingArchive["sourceDocumentBase64"] as! String) == noRegistry.sourceDocument)
        do {
            _ = try Preparation.replay(archive: unresolved.archiveCandidate, scope: scope, ownerProfileID: owner,
                profileID: owner, verifiedUID: uid, authority: authority)
            fatalError("pending journal mistaken for complete source archive")
        } catch {}
        let transient = try await Preparation.prepare(frame: captured, authority: authority, fetchMetadata: { _ in
            throw Preparation.Failure.incomplete
        })
        guard case .pending(let retry) = transient else { fatalError("failed metadata request acknowledged") }
        let resumed = try await Preparation.resumePending(archive: retry.archiveCandidate, scope: scope,
            ownerProfileID: owner, profileID: owner, verifiedUID: uid, authority: authority, fetchMetadata: { request in
                check(request.addon.transportURL == "https://catalog.example/manifest.json")
                return .init(request: request, raw: metadata)
            })
        guard case .prepared(let afterRetry) = resumed else { fatalError("original pending source failed to resume") }
        check(afterRetry.frame.sourceDocument == captured.sourceDocument && afterRetry.archive == first.archive)
        check(afterRetry.evidence == first.evidence)
        let shared = try frame(profile: child)
        let sharedOutcome = try await Preparation.prepare(frame: shared, authority: authority, fetchMetadata: { request in
            check(request.scope.profileID == child && request.scope.ownerProfileID == owner)
            return .init(request: request, raw: metadata)
        })
        guard case .prepared(let sharedPrepared) = sharedOutcome else { fatalError("shared initiating profile rejected") }
        check(try object(sharedPrepared.evidence)["profileId"] as? String == child.uuidString)
        let revoked = OwnerPreparationAuthority()
        do {
            _ = try await Preparation.prepare(frame: captured, authority: revoked, fetchMetadata: { request in
                revoked.revoke(); return .init(request: request, raw: metadata)
            })
            fatalError("revoked metadata lease returned ready/pending outcome")
        } catch {}
        let malformed = try frame(library: Data(#"{"result":[{"_id":"ttBad","type":"series","state":{"timeOffset":5000,"lastWatched":"2024-01-01T00:00:00.000Z"}}]}"#.utf8))
        guard case .pending(let held) = try await Preparation.prepare(frame: malformed, authority: authority, fetchMetadata: { _ in fatalError("unexpected metadata") })
        else { fatalError("series progress without video identity acknowledged") }
        check(held.heldProjectionCount > 0 && held.unresolvedMetadataCount == 0)
        for invalid in [
            #"{"result":[{"_id":"bad","type":"series","state":{"watched":17}}]}"#,
            #"{"result":[{"_id":"bad","type":"series","state":17}]}"#,
            #"{"result":[{"_id":"bad","type":"movie","state":{"watched":"unresolvable"}}]}"#
        ] {
            let rawInvalid = Data(invalid.utf8)
            let invalidFrame = try frame(library: rawInvalid)
            guard case .pending(let rowPending) = try await Preparation.prepare(frame: invalidFrame, authority: authority,
                fetchMetadata: { _ in fatalError("malformed row reached metadata network") })
            else { fatalError("malformed row was acknowledged") }
            check(rowPending.heldProjectionCount > 0 && rowPending.frame.sourceDocument == invalidFrame.sourceDocument)
        }
        var twoRows = try object(raw)
        var rows = twoRows["result"] as! [[String: Any]]
        rows.append(["_id": "ttOther", "type": "series", "state": ["watched": "ttOther:1:1:1:unavailable"]])
        twoRows["result"] = rows
        let partialFrame = try frame(library: encode(twoRows))
        let partial = try await Preparation.prepare(frame: partialFrame, authority: authority, fetchMetadata: { request in
            if request.metaID == "tt2934286" { return .init(request: request, raw: metadata) }
            throw Preparation.Failure.incomplete
        })
        guard case .pending(let partialPending) = partial else { fatalError("partial metadata unexpectedly complete") }
        let partialArchive = try object(partialPending.archiveCandidate)
        let acceptedRecords = partialArchive["metadataEvidenceBase64"] as! [String]
        check(acceptedRecords.count == 1)
        var poisoned = try object(Data(base64Encoded: acceptedRecords[0])!)
        var poisonedBody = try object(metadata); poisonedBody["authKey"] = "synthetic-metadata-secret"
        let poisonedBytes = try encode(poisonedBody)
        poisoned["metadataResponseBase64"] = poisonedBytes.base64EncodedString()
        poisoned["metadataResponseSha256"] = SHA256.hash(data: poisonedBytes).map { String(format: "%02x", $0) }.joined()
        do {
            _ = try await Preparation.prepare(frame: partialFrame, authority: authority, archivedMetadata: [encode(poisoned)],
                fetchMetadata: { _ in fatalError("uninspected retained metadata reached retry") })
            fatalError("credential-bearing retained metadata entered a pending archive")
        } catch {}
        print("Owner-specific pure conversion/exact original metadata/offline replay tests passed; no durable ACK claimed")
    }
}
