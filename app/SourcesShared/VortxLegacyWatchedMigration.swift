import Foundation
import CoreFoundation
import CryptoKit

/// Host-only preparation and cold replay. Neither raw source nor provider response is projected
/// into the kernel. The authenticated host seals `archives` beside its existing source archive.
enum VortxLegacyWatchedMigration {
    typealias Evidence = LegacyWatchedBitfieldMigrationEvidence
    typealias Object = [String: Any]
    typealias ArchivedEvidenceLookup = @Sendable (Evidence.Scope, String, Evidence.SourceRowLocator) throws -> [Data]
    typealias ReceiptSink = @Sendable (Data, Bool) async throws -> Void
    private static let maximumEagerReceiptBytes = 96 * 1_024 * 1_024

    enum Failure: Error, Equatable { case malformedArchive, staleBinding, ambiguousInventory, processingLimit }

    /// Only capture/replay can construct this authority. A caller cannot supply guessed IDs.
    struct ValidatedRow: Sendable {
        // Import authority needs the exact source and validated bare facts, not the provider
        // response/inventory. Those bytes are sealed by the receipt sink before this row escapes.
        private struct Facts: Sendable {
            let scope: Evidence.Scope
            let rowLocator: Evidence.SourceRowLocator
            let metaID: String
            let watchedBitfield: String
            let source: Data
            let sourceSHA256: String
            let watchedVideoIDs: [String]
        }
        private let evidence: Facts
        fileprivate init(_ value: Evidence.Evidence) {
            evidence = Facts(scope: value.scope, rowLocator: value.rowLocator, metaID: value.metaID,
                watchedBitfield: value.watchedBitfield, source: value.source, sourceSHA256: value.sourceSHA256,
                watchedVideoIDs: value.watchedVideoIDs)
        }

        func videoIDs(accountID: String, profileID: UUID, sourceSHA256: String,
                      verifiedStreamingUID: String?, locator: Evidence.SourceRowLocator,
                      metaID: String, bitmap: String) throws -> [String] {
            guard exact(evidence.scope.accountID, accountID), evidence.scope.profileID == profileID,
                  exact(evidence.sourceSHA256, sourceSHA256),
                  optionalExact(evidence.scope.verifiedStreamingUID, verifiedStreamingUID),
                  evidence.rowLocator == locator, exact(evidence.metaID, metaID),
                  exact(evidence.watchedBitfield, bitmap) else { throw Failure.staleBinding }
            return evidence.watchedVideoIDs
        }

        func matches(profileID: UUID, sourceSHA256: String, locator: Evidence.SourceRowLocator) -> Bool {
            evidence.scope.profileID == profileID && exact(evidence.sourceSHA256, sourceSHA256)
                && evidence.rowLocator == locator
        }

        func validateOwnerHistorySource(accountID: String, ownerProfileID: UUID, profileID: UUID,
                                        verifiedUID: String, sourceDocument: Data) throws {
            guard evidence.rowLocator.isOwnerAccount, exact(evidence.scope.accountID, accountID),
                  evidence.scope.ownerProfileID == ownerProfileID, evidence.scope.profileID == profileID,
                  optionalExact(evidence.scope.verifiedStreamingUID, verifiedUID),
                  evidence.source == sourceDocument else { throw Failure.staleBinding }
        }

        func validateSource(accountID: String, ownerProfileID: UUID, document: Data, roster: [UserProfile],
                            ownAccountSources: [VortxLegacyBootstrapMaterial.OwnAccountSource]) throws {
            guard exact(evidence.scope.accountID, accountID), evidence.scope.ownerProfileID == ownerProfileID,
                  let profile = roster.first(where: { $0.id == evidence.scope.profileID }) else { throw Failure.staleBinding }
            if profile.usesOwnAccount {
                guard let source = ownAccountSources.first(where: { $0.profileID == profile.id }),
                      evidence.source == source.sourceDocument,
                      optionalExact(evidence.scope.verifiedStreamingUID, source.verifiedStreamingUID) else { throw Failure.staleBinding }
            } else {
                guard evidence.source == document, evidence.scope.verifiedStreamingUID == nil else { throw Failure.staleBinding }
            }
        }
    }

    struct Pending: Sendable {
        fileprivate let scope: Evidence.Scope
        let profileID: UUID
        let sourceDocument: Data
        let sourceDocumentSHA256: String
        let row: Evidence.SourceRowLocator
        /// Fixed, token-free status. Never include a provider URL or localized network error.
        let reason: String

        var archive: Data {
            get throws {
                var object = sourceHeader(scope: scope, source: sourceDocument, locator: row)
                object["reason"] = reason
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            }
        }
    }

