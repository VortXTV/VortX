import Foundation
import CryptoKit

/// Recovery-only source proposal. Immutable source retention and offline replay, NOT a native
/// receipt verifier, durable checkpoint or peer capability. The production caller must bind the
/// returned replay evidence to the native canonicalizer before it can create a source-set witness.
struct VortxNativeOwnerHistoryJournal: Sendable {
    enum Failure: Error, Equatable {
        case malformed, excessive, sourceConflict, sourceSetMismatch, receiptMismatch
    }
    static let kind = "vortx.owner-history.journal/1"
    // Safety bound for parsing local material; not permission to exceed account export limits.
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumSources = 128

    struct Entry: Sendable {
        let archive: Data
        let receipt: VortxJSON
        let capturedBinding: VortxJSON
        let profileID: UUID
        let verifiedUID: String
        fileprivate init(archive: Data, receipt: VortxJSON, capturedBinding: VortxJSON,
                         profileID: UUID, verifiedUID: String) {
            self.archive = archive; self.receipt = receipt; self.capturedBinding = capturedBinding
            self.profileID = profileID; self.verifiedUID = verifiedUID
        }
    }

    /// All complete raw archives have been independently decoded under the supplied authority.
    /// Evidence and native receipts still require native typed canonicalization and binding
    /// validation. This type deliberately supplies no `isValid`, `trusted` or ACK property.
    struct ReplayedSources: Sendable {
        let evidenceBySourceID: [String: Data]
        let receiptBySourceID: [String: VortxJSON]
        let bindingBySourceID: [String: VortxJSON]
        fileprivate init(evidence: [String: Data], receipts: [String: VortxJSON],
                         bindings: [String: VortxJSON]) {
            evidenceBySourceID = evidence; receiptBySourceID = receipts; bindingBySourceID = bindings
        }
    }

    /// Full raw/native correspondence only. Session/cache ownership is deliberately not implied:
    /// the engine must bind this value to its own immutable source-set witness at open/install.
    /// Construction is limited to the full replay + native canonicalization method below.
    struct CrossValidatedSources: Sendable {
        let sourceIDs: Set<String>
        let nativeOwnerHistoryBytes: Data
        let journalBytes: Data
        private let authority: any VortxMutationAuthority
        fileprivate init(sourceIDs: Set<String>, nativeOwnerHistoryBytes: Data, journalBytes: Data,
                         authority: any VortxMutationAuthority) {
            self.sourceIDs = sourceIDs; self.nativeOwnerHistoryBytes = nativeOwnerHistoryBytes
            self.journalBytes = journalBytes; self.authority = authority
        }
        /// Cheap original-authority check only. The caller must additionally validate the
        /// engine-issued instance/mutation/source-set witness and current facade queue head.
        func withSourceAuthority(_ operation: () throws -> Void) throws {
            try authority.withActive(operation)
        }
    }

    let scope: String
    let ownerProfileID: UUID
    private(set) var entries: [String: Entry]

    init(scope: String, ownerProfileID: UUID) throws {
        try VortxAccountScope(account: scope, ownerProfileID: ownerProfileID.uuidString).validate()
        self.scope = scope; self.ownerProfileID = ownerProfileID; entries = [:]
    }

    /// Decodes only the journal envelope; never rewrites its immutable archive payloads.
    /// Every key is strict and duplicate-safe through the existing exact JSON inspector.
    init(bytes: Data, scope: String, ownerProfileID: UUID) throws {
        guard bytes.count <= Self.maximumBytes else { throw Failure.excessive }
        _ = try VortxProfileOverlayWitness.decodeObject(json: bytes)
        let raw = try JSONDecoder().decode(VortxJSON.self, from: bytes)
        let fields = try Self.object(raw)
        guard Set(fields.keys) == ["kind", "schemaVersion", "scope", "ownerProfileId", "sources"],
              fields["kind"] == .string(Self.kind),
              try fields["schemaVersion"]?.decode(Int.self) == 1,
              Self.sameText(fields["scope"], scope),
              Self.sameText(fields["ownerProfileId"], ownerProfileID.uuidString),
              let sourceObject = fields["sources"] else { throw Failure.malformed }
        let sources = try Self.object(sourceObject)
        guard sources.count <= Self.maximumSources else { throw Failure.excessive }
        var decoded: [String: Entry] = [:]
        var totalArchiveBytes = 0
        for (id, value) in sources {
            guard Self.digestText(id) else { throw Failure.malformed }
            let entry = try Self.object(value)
            guard Set(entry.keys) == ["archiveBase64", "receipt", "capturedBinding", "profileId", "verifiedStreamingUid"],
                  case .string(let encoded) = entry["archiveBase64"],
                  let archive = Data(base64Encoded: encoded), archive.base64EncodedString() == encoded,
                  case .string(let profileText) = entry["profileId"],
                  let profile = UUID(uuidString: profileText), profile.uuidString == profileText,
                  case .string(let uid) = entry["verifiedStreamingUid"],
                  !uid.isEmpty, uid.utf8.count <= 1024,
                  let receipt = entry["receipt"], let binding = entry["capturedBinding"] else { throw Failure.malformed }
            guard archive.count <= Self.maximumBytes - totalArchiveBytes else { throw Failure.excessive }
            totalArchiveBytes += archive.count
            try Self.validateReceiptShape(receipt, id: id, archive: archive)
            _ = try Self.object(binding)
            decoded[id] = .init(archive: archive, receipt: receipt, capturedBinding: binding,
                                profileID: profile, verifiedUID: uid)
        }
        try self.init(scope: scope, ownerProfileID: ownerProfileID)
        entries = decoded
    }

