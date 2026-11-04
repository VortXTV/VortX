package com.vortx.android.sync

import com.vortx.android.engine.NativeProfileOverlayWitness
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** Header syntax/tuple admission only. HTTPS supplies authenticity; the client has no signing key. */
internal object SessionRenewalPolicy {
    private const val MAX_SAFE = 9_007_199_254_740_991L
    private const val LIFETIME_MS = 121L * 24 * 60 * 60 * 1_000
    internal val tupleKeys get() = arrayOf("token", "account", "dataKey", "ownerEpoch")
    private data class Claims(val version: Long, val expiry: Long)

    fun eligibleResponse(method: String, path: String, status: Int, ifNoneMatch: String?,
                         etag: String?, emptyBody: Boolean): Boolean {
        if (path == "/v1/auth" || path.startsWith("/v1/auth/") ||
            path == "/v1/qr" || path.startsWith("/v1/qr/")) return false
        if (status in 200..299) return true
        if (status != 304 || method != "GET" || path != "/v1/backup" || !emptyBody ||
            ifNoneMatch == null || etag != ifNoneMatch) return false
        val revision = ifNoneMatch.removeSurrounding("\"")
        return ifNoneMatch == "\"$revision\"" && safeInteger(revision) != null
    }

    fun accepts(candidate: String?, sentToken: String, accountID: String, nowMilliseconds: Long): Boolean {
        if (nowMilliseconds !in 1..(MAX_SAFE - LIFETIME_MS) || candidate == null) return false
        val prior = claims(sentToken, accountID, nowMilliseconds) ?: return false
        val next = claims(candidate, accountID, nowMilliseconds) ?: return false
        return prior.version == next.version && next.expiry > prior.expiry
    }

    private fun claims(raw: String, accountID: String, now: Long): Claims? = runCatching {
        require(raw.length <= 4096 && UUID.fromString(accountID).toString() == accountID)
        val pieces = raw.split('.')
        require(pieces.size == 2)
        val payload = decode(pieces[0], 2048)
        require(decode(pieces[1], 64).size == 32)
        val obj = NativeProfileOverlayWitness.parseDocument(payload)
        require(obj.opt("a") is String && obj.getString("a") == accountID)
        val version = safeInteger((obj.opt("v") as? Number)?.toString()) ?: error("Invalid version")
        val expiry = safeInteger((obj.opt("exp") as? Number)?.toString()) ?: error("Invalid expiry")
        require(expiry > now && expiry <= now + LIFETIME_MS)
        Claims(version, expiry)
    }.getOrNull()

    private fun decode(raw: String, maximum: Int): ByteArray {
        require(raw.isNotEmpty() && raw.length <= maximum && raw.all {
            it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_'
        })
        val bytes = Base64.getUrlDecoder().decode(raw)
        require(Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == raw)
        return bytes
    }

    private fun safeInteger(raw: String?): Long? {
        if (raw == null || raw.isEmpty() || raw.length > 16 || raw.any { it !in '0'..'9' } ||
            raw.length > 1 && raw.first() == '0') return null
        return raw.toLongOrNull()?.takeIf { it in 0..MAX_SAFE }
    }

    /** Preserve exact stored non-token strings (including unknown account fields and legacy absent epoch).
     * The supplied CAS must compare, commit and read back this entire confirmed tuple under one store lock. */
    fun persistConfirmed(candidate: String, sentToken: String, session: VortXSyncManager.Session,
                         ownerEpoch: Long, snapshot: PersistentCredentialSnapshot,
                         replace: (Map<String, String?>, Map<String, String?>) -> Boolean): Boolean {
        if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE ||
            session.currentBearer != sentToken || snapshot.values.keys != tupleKeys.toSet()) return false
        val raw = snapshot.values
        if (raw["token"] != sentToken) return false
        val accountRaw = raw["account"] ?: return false
        val keyRaw = raw["dataKey"] ?: return false
        val storedEpoch = raw["ownerEpoch"]?.let(::safeInteger) ?: if (raw["ownerEpoch"] == null) 1L else return false
        if (storedEpoch != ownerEpoch || keyRaw != Base64.getEncoder().encodeToString(session.dataKey)) return false
        val key = runCatching { Base64.getDecoder().decode(keyRaw) }.getOrNull() ?: return false
        if (key.size != 32 || !MessageDigest.isEqual(key, session.dataKey)) return false
        val account = runCatching { NativeProfileOverlayWitness.parseDocument(accountRaw.toByteArray(Charsets.UTF_8)) }.getOrNull()
            ?: return false
        if (account.opt("id") != session.account.id || account.opt("email") != session.account.email ||
            account.opt("username") != session.account.username ||
            (account.opt("twoFactorEnabled") ?: false) != session.account.twoFactorEnabled) return false
        return replace(raw, mapOf("token" to candidate))
    }
}
