package com.vortx.android.engine

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import java.util.UUID

/** Device-only, account AND profile qualified streaming credentials. No legacy/global adoption.
 * All mutations and admissions use journal -> captured account admission; callers must not hold
 * the account monitor before entering this object. Native commits may enter with Session held. */
internal class NativeOwnAccountCredentials(
    private val read: (String) -> PersistentCredentialSnapshot,
    private val write: (String, String?) -> Boolean,
) {
    private val lock = Any()
    private val generations = mutableMapOf<String, UUID>()
    private var context = UUID.randomUUID()

    internal class Authority internal constructor(private val gate: (() -> Boolean) -> Boolean) {
        fun <T> withActive(action: () -> T): T {
            var result: Result<T>? = null
            check(gate { result = runCatching(action); true }) { "Streaming account capture changed" }
            return requireNotNull(result).getOrThrow()
        }
    }
    internal class Attempt internal constructor(val profileID: String, internal val key: String, val authority: Authority)
    internal class Capture internal constructor(val accountID: String, val profileID: String, val verifiedUID: String,
                                               private val token: String, val authority: Authority) {
        fun request(fields: JSONObject): JSONObject = authority.withActive { JSONObject(fields.toString()).put("authKey", token) }
    }

    fun invalidateContext() = synchronized(lock) { context = UUID.randomUUID() }

    private fun key(account: SessionOwnerSnapshot.Account, profileID: String): String {
        require(UUID.fromString(profileID).toString().uppercase() == profileID) { "Exact uppercase profile UUID required" }
        return "account.${UUID.fromString(account.id).toString().lowercase()}.profile.$profileID"
    }
    private fun confirmed(key: String): String? {
        val snapshot = read(key)
        check(snapshot.availability == PersistentCredentialAvailability.AVAILABLE) { "Streaming credential store unavailable" }
        return snapshot.values[key]
    }
    private fun authority(key: String, accountAdmission: (() -> Boolean) -> Boolean, expected: String? = null,
                          checkRecord: Boolean = false): Authority {
        val generation = generations.getOrPut(key, UUID::randomUUID); val capturedContext = context
        return Authority { action -> synchronized(lock) {
            generation == generations[key] && capturedContext == context && accountAdmission {
                (!checkRecord || confirmed(key) == expected) && action()
            }
        } }
    }
    /** Login starts a new epoch even if the server later returns the same token bytes. */
    fun begin(account: SessionOwnerSnapshot.Account, profileID: String, accountAdmission: (() -> Boolean) -> Boolean): Attempt = synchronized(lock) {
        val key = key(account, profileID); generations[key] = UUID.randomUUID()
        Attempt(profileID, key, authority(key, accountAdmission)).also { it.authority.withActive {} }
    }
    fun capture(account: SessionOwnerSnapshot.Account, profileID: String, accountAdmission: (() -> Boolean) -> Boolean): Capture? = synchronized(lock) {
        val key = key(account, profileID)
        authority(key, accountAdmission).withActive {
            val raw = confirmed(key) ?: return@withActive null
            val record = JSONObject(raw)
            require(record.keys().asSequence().toSet() == setOf("schemaVersion", "revision", "authKey", "verifiedUID"))
            require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 1.0)
            UUID.fromString(record.getString("revision"))
            val token = record.get("authKey") as? String ?: error("Invalid streaming credential")
            require(token.isNotBlank())
            val uid = record.get("verifiedUID") as? String ?: error("Invalid streaming identity")
            requireNativeStreamingUID(uid)
            Capture("account.${UUID.fromString(account.id).toString().lowercase()}", profileID, uid, token, authority(key, accountAdmission, raw, true))
        }
    }
    /** Called only after getUser verified the exact token; confirmed readback is mandatory. */
    fun storeVerified(attempt: Attempt, token: String, uid: String) = attempt.authority.withActive {
        require(token.isNotBlank()); requireNativeStreamingUID(uid)
        val value = JSONObject().put("schemaVersion", 1).put("revision", UUID.randomUUID().toString())
            .put("authKey", token).put("verifiedUID", uid).toString()
        check(write(attempt.key, value) && confirmed(attempt.key) == value) { "Streaming credential could not be stored securely" }
    }
    fun clear(attempt: Attempt) = attempt.authority.withActive {
        check(write(attempt.key, null) && confirmed(attempt.key) == null) { "Streaming credential removal could not be confirmed" }
    }

    companion object {
        const val FILE = "vortx_native_streaming_credentials"
        @Volatile private var instance: NativeOwnAccountCredentials? = null
        fun shared(context: Context): NativeOwnAccountCredentials = instance ?: synchronized(this) {
            instance ?: FailClosedCredentialStore(context, FILE, tag = "NativeStreamingCredentials").let { store ->
                NativeOwnAccountCredentials({ store.confirmedSnapshot(it) }, store::set).also { instance = it }
            }
        }
    }
}

internal fun requireNativeStreamingUID(uid: String) {
    require(uid.isNotBlank() && uid == uid.trim() && uid.toByteArray(Charsets.UTF_8).size <= 256 && uid.none(Char::isISOControl)) {
        "Invalid authenticated streaming identity"
    }
}