    /// Keeps all previous entries, including inactive/deleted/rebound profiles. Identical source
    /// IDs with any changed byte, receipt or original binding reject the entire candidate.
    func retaining(_ prepared: VortxNativeOwnerHistoryPreparation.Prepared,
                   nativeReceipt: VortxJSON, capturedBinding: VortxJSON) throws -> Self {
        guard Data(prepared.frame.scope.utf8) == Data(scope.utf8),
              prepared.frame.ownerProfileID == ownerProfileID,
              case .string(let id) = nativeReceipt["sourceId"] else { throw Failure.malformed }
        try Self.validateReceiptShape(nativeReceipt, id: id, archive: prepared.archive)
        let evidence = try JSONDecoder().decode(VortxJSON.self, from: prepared.evidence)
        guard Self.sameText(nativeReceipt["sourceDocumentSha256"], Self.digest(prepared.frame.sourceDocument)),
              Self.exact(nativeReceipt["sourceDocumentSha256"], evidence["sourceDocumentSha256"]),
              Self.exact(nativeReceipt["sourceArchiveSha256"], evidence["sourceArchiveSha256"]) else {
            throw Failure.receiptMismatch
        }
        _ = try Self.object(capturedBinding)
        let incoming = Entry(archive: prepared.archive, receipt: nativeReceipt, capturedBinding: capturedBinding,
                             profileID: prepared.frame.profileID, verifiedUID: prepared.frame.verifiedUID)
        var next = self
        if let old = entries[id], !Self.sameEntry(old, incoming) { throw Failure.sourceConflict }
        next.entries[id] = incoming
        guard next.entries.count <= Self.maximumSources else { throw Failure.excessive }
        _ = try next.encoded() // Preflight local parser budget; account budget is a separate real gate.
        return next
    }

    func joining(_ peer: Self) throws -> Self {
        guard Data(peer.scope.utf8) == Data(scope.utf8), peer.ownerProfileID == ownerProfileID else {
            throw Failure.sourceConflict
        }
        var next = self
        for (id, entry) in peer.entries {
            if let old = next.entries[id], !Self.sameEntry(old, entry) { throw Failure.sourceConflict }
            next.entries[id] = entry
        }
        guard next.entries.count <= Self.maximumSources else { throw Failure.excessive }
        _ = try next.encoded()
        return next
    }

    /// Run only when opening/importing/merging a changed immutable source set. This deliberately
    /// does not belong in ordinary progress, render, resume, query or native-control paths.
    func replayAll(expectedSourceIDs: Set<String>, authority: any VortxMutationAuthority) throws -> ReplayedSources {
        guard expectedSourceIDs == Set(entries.keys) else { throw Failure.sourceSetMismatch }
        try Task.checkCancellation()
        try authority.withActive {}
        var evidence: [String: Data] = [:], receipts: [String: VortxJSON] = [:], bindings: [String: VortxJSON] = [:]
        for id in entries.keys.sorted() {
            let entry = entries[id]!
            let replay = try VortxNativeOwnerHistoryPreparation.replay(archive: entry.archive, scope: scope,
                ownerProfileID: ownerProfileID, profileID: entry.profileID, verifiedUID: entry.verifiedUID,
                authority: authority)
            let typed = try JSONDecoder().decode(VortxJSON.self, from: replay.evidence)
            guard Self.exact(typed["sourceDocumentSha256"], entry.receipt["sourceDocumentSha256"]),
                  Self.exact(typed["sourceArchiveSha256"], entry.receipt["sourceArchiveSha256"]) else {
                throw Failure.receiptMismatch
            }
            evidence[id] = replay.evidence; receipts[id] = entry.receipt; bindings[id] = entry.capturedBinding
        }
        try authority.withActive {}
        try Task.checkCancellation()
        return .init(evidence: evidence, receipts: receipts, bindings: bindings)
    }

