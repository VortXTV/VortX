import Foundation
import CoreFoundation
import CryptoKit

/// Recovery proposal: real pure-source/metadata preparation and offline revalidation. No native
/// action, receipt assertion, persistence or public projection. Intended production SourcesShared.
enum VortxNativeOwnerHistoryPreparation {
    typealias Source = VortxNativeOwnerHistorySource
    typealias Migration = VortxLegacyWatchedMigration
    enum Failure: Error, Equatable { case malformedFrame, malformedArchive, incomplete, excessive }
    static let maximumArchiveBytes = 32 * 1024 * 1024

    struct Frame: Sendable {
        let scope: String
        let ownerProfileID: UUID
        let profileID: UUID
        let verifiedUID: String
        let sourceDocument: Data
        fileprivate init(scope: String, ownerProfileID: UUID, profileID: UUID, verifiedUID: String, sourceDocument: Data) {
            self.scope = scope; self.ownerProfileID = ownerProfileID; self.profileID = profileID
            self.verifiedUID = verifiedUID; self.sourceDocument = sourceDocument
        }
    }
    struct Prepared: Sendable {
        let frame: Frame
        let archive: Data
        let evidence: Data
        /// Only live preparation and complete offline re-decode construct this value.
        fileprivate init(frame: Frame, archive: Data, evidence: Data) {
            self.frame = frame; self.archive = archive; self.evidence = evidence
        }
    }
    struct Pending: Sendable {
        let frame: Frame
        /// Exact source plus accepted/pending metadata receipts. NOT an acknowledged source set.
        let archiveCandidate: Data
        let unresolvedMetadataCount: Int
        let heldProjectionCount: Int
        fileprivate init(frame: Frame, archiveCandidate: Data, unresolvedMetadataCount: Int, heldProjectionCount: Int) {
            self.frame = frame; self.archiveCandidate = archiveCandidate
            self.unresolvedMetadataCount = unresolvedMetadataCount; self.heldProjectionCount = heldProjectionCount
        }
    }
    enum Outcome: Sendable { case prepared(Prepared), pending(Pending) }

    static func fetch(capture: Source.Capture, authKey: String, authority: any VortxMutationAuthority,
                      verify: Source.Verify = { try await LinkAuthService.authenticatedIdentity(authKey: $0).uid },
                      send: Source.Send = { try await AuthenticatedHTTPTransport.shared.send($0,
                          allowedHosts: ["api.strem.io"], maxResponseBytes: Source.maximumBytes) }) async throws -> Frame {
        let library = try await Source.fetch(capture: capture, authKey: authKey, authority: authority, verify: verify, send: send)
        try check(authority)
        var request = URLRequest(url: URL(string: "https://api.strem.io/api/addonCollectionGet")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["authKey": authKey, "update": false])
        let response = try await send(request)
        try check(authority)
        guard (200..<300).contains(response.statusCode) else { throw Failure.malformedFrame }
        try validateAddons(response.data, prohibitedCredential: authKey)
        let frame = try encode([
            "schemaVersion": 1, "kind": "vortx.owner-history.source/1", "scope": capture.scope,
            "ownerProfileId": capture.ownerProfileID.uuidString, "profileId": capture.profileID.uuidString,
            "verifiedStreamingUid": capture.verifiedUID, "libraryResponseBase64": library.response.base64EncodedString(),
            "addonsResponseBase64": response.data.base64EncodedString()
        ])
        let result = try decodeFrame(frame, scope: capture.scope, ownerProfileID: capture.ownerProfileID,
                                    profileID: capture.profileID, verifiedUID: capture.verifiedUID)
        try check(authority)
        return result
    }

