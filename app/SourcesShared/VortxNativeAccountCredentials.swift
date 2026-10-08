import Foundation
import CryptoKit

/// Device-only immutable credential revisions. A durable native account binding chooses the
/// current revision; merely staging a verified candidate can never change that selection.
enum VortxNativeAccountCredentials {
    private static let lock = NSRecursiveLock()
    private struct OwnerSelection: Codable {
        let schemaVersion: Int
        let scope: String
        let ownerProfileID: UUID
        let verifiedUID: String
        let revision: String
    }
    static func ownerSelectionKey(scope: String, ownerProfileID: UUID) throws -> String {
        // Reuse exact namespace validation; this domain never aliases an immutable token slot.
        let qualified = try slot(scope: scope, profileID: ownerProfileID, uid: "owner-selector", transactionID: nil)
        return "vortx.native.owner-selection.v1." + qualified.components(separatedBy: ".").last!
    }
    static func selectedOwnerSlot(scope: String, ownerProfileID: UUID,
                                  read: (String) throws -> String?) throws -> String? {
        try lock.withLock {
            guard let raw = try read(ownerSelectionKey(scope: scope, ownerProfileID: ownerProfileID)) else { return nil }
            let selection = try JSONDecoder().decode(OwnerSelection.self, from: Data(raw.utf8))
            guard selection.schemaVersion == 1, selection.scope == scope, selection.ownerProfileID == ownerProfileID,
                  UUID(uuidString: selection.revision)?.uuidString.lowercased() == selection.revision else { throw VortxNativeError.invalidSnapshot }
            return try slot(scope: scope, profileID: ownerProfileID, uid: selection.verifiedUID, transactionID: "owner:" + selection.revision)
        }
    }
    /// A verified owner login changes only this captured account's device-local selector. The
    /// previous UID/revision remains securely retained, and failed CAS leaves it selected.
    @discardableResult
    static func connectOwner(token: String, scope: String, ownerProfileID: UUID, verifiedUID: String,
                             revision: String, expectedSelection: String?, authority: any VortxMutationAuthority,
                             read: (String) throws -> String?, write: (String, String) throws -> Bool) throws -> String {
        guard UUID(uuidString: revision)?.uuidString.lowercased() == revision else { throw VortxNativeError.invalidSnapshot }
        let selector = try ownerSelectionKey(scope: scope, ownerProfileID: ownerProfileID)
        let selection = OwnerSelection(schemaVersion: 1, scope: scope, ownerProfileID: ownerProfileID, verifiedUID: verifiedUID, revision: revision)
        let encoded = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        var result: String?
        try lock.withLock {
            try authority.withActive {
                guard try read(selector) == expectedSelection else { throw VortxNativeError.superseded }
                result = try stage(token: token, scope: scope, profileID: ownerProfileID, uid: verifiedUID,
                    transactionID: "owner:" + revision, authority: authority, read: read, write: write)
                guard try write(selector, encoded), try read(selector) == encoded else { throw VortxNativeError.unavailable }
            }
        }
        return result!
    }
    static func slot(scope: String, profileID: UUID, uid: String, transactionID: String?) throws -> String {
        guard !scope.isEmpty, !scope.contains("\u{0}"), !uid.isEmpty, uid.utf8.count <= 256,
              uid == uid.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              transactionID.map({ !$0.isEmpty && $0.utf8.count <= 128 &&
                  !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true else { throw VortxNativeError.invalidSnapshot }
        let fields = [scope, profileID.uuidString, uid, transactionID.map { "transaction:" + $0 } ?? "verified-import"]
        return "vortx.native.streaming.v1." + SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func selectedSlot(scope: String, profileID: UUID, binding: VortxJSON) throws -> String? {
        guard case .string(let kind) = binding["account"]?["kind"] else { throw VortxNativeError.invalidSnapshot }
        guard kind == "own" else { return nil }
        guard case .string(let uid) = binding["account"]?["value"], let revision = binding["revision"],
              let clock = try? revision.decode(UInt64.self), clock <= 9_007_199_254_740_991 else { throw VortxNativeError.invalidSnapshot }
        let transaction: String?
        switch binding["transactionId"] {
        case .null?: guard clock == 0 else { throw VortxNativeError.invalidSnapshot }; transaction = nil
        case .string(let value)?: guard clock > 0 else { throw VortxNativeError.invalidSnapshot }; transaction = value
        default: throw VortxNativeError.invalidSnapshot
        }
        return try slot(scope: scope, profileID: profileID, uid: uid, transactionID: transaction)
    }
    @discardableResult
    static func stage(token: String, scope: String, profileID: UUID, uid: String, transactionID: String?,
                      authority: any VortxMutationAuthority,
                      read: (String) throws -> String?, write: (String, String) throws -> Bool) throws -> String {
        guard !token.isEmpty else { throw VortxNativeError.invalidSnapshot }
        let key = try slot(scope: scope, profileID: profileID, uid: uid, transactionID: transactionID)
        try lock.withLock {
            try authority.withActive {
                if let existing = try read(key) {
                    guard existing == token else { throw VortxNativeError.invalidSnapshot }
                } else {
                    guard try write(key, token), try read(key) == token else { throw VortxNativeError.unavailable }
                }
            }
        }
        return key
    }
}
