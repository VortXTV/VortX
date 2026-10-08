import Foundation
import CryptoKit

@main
enum VortxLegacyWatchedMigrationTests {
    typealias Object = [String: Any]

    // Deliberately differs from UserProfile.ownerID. Migration authority must come from the
    // authenticated roster, not from the historical fixed owner UUID.
    private static let ownerID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
    private static let sharedID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let ownID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private static let bitmap = "tt2934286:1:5:5:eJyTZwAAAEAAIA=="
    private static let catalogURL = "https://catalog.example/manifest.json"
    private static let alternateURL = "https://catalog-two.example/manifest.json"

    private static var manifest: Object {
        ["id": "catalog", "name": "Original catalog", "version": "1.0.0",
         "resources": ["meta"], "types": ["series"]]
    }
    private static var alternateManifest: Object {
        ["id": "catalog-two", "name": "Original second catalog", "version": "1.0.0",
         "resources": ["meta"], "types": ["series"]]
    }

    static func main() async throws {
        try await capturesAndMergesFreshOwnerEvidence()
        try await rejectsCancellationAfterFetchReturnsSuccess()
        try await enforcesSourceRowIndexArchiveBoundary()
        try await coldArchiveReplayIsBoundAndNetworkFree()
        try await historicalOwnerHistoryMapsToResolvedOwner()
        try await rejectsChangedOriginalAddon()
        try await unresolvedInventoriesStayPendingAndStrict()
        try await retriesHistoricalPendingWithoutReplacingSource()
        try await retriesOwnPendingWithCapturedIdentityOnly()
        try await failedPendingRetriesPreserveExactSidecars()
        try await ownAccountEnvelopeAndOverlayAreExactForBothSchemas()
        try await originalManifestNumberLexemesSurviveCapture()
        try await metadataTransportUsesOnlyBoundedOriginalEndpoint()
        print("Apple legacy watched migration: scoped capture, clock precedence, cold replay, provenance rejection, pending reconciliation, and own-account envelopes passed")
    }

