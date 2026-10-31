import CryptoKit
import Foundation
import Security

/// E2E codec for the opaque relay frame. `roomKey` must be a dedicated random
/// 256-bit party key, never the account backup key. Key distribution/rotation is
/// intentionally supplied by a separate reviewed adapter.
enum WatchPartyWire {
    struct Control: Codable, Equatable {
        let action: String
        let mediaId: String
        let positionMs: Int64
    }

    static func makeRoomKey() -> Data? {
        var bytes = Data(repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return status == errSecSuccess ? bytes : nil
    }

    static func associatedData(roomGeneration: String, leaderTerm: Int64, serverSequence: Int64) -> Data? {
        guard token(roomGeneration), leaderTerm > 0, serverSequence > 0 else { return nil }
        return Data("vortx/watch-party/v1\n\(roomGeneration)\n\(leaderTerm)\n\(serverSequence)".utf8)
    }

    static func seal(_ control: Control, roomKey: Data, roomGeneration: String,
                     leaderTerm: Int64, serverSequence: Int64) -> String? {
        guard roomKey.count == 32, valid(control),
              let aad = associatedData(roomGeneration: roomGeneration, leaderTerm: leaderTerm, serverSequence: serverSequence),
              let plaintext = try? JSONEncoder.sorted.encode(control),
              let box = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: roomKey), authenticating: aad) else { return nil }
        return box.combined?.base64EncodedString()
    }

    static func open(_ ciphertext: String, roomKey: Data, roomGeneration: String,
                     leaderTerm: Int64, serverSequence: Int64) -> Control? {
        guard roomKey.count == 32, let bytes = Data(base64Encoded: ciphertext),
              let box = try? AES.GCM.SealedBox(combined: bytes),
              let aad = associatedData(roomGeneration: roomGeneration, leaderTerm: leaderTerm, serverSequence: serverSequence),
              let clear = try? AES.GCM.open(box, using: SymmetricKey(data: roomKey), authenticating: aad),
              let object = try? JSONSerialization.jsonObject(with: clear) as? [String: Any],
              Set(object.keys) == Set(["action", "mediaId", "positionMs"]),
              let decoded = try? JSONDecoder().decode(Control.self, from: clear), valid(decoded) else { return nil }
        return decoded
    }

    /// Exact URL-safe media token for the transport. Callers must fail when their
    /// current title has no canonical token; this codec never truncates or maps it.
    static func canonicalTitleToken(_ value: String) -> String? {
        canonicalMediaId(value) ? value : nil
    }

    private static func token(_ value: String) -> Bool {
        canonicalAsciiToken(value, maximumLength: 128)
    }

    private static func valid(_ control: Control) -> Bool {
        ["play", "pause", "seek"].contains(control.action) &&
            canonicalMediaId(control.mediaId) && control.positionMs >= 0 && control.positionMs <= 86_400_000
    }

    /// Integration must pass a canonical title token verbatim; this codec never truncates or normalizes IDs.
    private static func canonicalMediaId(_ value: String) -> Bool {
        canonicalAsciiToken(value, maximumLength: 256)
    }

    private static func canonicalAsciiToken(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                (48...57).contains(scalar.value) || scalar.value == 95 || scalar.value == 45
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
