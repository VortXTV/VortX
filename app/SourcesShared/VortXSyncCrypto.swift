import Foundation
import CryptoKit
import CommonCrypto

/// Client crypto for the VortX end-to-end-encrypted account, byte-for-byte matching the Cloudflare
/// Worker contract (cloudflare/src/index.ts header) and the website (vortx-site/src/lib/vault.ts),
/// verified interoperable by cloudflare/e2e-test.mjs. The password derives the master key on-device;
/// the server only ever sees verifiers, wrapped keys, and ciphertext, so it can never read user data.
///
///   masterKey    = PBKDF2-SHA256(password, salt=kdfSalt, iters, 256)
///   authVerifier = base64(PBKDF2-SHA256(masterKey, salt=utf8(password), 1, 256))   // sent to log in
///   dataKey      = random 32 bytes (minted at signup)
///   wrappedKeyPw = base64(AES-256-GCM(dataKey, key=masterKey))                      // combined iv|ct|tag
///   recoveryKey  = PBKDF2-SHA256(recoveryCode, salt=kdfSalt, iters, 256)
///   wrappedKeyRec= base64(AES-256-GCM(dataKey, key=recoveryKey))
///   recVerifier  = base64(PBKDF2-SHA256(recoveryKey, salt=utf8(recoveryCode), 1, 256))
///   document     = base64(AES-256-GCM(syncDocJSON, key=dataKey))
enum VortXSyncCrypto {
    static let defaultIters = 210_000
    /// Hard floor for a server-supplied `kdfIters`. `/v1/auth/prelogin` and `/v1/auth/recover-start` are
    /// UNAUTHENTICATED, so a spoofed/compromised api.vortx.tv (or a MITM) could return `kdfIters: 1` and make
    /// the client derive a near-unstretched master key, collapsing the offline cost of cracking the account's
    /// stored wrapped key. Reject anything below this floor before deriving. Well under defaultIters so every
    /// legitimate account (minted at 210k) passes; far above any downgrade an attacker would want.
    static let minIters = 100_000

    // MARK: PBKDF2-SHA256 (CryptoKit has no PBKDF2; CommonCrypto provides it)

    static func pbkdf2(_ password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var derived = Data(repeating: 0, count: length)
        let status = derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltPtr: UnsafeRawBufferPointer) -> Int32 in
                password.withUnsafeBytes { (pwPtr: UnsafeRawBufferPointer) -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data {
        pbkdf2(Data(password.utf8), salt: salt, iterations: iterations)
    }

    // MARK: AES-256-GCM, combined iv|ct|tag, base64 (matches WebCrypto + the Worker)

    static func seal(key: Data, _ plaintext: Data) -> String? {
        guard let combined = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else { return nil }
        return combined.base64EncodedString()
    }

    static func open(key: Data, _ base64Ciphertext: String) -> Data? {
        guard let data = Data(base64Encoded: base64Ciphertext),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    // MARK: Sync-document sealing with version binding (rollback protection)
    //
    // The sync `document` (ONLY - never the wrapped keys) is bound to the (accountId, version) it was written
    // at via AES-GCM additional-authenticated-data. Because the GCM tag then covers that version, a storage
    // backend that cannot read the data key still cannot replay an OLD ciphertext under a fabricated HIGHER
    // version to silently roll the account back (the client's monotonic lastSyncedVersion check alone let a
    // faked-higher version through). A "v2." prefix marks the new format; legacy docs (bare base64, no AAD)
    // still open, so this is backward-compatible. The webapp (vortx-site/src/lib/vault.ts) mirrors this byte
    // for byte, and the Worker stores the document as an opaque string and already echoes the authentic
    // version, so no Worker change is needed. MIGRATION: ship dual-READ everywhere first (writeV2 == false),
    // then flip to writeV2 == true once every client can read v2 (a v2 doc is unreadable by an older client).
    static let docV2Prefix = "v2."

    /// The AAD bytes that bind a sync document to its account + version. Identical construction in the webapp.
    static func documentAAD(accountId: String, version: Int) -> Data {
        Data("vortx/sync-doc/v2\n\(accountId)\n\(version)".utf8)
    }

    /// Seal the sync document. `writeV2 == true` binds (accountId, version) as GCM AAD and marks the blob
    /// "v2."; `false` writes the legacy no-AAD format so an older client can still read it during migration.
    static func sealDocument(dataKey: Data, plaintext: Data, accountId: String, version: Int, writeV2: Bool) -> String? {
        guard writeV2 else { return seal(key: dataKey, plaintext) }
        let aad = documentAAD(accountId: accountId, version: version)
        guard let combined = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: dataKey), authenticating: aad).combined
        else { return nil }
        return docV2Prefix + combined.base64EncodedString()
    }

    /// Open a sync document of either format. A "v2." blob MUST authenticate against (accountId, version):
    /// a replay under a different version, or a stripped/forged prefix, fails the GCM tag and returns nil. A
    /// bare-base64 (legacy) blob opens without AAD. `version` is ignored for legacy blobs.
    static func openDocument(dataKey: Data, stored: String, accountId: String, version: Int) -> Data? {
        guard stored.hasPrefix(docV2Prefix) else { return open(key: dataKey, stored) }
        let b64 = String(stored.dropFirst(docV2Prefix.count))
        guard let data = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        let aad = documentAAD(accountId: accountId, version: version)
        return try? AES.GCM.open(box, using: SymmetricKey(data: dataKey), authenticating: aad)
    }

    // MARK: Derived values

    static func masterKey(password: String, kdfSalt: Data, iters: Int) -> Data {
        pbkdf2(password, salt: kdfSalt, iterations: iters)
    }

    /// base64(PBKDF2(masterKey, salt=utf8(password), 1)) — the value sent to register/login.
    static func authVerifier(masterKey: Data, password: String) -> String {
        pbkdf2(masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    static func recoveryKey(recoveryCode: String, kdfSalt: Data, iters: Int) -> Data {
        pbkdf2(recoveryCode, salt: kdfSalt, iterations: iters)
    }

    static func recVerifier(recoveryKey: Data, recoveryCode: String) -> String {
        pbkdf2(recoveryKey, salt: Data(recoveryCode.utf8), iterations: 1).base64EncodedString()
    }

    static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }

    /// A strong human-friendly recovery code, identical scheme to the website: VX- + 26 Crockford
    /// base32 chars over 128 random bits, grouped in 4s.
    static func makeRecoveryCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let bytes = randomBytes(16)
        var bits = ""
        for b in bytes { bits += String(b, radix: 2).leftPadded(to: 8) }
        var out = ""
        var i = bits.startIndex
        while i < bits.endIndex {
            let end = bits.index(i, offsetBy: 5, limitedBy: bits.endIndex) ?? bits.endIndex
            let chunk = String(bits[i..<end]).rightPadded(to: 5)
            if let v = Int(chunk, radix: 2) { out.append(alphabet[v]) }
            i = end
        }
        let groups = stride(from: 0, to: out.count, by: 4).map { start -> String in
            let s = out.index(out.startIndex, offsetBy: start)
            let e = out.index(s, offsetBy: 4, limitedBy: out.endIndex) ?? out.endIndex
            return String(out[s..<e])
        }
        return "VX-" + groups.joined(separator: "-")
    }
}

private extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
    func rightPadded(to n: Int) -> String { count >= n ? self : self + String(repeating: "0", count: n - count) }
}