    struct Preparation: Sendable {
        let rows: [ValidatedRow]
        let archives: [Data]
        let unresolved: [Pending]
        var pendingArchives: [Data] {
            get throws {
                var remaining = maximumEagerReceiptBytes
                for receipt in archives {
                    guard receipt.count <= remaining else { throw Failure.processingLimit }
                    remaining -= receipt.count
                }
                return try unresolved.map {
                    let bytes = try $0.archive
                    guard bytes.count <= remaining else { throw Failure.processingLimit }
                    remaining -= bytes.count
                    return bytes
                }
            }
        }
    }

    /// Historical repair deliberately exposes no material-authorizing rows. The host unions the
    /// evidence into its sealed archive and retains every original pending record, including those
    /// now matched by evidence. `unresolved` is a display/retry subset, never a deletion ACK.
    struct HistoricalRetry: Sendable {
        let archives: [Data]
        let unresolved: [Data]
    }

    private struct Candidate: Sendable {
        let scope: Evidence.Scope
        let source: Data
        let locator: Evidence.SourceRowLocator
        let metaID: String
    }

    /// `profileIDs` includes only root-account/shared profiles. Own profiles are supplied solely
    /// through their independently authenticated envelope; retained own slots need no reimport.
    static func prepare(accountID: String, ownerProfileID: UUID, document: Data,
                        profileIDs: [UUID], ownAccountSources: [VortxLegacyBootstrapMaterial.OwnAccountSource] = [],
                        archivedEvidence: [Data] = [], archivedEvidenceLookup: ArchivedEvidenceLookup? = nil,
                        receiptSink: ReceiptSink? = nil,
                        isCurrent: @escaping @Sendable () -> Bool,
                        fetch: Evidence.MetadataFetcher) async throws -> Preparation {
        try Task.checkCancellation()
        guard isCurrent() else { throw Evidence.Failure.admissionRevoked }
        var candidates = [Candidate]()
        let root = try VortxProfileOverlayWitness.decodeObject(json: document)
        let profiles = Set(profileIDs)
        guard profiles.count == profileIDs.count, profiles.contains(ownerProfileID),
              Set(ownAccountSources.map(\.profileID)).count == ownAccountSources.count,
              profiles.isDisjoint(with: ownAccountSources.map(\.profileID)) else { throw Failure.staleBinding }
        let vortx = try object(root, "vortx") ?? [:]
        let ownerScope = try Evidence.Scope(accountID: accountID, profileID: ownerProfileID, ownerProfileID: ownerProfileID)
        if let rows = try array(vortx, "library") {
            try append(rows, scope: ownerScope, source: document,
                       locator: { .authenticatedOwnerLibrary(index: $0) }, to: &candidates)
        } else {
            try append(try array(root, "library") ?? [], scope: ownerScope, source: document,
                       locator: { .authenticatedLegacyRootLibrary(index: $0) }, to: &candidates)
        }
        for (rawID, value) in try object(vortx, "byProfile") ?? [:] {
            guard let id = UUID(uuidString: rawID), let bucket = value as? Object else { throw Failure.malformedArchive }
            if id == ownerProfileID || id == UserProfile.ownerID {
                try append(try array(bucket, "ownerHistory") ?? [], scope: ownerScope, source: document,
                           locator: { .authenticatedOwnerHistory(sourceProfileID: rawID, index: $0) }, to: &candidates)
            }
            guard profiles.contains(id) else { continue }
            let scope = try Evidence.Scope(accountID: accountID, profileID: id, ownerProfileID: ownerProfileID)
            try append(try array(bucket, "library") ?? [], scope: scope, source: document,
                       locator: { .authenticatedProfileLibrary(index: $0) }, to: &candidates)
        }
        for source in ownAccountSources {
            let envelope = try VortxProfileOverlayWitness.decodeObject(json: source.sourceDocument)
            let library = try VortxProfileOverlayWitness.decodeObject(json: bytes(envelope, "libraryResponseBase64"))
            let scope = try Evidence.Scope(accountID: accountID, profileID: source.profileID,
                                           verifiedStreamingUID: source.verifiedStreamingUID, ownerProfileID: ownerProfileID)
            try append(try array(library, "result") ?? [], scope: scope, source: source.sourceDocument,
                       ownLibrary: true, locator: { .ownAccountLibraryResponse(index: $0) }, to: &candidates)
            let overlay = try VortxProfileOverlayWitness.decodeObject(json: bytes(envelope, "profileOverlayBase64"))
            let ownVortx = try object(overlay, "vortx") ?? [:]
            let buckets = try object(ownVortx, "byProfile") ?? [:]
            if let bucket = try object(buckets, source.profileID.uuidString) {
                try append(try array(bucket, "library") ?? [], scope: scope, source: source.sourceDocument,
                           locator: { .ownAccountProfileLibrary(index: $0) }, to: &candidates)
                try append(try array(bucket, "ownerHistory") ?? [], scope: scope, source: source.sourceDocument,
                           locator: { .ownAccountOwnerHistory(index: $0) }, to: &candidates)
            }
        }
        return try await prepareCandidates(candidates, accountID: accountID, ownerProfileID: ownerProfileID,
            archivedEvidence: archivedEvidence, archivedEvidenceLookup: archivedEvidenceLookup,
            receiptSink: receiptSink, isCurrent: isCurrent, fetch: fetch)
    }

