import Foundation
import CryptoKit

/// End-to-end encryption for the cloud backup blob.
///
/// The symmetric key lives ONLY on the user's own devices (in the Keychain) and travels
/// device to device inside the pairing QR. The VortX sync service therefore only ever stores
/// ciphertext and can never read a user's profiles, PINs, or preferences: a blind relay. We use
/// AES-256-GCM via CryptoKit and store the sealed box in its combined form (nonce + ciphertext
/// + tag), so one `Data` round-trips cleanly through the network and back.
enum BackupCrypto {
    enum CryptoError: Error { case sealFailed, badKey }

    /// Encrypt `plaintext` under `key`. Returns the combined sealed box.
    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw CryptoError.sealFailed }
        return combined
    }

    /// Decrypt a combined sealed box produced by `seal`.
    static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key)
    }

    /// A fresh random 256-bit key (minted when a new VortX account is created).
    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    // MARK: Key <-> URL-safe text (for the pairing QR, deep links, and Keychain storage)

    static func keyToBase64URL(_ key: SymmetricKey) -> String {
        base64URL(key.withUnsafeBytes { Data($0) })
    }

    static func keyFromBase64URL(_ string: String) -> SymmetricKey? {
        guard let data = dataFromBase64URL(string), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: Base64URL (no padding, URL-safe alphabet) so secrets fit cleanly in a QR / link.

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64URL(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