    private static func capturesAndMergesFreshOwnerEvidence() async throws {
        let document = try ownerDocument()
        let calls = Locked(0)
        let prepared = try await prepare(document: document) { request in
            calls.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(calls.value == 1, "one original add-on request for one watched owner row")
        check(prepared.rows.count == 1 && prepared.archives.count == 1 && prepared.unresolved.isEmpty,
              "fresh non-A11C owner row captures complete evidence")
        let row = prepared.rows[0]
        let locator = LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.authenticatedOwnerLibrary(index: 0)
        let ids = try row.videoIDs(accountID: "account-a", profileID: ownerID,
            sourceSHA256: digest(document), verifiedStreamingUID: nil, locator: locator,
            metaID: "tt2934286", bitmap: bitmap)
        check(ids == episodeIDs, "bitmap maps to the actual five episode IDs")

        let materialData = try VortxLegacyBootstrapMaterial.encode(document: document,
            roster: [ownerProfile], ownerProfileID: ownerID, rosterModifiedSeconds: nil,
            accountID: "account-a", watchedEvidence: prepared.rows)
        let material = try object(materialData)
        let watches = (material["watches"] as! [String: [Object]])[ownerID.uuidString]!
        check(Set(watches.compactMap { $0["videoId"] as? String }) == Set(episodeIDs),
              "material contains all bitmap-derived episodes")
        let byVideo = Dictionary(uniqueKeysWithValues: watches.compactMap { watch -> (String, Object)? in
            guard let video = watch["videoId"] as? String else { return nil }
            return (video, watch)
        })
        let explicitlyMarked = byVideo[episodeIDs[1]]!
        let explicitlyReset = byVideo[episodeIDs[3]]!
        check((explicitlyMarked["markedAtMs"] as? Double) == 1234.125 && explicitlyMarked["watched"] == nil,
              "explicit ma clock supersedes bitmap bare mark")
        check((explicitlyReset["resetAtMs"] as? Double) == 4321.5 && explicitlyReset["watched"] == nil,
              "explicit ua clock supersedes bitmap bare mark")
        for video in [episodeIDs[0], episodeIDs[2], episodeIDs[4]] {
            let watch = byVideo[video]!
            check(watch["watched"] as? Bool == true, "bitmap retains bare watched fact for \(video)")
        }
        for watch in watches {
            check(watch["lastPlayedAtMs"] == nil && watch["positionMs"] == nil,
                  "watched evidence does not invent viewing clocks or progress")
        }

        await expectFailure("unresolved opaque bitmap is still rejected by strict material adapter") {
            _ = try VortxLegacyBootstrapMaterial.encode(document: document,
                roster: [ownerProfile], ownerProfileID: ownerID, rosterModifiedSeconds: nil,
                accountID: "account-a")
        }
        let changedDocument = Data(document + Data([0x20]))
        try await expectStale("changed source bytes") {
            _ = try row.videoIDs(accountID: "account-a", profileID: ownerID, sourceSHA256: digest(changedDocument),
                verifiedStreamingUID: nil, locator: locator, metaID: "tt2934286", bitmap: bitmap)
        }
    }

    private static func coldArchiveReplayIsBoundAndNetworkFree() async throws {
        let document = try ownerDocument()
        let first = try await prepare(document: document) { request in .init(request: request, raw: metadata()) }
        let replayCalls = Locked(0)
        let second = try await prepare(document: document, archived: first.archives) { request in
            replayCalls.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(replayCalls.value == 0 && second.rows.count == 1 && second.archives == first.archives,
              "cold prepare replays the exact archived evidence without fetching")
        try VortxLegacyWatchedMigration.validateArchivedEvidence(first.archives[0],
            accountID: "account-a", ownerProfileID: ownerID)
        let replayed = try VortxLegacyWatchedMigration.replay(first.archives[0], accountID: "account-a",
            profileID: ownerID, ownerProfileID: ownerID, verifiedStreamingUID: nil,
            sourceDocument: document, isCurrent: { true })
        let ids = try replayed.videoIDs(accountID: "account-a", profileID: ownerID,
            sourceSHA256: digest(document), verifiedStreamingUID: nil,
            locator: .authenticatedOwnerLibrary(index: 0), metaID: "tt2934286", bitmap: bitmap)
        check(ids == episodeIDs, "direct cold replay retains the decoded IDs")

        try await expectStale("account rebinding") {
            _ = try VortxLegacyWatchedMigration.replay(first.archives[0], accountID: "account-b",
                profileID: ownerID, ownerProfileID: ownerID, verifiedStreamingUID: nil,
                sourceDocument: document, isCurrent: { true })
        }
        try await expectStale("profile rebinding") {
            _ = try VortxLegacyWatchedMigration.replay(first.archives[0], accountID: "account-a",
                profileID: sharedID, ownerProfileID: ownerID, verifiedStreamingUID: nil,
                sourceDocument: document, isCurrent: { true })
        }
        try await expectStale("owner profile rebinding") {
            _ = try VortxLegacyWatchedMigration.replay(first.archives[0], accountID: "account-a",
                profileID: ownerID, ownerProfileID: sharedID, verifiedStreamingUID: nil,
                sourceDocument: document, isCurrent: { true })
        }
        try await expectStale("source bytes rebinding") {
            _ = try VortxLegacyWatchedMigration.replay(first.archives[0], accountID: "account-a",
                profileID: ownerID, ownerProfileID: ownerID, verifiedStreamingUID: nil,
                sourceDocument: Data(document + Data([0x20])), isCurrent: { true })
        }
        await expectFailure("sealed evidence account scope mismatch") {
            try VortxLegacyWatchedMigration.validateArchivedEvidence(first.archives[0],
                accountID: "account-b", ownerProfileID: ownerID)
        }
    }

    private static func rejectsCancellationAfterFetchReturnsSuccess() async throws {
        let document = try ownerDocument()
        let gate = CancellationGate()
        let preparation = Task {
            try await VortxLegacyWatchedMigration.prepare(accountID: "account-a", ownerProfileID: ownerID,
                document: document, profileIDs: [ownerID], isCurrent: { true }) { request in
                    // Deliberately ignore Task cancellation and deliver a successful provider response.
                    await gate.fetchStartedAndWait()
                    return .init(request: request, raw: metadata())
                }
        }
        await gate.waitForFetchStart()
        preparation.cancel()
        await gate.releaseFetch()
        do {
            _ = try await preparation.value
            preconditionFailure("cancelled preparation accepted a late successful fetch")
        } catch is CancellationError {
            check(true, "late successful fetch is rejected as canceled work")
        } catch {
            preconditionFailure("cancelled preparation failed with the wrong error: \(error)")
        }
    }

    private static func enforcesSourceRowIndexArchiveBoundary() async throws {
        let boundaryDocument = try indexedOwnerDocument(unwatchedRowCount: 9_999)
        let boundaryCalls = Locked(0)
        let boundary = try await prepare(document: boundaryDocument) { request in
            boundaryCalls.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(boundaryDocument.count < 2 * 1024 * 1024, "index 9999 boundary fixture stays below 2 MiB")
        check(boundaryCalls.value == 1 && boundary.rows.count == 1 && boundary.archives.count == 1,
              "source row index 9999 remains capturable")
        let replayCalls = Locked(0)
        let replayed = try await prepare(document: boundaryDocument, archived: boundary.archives) { request in
            replayCalls.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(replayCalls.value == 0 && replayed.rows.count == 1,
              "source row index 9999 archive replays without fetching")

        let outsideDocument = try indexedOwnerDocument(unwatchedRowCount: 10_000)
        check(outsideDocument.count < 2 * 1024 * 1024, "index 10000 boundary fixture stays below 2 MiB")
        let outsideCalls = Locked(0)
        await expectFailure("source row index 10000 rejected before network") {
            _ = try await prepare(document: outsideDocument) { request in
                outsideCalls.modify { $0 += 1 }
                return .init(request: request, raw: metadata())
            }
        }
        check(outsideCalls.value == 0, "out-of-range watched row never starts a metadata request")
    }

    private static func rejectsChangedOriginalAddon() async throws {
        let document = try ownerDocument(addons: [addon(url: catalogURL, manifest: manifest),
                                                   addon(url: alternateURL, manifest: alternateManifest)])
        let captured = try await prepare(document: document) { request in .init(request: request, raw: metadata()) }
        check(captured.archives.count == 1, "both equivalent original inventories permit capture")
        var archived = try object(captured.archives[0])
        archived["addon"] = ["transportUrl": "https://substituted.example/manifest.json",
                              "manifestBase64": Data(#"{"id":"substitute","name":"Substitute","version":"1"}"#.utf8).base64EncodedString()]
        let substituted = try JSONSerialization.data(withJSONObject: archived, options: [.sortedKeys])
        await expectFailure("archive add-on identity mismatch") {
            _ = try await prepare(document: document, archived: [substituted]) { request in
                .init(request: request, raw: metadata())
            }
        }
    }

    private static func historicalOwnerHistoryMapsToResolvedOwner() async throws {
        let document = try ownerHistoryDocument()
        let prepared = try await prepare(document: document) { request in .init(request: request, raw: metadata()) }
        check(prepared.rows.count == 1 && prepared.unresolved.isEmpty,
              "historical A11C ownerHistory row binds to the authenticated non-A11C owner")
        let locator = LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.authenticatedOwnerHistory(
            sourceProfileID: UserProfile.ownerID.uuidString, index: 0)
        let row = prepared.rows[0]
        let migratedIDs = try row.videoIDs(accountID: "account-a", profileID: ownerID, sourceSHA256: digest(document),
            verifiedStreamingUID: nil, locator: locator, metaID: "tt2934286", bitmap: bitmap)
        check(migratedIDs == episodeIDs,
            "historical ownerHistory bitmap resolves every episode")

        let materialData = try VortxLegacyBootstrapMaterial.encode(document: document,
            roster: [ownerProfile], ownerProfileID: ownerID, rosterModifiedSeconds: nil,
            accountID: "account-a", watchedEvidence: prepared.rows)
        let material = try object(materialData)
        let watches = (material["watches"] as! [String: [Object]])[ownerID.uuidString]!
        let byVideo = Dictionary(uniqueKeysWithValues: watches.compactMap { watch -> (String, Object)? in
            guard let video = watch["videoId"] as? String else { return nil }
            return (video, watch)
        })
        check(Set(byVideo.keys) == Set(episodeIDs), "ownerHistory progress merge retains all bitmap episodes")
        let progress = byVideo[episodeIDs[4]]!
        check(progress["positionMs"] as? Int64 == 12_000
              && progress["lastPlayedAtMs"] as? Double == 1_767_225_600_123.5,
              "genuine ownerHistory t/eventEpochMs clocks remain on the current episode")
    }

    private static func unresolvedInventoriesStayPendingAndStrict() async throws {
        let document = try ownerDocument()
        let unavailable = try await prepare(document: document) { request in
            .init(request: request, raw: Data(#"{"meta":{"id":"tt2934286","type":"series","videos":[]}}"#.utf8))
        }
        check(unavailable.rows.isEmpty && unavailable.unresolved.count == 1,
              "incomplete inventory remains unresolved")
        check(unavailable.unresolved[0].sourceDocument == document
              && unavailable.unresolved[0].sourceDocumentSHA256 == digest(document),
              "pending row retains exact original source bytes and digest")
        let pendingArchive = try unavailable.pendingArchives[0]
        try VortxLegacyWatchedMigration.validateArchivedPending(pendingArchive, accountID: "account-a", ownerProfileID: ownerID)
        let pendingObject = try object(pendingArchive)
        check(Data(base64Encoded: pendingObject["sourceDocumentBase64"] as! String) == document,
              "sealed pending archive retains original source bytes")
        var corruptPending = pendingObject
        corruptPending["sourceDocumentSha256"] = String(repeating: "0", count: 64)
        let corruptPendingBytes = try JSONSerialization.data(withJSONObject: corruptPending, options: [.sortedKeys])
        await expectFailure("pending archive source digest corruption") {
            try VortxLegacyWatchedMigration.validateArchivedPending(corruptPendingBytes,
                accountID: "account-a", ownerProfileID: ownerID)
        }
        await expectFailure("pending archive account scope mismatch") {
            try VortxLegacyWatchedMigration.validateArchivedPending(pendingArchive,
                accountID: "account-b", ownerProfileID: ownerID)
        }
        await expectFailure("pending archive owner scope mismatch") {
            try VortxLegacyWatchedMigration.validateArchivedPending(pendingArchive,
                accountID: "account-a", ownerProfileID: sharedID)
        }
        await expectFailure("incomplete inventory strict adapter") {
            _ = try VortxLegacyBootstrapMaterial.encode(document: document,
                roster: [ownerProfile], ownerProfileID: ownerID, rosterModifiedSeconds: nil,
                accountID: "account-a", watchedEvidence: unavailable.rows)
        }

        let twoAddons = try ownerDocument(addons: [addon(url: catalogURL, manifest: manifest),
                                                    addon(url: alternateURL, manifest: alternateManifest)])
        let ambiguous = try await prepare(document: twoAddons) { request in
            let response = request.addon.transportURL == catalogURL ? metadata() : metadata(releaseOffset: 1)
            return .init(request: request, raw: response)
        }
        check(ambiguous.rows.isEmpty && ambiguous.archives.isEmpty && ambiguous.unresolved.count == 1,
              "conflicting original inventories remain pending instead of choosing one")
        check(ambiguous.unresolved[0].sourceDocument == twoAddons
              && ambiguous.unresolved[0].sourceDocumentSHA256 == digest(twoAddons),
              "ambiguous inventory preserves exact source bytes and digest")
        await expectFailure("ambiguous inventory strict adapter") {
            _ = try VortxLegacyBootstrapMaterial.encode(document: twoAddons,
                roster: [ownerProfile], ownerProfileID: ownerID, rosterModifiedSeconds: nil,
                accountID: "account-a", watchedEvidence: ambiguous.rows)
        }
    }

    private static func retriesHistoricalPendingWithoutReplacingSource() async throws {
        let sourceA = try ownerDocument()
        let pendingPreparation = try await prepare(document: sourceA) { request in
            .init(request: request, raw: emptyInventory())
        }
        let pendingA = try pendingPreparation.pendingArchives[0]
        let originalPending = pendingA
        let sourceB = try JSONSerialization.data(withJSONObject: ["unrelatedSetting": "newer",
            "vortx": ["library": [], "addons": [addon(url: catalogURL, manifest: manifest)]]], options: [.sortedKeys])
        let fetches = Locked(0)
        let retried = try await retryPending([pendingA]) { request in
            fetches.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(fetches.value == 1 && retried.archives.count == 1 && retried.unresolved.isEmpty,
              "historical pending source retries successfully")
        check(pendingA == originalPending, "retry does not rewrite its input pending sidecar")
        let completed = try object(retried.archives[0])
        let retainedSource = Data(base64Encoded: completed["sourceDocumentBase64"] as! String)!
        check(retainedSource == sourceA && digest(retainedSource) == digest(sourceA),
              "retry evidence remains bound to exact source A bytes and digest")
        try await expectStale("retried historical evidence cannot bind to current source B") {
            _ = try VortxLegacyWatchedMigration.replay(retried.archives[0], accountID: "account-a",
                profileID: ownerID, ownerProfileID: ownerID, verifiedStreamingUID: nil,
                sourceDocument: sourceB, isCurrent: { true })
        }

        let idempotentCalls = Locked(0)
        let idempotent = try await retryPending([pendingA], evidence: retried.archives) { request in
            idempotentCalls.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(idempotentCalls.value == 0 && idempotent.archives == retried.archives
              && idempotent.unresolved.isEmpty,
              "archived evidence makes retry idempotent and network-free")

        await expectFailure("pending retry account mismatch") {
            _ = try await retryPending([pendingA], accountID: "account-b") { request in
                .init(request: request, raw: metadata())
            }
        }
        await expectFailure("pending retry owner mismatch") {
            _ = try await retryPending([pendingA], ownerProfileID: sharedID) { request in
                .init(request: request, raw: metadata())
            }
        }
    }

    private static func retriesOwnPendingWithCapturedIdentityOnly() async throws {
        let ownA = try ownNetworkOnlySource(verifiedUID: "captured-uid-a")
        let rootA = Data("{}".utf8)
        let ownEnvelope = try object(ownA.sourceDocument)
        let retainedOverlay = Data(base64Encoded: ownEnvelope["profileOverlayBase64"] as! String)!
        check(retainedOverlay == Data("{}".utf8), "network-only own reconnect retains an empty schema-1 overlay")
        let pendingPreparation = try await VortxLegacyWatchedMigration.prepare(accountID: "account-a",
            ownerProfileID: ownerID, document: rootA, profileIDs: [ownerID], ownAccountSources: [ownA],
            isCurrent: { true }) { request in .init(request: request, raw: emptyInventory()) }
        let pendingA = try pendingPreparation.pendingArchives[0]
        let pendingObject = try object(pendingA)
        check(pendingObject["verifiedStreamingUid"] as? String == "captured-uid-a",
              "own pending sidecar seals the captured UID")

        let observedUID = Locked<String?>(nil)
        let retried = try await retryPending([pendingA]) { request in
            observedUID.modify { $0 = request.scope.verifiedStreamingUID }
            return .init(request: request, raw: metadata())
        }
        check(observedUID.value == "captured-uid-a" && retried.archives.count == 1,
              "retry reads the captured own UID instead of substituting a later session")

        try await expectStale("own retry result cannot rebind to UID B") {
            _ = try VortxLegacyWatchedMigration.replay(retried.archives[0], accountID: "account-a",
                profileID: ownID, ownerProfileID: ownerID, verifiedStreamingUID: "captured-uid-b",
                sourceDocument: ownA.sourceDocument, isCurrent: { true })
        }
        let ownB = try ownNetworkOnlySource(verifiedUID: "captured-uid-b", libraryName: "Changed current source")
        try await expectStale("own retry result cannot bind to changed source B") {
            _ = try VortxLegacyWatchedMigration.replay(retried.archives[0], accountID: "account-a",
                profileID: ownID, ownerProfileID: ownerID, verifiedStreamingUID: "captured-uid-b",
                sourceDocument: ownB.sourceDocument, isCurrent: { true })
        }

        // This receipt has the same profile, exact raw source and locator, but a different
        // authenticated UID. It may be retained alongside A, but cannot resolve A's pending row.
        let uidBPrepared = try await VortxLegacyWatchedMigration.prepare(accountID: "account-a",
            ownerProfileID: ownerID, document: rootA, profileIDs: [ownerID],
            ownAccountSources: [try ownNetworkOnlySource(verifiedUID: "captured-uid-b")],
            isCurrent: { true }) { request in .init(request: request, raw: metadata()) }
        let bOnlyFetches = Locked(0)
        let recoveredA = try await retryPending([pendingA], evidence: uidBPrepared.archives) { request in
            bOnlyFetches.modify { $0 += 1 }
            check(request.scope.verifiedStreamingUID == "captured-uid-a",
                  "UID-B evidence cannot change the pending retry's captured UID A")
            return .init(request: request, raw: metadata())
        }
        check(bOnlyFetches.value > 0 && recoveredA.archives.count == 1 && recoveredA.unresolved.isEmpty,
              "UID-B-only evidence does not resolve UID-A pending row; retry captures A instead")
        try await expectStale("UID-A retry evidence cannot rebind to UID B") {
            _ = try VortxLegacyWatchedMigration.replay(recoveredA.archives[0], accountID: "account-a",
                profileID: ownID, ownerProfileID: ownerID, verifiedStreamingUID: "captured-uid-b",
                sourceDocument: ownA.sourceDocument, isCurrent: { true })
        }

        let bothEvidence = recoveredA.archives + uidBPrepared.archives
        let aReplayFetches = Locked(0)
        let replayedA = try await retryPending([pendingA], evidence: bothEvidence) { request in
            aReplayFetches.modify { $0 += 1 }
            return .init(request: request, raw: metadata())
        }
        check(aReplayFetches.value == 0 && replayedA.archives == recoveredA.archives && replayedA.unresolved.isEmpty,
              "retained UID-A and UID-B evidence zero-network replays the exact UID-A receipt")

        let bReplayFetches = Locked(0)
        let bReplay = try await VortxLegacyWatchedMigration.prepare(accountID: "account-a",
            ownerProfileID: ownerID, document: rootA, profileIDs: [ownerID],
            ownAccountSources: [try ownNetworkOnlySource(verifiedUID: "captured-uid-b")],
            archivedEvidence: bothEvidence, isCurrent: { true }) { request in
                bReplayFetches.modify { $0 += 1 }
                return .init(request: request, raw: metadata())
            }
        check(bReplayFetches.value == 0 && bReplay.rows.count == 1 && bReplay.archives == uidBPrepared.archives,
              "current UID-B source zero-network selects its exact UID-B receipt from retained A+B")

        var missingUID = pendingObject
        missingUID.removeValue(forKey: "verifiedStreamingUid")
        let malformedPending = try JSONSerialization.data(withJSONObject: missingUID, options: [.sortedKeys])
        let requestCount = Locked(0)
        await expectFailure("own pending archive without captured UID") {
            _ = try await retryPending([malformedPending]) { request in
                requestCount.modify { $0 += 1 }
                return .init(request: request, raw: metadata())
            }
        }
        check(requestCount.value == 0, "missing own UID is rejected before metadata fetch")

        let mismatchedResponse = try await retryPending([pendingA]) { request in
            let otherUID = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a",
                profileID: ownID, verifiedStreamingUID: "captured-uid-b", ownerProfileID: ownerID)
            let foreignRequest = LegacyWatchedBitfieldMigrationEvidence.MetadataRequest(scope: otherUID,
                addon: request.addon, type: request.type, metaID: request.metaID)
            return .init(request: foreignRequest, raw: metadata())
        }
        check(mismatchedResponse.archives.isEmpty && mismatchedResponse.unresolved == [pendingA],
              "metadata response with a different request UID leaves exact pending sidecar unresolved")
    }

    private static func failedPendingRetriesPreserveExactSidecars() async throws {
        let source = try ownerDocument()
        let pending = try await prepare(document: source) { request in .init(request: request, raw: emptyInventory()) }
        let pendingA = try pending.pendingArchives[0]

        let hostile = try await retryPending([pendingA]) { request in
            .init(request: request, raw: Data(#"{"meta":{"id":"other-title","type":"series","videos":[]}}"#.utf8))
        }
        check(hostile.archives.isEmpty && hostile.unresolved == [pendingA],
              "hostile metadata leaves the exact original pending bytes unresolved")

        let missing = try await retryPending([pendingA]) { request in
            .init(request: request, raw: emptyInventory())
        }
        check(missing.archives.isEmpty && missing.unresolved == [pendingA],
              "missing inventory leaves the exact original pending bytes unresolved")

        let ambiguousSource = try ownerDocument(addons: [addon(url: catalogURL, manifest: manifest),
                                                            addon(url: alternateURL, manifest: alternateManifest)])
        let ambiguousPending = try await prepare(document: ambiguousSource) { request in
            .init(request: request, raw: request.addon.transportURL == catalogURL ? metadata() : metadata(releaseOffset: 1))
        }
        let ambiguousBytes = try ambiguousPending.pendingArchives[0]
        let stillAmbiguous = try await retryPending([ambiguousBytes]) { request in
            .init(request: request, raw: request.addon.transportURL == catalogURL ? metadata() : metadata(releaseOffset: 1))
        }
        check(stillAmbiguous.archives.isEmpty && stillAmbiguous.unresolved == [ambiguousBytes],
              "conflicting inventories leave the exact ambiguous pending bytes unresolved")

        let gate = CancellationGate()
        let canceledRetry = Task {
            try await retryPending([pendingA]) { request in
                await gate.fetchStartedAndWait()
                return .init(request: request, raw: metadata())
            }
        }
        await gate.waitForFetchStart()
        canceledRetry.cancel()
        await gate.releaseFetch()
        do {
            _ = try await canceledRetry.value
            preconditionFailure("canceled historical retry accepted a late successful fetch")
        } catch is CancellationError {
            check(true, "historical retry propagates cancellation after successful fetch")
        } catch {
            preconditionFailure("historical retry propagated the wrong cancellation error: \(error)")
        }
    }

    private static func metadataTransportUsesOnlyBoundedOriginalEndpoint() async throws {
        let scope = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "account-a", profileID: ownerID,
                                                                       ownerProfileID: ownerID)
        let configuredURL = "https://Catalog.Example/Config%2FAbC/manifest.json?tenant=one%2Ftwo"
        let authorized = try LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(
            transportURL: configuredURL,
            manifest: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
        let request = LegacyWatchedBitfieldMigrationEvidence.MetadataRequest(
            scope: scope, addon: authorized, type: "series", metaID: "tt/foo%?bar#frag")
        let observation = Locked<TransportObservation?>(nil)
        let raw = Data(#"{"meta":{"id":"tt/foo%?bar#frag","type":"series","videos":[]}}"#.utf8)
        let result = try await VortxLegacyWatchedMetadataTransport.fetch(request) { http, hosts, limit in
            observation.modify { $0 = TransportObservation(url: http.url?.absoluteString, method: http.httpMethod,
                hosts: hosts, limit: limit, accept: http.value(forHTTPHeaderField: "Accept"),
                authorization: http.value(forHTTPHeaderField: "Authorization"),
                cookie: http.value(forHTTPHeaderField: "Cookie"),
                proxyAuthorization: http.value(forHTTPHeaderField: "Proxy-Authorization")) }
            return AuthenticatedHTTPResponse(data: raw, statusCode: 200)
        }
        check(result.request == request && result.raw == raw, "metadata transport returns the exact token-free response bytes")
        guard let captured = observation.value, let sentRawURL = captured.url,
              let sentURL = URL(string: sentRawURL) else {
            preconditionFailure("send seam was not invoked")
        }
        let configuredHost = URLComponents(string: configuredURL)!.host!
        let sentComponents = URLComponents(url: sentURL, resolvingAgainstBaseURL: false)!
        check(captured.method == "GET", "metadata transport uses GET")
        check(sentURL.host?.lowercased() == configuredHost.lowercased(), "request remains on the configured exact host")
        check(captured.hosts == Set([configuredHost]), "only the configured exact host is allowlisted")
        check(sentComponents.percentEncodedPath == "/Config%2FAbC/meta/series/tt%2Ffoo%25%3Fbar%23frag.json",
              "configured case-sensitive path and encoded single meta ID segment are preserved")
        check(sentComponents.percentEncodedQuery == "tenant=one%2Ftwo",
              "configured query remains unchanged")
        check(captured.limit == 2 * 1024 * 1024, "metadata response cap is exactly 2 MiB")
        check(captured.accept == "application/json" && captured.authorization == nil
              && captured.cookie == nil && captured.proxyAuthorization == nil,
              "metadata request carries no credentials or cookies")

        let calls = Locked(0)
        await expectFailure("non-2xx metadata status") {
            _ = try await VortxLegacyWatchedMetadataTransport.fetch(request) { _, _, _ in
                calls.modify { $0 += 1 }
                return AuthenticatedHTTPResponse(data: raw, statusCode: 503)
            }
        }
        await expectFailure("metadata response exceeding 2 MiB") {
            _ = try await VortxLegacyWatchedMetadataTransport.fetch(request) { _, _, _ in
                AuthenticatedHTTPResponse(data: Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1), statusCode: 200)
            }
        }
        check(calls.value == 1, "failed HTTP status reached the injected sender once")

        let nonHTTPS = try metadataRequest(scope: scope, transportURL: "http://catalog.example/manifest.json", metaID: "tt1")
        await expectFailure("non-HTTPS metadata endpoint") {
            _ = try await VortxLegacyWatchedMetadataTransport.fetch(nonHTTPS) { _, _, _ in
                calls.modify { $0 += 1 }
                return AuthenticatedHTTPResponse(data: raw, statusCode: 200)
            }
        }
        let nonManifest = try metadataRequest(scope: scope, transportURL: "https://catalog.example/not-manifest.json", metaID: "tt1")
        await expectFailure("non-manifest metadata endpoint") {
            _ = try await VortxLegacyWatchedMetadataTransport.fetch(nonManifest) { _, _, _ in
                calls.modify { $0 += 1 }
                return AuthenticatedHTTPResponse(data: raw, statusCode: 200)
            }
        }
        check(calls.value == 1, "invalid endpoints are rejected before transport")
    }

    private static func originalManifestNumberLexemesSurviveCapture() async throws {
        let manifestRaw = #"{"id":"catalog","name":"Original catalog","version":"1.0.0","resources":["meta"],"types":["series"],"rank":1.0000000000000001,"tiny":4.9406564584124654e-324}"#
        let sourceText = #"{"vortx":{"library":[{"id":"tt2934286","type":"series","watched":"tt2934286:1:5:5:eJyTZwAAAEAAIA=="}],"addons":[{"transportUrl":"https://catalog.example/manifest.json","manifest":\#(manifestRaw)}]}}"#
        let source = Data(sourceText.utf8)
        let captured = try await prepare(document: source) { request in
            .init(request: request, raw: metadata())
        }
        check(captured.rows.count == 1 && captured.archives.count == 1 && captured.unresolved.isEmpty,
              "manifest with precise and tiny numeric lexemes is captured")
        let archive = try object(captured.archives[0])
        let archivedSource = Data(base64Encoded: archive["sourceDocumentBase64"] as! String)!
        check(archivedSource == source && digest(archivedSource) == digest(source),
              "sidecar source bytes and digest remain exact")
        let addon = archive["addon"] as! Object
        let archivedManifest = Data(base64Encoded: addon["manifestBase64"] as! String)!
        check(archivedManifest == Data(manifestRaw.utf8),
              "sidecar original manifest preserves exact decimal and exponent lexemes")
    }

    private static func metadataRequest(scope: LegacyWatchedBitfieldMigrationEvidence.Scope,
                                        transportURL: String, metaID: String) throws -> LegacyWatchedBitfieldMigrationEvidence.MetadataRequest {
        let descriptor = try LegacyWatchedBitfieldMigrationEvidence.AuthorizedAddon(transportURL: transportURL,
            manifest: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
        return .init(scope: scope, addon: descriptor, type: "series", metaID: metaID)
    }

    private static func ownAccountEnvelopeAndOverlayAreExactForBothSchemas() async throws {
        for version in [1, 2] {
            let owner = UserProfile(id: ownerID, name: "Owner", avatar: "O", isOwner: true)
            var ownProfile = UserProfile(id: ownID, name: "Own", avatar: "A")
            ownProfile.usesOwnAccount = true
            let ownSource = try ownAccountSource(schemaVersion: version)
            let sourceEnvelope = try object(ownSource.sourceDocument)
            let source = Data(base64Encoded: sourceEnvelope["profileOverlayBase64"] as! String)!
            let prepared = try await VortxLegacyWatchedMigration.prepare(accountID: "account-a", ownerProfileID: ownerID,
                document: source, profileIDs: [ownerID], ownAccountSources: [ownSource], isCurrent: { true }) { request in
                    .init(request: request, raw: metadata())
                }
            check(prepared.rows.count == 1 && prepared.unresolved.isEmpty,
                  "schema \(version) own overlay source produces evidence")
            let locator = LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.ownAccountOwnerHistory(index: 0)
            let row = prepared.rows[0]
            let videoIDs = try row.videoIDs(accountID: "account-a", profileID: ownID,
                sourceSHA256: ownSource.sourceDocumentSHA256, verifiedStreamingUID: "verified-own-uid",
                locator: locator, metaID: "tt2934286", bitmap: bitmap)
            check(videoIDs == episodeIDs, "schema \(version) overlay bitmap resolves against authenticated UID")
            let archived = try object(prepared.archives[0])
            let retainedSource = Data(base64Encoded: archived["sourceDocumentBase64"] as! String)!
            check(retainedSource == ownSource.sourceDocument && digest(retainedSource) == ownSource.sourceDocumentSHA256,
                  "schema \(version) archive retains exact raw own envelope and digest")

            try await expectStale("schema \(version) own UID rebinding") {
                _ = try VortxLegacyWatchedMigration.replay(prepared.archives[0], accountID: "account-a",
                    profileID: ownID, ownerProfileID: ownerID, verifiedStreamingUID: "different-uid",
                    sourceDocument: ownSource.sourceDocument, isCurrent: { true })
            }

            let materialData = try VortxLegacyBootstrapMaterial.encode(document: source, roster: [owner, ownProfile],
                ownerProfileID: ownerID, rosterModifiedSeconds: nil, ownAccountSources: [ownSource],
                accountID: "account-a", watchedEvidence: prepared.rows)
            let material = try object(materialData)
            let proof = (material["ownAccountSources"] as! [String: Object])[ownID.uuidString]!
            check(proof["sourceDocumentSha256"] as? String == ownSource.sourceDocumentSHA256,
                  "schema \(version) material digest binds exact own envelope")
            let ownWatches = (material["watches"] as! [String: [Object]])[ownID.uuidString]!
            check(Set(ownWatches.compactMap { $0["videoId"] as? String }) == Set(episodeIDs),
                  "schema \(version) own overlay source reaches its isolated watch bucket")
            let ownProgress = ownWatches.first { $0["videoId"] as? String == episodeIDs[4] }!
            check(ownProgress["positionMs"] as? Int64 == 12_000
                  && ownProgress["lastPlayedAtMs"] as? Double == 1_767_225_600_123.5,
                  "schema \(version) own ownerHistory preserves genuine episode progress")
        }
    }

    private static var ownerProfile: UserProfile {
        UserProfile(id: ownerID, name: "Owner", avatar: "O", isOwner: true)
    }

    private static var episodeIDs: [String] { (1...5).map { "tt2934286:1:\($0)" } }

    private static func prepare(document: Data, archived: [Data] = [],
                                fetch: @escaping LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher) async throws -> VortxLegacyWatchedMigration.Preparation {
        try await VortxLegacyWatchedMigration.prepare(accountID: "account-a", ownerProfileID: ownerID,
            document: document, profileIDs: [ownerID], archivedEvidence: archived,
            isCurrent: { true }, fetch: fetch)
    }

    private static func retryPending(_ archives: [Data], accountID: String = "account-a",
                                     ownerProfileID: UUID = ownerID, evidence: [Data] = [],
                                     fetch: @escaping LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher) async throws
        -> VortxLegacyWatchedMigration.HistoricalRetry {
        try await VortxLegacyWatchedMigration.retryArchivedPending(archives, accountID: accountID,
            ownerProfileID: ownerProfileID, archivedEvidence: evidence, isCurrent: { true }, fetch: fetch)
    }

    private static func ownerDocument(addons: [Object]? = nil) throws -> Data {
        let row: Object = ["id": "tt2934286", "type": "series", "name": "Fixture Series", "watched": bitmap,
                           "ma": [episodeIDs[1]: 1234.125], "ua": [episodeIDs[3]: 4321.5]]
        let document: Object = ["vortx": ["library": [row], "addons": addons ?? [addon(url: catalogURL, manifest: manifest)]]]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    private static func indexedOwnerDocument(unwatchedRowCount: Int) throws -> Data {
        let ordinary: Object = ["id": "tt-unwatched", "type": "movie"]
        let watched: Object = ["id": "tt2934286", "type": "series", "watched": bitmap]
        let rows = Array(repeating: ordinary, count: unwatchedRowCount) + [watched]
        return try JSONSerialization.data(withJSONObject: ["vortx": [
            "library": rows, "addons": [addon(url: catalogURL, manifest: manifest)]
        ]], options: [.sortedKeys])
    }

    private static func ownerHistoryDocument() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["vortx": [
            "addons": [addon(url: catalogURL, manifest: manifest)],
            "byProfile": [UserProfile.ownerID.uuidString: ["ownerHistory": [historyRow()]]]
        ]], options: [.sortedKeys])
    }

    private static func historyRow() -> Object {
        ["id": "tt2934286", "type": "series", "name": "Fixture Series", "watched": bitmap,
         "eventEpochMs": 1_767_225_600_123.5, "lastWatched": "2026-01-01T00:00:00Z",
         "t": 12, "d": 1800, "v": episodeIDs[4]]
    }

    private static func addon(url: String, manifest: Object) -> Object {
        ["transportUrl": url, "manifest": manifest]
    }

    private static func metadata(releaseOffset: Int = 0) -> Data {
        let videos: [Object] = (1...5).map { episode in
            let day = episode + releaseOffset
            return ["id": "tt2934286:1:\(episode)", "season": 1, "episode": episode,
                    "released": String(format: "2005-01-%02dT00:00:00Z", day)]
        }
        return try! JSONSerialization.data(withJSONObject: ["meta": ["id": "tt2934286", "type": "series", "videos": videos]],
                                           options: [.sortedKeys])
    }

    private static func ownAccountSource(schemaVersion: Int, verifiedUID: String = "verified-own-uid",
                                         historyName: String = "Fixture Series") throws -> VortxLegacyBootstrapMaterial.OwnAccountSource {
        let ownAddon = addon(url: catalogURL, manifest: manifest)
        let libraryRows: [Object] = [["_id": "tt2934286", "type": "series", "name": "Fixture Series",
                                      "state": ["timeOffset": 0, "duration": 0]]]
        let addonBody = try JSONSerialization.data(withJSONObject: ["result": ["addons": [ownAddon]]], options: [.sortedKeys])
        let libraryBody = try JSONSerialization.data(withJSONObject: ["result": libraryRows], options: [.sortedKeys])
        var ownHistory = historyRow()
        ownHistory["name"] = historyName
        let overlay: Object = ["vortx": ["byProfile": [ownID.uuidString: ["ownerHistory": [ownHistory]]]]]
        let overlayBody = try JSONSerialization.data(withJSONObject: overlay, options: [.sortedKeys])
        let envelope: Object = ["schemaVersion": schemaVersion,
            "libraryResponseBase64": libraryBody.base64EncodedString(),
            "addonsResponseBase64": addonBody.base64EncodedString(),
            "profileOverlayBase64": overlayBody.base64EncodedString()]
        let source = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let overlayWitness = schemaVersion == 2 ? try VortxProfileOverlayWitness.digest(json: overlayBody) : nil
        return VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: ownID, verifiedStreamingUID: verifiedUID,
            sourceDocument: source, profileOverlaySHA256: overlayWitness)
    }

    private static func ownNetworkOnlySource(verifiedUID: String,
                                            libraryName: String = "Fixture Series") throws -> VortxLegacyBootstrapMaterial.OwnAccountSource {
        let ownAddon = addon(url: catalogURL, manifest: manifest)
        let libraryRows: [Object] = [
            ["_id": "tt2934286", "type": "series", "name": libraryName,
             "state": ["watched": bitmap, "timeOffset": 0, "duration": 0]]
        ]
        let addonBody = try JSONSerialization.data(withJSONObject: ["result": ["addons": [ownAddon]]], options: [.sortedKeys])
        let libraryBody = try JSONSerialization.data(withJSONObject: ["result": libraryRows], options: [.sortedKeys])
        let overlayBody = Data("{}".utf8)
        let envelope: Object = ["schemaVersion": 1,
            "libraryResponseBase64": libraryBody.base64EncodedString(),
            "addonsResponseBase64": addonBody.base64EncodedString(),
            "profileOverlayBase64": overlayBody.base64EncodedString()]
        let source = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return VortxLegacyBootstrapMaterial.OwnAccountSource(profileID: ownID, verifiedStreamingUID: verifiedUID,
            sourceDocument: source, profileOverlaySHA256: nil)
    }

    private static func overlayDocument(from source: VortxLegacyBootstrapMaterial.OwnAccountSource) throws -> Data {
        let envelope = try object(source.sourceDocument)
        guard let overlay = envelope["profileOverlayBase64"] as? String, let bytes = Data(base64Encoded: overlay) else {
            throw TestFailure.expectedObject
        }
        return bytes
    }

    private static func emptyInventory() -> Data {
        Data(#"{"meta":{"id":"tt2934286","type":"series","videos":[]}}"#.utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func object(_ data: Data) throws -> Object {
        guard let value = try JSONSerialization.jsonObject(with: data) as? Object else { throw TestFailure.expectedObject }
        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func expectFailure(_ description: String, _ action: () async throws -> Void) async {
        do {
            try await action()
            preconditionFailure("Expected rejection: \(description)")
        } catch is TestFailure {
            preconditionFailure("Test fixture failed while checking rejection: \(description)")
        } catch { }
    }

    private static func expectStale(_ description: String, _ action: () throws -> Void) async throws {
        do {
            try action()
            preconditionFailure("Expected stale-binding rejection: \(description)")
        } catch is TestFailure {
            throw TestFailure.expectedStale(description)
        } catch { }
    }

    private enum TestFailure: Error { case expectedObject, expectedStale(String) }
}

private struct TransportObservation: Sendable {
    let url: String?
    let method: String?
    let hosts: Set<String>
    let limit: Int
    let accept: String?
    let authorization: String?
    let cookie: String?
    let proxyAuthorization: String?
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func modify(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private actor CancellationGate {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func fetchStartedAndWait() async {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForFetchStart() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releaseFetch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
