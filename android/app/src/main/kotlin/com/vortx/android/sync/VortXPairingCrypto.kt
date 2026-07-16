package com.vortx.android.sync

import com.google.crypto.tink.subtle.X25519
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Zero-knowledge device pairing for the VortX account handoff (e.g. phone -> Android TV, which has no
 * camera to scan back). Ported BYTE-FOR-BYTE from the Apple app (`app/SourcesShared/PairingCrypto.swift`
 * + `BackupCrypto.swift`) and the webapp / website (`vault.ts` pairing section), verified interoperable
 * by `cloudflare/e2e-test.mjs` (the household variant shares the exact ECDH + HKDF primitive with a
 * distinct salt/info for domain separation). The joining device publishes an ephemeral X25519 public key;
 * the holder does ECDH against it, derives a one-time wrapping key (HKDF), and seals the 32-byte data key
 * under it. The sync service relays only that ciphertext, so it never learns the account key.
 *
 *   wrappingKey  = HKDF-SHA256(ECDH(ourPriv, peerPub),
 *                              salt = utf8("vortx-pairing-salt-v1"),
 *                              info = utf8("vortx-pairing-v1"), L = 32)
 *   wrapped      = base64url( AES-256-GCM(dataKey 32B, wrappingKey) )   // nonce(12)||ct(32)||tag(16)
 *   public keys  = base64url( X25519 raw public key, 32 bytes )
 *
 * X25519 comes from Tink's `subtle.X25519` (raw RFC 7748 scalar mult), which produces the identical
 * 32-byte shared secret as CryptoKit's `Curve25519.KeyAgreement` (`rawRepresentation`) and WebCrypto's
 * `deriveBits({name:"X25519"}, 256)`. HKDF-SHA256 is hand-rolled per RFC 5869 (extract + expand) over
 * `HmacSHA256`, matching CryptoKit's `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256, salt:, info:)`.
 */
object VortXPairingCrypto {
    private val PAIRING_SALT = "vortx-pairing-salt-v1".toByteArray(Charsets.UTF_8)
    private val PAIRING_INFO = "vortx-pairing-v1".toByteArray(Charsets.UTF_8)
    private const val SHARED_KEY_LEN = 32

    /** A joining device's one-time X25519 key agreement pair. Hold [privateKey] until the handoff completes. */
    class Ephemeral(val privateKey: ByteArray, val publicKey: ByteArray) {
        /** Raw 32-byte public key as base64url (published in the QR / pairing record). */
        val publicKeyBase64URL: String get() = VortXCrypto.b64url(publicKey)
    }

    /** Mint a fresh ephemeral X25519 keypair (private clamped per RFC 7748 by Tink). */
    fun newEphemeral(): Ephemeral {
        val priv = X25519.generatePrivateKey()
        return Ephemeral(priv, X25519.publicFromPrivate(priv))
    }

    /**
     * ECDH(X25519) + HKDF-SHA256 -> the 32-byte one-time wrapping key, from our private key + the peer's
     * raw public key. ECDH is symmetric, so holder and joiner derive the same key. Returns null if the
     * peer key is malformed or the agreement fails.
     */
    private fun wrappingKey(ourPrivate: ByteArray, peerPublic: ByteArray): ByteArray? = runCatching {
        val secret = X25519.computeSharedSecret(ourPrivate, peerPublic)
        hkdfSha256(ikm = secret, salt = PAIRING_SALT, info = PAIRING_INFO, length = SHARED_KEY_LEN)
    }.getOrNull()

    /**
     * Holder side: wrap a raw 32-byte sync data key to the joiner's published public key. Returns the
     * holder's own ephemeral public key (`claimPublicKey`) and the sealed key (`wrapped`), both base64url,
     * or null if anything fails. Mirrors `PairingCrypto.wrapDataKey`.
     */
    fun wrapDataKey(dataKey: ByteArray, toJoinerPublicKeyBase64URL: String): Pair<String, String>? {
        if (dataKey.size != 32) return null
        val peer = VortXCrypto.unb64url(toJoinerPublicKeyBase64URL) ?: return null
        val ephemeralPriv = X25519.generatePrivateKey()
        val wrapKey = wrappingKey(ephemeralPriv, peer) ?: return null
        val sealed = VortXCrypto.aesGcmSealCombined(wrapKey, dataKey) ?: return null
        val claimPublicKey = VortXCrypto.b64url(X25519.publicFromPrivate(ephemeralPriv))
        return claimPublicKey to VortXCrypto.b64url(sealed)
    }

    /**
     * Joiner side: unwrap the sealed 32-byte data key with our ephemeral private key + the holder's
     * ephemeral public key. Returns the raw 32 bytes, or null if anything fails to verify (wrong key,
     * tamper, or the recovered bytes are not exactly 32 long). Mirrors `PairingCrypto.unwrapDataKey`.
     */
    fun unwrapDataKey(wrappedBase64URL: String, holderPublicKeyBase64URL: String, ourPrivate: ByteArray): ByteArray? {
        val holder = VortXCrypto.unb64url(holderPublicKeyBase64URL) ?: return null
        val wrapKey = wrappingKey(ourPrivate, holder) ?: return null
        val sealed = VortXCrypto.unb64url(wrappedBase64URL) ?: return null
        val keyBytes = VortXCrypto.aesGcmOpenCombined(wrapKey, sealed) ?: return null
        return if (keyBytes.size == 32) keyBytes else null
    }

    // MARK: HKDF-SHA256 (RFC 5869) — extract + expand, hand-rolled over HMAC-SHA256

    /**
     * HKDF-SHA256 with an explicit [salt] and [info] to [length] bytes. Standard RFC 5869: PRK =
     * HMAC(salt, ikm); OKM = T(1)||T(2)||... where T(n) = HMAC(PRK, T(n-1) || info || byte(n)). For the
     * pairing use L = 32 = hashLen, so a single expand block. Byte-identical to CryptoKit's
     * `hkdfDerivedSymmetricKey` and WebCrypto's HKDF with the same salt / info / IKM.
     */
    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extract.doFinal(ikm)

        val expand = Mac.getInstance("HmacSHA256")
        expand.init(SecretKeySpec(prk, "HmacSHA256"))
        val hLen = expand.macLength
        val blocks = (length + hLen - 1) / hLen
        val okm = ByteArray(blocks * hLen)
        var prev = ByteArray(0)
        for (n in 1..blocks) {
            expand.update(prev)
            expand.update(info)
            prev = expand.doFinal(byteArrayOf(n.toByte()))
            System.arraycopy(prev, 0, okm, (n - 1) * hLen, hLen)
        }
        return if (okm.size == length) okm else okm.copyOf(length)
    }
}