    /// Same metadata capture/replay worker as legacy preparation, but an explicit owner-source
    /// locator/binding. No OwnAccountSource, overlay attribution or baseline import is created.
    static func prepareOwnerHistory(accountID: String, ownerProfileID: UUID, profileID: UUID,
                                    verifiedUID: String, sourceDocument: Data,
                                    archivedEvidence: [Data] = [], receiptSink: ReceiptSink? = nil,
                                    isCurrent: @escaping @Sendable () -> Bool,
                                    fetch: Evidence.MetadataFetcher) async throws -> Preparation {
        let candidates = try ownerHistoryCandidates(accountID: accountID, ownerProfileID: ownerProfileID,
            profileID: profileID, verifiedUID: verifiedUID, sourceDocument: sourceDocument)
        return try await prepareCandidates(candidates, accountID: accountID, ownerProfileID: ownerProfileID,
            archivedEvidence: archivedEvidence, archivedEvidenceLookup: nil, receiptSink: receiptSink,
            isCurrent: isCurrent, fetch: fetch)
    }

    /// Complete, offline metadata replay for final checkpoint/open validation. Missing, extra,
    /// duplicate and retargeted receipts fail; no fetch, cache or decoded-ID shortcut is available.
    static func replayOwnerHistory(accountID: String, ownerProfileID: UUID, profileID: UUID,
                                   verifiedUID: String, sourceDocument: Data, archives: [Data],
                                   isCurrent: @escaping @Sendable () -> Bool) throws -> [ValidatedRow] {
        try requireAdmission(isCurrent)
        let candidates = try ownerHistoryCandidates(accountID: accountID, ownerProfileID: ownerProfileID,
            profileID: profileID, verifiedUID: verifiedUID, sourceDocument: sourceDocument)
        guard archives.count == candidates.count else { throw Failure.malformedArchive }
        var remaining = maximumEagerReceiptBytes
        for bytes in archives {
            guard bytes.count <= remaining else { throw Failure.processingLimit }
            remaining -= bytes.count
        }
        let retained = try archives.map(decodeArchive)
        var rows: [ValidatedRow] = []
        for candidate in candidates {
            try requireAdmission(isCurrent)
            let matches = retained.filter { sameScope($0.scope, candidate.scope)
                && $0.source == candidate.source && $0.locator == candidate.locator }
            guard matches.count == 1, let archive = matches.first else { throw Failure.staleBinding }
            rows.append(ValidatedRow(try Evidence.replay(scope: candidate.scope, source: candidate.source,
                rowLocator: candidate.locator, addon: archive.addon, metadata: archive.metadata, isCurrent: isCurrent)))
        }
        try requireAdmission(isCurrent)
        return rows
    }

    private static func ownerHistoryCandidates(accountID: String, ownerProfileID: UUID, profileID: UUID,
                                               verifiedUID: String, sourceDocument: Data) throws -> [Candidate] {
        let scope = try Evidence.Scope(accountID: accountID, profileID: profileID,
                                       verifiedStreamingUID: verifiedUID, ownerProfileID: ownerProfileID)
        try Evidence.validateOwnerSource(scope: scope, source: sourceDocument)
        let library = try VortxProfileOverlayWitness.decodeObject(
            json: Evidence.ownerHistoryLibraryProjection(scope: scope, source: sourceDocument))
        var candidates: [Candidate] = []
        guard let rows = try array(library, "result") else { throw Failure.malformedArchive }
        for (index, raw) in rows.enumerated() {
            // Discovery selects only well-shaped bitmap-series candidates. The actual pure row
            // converter separately holds malformed/unsupported rows, preserving their original
            // source in a pending result. Existing shared/Own append validation stays unchanged.
            guard index < Evidence.maximumSourceRows, let row = raw as? Object,
                  let state = row["state"] as? Object, let bitmap = state["watched"] as? String,
                  !bitmap.isEmpty, row["type"] as? String == "series",
                  let meta = row["_id"] as? String, !meta.isEmpty else { continue }
            candidates.append(.init(scope: scope, source: sourceDocument,
                locator: .ownerAccountLibraryResponse(index: index), metaID: meta))
        }
        guard candidates.count <= 10_000 else { throw Failure.malformedArchive }
        for candidate in candidates {
            try Evidence.validateSource(scope: scope, source: sourceDocument, rowLocator: candidate.locator)
        }
        return candidates
    }

