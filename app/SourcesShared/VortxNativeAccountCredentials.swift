import Foundation
import CryptoKit

/// Device-only immutable credential revisions. A durable native account binding chooses the
/// current revision; merely staging a verified candidate can never change that selection.
enum VortxNativeAccountCredentials {
    private static let lock = NSRecursiveLock()
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
