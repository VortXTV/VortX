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
    struct OwnerPublicationUncertain: Error {}
    private struct OwnerIntent: Codable {
        let schemaVersion: Int
        let scope: String
        let ownerProfileID: UUID
        let revision: String
        let previousSelection: String?
        let proposedSelection: String
        let credentialSHA256: String
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func ownerIntentKey(selector: String, revision: String) -> String {
        "vortx.native.owner-intent.v1." + digest(selector + "\u{0}" + revision)
    }
    static func ownerSelectionKey(scope: String, ownerProfileID: UUID) throws -> String {
        // Reuse exact namespace validation; this domain never aliases an immutable token slot.
        let qualified = try slot(scope: scope, profileID: ownerProfileID, uid: "owner-selector", transactionID: nil)
        return "vortx.native.owner-selection.v1." + qualified.components(separatedBy: ".").last!
    }
    static func selectedOwnerSlot(scope: String, ownerProfileID: UUID,
                                  read: (String) throws -> String?) throws -> String? {
        try lock.withLock {
            let selector = try ownerSelectionKey(scope: scope, ownerProfileID: ownerProfileID)
            guard let raw = try read(selector) else { return nil }
            let selection = try JSONDecoder().decode(OwnerSelection.self, from: Data(raw.utf8))
            guard selection.schemaVersion == 2, selection.scope == scope, selection.ownerProfileID == ownerProfileID,
                  UUID(uuidString: selection.revision)?.uuidString.lowercased() == selection.revision else { throw VortxNativeError.invalidSnapshot }
            // Cold and live selection both reconcile against the independently durable intent.
            // A pointer alone, including one left by an uncertain secure mutation, is not authority.
            guard let intentRaw = try read(ownerIntentKey(selector: selector, revision: selection.revision)) else { throw VortxNativeError.invalidSnapshot }
            let intent = try JSONDecoder().decode(OwnerIntent.self, from: Data(intentRaw.utf8))
            guard intent.schemaVersion == 1, intent.scope == scope, intent.ownerProfileID == ownerProfileID,
                  intent.revision == selection.revision, intent.proposedSelection == raw else { throw VortxNativeError.invalidSnapshot }
            let key = try slot(scope: scope, profileID: ownerProfileID, uid: selection.verifiedUID, transactionID: "owner:" + selection.revision)
            guard let token = try read(key), !token.isEmpty else { return nil }
            guard digest(token) == intent.credentialSHA256 else { throw VortxNativeError.invalidSnapshot }
            return key
        }
    }
    /// A verified owner login changes only this captured account's device-local selector. The
    /// previous UID/revision remains securely retained, and failed CAS leaves it selected.
    @discardableResult
    static func connectOwner(token: String, scope: String, ownerProfileID: UUID, verifiedUID: String,
                             revision: String, expectedSelection: String?, authority: any VortxMutationAuthority,
                             read: (String) throws -> String?, write: (String, String) throws -> Bool,
                             restoreSelection: (String, String?) throws -> Bool,
                             selectionAttempted: () -> Void) throws -> String {
        guard UUID(uuidString: revision)?.uuidString.lowercased() == revision else { throw VortxNativeError.invalidSnapshot }
        let selector = try ownerSelectionKey(scope: scope, ownerProfileID: ownerProfileID)
        let selection = OwnerSelection(schemaVersion: 2, scope: scope, ownerProfileID: ownerProfileID, verifiedUID: verifiedUID, revision: revision)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(selection), as: UTF8.self)
        let intentKey = ownerIntentKey(selector: selector, revision: revision)
        let intent = OwnerIntent(schemaVersion: 1, scope: scope, ownerProfileID: ownerProfileID, revision: revision,
            previousSelection: expectedSelection, proposedSelection: encoded, credentialSHA256: digest(token))
        let intentBytes = String(decoding: try encoder.encode(intent), as: UTF8.self)
        var result: String?
        try lock.withLock {
            try authority.withActive {
                guard try read(selector) == expectedSelection else { throw VortxNativeError.superseded }
                result = try stage(token: token, scope: scope, profileID: ownerProfileID, uid: verifiedUID,
                    transactionID: "owner:" + revision, authority: authority, read: read, write: write)
                if let existing = try read(intentKey) {
                    guard existing == intentBytes else { throw VortxNativeError.invalidSnapshot }
                } else {
                    guard try write(intentKey, intentBytes), try read(intentKey) == intentBytes else { throw VortxNativeError.unavailable }
                }
                // Retire every pre-publication producer before the secure write, including when
                // that write takes effect but its acknowledgement/readback fails.
                selectionAttempted()
                do {
                    // `write` is the certified secure-store transaction, including its own exact
                    // readback and durable marker clearing. A second fallible read here must not
                    // turn that already committed publication into a reported authentication failure.
                    guard try write(selector, encoded) else { throw VortxNativeError.unavailable }
                } catch {
                    // Rollback can also fail before establishing an invalidation marker. Never
                    // infer a tombstone or the old selection from a failed recovery acknowledgement.
                    do {
                        guard try restoreSelection(selector, expectedSelection),
                              try read(selector) == expectedSelection else { throw OwnerPublicationUncertain() }
                    } catch {
                        // An exact intended candidate may be completed only by reconciling its
                        // durable intent and credential. Otherwise expose uncertainty, not failure
                        // with an assertion that the old account is still selected.
                        if let reconciled = try? selectedOwnerSlot(scope: scope, ownerProfileID: ownerProfileID, read: read),
                           reconciled == result { return }
                        throw OwnerPublicationUncertain()
                    }
                    throw error
                }
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
