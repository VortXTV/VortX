package com.vortx.android.party

import java.util.Base64
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Same AES-256-GCM combined nonce/ciphertext/tag and AAD as the Apple codec. */
internal object WatchPartyWire {
    private val random = SecureRandom()
    private const val MAX_POSITION = 86_400_000L
    data class Control(val action: String, val mediaId: String, val positionMs: Long) {
        override fun toString() = "WatchPartyControl(action=$action, positionMs=$positionMs)"
    }
    fun opaque(value: String, minimum: Int = 22, maximum: Int = 128) =
        value.length in minimum..maximum && value.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-' }
    fun randomToken(): String = encodeUrl(ByteArray(24).also(random::nextBytes))
    fun roomKey(): ByteArray = ByteArray(32).also(random::nextBytes)
    fun encodeUrl(value: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(value)
    fun decodeUrl(value: String): ByteArray? = runCatching {
        require(opaque(value, 1, 128))
        Base64.getUrlDecoder().decode(value).also { require(encodeUrl(it) == value) }
    }.getOrNull()
    fun titleToken(videoId: String): String? {
        val bytes = runCatching {
            val encoded = Charsets.UTF_8.newEncoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                .encode(java.nio.CharBuffer.wrap(videoId))
            ByteArray(encoded.remaining()).also { encoded.get(it) }
        }.getOrNull() ?: return null
        if (bytes.isEmpty() || bytes.size > 512) return null
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("vortx/watch-party/title/v1\n".toByteArray(Charsets.UTF_8))
        return encodeUrl(digest.digest(bytes))
    }
    private fun valid(c: Control) = c.action in setOf("play", "pause", "seek") && opaque(c.mediaId, 1, 256) && c.positionMs in 0..MAX_POSITION
    private fun aad(room: String, term: Long, sequence: Long): ByteArray {
        require(opaque(room) && term in 1..MAX_SAFE_INTEGER && sequence in 1..MAX_SAFE_INTEGER)
        return "vortx/watch-party/v1\n$room\n$term\n$sequence".toByteArray(Charsets.UTF_8)
    }
    fun seal(control: Control, key: ByteArray, room: String, term: Long, sequence: Long): String {
        require(key.size == 32 && valid(control))
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(room, term, sequence))
        val plain = JSONObject().put("action", control.action).put("mediaId", control.mediaId).put("positionMs", control.positionMs)
        return Base64.getEncoder().encodeToString(nonce + cipher.doFinal(plain.toString().toByteArray(Charsets.UTF_8)))
    }
    fun open(encoded: String, key: ByteArray, room: String, term: Long, sequence: Long): Control {
        require(key.size == 32 && encoded.length in 1..8192 && encoded.all { it.isLetterOrDigit() && it.code < 128 || it in "+/=" })
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size in 29..6144 && Base64.getEncoder().encodeToString(bytes) == encoded)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(aad(room, term, sequence))
        val clear = cipher.doFinal(bytes.copyOfRange(12, bytes.size))
        // JSONObject rejects malformed JSON. Exact keys/types prevent coercion, e.g. "1" or 1.5.
        val json = JSONObject(clear.toString(Charsets.UTF_8))
        require(json.keys().asSequence().toSet() == setOf("action", "mediaId", "positionMs"))
        return Control(json.strictString("action"), json.strictString("mediaId"), json.strictLong("positionMs")).also { require(valid(it)) }
    }
}

internal const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
internal fun JSONObject.strictString(key: String): String = (get(key) as? String) ?: error("Invalid party response")
internal fun JSONObject.strictLong(key: String): Long {
    val raw = get(key)
    require(raw is Int || raw is Long) { "Invalid party response" }
    return (raw as Number).toLong().also { require(it in 0..MAX_SAFE_INTEGER) }
}
internal fun JSONObject.opaqueString(key: String): String = strictString(key).also { require(WatchPartyWire.opaque(it)) }
