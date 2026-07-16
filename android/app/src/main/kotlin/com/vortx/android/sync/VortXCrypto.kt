package com.vortx.android.sync

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Client crypto for the VortX end-to-end-encrypted account, ported BYTE-FOR-BYTE from the Apple app
 * (`app/SourcesShared/VortXSyncCrypto.swift` + `BackupCrypto.swift`), the website / webapp
 * (`webapp/src/lib/vault.ts`, `vortx-site/src/lib/vault.ts`), and the Cloudflare Worker contract
 * (`cloudflare/src/index.ts`), all verified interoperable by `cloudflare/e2e-test.mjs`. Because the
 * password derives the master key on-device, the server only ever sees verifiers, wrapped keys, and
 * ciphertext, so it can never read user data. An account created on ANY surface must decrypt on every
 * other, so every parameter below is pinned to the shared contract and must NOT drift in isolation:
 *
 *   masterKey    = PBKDF2-SHA256(password, salt=kdfSalt, iters, 256)                   // [masterKey]
 *   authVerifier = base64(PBKDF2-SHA256(masterKey, salt=utf8(password), 1, 256))       // sent to log in
 *   dataKey      = random 32 bytes (minted at signup)
 *   wrappedKeyPw = base64(AES-256-GCM(dataKey, key=masterKey))                          // combined iv|ct|tag
 *   recoveryKey  = PBKDF2-SHA256(recoveryCode, salt=kdfSalt, iters, 256)
 *   wrappedKeyRec= base64(AES-256-GCM(dataKey, key=recoveryKey))
 *   recVerifier  = base64(PBKDF2-SHA256(recoveryKey, salt=utf8(recoveryCode), 1, 256))
 *   document     = base64(AES-256-GCM(syncDocJSON, key=dataKey))   // v2 binds (accountId, version) as AAD
 *
 * IMPLEMENTATION NOTES (why these choices are byte-exact):
 *   - PBKDF2 is hand-rolled over `HmacSHA256` (RFC 8018) rather than JCA `SecretKeyFactory`
 *     ("PBKDF2WithHmacSHA256"). The verifiers feed the RAW 32-byte master/recovery key as the PBKDF2
 *     "password"; JCA's `PBEKeySpec` only takes a `char[]` and would mangle arbitrary binary IKM. The
 *     hand-rolled form takes a `ByteArray` password, exactly like Apple's `CCKeyDerivationPBKDF` (raw
 *     bytes) and WebCrypto's `importKey("raw", ikm, "PBKDF2")`. One code path, byte-identical for both
 *     the master/recovery derivation (utf8 password) AND the 1-iteration verifiers (raw-key IKM).
 *   - AES-256-GCM uses a 12-byte nonce and a 16-byte (128-bit) tag, and stores the box in its COMBINED
 *     form `nonce || ciphertext || tag` (CryptoKit `.combined`; WebCrypto `iv || ct` where the tag is
 *     appended to `ct`; JCA `Cipher` GCM output is `ct || tag`). Standard base64 (with padding) on the
 *     account channel; base64url (no padding) on the pairing channel (see [VortXPairingCrypto]).
 */
object VortXCrypto {
    /** Iteration count minted for every new account. Pinned across app / web / worker. */
    const val DEFAULT_ITERS = 210_000

    /**
     * Hard floor for a server-supplied `kdfIters`. `/v1/auth/prelogin` and `/v1/auth/recover-start` are
     * UNAUTHENTICATED, so a spoofed / MITM'd api.vortx.tv could return `kdfIters: 1` and make the client
     * derive a near-unstretched master key. Reject anything below this floor before deriving. Matches the
     * Apple `VortXSyncCrypto.minIters` (100_000); well under DEFAULT_ITERS so every legit account passes.
     */
    const val MIN_ITERS = 100_000

    /** Marks the version-bound (AAD) sync-document format. Legacy docs are bare base64 with no prefix. */
    const val DOC_V2_PREFIX = "v2."

    private const val PBKDF2_OUT_LEN = 32 // 256-bit derived keys everywhere
    private const val GCM_NONCE_LEN = 12
    private const val GCM_TAG_BITS = 128

    private val secureRandom = SecureRandom()

    // MARK: PBKDF2-SHA256 (RFC 8018), hand-rolled over HMAC so the "password" can be arbitrary raw bytes