    private static func prepareCandidates(_ candidates: [Candidate], accountID: String, ownerProfileID: UUID,
                                          archivedEvidence: [Data], archivedEvidenceLookup: ArchivedEvidenceLookup?,
                                          receiptSink: ReceiptSink?, isCurrent: @escaping @Sendable () -> Bool,
                                          fetch: Evidence.MetadataFetcher) async throws -> Preparation {
        guard candidates.count <= 10_000, archivedEvidence.count <= 10_000 else { throw Failure.malformedArchive }
        guard archivedEvidence.isEmpty || archivedEvidenceLookup == nil else { throw Failure.malformedArchive }
        var rows = [ValidatedRow](), archives = [Data](), pending = [Pending]()
        var remainingOutput = maximumEagerReceiptBytes
        func retainReceipt(_ bytes: Data, pending isPending: Bool) async throws {
            try requireAdmission(isCurrent)
            if let receiptSink { try await receiptSink(bytes, isPending) }
            else if !isPending {
                guard bytes.count <= remainingOutput else { throw Failure.processingLimit }
                remainingOutput -= bytes.count
                archives.append(bytes)
            }
            try requireAdmission(isCurrent)
        }
        // Invalid sidecars are not converted to network misses: a corrupt authenticated archive
        // must remain a visible reconciliation failure. Unrelated retained source tuples are okay.
        var remainingInput = maximumEagerReceiptBytes
        for receipt in archivedEvidence {
            guard receipt.count <= remainingInput else { throw Failure.processingLimit }
            remainingInput -= receipt.count
        }
        let retained = try archivedEvidence.map(decodeArchive)
        guard retained.allSatisfy({ exact($0.scope.accountID, accountID) && $0.scope.ownerProfileID == ownerProfileID }) else {
            throw Failure.staleBinding
        }
        for candidate in candidates {
            try Task.checkCancellation()
            guard isCurrent() else { throw Evidence.Failure.admissionRevoked }
            try Evidence.validateSource(scope: candidate.scope, source: candidate.source, rowLocator: candidate.locator)
            let digest = sha256(candidate.source)
            let matches: [Archive]
            if let archivedEvidenceLookup {
                matches = try archivedEvidenceLookup(candidate.scope, digest, candidate.locator).map(decodeArchive)
            } else {
                matches = retained.filter { sameScope($0.scope, candidate.scope)
                    && exact($0.sourceSHA256, digest) && $0.locator == candidate.locator }
            }
            guard matches.count <= 1 else { throw Failure.malformedArchive }
            if let archive = matches.first {
                guard sameScope(archive.scope, candidate.scope), archive.source == candidate.source,
                      exact(archive.sourceSHA256, digest), archive.locator == candidate.locator else { throw Failure.staleBinding }
                let replayed = try Evidence.replay(scope: candidate.scope, source: candidate.source,
                    rowLocator: candidate.locator, addon: archive.addon, metadata: archive.metadata, isCurrent: isCurrent)
                try Task.checkCancellation()
                try await retainReceipt(archive.bytes, pending: false)
                rows.append(ValidatedRow(replayed))
                continue
            }
            switch try await capture(candidate, isCurrent: isCurrent, fetch: fetch) {
            case .accepted(let accepted):
                try await retainReceipt(encodeArchive(accepted), pending: false)
                rows.append(ValidatedRow(accepted))
            case .pending(let reason):
                let unresolved = Pending(scope: candidate.scope, profileID: candidate.scope.profileID, sourceDocument: candidate.source,
                    sourceDocumentSHA256: digest, row: candidate.locator, reason: reason)
                if receiptSink != nil { try await retainReceipt(unresolved.archive, pending: true) }
                pending.append(unresolved)
            }
        }
        guard isCurrent() else { throw Evidence.Failure.admissionRevoked }
        try Task.checkCancellation()
        return Preparation(rows: rows, archives: archives, unresolved: pending)
    }

