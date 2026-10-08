package com.vortx.android.engine

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import java.security.MessageDigest
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
    internal class Attempt internal constructor(val accountID: String, val profileID: String, internal val key: String,
                                               val transactionID: String?, val authority: Authority,
                                               internal val admission: (() -> Boolean) -> Boolean)
    internal class Capture internal constructor(val accountID: String, val profileID: String, val verifiedUID: String,
                                               val transactionID: String?, private val token: String, val authority: Authority) {
        fun request(fields: JSONObject): JSONObject = authority.withActive { JSONObject(fields.toString()).put("authKey", token) }
    }

    fun invalidateContext() = synchronized(lock) { context = UUID.randomUUID() }

    private fun key(account: SessionOwnerSnapshot.Account, profileID: String): String {
        require(UUID.fromString(profileID).toString().uppercase() == profileID) { "Exact uppercase profile UUID required" }
        return "account.${UUID.fromString(account.id).toString().lowercase()}.profile.$profileID"
    }
    private fun slot(accountID: String, profileID: String, uid: String, transactionID: String?): String {
        requireNativeStreamingUID(uid)
        transactionID?.let(NativeAccountBinding::requireTransactionID)
        val domain = transactionID?.let { "transaction:$it" } ?: "verified-import"
        val bytes = "$accountID\u0000$profileID\u0000$uid\u0000$domain".toByteArray(Charsets.UTF_8)
        return "revision." + MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
    private fun confirmed(key: String): String? {
        val snapshot = read(key)
        check(snapshot.availability == PersistentCredentialAvailability.AVAILABLE) { "Streaming credential store unavailable" }
        return snapshot.values[key]
    }
    private fun authority(key: String, accountAdmission: (() -> Boolean) -> Boolean, expected: String? = null,
                          recordKey: String? = null): Authority {
        val generation = generations.getOrPut(key, UUID::randomUUID); val capturedContext = context
        return Authority { action -> synchronized(lock) {
            generation == generations[key] && capturedContext == context && accountAdmission {
                (recordKey == null || confirmed(recordKey) == expected) && action()
            }
        } }
    }
    /** Login starts a new epoch even if the server later returns the same token bytes. */
    fun begin(account: SessionOwnerSnapshot.Account, profileID: String, accountAdmission: (() -> Boolean) -> Boolean,
              transactionID: String? = null): Attempt = synchronized(lock) {
        transactionID?.let(NativeAccountBinding::requireTransactionID)
        val key = key(account, profileID); generations[key] = UUID.randomUUID()
        Attempt("account.${UUID.fromString(account.id).toString().lowercase()}", profileID, key, transactionID,
            authority(key, accountAdmission), accountAdmission).also { it.authority.withActive {} }
    }
    /** Only an exact native selection (or a verified initial-import UID) may name a secure slot.
     * No latest-UID/profile pointer exists; staged failed-CAS revisions are never selected. */
    fun capture(account: SessionOwnerSnapshot.Account, profileID: String, verifiedUID: String, transactionID: String?,
                accountAdmission: (() -> Boolean) -> Boolean): Capture? = synchronized(lock) {
        val key = key(account, profileID)
        val accountID = "account.${UUID.fromString(account.id).toString().lowercase()}"
        val recordKey = slot(accountID, profileID, verifiedUID, transactionID)
        authority(key, accountAdmission).withActive {
            val raw = confirmed(recordKey) ?: return@withActive null
            val record = JSONObject(raw)
            require(record.keys().asSequence().toSet() == setOf("schemaVersion", "accountID", "profileID", "transactionID", "authKey", "verifiedUID"))
            require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 2.0)
            require(record.getString("accountID") == accountID && record.getString("profileID") == profileID &&
                record.get("transactionID") == (transactionID ?: JSONObject.NULL))
            val token = record.get("authKey") as? String ?: error("Invalid streaming credential")
            require(token.isNotBlank())
            val uid = record.get("verifiedUID") as? String ?: error("Invalid streaming identity")
            requireNativeStreamingUID(uid); require(uid == verifiedUID)
            Capture(accountID, profileID, uid, transactionID, token, authority(key, accountAdmission, raw, recordKey))
        }
    }
    /** Called only after getUser verified the exact token; confirmed readback is mandatory. */
    fun storeVerified(attempt: Attempt, token: String, uid: String): Capture = attempt.authority.withActive {
        require(token.isNotBlank()); requireNativeStreamingUID(uid)
        val recordKey = slot(attempt.accountID, attempt.profileID, uid, attempt.transactionID)
        val value = JSONObject().put("schemaVersion", 2).put("accountID", attempt.accountID).put("profileID", attempt.profileID)
            .put("transactionID", attempt.transactionID ?: JSONObject.NULL)
            .put("authKey", token).put("verifiedUID", uid).toString()
        val old = confirmed(recordKey)
        require(old == null || NativeHostPreferences.equal(JSONObject(old), JSONObject(value))) {
            "An immutable streaming credential revision cannot be replaced"
        }
        check((old != null || write(recordKey, value)) && confirmed(recordKey) == (old ?: value)) {
            "Streaming credential could not be stored securely"
        }
        Capture(attempt.accountID, attempt.profileID, uid, attempt.transactionID, token,
            authority(attempt.key, attempt.admission, old ?: value, recordKey))
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