    /**
     * PBKDF2-SHA256(password, salt, iterations) -> [length] bytes. [password] and [salt] are RAW bytes
     * (the salt is `utf8(password)` for the 1-iteration verifiers and the random `kdfSalt` for the master
     * / recovery keys). Byte-identical to Apple's `CCKeyDerivationPBKDF(kCCPRFHmacAlgSHA256, ...)` and
     * WebCrypto's PBKDF2 deriveBits.
     */
    fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int, length: Int = PBKDF2_OUT_LEN): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password, "HmacSHA256"))
        val hLen = mac.macLength // 32 for SHA-256
        val blocks = (length + hLen - 1) / hLen
        val out = ByteArray(blocks * hLen)
        val intBuf = ByteArray(4)
        for (i in 1..blocks) {
            // U_1 = HMAC(P, S || INT_32_BE(i))
            intBuf[0] = (i ushr 24).toByte()
            intBuf[1] = (i ushr 16).toByte()
            intBuf[2] = (i ushr 8).toByte()
            intBuf[3] = i.toByte()
            mac.update(salt)
            var u = mac.doFinal(intBuf)
            val t = u.copyOf() // T_i starts as U_1
            // U_j = HMAC(P, U_{j-1}); T_i ^= U_j
            for (j in 2..iterations) {
                u = mac.doFinal(u)
                for (k in t.indices) t[k] = (t[k].toInt() xor u[k].toInt()).toByte()
            }
            System.arraycopy(t, 0, out, (i - 1) * hLen, hLen)
        }
        return if (out.size == length) out else out.copyOf(length)
    }

    /** PBKDF2 over the UTF-8 bytes of a [password] string (the master- / recovery-key derivation). */
    fun pbkdf2(password: String, salt: ByteArray, iterations: Int): ByteArray =
        pbkdf2(password.toByteArray(Charsets.UTF_8), salt, iterations)

    // MARK: AES-256-GCM, combined nonce||ct||tag (matches CryptoKit .combined + WebCrypto + the Worker)

    /**
     * AES-256-GCM seal returning the COMBINED box `nonce(12) || ciphertext || tag(16)` as raw bytes, with
     * optional [aad] bound into the tag. A fresh random nonce every call. Returns null on any crypto error.
     * The base64 (account) and base64url (pairing) channels both wrap this.
     */
    fun aesGcmSealCombined(key: ByteArray, plaintext: ByteArray, aad: ByteArray? = null): ByteArray? = runCatching {
        val nonce = ByteArray(GCM_NONCE_LEN).also { secureRandom.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        if (aad != null) cipher.updateAAD(aad)
        val body = cipher.doFinal(plaintext) // ciphertext || tag
        nonce + body
    }.getOrNull()

    /**
     * AES-256-GCM open of a COMBINED box `nonce(12) || ciphertext || tag(16)`, with optional [aad] that
     * must match what sealing bound. Returns null on any failure (wrong key, tamper, wrong AAD / version),
     * so callers treat "could not unlock" as a clean expected outcome, never a thrown crypto error.
     */
    fun aesGcmOpenCombined(key: ByteArray, combined: ByteArray, aad: ByteArray? = null): ByteArray? = runCatching {
        if (combined.size < GCM_NONCE_LEN) return null
        val nonce = combined.copyOfRange(0, GCM_NONCE_LEN)
        val body = combined.copyOfRange(GCM_NONCE_LEN, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        if (aad != null) cipher.updateAAD(aad)
        cipher.doFinal(body)
    }.getOrNull()

    /** AES-256-GCM seal to standard base64 (`iv||ct||tag`) — the account wrap/encrypt framing. */
    fun seal(key: ByteArray, plaintext: ByteArray): String? =
        aesGcmSealCombined(key, plaintext)?.let { b64(it) }

    /** AES-256-GCM open of a standard-base64 combined ciphertext. Null on wrong key / tamper. */
    fun open(key: ByteArray, base64Ciphertext: String): ByteArray? =
        unb64(base64Ciphertext)?.let { aesGcmOpenCombined(key, it) }

    // MARK: Sync-document sealing with version binding (rollback protection)
    //
    // The sync `document` (ONLY, never the wrapped keys) binds (accountId, version) as AES-GCM AAD, so a
    // storage backend that cannot read the data key still cannot replay an OLD ciphertext under a fabricated
    // HIGHER version to silently roll the account back. A "v2." prefix marks the format; legacy docs (bare
    // base64, no AAD) still open. openDocument reads BOTH; only WRITE is gated by writeV2. Identical AAD
    // construction on every surface (VortXSyncCrypto.documentAAD / vault.ts documentAAD).

    /**
     * The AAD bytes that bind a sync document to its account + version: `utf8("vortx/sync-doc/v2\n{id}\n{v}")`.
     * [version] is the raw decimal epoch-ms (a 64-bit value; e.g. 1720000000042), stringified with no
     * separators, exactly as Swift `\(version)` and JS `${version}` produce it.
     */
    fun documentAAD(accountId: String, version: Long): ByteArray =
        "vortx/sync-doc/v2\n$accountId\n$version".toByteArray(Charsets.UTF_8)

    /**
     * Seal the sync document. [writeV2] == true binds (accountId, version) as GCM AAD and prefixes "v2.";
     * false writes the legacy no-AAD format so an older client can still read it during migration.
     */
    fun sealDocument(dataKey: ByteArray, plaintext: ByteArray, accountId: String, version: Long, writeV2: Boolean): String? {
        if (!writeV2) return seal(dataKey, plaintext)
        val combined = aesGcmSealCombined(dataKey, plaintext, documentAAD(accountId, version)) ?: return null
        return DOC_V2_PREFIX + b64(combined)
    }

    /**
     * Open a sync document of either format. A "v2." blob MUST authenticate against (accountId, version):
     * a replay under a different version, or a stripped / forged prefix, fails the GCM tag and returns null.
     * A bare-base64 (legacy) blob opens without AAD; [version] is ignored for legacy blobs.
     */
    fun openDocument(dataKey: ByteArray, stored: String, accountId: String, version: Long): ByteArray? {
        if (!stored.startsWith(DOC_V2_PREFIX)) return open(dataKey, stored)
        val combined = unb64(stored.substring(DOC_V2_PREFIX.length)) ?: return null
        return aesGcmOpenCombined(dataKey, combined, documentAAD(accountId, version))
    }

    // MARK: Derived values

    /** masterKey = PBKDF2(utf8(password), kdfSalt, iters). Unlocks the password-wrapped data key. */
    fun masterKey(password: String, kdfSalt: ByteArray, iters: Int): ByteArray =
        pbkdf2(password, kdfSalt, iters)

    /** base64(PBKDF2(masterKey, salt=utf8(password), 1)) — the value sent to register / login. */
    fun authVerifier(masterKey: ByteArray, password: String): String =
        b64(pbkdf2(masterKey, password.toByteArray(Charsets.UTF_8), 1))

    /** recoveryKey = PBKDF2(utf8(recoveryCode), kdfSalt, iters). Unlocks the recovery-wrapped data key. */
    fun recoveryKey(recoveryCode: String, kdfSalt: ByteArray, iters: Int): ByteArray =
        pbkdf2(recoveryCode, kdfSalt, iters)

    /** base64(PBKDF2(recoveryKey, salt=utf8(recoveryCode), 1)) — proves recovery-code knowledge to recover. */
    fun recVerifier(recoveryKey: ByteArray, recoveryCode: String): String =
        b64(pbkdf2(recoveryKey, recoveryCode.toByteArray(Charsets.UTF_8), 1))

    /** [count] cryptographically-random bytes (kdfSalt, dataKey, recovery entropy). */
    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

    /**
     * A strong human-friendly recovery code, identical scheme to Apple + the website: "VX-" + 26 Crockford
     * base32 chars over 128 random bits, grouped in 4s. Generated on-device and shown once; the code itself
     * is client-local (each device mints its own), so only its verifier + wrapped key cross the wire.
     */
    fun makeRecoveryCode(): String {
        val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        val bytes = randomBytes(16)
        val bits = StringBuilder(128)
        for (b in bytes) bits.append((b.toInt() and 0xFF).toString(2).padStart(8, '0'))
        val out = StringBuilder()
        var i = 0
        while (i < bits.length) {
            val end = minOf(i + 5, bits.length)
            val chunk = bits.substring(i, end).padEnd(5, '0')
            out.append(alphabet[chunk.toInt(2)])
            i = end
        }
        val groups = mutableListOf<String>()
        var s = 0
        while (s < out.length) {
            val e = minOf(s + 4, out.length)
            groups.add(out.substring(s, e))
            s = e
        }
        return "VX-" + groups.joinToString("-")
    }

    // MARK: Base64 (standard, with padding) + Base64URL (URL-safe, no padding)

    /** Standard base64 WITH padding (salts, wrapped keys, verifiers, account ciphertext on the wire). */
    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    /** Decode standard base64. Null on malformed input (lenient about the exact padding). */
    fun unb64(s: String): ByteArray? = runCatching { Base64.getDecoder().decode(s) }.getOrNull()

    /** base64url, URL-safe alphabet, NO padding — the pairing channel (matches BackupCrypto.base64URL). */
    fun b64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** Decode base64url (accepts input with or without trailing padding). Null on malformed input. */
    fun unb64url(s: String): ByteArray? = runCatching {
        Base64.getUrlDecoder().decode(s.trimEnd('='))
    }.getOrNull()
}