    /// Retries only snapshots already retained by the authenticated, same-account host archive.
    /// In particular, a historical own UID comes from that sealed pending tuple, never from the
    /// currently selected credential or active native slot. The original snapshot may no longer
    /// be present in the current account document. This API cannot authorize current material.
    static func retryArchivedPending(_ archives: [Data], accountID: String, ownerProfileID: UUID,
                                     archivedEvidence: [Data] = [], isCurrent: @escaping @Sendable () -> Bool,
                                     fetch: Evidence.MetadataFetcher) async throws -> HistoricalRetry {
        try requireAdmission(isCurrent)
        _ = try Evidence.Scope(accountID: accountID, profileID: ownerProfileID, ownerProfileID: ownerProfileID)
        guard archives.count <= 10_000, archivedEvidence.count <= 10_000 else { throw Failure.malformedArchive }
        // Compatibility API only; production sends one tuple. Bound both eager input arrays
        // before decoding any receipt, and bound new metadata output before accumulating it.
        var remainingInput = maximumEagerReceiptBytes
        for records in [archives, archivedEvidence] {
            for bytes in records {
                guard bytes.count <= remainingInput else { throw Failure.processingLimit }
                remainingInput -= bytes.count
            }
        }
        let pending = try archives.map { try decodePending($0, accountID: accountID, ownerProfileID: ownerProfileID) }
        let retained = try archivedEvidence.map(decodeArchive)
        guard retained.allSatisfy({ exact($0.scope.accountID, accountID) && $0.scope.ownerProfileID == ownerProfileID }) else {
            throw Failure.staleBinding
        }
        var evidence = [Data](), unresolved = [Data]()
        var remainingOutput = maximumEagerReceiptBytes
        func admitOutput(_ bytes: Data) throws {
            guard bytes.count <= remainingOutput else { throw Failure.processingLimit }
            remainingOutput -= bytes.count
        }
        var seenPending = Set<Data>(), seenEvidence = Set<Data>()
        for (original, candidate) in zip(archives, pending) where seenPending.insert(original).inserted {
            try requireAdmission(isCurrent)
            let digest = sha256(candidate.source)
            let matches = retained.filter { sameScope($0.scope, candidate.scope)
                && exact($0.sourceSHA256, digest) && $0.locator == candidate.locator }
            guard matches.count <= 1 else { throw Failure.malformedArchive }
            if let retained = matches.first {
                guard sameScope(retained.scope, candidate.scope), retained.source == candidate.source else { throw Failure.staleBinding }
                _ = try Evidence.replay(scope: candidate.scope, source: candidate.source, rowLocator: candidate.locator,
                    addon: retained.addon, metadata: retained.metadata, isCurrent: isCurrent)
                try requireAdmission(isCurrent)
                if !seenEvidence.contains(retained.bytes) {
                    try admitOutput(retained.bytes); seenEvidence.insert(retained.bytes); evidence.append(retained.bytes)
                }
                continue
            }
            switch try await capture(candidate, isCurrent: isCurrent, fetch: fetch) {
            case .accepted(let captured):
                let archive = try encodeArchive(captured)
                try requireAdmission(isCurrent)
                if !seenEvidence.contains(archive) {
                    try admitOutput(archive); seenEvidence.insert(archive); evidence.append(archive)
                }
            case .pending:
                // Preserve even the old reason and JSON spelling; a failed retry never rewrites
                // the original attested tuple or manufactures an acknowledgement for it.
                try admitOutput(original)
                unresolved.append(original)
            }
        }
        try requireAdmission(isCurrent)
        return HistoricalRetry(archives: evidence, unresolved: unresolved)
    }

    private enum CaptureResult { case accepted(Evidence.Evidence), pending(String) }

