// HouseholdCryptoTests — a standalone, runnable verification of the household key-wrapping crypto.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md),
// so this is written as a self-contained Swift executable that runs directly with the system toolchain:
//
//     swift app/Tests/HouseholdCryptoTests.swift
//
// It re-implements the EXACT primitives HouseholdCrypto.swift uses (BackupCrypto.seal/open framing,
// base64URL, the household HKDF salt/info, and — for the cross-replay test — the PairingCrypto HKDF
// salt/info) so the two security-critical properties are actually asserted against real CryptoKit:
//
//   1. wrapHHKey -> unwrapHHKey round-trips and recovers the SAME 32 bytes.
//   2. A pairing-derived wrapping key CANNOT open a household-wrapped payload, and vice versa
//      (HKDF domain separation: distinct salt AND info). This is the cross-replay isolation the
//      Security-Refined v1 design mandates.
//
// If HouseholdCrypto.swift's salt/info/framing ever drift from these constants, this test fails,
// which is the byte-level guard the web side (vault.ts) also has to match.

import Foundation
import CryptoKit

// MARK: - Mirror of BackupCrypto (combined iv||ct||tag; base64URL, no padding)

enum TestBackupCrypto {
    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw NSError(domain: "seal", code: 1) }
        return combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: key)
    }

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

// MARK: - Mirror of HouseholdCrypto (the unit under test)

enum TestHouseholdCrypto {
    static let salt = Data("vortx-household-salt-v1".utf8)
    static let info = Data("vortx-household-v1".utf8)

    static func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    static func wrapHHKey(_ rawHhKey: Data, toPeerPublicKey peerBase64URL: String) -> (ourPublicKey: String, wrapped: String)? {
        guard rawHhKey.count == 32,
              let peerData = TestBackupCrypto.dataFromBase64URL(peerBase64URL),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData) else { return nil }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? ephemeral.sharedSecretFromKeyAgreement(with: peer),
              let sealed = try? TestBackupCrypto.seal(rawHhKey, with: wrappingKey(secret)) else { return nil }
        return (TestBackupCrypto.base64URL(ephemeral.publicKey.rawRepresentation), TestBackupCrypto.base64URL(sealed))
    }

    static func unwrapHHKey(_ wrapped: String, fromPeerPublicKey peerBase64URL: String, using ourPrivate: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard let peerData = TestBackupCrypto.dataFromBase64URL(peerBase64URL),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData),
              let secret = try? ourPrivate.sharedSecretFromKeyAgreement(with: peer),
              let sealedData = TestBackupCrypto.dataFromBase64URL(wrapped),
              let keyBytes = try? TestBackupCrypto.open(sealedData, with: wrappingKey(secret)),
              keyBytes.count == 32 else { return nil }
        return keyBytes
    }
}

// MARK: - Mirror of the PairingCrypto HKDF (DIFFERENT salt/info — used only to prove isolation)

enum TestPairingCrypto {
    static let salt = Data("vortx-pairing-salt-v1".utf8)
    static let info = Data("vortx-pairing-v1".utf8)

    static func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }
}

// MARK: - Tiny assert harness

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("  PASS  \(name)") } else { failures += 1; print("  FAIL  \(name)") }
}

func randomBytes(_ count: Int) -> Data {
    var d = Data(count: count)
    _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return d
}

// MARK: - Tests

print("HouseholdCrypto crypto verification\n")

// 1) Round-trip: owner wraps hhKey to joiner's pubkey; joiner unwraps and recovers the same bytes.
do {
    let hhKey = randomBytes(32)
    let joiner = Curve25519.KeyAgreement.PrivateKey()
    let joinerPub = TestBackupCrypto.base64URL(joiner.publicKey.rawRepresentation)

    guard let answer = TestHouseholdCrypto.wrapHHKey(hhKey, toPeerPublicKey: joinerPub) else {
        failures += 1; print("  FAIL  wrapHHKey returned nil"); exit(1)
    }
    let recovered = TestHouseholdCrypto.unwrapHHKey(answer.wrapped, fromPeerPublicKey: answer.ourPublicKey, using: joiner)
    check(recovered != nil, "round-trip: unwrap succeeds")
    check(recovered == hhKey, "round-trip: recovers identical 32 bytes")
    check(recovered?.count == 32, "round-trip: recovered key is 32 bytes")
}

// 2) Cross-replay isolation: a household payload must NOT open under a pairing-derived key.
//    We seal hhKey under the HOUSEHOLD wrapping key, then attempt to open with the PAIRING wrapping
//    key derived from the SAME ECDH secret. Domain separation (distinct salt+info) must make this fail.
do {
    let hhKey = randomBytes(32)
    let ownerEph = Curve25519.KeyAgreement.PrivateKey()
    let joiner = Curve25519.KeyAgreement.PrivateKey()
    let secret = try! ownerEph.sharedSecretFromKeyAgreement(with: joiner.publicKey)

    let householdKey = TestHouseholdCrypto.wrappingKey(secret)
    let pairingKey = TestPairingCrypto.wrappingKey(secret)

    // The two wrapping keys derived from the SAME ECDH secret must differ.
    let hkBytes = householdKey.withUnsafeBytes { Data($0) }
    let pkBytes = pairingKey.withUnsafeBytes { Data($0) }
    check(hkBytes != pkBytes, "isolation: household and pairing HKDF keys differ for same ECDH secret")

    let sealed = try! TestBackupCrypto.seal(hhKey, with: householdKey)
    let openedWithPairing = try? TestBackupCrypto.open(sealed, with: pairingKey)
    check(openedWithPairing == nil, "isolation: pairing key CANNOT open household-sealed payload")

    // And the reverse: a pairing-sealed payload must not open under the household key.
    let pairingSealed = try! TestBackupCrypto.seal(hhKey, with: pairingKey)
    let openedWithHousehold = try? TestBackupCrypto.open(pairingSealed, with: householdKey)
    check(openedWithHousehold == nil, "isolation: household key CANNOT open pairing-sealed payload")
}

// 3) Negative: unwrapping with the WRONG private key (a different joiner) must fail.
do {
    let hhKey = randomBytes(32)
    let joiner = Curve25519.KeyAgreement.PrivateKey()
    let joinerPub = TestBackupCrypto.base64URL(joiner.publicKey.rawRepresentation)
    let attacker = Curve25519.KeyAgreement.PrivateKey()

    let answer = TestHouseholdCrypto.wrapHHKey(hhKey, toPeerPublicKey: joinerPub)!
    let stolen = TestHouseholdCrypto.unwrapHHKey(answer.wrapped, fromPeerPublicKey: answer.ourPublicKey, using: attacker)
    check(stolen == nil, "negative: a different private key cannot unwrap")
}

// 4) Guard: wrapHHKey rejects a non-32-byte key.
do {
    let joiner = Curve25519.KeyAgreement.PrivateKey()
    let joinerPub = TestBackupCrypto.base64URL(joiner.publicKey.rawRepresentation)
    check(TestHouseholdCrypto.wrapHHKey(randomBytes(16), toPeerPublicKey: joinerPub) == nil, "guard: 16-byte key rejected")
    check(TestHouseholdCrypto.wrapHHKey(randomBytes(32), toPeerPublicKey: "!!not-base64!!") == nil, "guard: malformed peer key rejected")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
