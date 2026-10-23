import Foundation
import CryptoKit

/// The original capture's two authorities. Short sequential checks preserve the existing lock
/// order; this is not an admitted FIFO ticket or permission to manufacture a replacement lease.
struct OwnerHistoryCaptureAuthority: VortxMutationAuthority {
    let source: any VortxMutationAuthority
    let queue: any VortxMutationAuthority

    func withActive(_ operation: () throws -> Void) throws {
        try source.withActive {}
        try queue.withActive(operation)
        try source.withActive {}
    }

    /// Actual producer replay, not a copied parser or fake receipt. Every producer admission
    /// callback sees both original authorities, including its final post-interpretation check.
    func replay(archive: Data, scope: String, ownerProfileID: UUID, profileID: UUID,
                verifiedUID: String) throws -> VortxNativeOwnerHistoryPreparation.Prepared {
        try withActive {}
        let result = try VortxNativeOwnerHistoryPreparation.replay(archive: archive, scope: scope,
            ownerProfileID: ownerProfileID, profileID: profileID, verifiedUID: verifiedUID,
            authority: self)
        try withActive {}
        return result
    }
}

/// Persistent pending data, not an authority. Cold reopen must retain the binding captured when
/// the bytes were fetched; the same UID under a new revision/transaction is not the same owner.
/// The surrounding Local decoder still performs the real source-frame/scope validation.
struct OwnerHistoryPendingRecord: Sendable {
    private typealias Exact = OwnerHistoryExactJSON
    let archive: Data
    let binding: Data

    init(archive: Data, binding: Data) throws {
        _ = try Exact.Object(binding)
        self.archive = archive
        self.binding = binding // Retain original bytes, including unknown/numeric fields.
    }

    init(encoded: Data, expectedDigest: String) throws {
        // A legacy base64 string has no authenticated original native binding. Preserve it on
        // disk by refusing to open it; never assign the current capture's binding during reopen.
        guard encoded.first == 123 else { throw VortxNativeError.unavailable }
        let record = try Exact.Object(encoded)
        guard Set(record.fields.keys) == ["archiveBase64", "capturedBinding"] else {
            throw VortxNativeError.unavailable
        }
        let text = try record.text("archiveBase64")
        guard let archive = Data(base64Encoded: text), archive.base64EncodedString() == text,
              Self.digest(archive) == expectedDigest else { throw VortxNativeError.invalidSnapshot }
        try self.init(archive: archive, binding: record.required("capturedBinding"))
    }

    func encoded() throws -> Data {
        var record = try Exact.Object(Data("{}".utf8))
        record.set("archiveBase64", try Exact.string(archive.base64EncodedString()))
        record.set("capturedBinding", binding)
        return try record.encoded()
    }

    func matches(binding candidate: Data) throws -> Bool {
        try Exact.canonical(binding) == Exact.canonical(candidate)
    }

    /// Identical source bytes must not overwrite an earlier binding merely because the UID
    /// matches. Conflicting retention fails without replacing or pruning the original record.
    func requireSame(as candidate: Self) throws {
        guard archive == candidate.archive, try matches(binding: candidate.binding) else {
            throw VortxNativeError.superseded
        }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