    static func decodeFrame(_ bytes: Data, scope: String, ownerProfileID: UUID, profileID: UUID, verifiedUID: String) throws -> Frame {
        guard bytes.count <= maximumArchiveBytes else { throw Failure.excessive }
        let bound = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: scope, profileID: profileID,
            verifiedStreamingUID: verifiedUID, ownerProfileID: ownerProfileID)
        try LegacyWatchedBitfieldMigrationEvidence.validateOwnerSource(scope: bound, source: bytes)
        let object = try VortxProfileOverlayWitness.decodeObject(json: bytes)
        let library = try raw(object, "libraryResponseBase64")
        let parsed = try Source.credentialFreeObject(library, prohibitedCredential: nil)
        guard parsed["error"] == nil || parsed["error"] is NSNull,
              let rows = parsed["result"] as? [[String: Any]], rows.count <= Source.maximumRows else { throw Failure.malformedFrame }
        try validateAddons(raw(object, "addonsResponseBase64"), prohibitedCredential: nil)
        return Frame(scope: scope, ownerProfileID: ownerProfileID, profileID: profileID,
                     verifiedUID: verifiedUID, sourceDocument: bytes)
    }

    static func prepare(frame: Frame, authority: any VortxMutationAuthority, archivedMetadata: [Data] = [],
                        fetchMetadata: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher = {
                            try await VortxLegacyWatchedMetadataTransport.fetch($0)
                        }) async throws -> Outcome {
        try check(authority)
        let current: @Sendable () -> Bool = { (try? authority.withActive {}) != nil }
        // Retained evidence may reach a pending result before complete-archive replay. Apply the
        // exact same raw metadata privacy gate BEFORE it can enter any pending archive candidate.
        guard archivedMetadata.count <= 10_000 else { throw Failure.excessive }
        var retainedBudget = maximumArchiveBytes
        for bytes in archivedMetadata {
            guard bytes.count <= retainedBudget else { throw Failure.excessive }
            retainedBudget -= bytes.count
            let record = try VortxProfileOverlayWitness.decodeObject(json: bytes)
            _ = try Source.credentialFreeObject(raw(record, "metadataResponseBase64"), prohibitedCredential: nil)
        }
        let metadata = try await Migration.prepareOwnerHistory(accountID: frame.scope, ownerProfileID: frame.ownerProfileID,
            profileID: frame.profileID, verifiedUID: frame.verifiedUID, sourceDocument: frame.sourceDocument,
            archivedEvidence: archivedMetadata, isCurrent: current, fetch: { request in
                try check(authority)
                let response = try await fetchMetadata(request)
                try check(authority)
                _ = try Source.credentialFreeObject(response.raw, prohibitedCredential: nil)
                return response
            })
        try check(authority)
        let projected = try project(frame, rows: metadata.rows)
        guard metadata.unresolved.isEmpty && projected.held.isEmpty else {
            let candidate = try encode([
                "schemaVersion": 1, "kind": "vortx.owner-history.pending/1",
                "sourceDocumentBase64": frame.sourceDocument.base64EncodedString(),
                "metadataEvidenceBase64": ordered(metadata.archives).map { $0.base64EncodedString() },
                "metadataPendingBase64": try metadata.pendingArchives.map { $0.base64EncodedString() },
                "heldProjectionKinds": projected.held.map(\.kind).sorted()
            ])
            guard candidate.count <= maximumArchiveBytes else { throw Failure.excessive }
            try check(authority)
            return .pending(Pending(frame: frame, archiveCandidate: candidate,
                unresolvedMetadataCount: metadata.unresolved.count, heldProjectionCount: projected.held.count))
        }
        let archive = try encode([
            "schemaVersion": 1, "kind": "vortx.owner-history.archive/1",
            "sourceDocumentBase64": frame.sourceDocument.base64EncodedString(),
            "metadataEvidenceBase64": ordered(metadata.archives).map { $0.base64EncodedString() }
        ])
        // Full offline replay on the exact bytes destined for the journal, including metadata.
        let accepted = try replay(archive: archive, scope: frame.scope, ownerProfileID: frame.ownerProfileID,
            profileID: frame.profileID, verifiedUID: frame.verifiedUID, authority: authority)
        try check(authority)
        return .prepared(accepted)
    }

    /// Retry the original pending bytes after an authenticated reopen; never recapture a different
    /// source or relabel its UID. Accepted metadata is replayed, and only still-pending rows fetch.
    static func resumePending(archive: Data, scope: String, ownerProfileID: UUID, profileID: UUID, verifiedUID: String,
                              authority: any VortxMutationAuthority,
                              fetchMetadata: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher) async throws -> Outcome {
        try check(authority)
        guard archive.count <= maximumArchiveBytes else { throw Failure.excessive }
        let object = try VortxProfileOverlayWitness.decodeObject(json: archive)
        guard Set(object.keys) == ["schemaVersion", "kind", "sourceDocumentBase64", "metadataEvidenceBase64",
                                   "metadataPendingBase64", "heldProjectionKinds"],
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1", object["kind"] as? String == "vortx.owner-history.pending/1",
              let accepted = object["metadataEvidenceBase64"] as? [String], accepted.count <= 10_000,
              let pending = object["metadataPendingBase64"] as? [String], pending.count <= 10_000,
              object["heldProjectionKinds"] is [String] else { throw Failure.malformedArchive }
        let frame = try decodeFrame(raw(object, "sourceDocumentBase64"), scope: scope, ownerProfileID: ownerProfileID,
                                    profileID: profileID, verifiedUID: verifiedUID)
        let receipts = try accepted.map { value -> Data in
            let bytes = try raw(["value": value], "value")
            let record = try VortxProfileOverlayWitness.decodeObject(json: bytes)
            _ = try Source.credentialFreeObject(raw(record, "metadataResponseBase64"), prohibitedCredential: nil)
            _ = try Migration.replay(bytes, accountID: scope, profileID: profileID, ownerProfileID: ownerProfileID,
                verifiedStreamingUID: verifiedUID, sourceDocument: frame.sourceDocument,
                isCurrent: { (try? authority.withActive {}) != nil })
            return bytes
        }
        guard receipts == ordered(receipts), Set(receipts).count == receipts.count else { throw Failure.malformedArchive }
        for value in pending {
            let bytes = try raw(["value": value], "value")
            try Migration.validateArchivedPending(bytes, accountID: scope, ownerProfileID: ownerProfileID)
            let record = try VortxProfileOverlayWitness.decodeObject(json: bytes)
            guard exact(record["profileId"], profileID.uuidString),
                  exact(record["verifiedStreamingUid"], verifiedUID),
                  try raw(record, "sourceDocumentBase64") == frame.sourceDocument else { throw Failure.malformedArchive }
        }
        try check(authority)
        return try await prepare(frame: frame, authority: authority, archivedMetadata: receipts, fetchMetadata: fetchMetadata)
    }

    /// Synchronous callback seam for cold open/import/peer merge. Every raw and metadata byte is
    /// re-decoded and the typed carrier recomputed. The caller must compare native's typed receipt
    /// using the engine's canonicalizer; Swift never invents typedCarrierFingerprint/sourceId.
    static func replay(archive: Data, scope: String, ownerProfileID: UUID, profileID: UUID, verifiedUID: String,
                       authority: any VortxMutationAuthority) throws -> Prepared {
        try check(authority)
        guard archive.count <= maximumArchiveBytes else { throw Failure.excessive }
        let object = try VortxProfileOverlayWitness.decodeObject(json: archive)
        guard Set(object.keys) == ["schemaVersion", "kind", "sourceDocumentBase64", "metadataEvidenceBase64"],
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1", object["kind"] as? String == "vortx.owner-history.archive/1",
              let records = object["metadataEvidenceBase64"] as? [String], records.count <= 10_000 else { throw Failure.malformedArchive }
        let frame = try decodeFrame(raw(object, "sourceDocumentBase64"), scope: scope, ownerProfileID: ownerProfileID,
                                    profileID: profileID, verifiedUID: verifiedUID)
        let receipts = try records.map { encoded -> Data in
            guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else { throw Failure.malformedArchive }
            // Inspect actual decoded metadata, not an opaque caller-attested hash.
            let receipt = try VortxProfileOverlayWitness.decodeObject(json: data)
            _ = try Source.credentialFreeObject(raw(receipt, "metadataResponseBase64"), prohibitedCredential: nil)
            return data
        }
        guard receipts == ordered(receipts) else { throw Failure.malformedArchive }
        let rows = try Migration.replayOwnerHistory(accountID: scope, ownerProfileID: ownerProfileID, profileID: profileID,
            verifiedUID: verifiedUID, sourceDocument: frame.sourceDocument, archives: receipts,
            isCurrent: { (try? authority.withActive {}) != nil })
        let projected = try project(frame, rows: rows)
        guard projected.held.isEmpty else { throw Failure.incomplete }
        let carrier = try VortxProfileOverlayWitness.decodeObject(json: projected.carrier)
        guard let library = carrier["library"], let watches = carrier["watches"], let links = carrier["identityLinks"] else { throw Failure.malformedArchive }
        let evidence = try encode([
            "schemaVersion": 1, "scope": scope, "ownerProfileId": ownerProfileID.uuidString, "profileId": profileID.uuidString,
            "verifiedStreamingUid": verifiedUID, "sourceDocumentSha256": digest(frame.sourceDocument),
            "sourceArchiveSha256": digest(archive), "library": library, "watches": watches, "identityLinks": links
        ])
        try check(authority)
        return Prepared(frame: frame, archive: archive, evidence: evidence)
    }

    private static func project(_ frame: Frame, rows: [Migration.ValidatedRow]) throws -> VortxLegacyBootstrapMaterial.OwnerHistoryProjection {
        try VortxLegacyBootstrapMaterial.projectOwnerHistory(accountID: frame.scope, ownerProfileID: frame.ownerProfileID,
            profileID: frame.profileID, verifiedUID: frame.verifiedUID, sourceDocument: frame.sourceDocument, watchedEvidence: rows)
    }
    private static func validateAddons(_ bytes: Data, prohibitedCredential: String?) throws {
        let object = try Source.credentialFreeObject(bytes, prohibitedCredential: prohibitedCredential)
        guard object["error"] == nil || object["error"] is NSNull,
              let result = object["result"] as? [String: Any], let rows = result["addons"] as? [[String: Any]],
              rows.count <= 10_000 else { throw Failure.malformedFrame }
    }
    private static func ordered(_ records: [Data]) -> [Data] { records.sorted { $0.lexicographicallyPrecedes($1) } }
    private static func exact(_ value: Any?, _ expected: String) -> Bool {
        guard let value = value as? String else { return false }
        return Data(value.utf8) == Data(expected.utf8)
    }
    private static func raw(_ object: [String: Any], _ key: String) throws -> Data {
        guard let value = object[key] as? String, let data = Data(base64Encoded: value),
              data.base64EncodedString() == value else { throw Failure.malformedArchive }
        return data
    }
    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func check(_ authority: any VortxMutationAuthority) throws {
        try Task.checkCancellation(); try authority.withActive {}; try Task.checkCancellation()
    }
}