    private static func capture(_ candidate: Candidate, isCurrent: @escaping @Sendable () -> Bool,
                                fetch: Evidence.MetadataFetcher) async throws -> CaptureResult {
        try requireAdmission(isCurrent)
        var accepted: Evidence.Evidence?
        var ambiguous = false
        let addons: [Evidence.AuthorizedAddon]
        do {
            addons = try Evidence.originalAddons(source: candidate.source, rowLocator: candidate.locator)
                .filter { try supports($0, metaID: candidate.metaID) }
        } catch {
            try requireAdmission(isCurrent)
            guard candidate.locator.isOwnerAccount else { throw error }
            // The immutable owner source remains recoverable when its original registry cannot
            // authorize an inventory request. Never substitute the current registry. Reuse the
            // existing pending reason so offline validation and retry retain the exact source.
            return .pending("episode_inventory_unavailable")
        }
        for addon in addons {
            do {
                let evidence = try await Evidence.capture(scope: candidate.scope, source: candidate.source,
                    rowLocator: candidate.locator, addon: addon, isCurrent: isCurrent, fetch: fetch)
                try requireAdmission(isCurrent)
                if let first = accepted {
                    if !exactInventory(evidence.inventory, first.inventory) { ambiguous = true }
                } else { accepted = evidence }
            } catch {
                try requireAdmission(isCurrent)
                // A provider failure never establishes an empty inventory or an unwatch.
            }
        }
        try requireAdmission(isCurrent)
        guard let accepted else { return .pending("episode_inventory_unavailable") }
        guard !ambiguous else {
            return .pending("episode_inventory_ambiguous")
        }
        try requireAdmission(isCurrent)
        return .accepted(accepted)
    }

