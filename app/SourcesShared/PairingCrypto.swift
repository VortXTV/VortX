import Foundation
import CryptoKit

/// Zero-knowledge device pairing for the VortX account handoff (e.g. phone -> Apple TV, which has no
/// camera to scan back). The joining device publishes an ephemeral X25519 public key in its QR /
/// pairing record. The holder device does ECDH against it, derives a one-time wrapping key (HKDF),
/// and seals the 32-byte account key under it. The sync service relays only that ciphertext, so it
/// never learns the account key. The joining device repeats the ECDH against the holder's ephemeral
/// public key and unwraps. The account id is re-derived from the key, so only the key travels.
enum PairingCrypto {
    /// A joining device's one-time key agreement pair. Keep `privateKey` until the handoff completes.
    struct Ephemeral {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        var publicKeyBase64URL: String {
            BackupCrypto.base64URL(privateKey.publicKey.rawRepresentation)
        }
    }

    static func newEphemeral() -> Ephemeral {
        Ephemeral(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    private static let salt = Data("vortx-pairing-salt-v1".utf8)
    private static let info = Data("vortx-pairing-v1".utf8)

    private static func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    /// Holder side: wrap `account.key` to the joiner's published public key. Returns the holder's own
    /// ephemeral public key (sent as `claimPublicKey`) and the sealed key (sent as `wrappedAccount`).
    static func wrap(_ account: VortXAccount, toJoinerPublicKey joinerBase64URL: String) -> (claimPublicKey: String, wrapped: String)? {
        guard let peerData = BackupCrypto.dataFromBase64URL(joinerBase64URL),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData) else { return nil }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let keyBytes = account.key.withUnsafeBytes { Data($0) }
        guard let sealed = try? BackupCrypto.seal(keyBytes, with: wrappingKey(secret)) else { return nil }
        return (BackupCrypto.base64URL(ephemeral.publicKey.rawRepresentation), BackupCrypto.base64URL(sealed))
    }

    /// Joiner side: unwrap with our ephemeral private key + the holder's ephemeral public key.
    /// Returns the account (id re-derived from the recovered key), or nil if anything fails to verify.
    static func unwrap(wrapped: String, holderPublicKey holderBase64URL: String, using ourPrivate: Curve25519.KeyAgreement.PrivateKey) -> VortXAccount? {
        guard let holderData = BackupCrypto.dataFromBase64URL(holderBase64URL),
              let holder = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: holderData),
              let secret = try? ourPrivate.sharedSecretFromKeyAgreement(with: holder),
              let sealedData = BackupCrypto.dataFromBase64URL(wrapped),
              let keyBytes = try? BackupCrypto.open(sealedData, with: wrappingKey(secret)),
              keyBytes.count == 32 else { return nil }
        return VortXAccount.from(key: SymmetricKey(data: keyBytes))
    }
}