    /// Called by the real engine full-validation callback AFTER native schema/binding validation,
    /// under the original authenticated local/peer envelope authority. All retained sources count,
    /// including deleted/inactive/rebound profiles. No orphan or missing sidecar is tolerated.
    func crossValidate(native: VortxJSON, authority: any VortxMutationAuthority,
                       canonicalizer: VortxNativeOwnerHistoryCanonicalizer) throws -> CrossValidatedSources {
        try authority.withActive {}
        guard Self.sameText(native["scope"], scope),
              Self.sameText(native["ownerProfileId"], ownerProfileID.uuidString),
              try native["schemaVersion"]?.decode(Int.self) == 6,
              let history = native["ownerHistory"] else { throw Failure.sourceSetMismatch }
        let historyFields = try Self.object(history)
        guard Set(historyFields.keys) == ["schemaVersion", "capability", "sources", "attestations"],
              try historyFields["schemaVersion"]?.decode(Int.self) == 1,
              Self.sameText(historyFields["capability"], "vortx.owner-history-fallback/1"),
              let sourceCarrier = historyFields["sources"], let proofs = historyFields["attestations"] else {
            throw Failure.malformed
        }
        let sourceFields = try Self.object(sourceCarrier)
        guard Set(sourceFields.keys) == ["sources"], let rawSources = sourceFields["sources"] else {
            throw Failure.malformed
        }
        let sources = try Self.object(rawSources), attestations = try Self.object(proofs)
        guard !sources.isEmpty, Set(sources.keys) == Set(attestations.keys) else {
            throw Failure.sourceSetMismatch
        }
        let replayed = try replayAll(expectedSourceIDs: Set(sources.keys), authority: authority)
        for id in sources.keys.sorted() {
            try Task.checkCancellation()
            let attestation = try Self.object(attestations[id]!)
            guard Set(attestation.keys) == ["binding", "receipt"],
                  Self.exact(attestation["binding"], replayed.bindingBySourceID[id]),
                  Self.exact(attestation["receipt"], replayed.receiptBySourceID[id]) else {
                throw Failure.receiptMismatch
            }
            // Both sides go through actual Rust serde and its native receipt implementation.
            // This rejects an altered interpretation even with unchanged archive/digest text.
            let rawReplay = try canonicalizer.canonicalize(replayed.evidenceBySourceID[id]!)
            let nativeSource = try canonicalizer.canonicalize(VortxNativeHostFieldEvidence.canonicalData(sources[id]!))
            guard rawReplay.equals(nativeSource),
                  Self.sameText(rawReplay.receipt["sourceId"], id),
                  Self.exact(rawReplay.receipt, attestation["receipt"]) else { throw Failure.receiptMismatch }
        }
        let historyBytes = try VortxNativeHostFieldEvidence.canonicalData(history)
        let journalBytes = try encoded()
        try authority.withActive {}
        try Task.checkCancellation()
        return .init(sourceIDs: Set(sources.keys), nativeOwnerHistoryBytes: historyBytes,
                     journalBytes: journalBytes, authority: authority)
    }

    /// Same complete carrier can be embedded inside the encrypted local host journal or encrypted
    /// account envelope. Merely producing bytes does not authenticate a peer or permit upload.
    func encoded() throws -> Data {
        let sources = entries.mapValues { entry in VortxJSON.object([
            "archiveBase64": .string(entry.archive.base64EncodedString()),
            "receipt": entry.receipt, "capturedBinding": entry.capturedBinding,
            "profileId": .string(entry.profileID.uuidString), "verifiedStreamingUid": .string(entry.verifiedUID)
        ]) }
        let value: VortxJSON = .object([
            "schemaVersion": .integer(1), "kind": .string(Self.kind), "scope": .string(scope),
            "ownerProfileId": .string(ownerProfileID.uuidString), "sources": .object(sources)
        ])
        let bytes = try VortxNativeHostFieldEvidence.canonicalData(value)
        guard bytes.count <= Self.maximumBytes else { throw Failure.excessive }
        return bytes
    }

    private static func validateReceiptShape(_ receipt: VortxJSON, id: String, archive: Data) throws {
        let fields = try object(receipt)
        guard digestText(id),
              Set(fields.keys) == ["sourceId", "sourceDocumentSha256", "sourceArchiveSha256", "typedCarrierFingerprint"],
              sameText(fields["sourceId"], id),
              sameText(fields["sourceArchiveSha256"], digest(archive)) else { throw Failure.receiptMismatch }
        for key in ["sourceDocumentSha256", "typedCarrierFingerprint"] {
            guard case .string(let value) = fields[key], digestText(value) else { throw Failure.receiptMismatch }
        }
    }
    private static func sameEntry(_ a: Entry, _ b: Entry) -> Bool {
        a.archive == b.archive && a.profileID == b.profileID
            && Data(a.verifiedUID.utf8) == Data(b.verifiedUID.utf8)
            && exact(a.receipt, b.receipt) && exact(a.capturedBinding, b.capturedBinding)
    }
    private static func exact(_ a: VortxJSON?, _ b: VortxJSON?) -> Bool {
        VortxNativeHostFieldEvidence.json(a, b)
    }
    private static func sameText(_ value: VortxJSON?, _ expected: String) -> Bool {
        guard case .string(let text) = value else { return false }
        return Data(text.utf8) == Data(expected.utf8)
    }
    private static func digestText(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func object(_ value: VortxJSON) throws -> [String: VortxJSON] {
        guard case .object(let fields) = value else { throw Failure.malformed }
        return fields
    }
}