    private static func requireAdmission(_ isCurrent: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw Evidence.Failure.admissionRevoked }
        try Task.checkCancellation()
    }

    /// Cold open makes no request. The caller still provides the currently authenticated account,
    /// profile, exact source and UID. Archived provenance cannot grant a new account binding.
    static func replay(_ archive: Data, accountID: String, profileID: UUID, ownerProfileID: UUID,
                       verifiedStreamingUID: String?, sourceDocument: Data,
                       isCurrent: @escaping @Sendable () -> Bool) throws -> ValidatedRow {
        try Task.checkCancellation()
        let retained = try decodeArchive(archive)
        let scope = try Evidence.Scope(accountID: accountID, profileID: profileID,
                                       verifiedStreamingUID: verifiedStreamingUID, ownerProfileID: ownerProfileID)
        guard sameScope(retained.scope, scope), retained.source == sourceDocument else { throw Failure.staleBinding }
        let row = ValidatedRow(try Evidence.replay(scope: scope, source: sourceDocument, rowLocator: retained.locator,
                                                 addon: retained.addon, metadata: retained.metadata, isCurrent: isCurrent))
        try Task.checkCancellation()
        return row
    }

    /// A sealed host archive can validate historical tuples without authorizing their reuse for a
    /// different current source. `prepare`/`replay` still require the complete current binding.
    static func validateArchivedEvidence(_ archive: Data, accountID: String, ownerProfileID: UUID) throws {
        let retained = try decodeArchive(archive)
        guard exact(retained.scope.accountID, accountID), retained.scope.ownerProfileID == ownerProfileID else { throw Failure.staleBinding }
    }

    static func validateArchivedPending(_ archive: Data, accountID: String, ownerProfileID: UUID) throws {
        _ = try decodePending(archive, accountID: accountID, ownerProfileID: ownerProfileID)
    }

    /// Denial-only title attribution from the same strict pending decoder. It does not
    /// authorize replay, current UID binding, alias installation, or import completion.
    static func pendingAttribution(_ archive: Data, accountID: String, ownerProfileID: UUID)
        throws -> (profileID: UUID, metaID: String) {
        let retained = try decodePending(archive, accountID: accountID, ownerProfileID: ownerProfileID)
        return (retained.scope.profileID, retained.metaID)
    }

    private static func decodePending(_ archive: Data, accountID: String, ownerProfileID: UUID) throws -> Candidate {
        try Task.checkCancellation()
        let value = try VortxProfileOverlayWitness.decodeObject(json: archive)
        let required: Set<String> = ["schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "reason"]
        guard Set(value.keys) == required || Set(value.keys) == required.union(["verifiedStreamingUid"]),
              let version = value["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let account = value["accountId"] as? String, exact(account, accountID),
              let profileRaw = value["profileId"] as? String, let profile = UUID(uuidString: profileRaw), profile.uuidString == profileRaw,
              value["ownerProfileId"] as? String == ownerProfileID.uuidString,
              let digest = value["sourceDocumentSha256"] as? String,
              let row = value["row"] as? Object, let reason = value["reason"] as? String,
              ["episode_inventory_unavailable", "episode_inventory_ambiguous"].contains(reason),
              value["verifiedStreamingUid"] == nil || value["verifiedStreamingUid"] is String else { throw Failure.malformedArchive }
        let source = try bytes(value, "sourceDocumentBase64")
        guard exact(digest, sha256(source)) else { throw Failure.malformedArchive }
        let scope = try Evidence.Scope(accountID: account, profileID: profile,
            verifiedStreamingUID: value["verifiedStreamingUid"] as? String, ownerProfileID: ownerProfileID)
        let locator = try decodeLocator(row)
        let metaID = try Evidence.sourceMetaID(scope: scope, source: source, rowLocator: locator)
        return Candidate(scope: scope, source: source, locator: locator, metaID: metaID)
    }

    private static func append(_ rows: [Any], scope: Evidence.Scope, source: Data,
                               ownLibrary: Bool = false,
                               locator: (Int) -> Evidence.SourceRowLocator, to result: inout [Candidate]) throws {
        for (index, raw) in rows.enumerated() {
            guard let row = raw as? Object else { throw Failure.malformedArchive }
            let state = ownLibrary ? try object(row, "state") ?? [:] : row
            guard let rawBitmap = state["watched"], !(rawBitmap is NSNull) else { continue }
            guard let bitmap = rawBitmap as? String else { throw Failure.malformedArchive }
            if bitmap.isEmpty { continue }
            guard index < Evidence.maximumSourceRows else { throw Failure.malformedArchive }
            guard let meta = row[ownLibrary ? "_id" : "id"] as? String, !meta.isEmpty,
                  row["type"] as? String == "series" else { throw Failure.malformedArchive }
            result.append(.init(scope: scope, source: source, locator: locator(index), metaID: meta))
        }
    }

    private static func supports(_ addon: Evidence.AuthorizedAddon, metaID: String) throws -> Bool {
        let manifest = try VortxProfileOverlayWitness.decodeObject(json: addon.manifest)
        func typesMatch(_ value: Any?) -> Bool { (value as? [String])?.contains("series") == true }
        func prefixMatches(_ value: Any?) -> Bool {
            guard let value else { return true }
            guard let prefixes = value as? [String] else { return false }
            return prefixes.contains { prefix in Array(metaID.utf8).starts(with: prefix.utf8) }
        }
        guard let resources = manifest["resources"] as? [Any] else { return false }
        return resources.contains { value in
            if let resource = value as? String {
                return resource == "meta" && typesMatch(manifest["types"]) && prefixMatches(manifest["idPrefixes"])
            }
            guard let resource = value as? Object, resource["name"] as? String == "meta" else { return false }
            return typesMatch(resource["types"] ?? manifest["types"])
                && prefixMatches(resource["idPrefixes"] ?? manifest["idPrefixes"])
        }
    }

    private struct Archive {
        let bytes: Data
        let scope: Evidence.Scope
        let source: Data
        let sourceSHA256: String
        let locator: Evidence.SourceRowLocator
        let addon: Evidence.AuthorizedAddon
        let metadata: Data
    }

    private static func encodeArchive(_ value: Evidence.Evidence) throws -> Data {
        var result = sourceHeader(scope: value.scope, source: value.source, locator: value.rowLocator)
        result["addon"] = ["transportUrl": value.addon.transportURL, "manifestBase64": value.addon.manifest.base64EncodedString()]
        result["metadataResponseBase64"] = value.metadata.base64EncodedString()
        result["metadataResponseSha256"] = value.metadataSHA256
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sourceHeader(scope: Evidence.Scope, source: Data, locator: Evidence.SourceRowLocator) -> Object {
        var result: Object = ["schemaVersion": 1, "accountId": scope.accountID,
            "profileId": scope.profileID.uuidString, "ownerProfileId": scope.ownerProfileID.uuidString,
            "sourceDocumentBase64": source.base64EncodedString(), "sourceDocumentSha256": sha256(source), "row": encodeLocator(locator)]
        if let uid = scope.verifiedStreamingUID { result["verifiedStreamingUid"] = uid }
        return result
    }

    private static func decodeArchive(_ data: Data) throws -> Archive {
        let object = try VortxProfileOverlayWitness.decodeObject(json: data)
        let required: Set<String> = ["schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64",
            "sourceDocumentSha256", "row", "addon", "metadataResponseBase64", "metadataResponseSha256"]
        guard Set(object.keys) == required || Set(object.keys) == required.union(["verifiedStreamingUid"]),
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let account = object["accountId"] as? String, let profileRaw = object["profileId"] as? String,
              let profile = UUID(uuidString: profileRaw), profile.uuidString == profileRaw,
              let ownerRaw = object["ownerProfileId"] as? String, let owner = UUID(uuidString: ownerRaw), owner.uuidString == ownerRaw,
              let sourceSHA = object["sourceDocumentSha256"] as? String,
              let metadataSHA = object["metadataResponseSha256"] as? String,
              let row = object["row"] as? Object, let addon = object["addon"] as? Object,
              Set(addon.keys) == ["transportUrl", "manifestBase64"], let url = addon["transportUrl"] as? String,
              object["verifiedStreamingUid"] == nil || object["verifiedStreamingUid"] is String else { throw Failure.malformedArchive }
        let source = try bytes(object, "sourceDocumentBase64"), metadata = try bytes(object, "metadataResponseBase64")
        guard exact(sha256(source), sourceSHA), exact(sha256(metadata), metadataSHA) else { throw Failure.malformedArchive }
        let scope = try Evidence.Scope(accountID: account, profileID: profile,
                                       verifiedStreamingUID: object["verifiedStreamingUid"] as? String, ownerProfileID: owner)
        let locator = try decodeLocator(row)
        let descriptor = try Evidence.AuthorizedAddon(transportURL: url, manifest: bytes(addon, "manifestBase64"))
        _ = try Evidence.replay(scope: scope, source: source, rowLocator: locator, addon: descriptor, metadata: metadata, isCurrent: { true })
        return Archive(bytes: data, scope: scope, source: source, sourceSHA256: sourceSHA,
                       locator: locator, addon: descriptor, metadata: metadata)
    }

    static func encodeLocator(_ row: Evidence.SourceRowLocator) -> Object {
        switch row {
        case .authenticatedOwnerLibrary(let index): return ["kind": "owner_library", "index": index]
        case .authenticatedLegacyRootLibrary(let index): return ["kind": "legacy_root_library", "index": index]
        case .authenticatedProfileLibrary(let index): return ["kind": "profile_library", "index": index]
        case .authenticatedOwnerHistory(let sourceProfileID, let index): return ["kind": "owner_history", "index": index, "sourceProfileId": sourceProfileID]
        case .ownAccountLibraryResponse(let index): return ["kind": "own_library", "index": index]
        case .ownerAccountLibraryResponse(let index): return ["kind": "owner_account_library", "index": index]
        case .ownAccountProfileLibrary(let index): return ["kind": "own_profile_library", "index": index]
        case .ownAccountOwnerHistory(let index): return ["kind": "own_owner_history", "index": index]
        }
    }

    private static func decodeLocator(_ row: Object) throws -> Evidence.SourceRowLocator {
        guard let kind = row["kind"] as? String, let number = row["index"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
              number.doubleValue < Double(Evidence.maximumSourceRows), number.doubleValue == Double(number.intValue),
              Set(row.keys) == (kind == "owner_history" ? ["kind", "index", "sourceProfileId"] : ["kind", "index"]) else { throw Failure.malformedArchive }
        let index = number.intValue
        switch kind {
        case "owner_library": return .authenticatedOwnerLibrary(index: index)
        case "legacy_root_library": return .authenticatedLegacyRootLibrary(index: index)
        case "profile_library": return .authenticatedProfileLibrary(index: index)
        case "owner_history":
            guard let source = row["sourceProfileId"] as? String, UUID(uuidString: source) != nil else { throw Failure.malformedArchive }
            return .authenticatedOwnerHistory(sourceProfileID: source, index: index)
        case "own_library": return .ownAccountLibraryResponse(index: index)
        case "owner_account_library": return .ownerAccountLibraryResponse(index: index)
        case "own_profile_library": return .ownAccountProfileLibrary(index: index)
        case "own_owner_history": return .ownAccountOwnerHistory(index: index)
        default: throw Failure.malformedArchive
        }
    }

    private static func object(_ value: Object, _ key: String) throws -> Object? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let result = raw as? Object else { throw Failure.malformedArchive }; return result
    }
    private static func array(_ value: Object, _ key: String) throws -> [Any]? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let result = raw as? [Any] else { throw Failure.malformedArchive }; return result
    }
    private static func bytes(_ value: Object, _ key: String) throws -> Data {
        guard let text = value[key] as? String, let data = Data(base64Encoded: text),
              data.base64EncodedString() == text else { throw Failure.malformedArchive }; return data
    }
    private static func sameScope(_ left: Evidence.Scope, _ right: Evidence.Scope) -> Bool {
        exact(left.accountID, right.accountID) && left.profileID == right.profileID && left.ownerProfileID == right.ownerProfileID
            && optionalExact(left.verifiedStreamingUID, right.verifiedStreamingUID)
    }
    private static func exactInventory(_ left: [LegacyWatchedBitfieldEpisode], _ right: [LegacyWatchedBitfieldEpisode]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { a, b in
            exact(a.id, b.id) && a.season == b.season && a.episode == b.episode && a.releasedMs == b.releasedMs
        }
    }
    private static func exact(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    private static func optionalExact(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) { case (nil, nil): return true; case let (.some(a), .some(b)): return exact(a, b); default: return false }
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
