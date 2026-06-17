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
