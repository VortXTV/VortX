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
        internal fun fenced(authority: Authority) = Capture(accountID, profileID, verifiedUID, transactionID, token, authority)
    }
    internal class OwnerSelection internal constructor(val accountID: String, val profileID: String,
        internal val raw: String?, val verifiedUID: String?, internal val revision: String?)

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

    private fun ownerSelector(accountID: String, profileID: String): String = "owner-selection." +
        MessageDigest.getInstance("SHA-256").digest("$accountID\u0000$profileID".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    /** Device-local selection only. No global/legacy token or native owner account mutation. */
    fun ownerSelection(account: SessionOwnerSnapshot.Account, ownerID: String,
                       admission: (() -> Boolean) -> Boolean): OwnerSelection = synchronized(lock) {
        val key = key(account, ownerID)
        authority(key, admission).withActive {
            val scope = "account.${UUID.fromString(account.id).toString().lowercase()}"
            val raw = confirmed(ownerSelector(scope, ownerID))
            val value = raw?.let(::JSONObject)
            if (value != null) {
                require(value.keys().asSequence().toSet() == setOf("schemaVersion", "scope", "ownerProfileID", "verifiedUID", "revision"))
                require(value.get("schemaVersion") is Number && value.getDouble("schemaVersion") == 2.0)
                require(value.getString("scope") == scope && value.getString("ownerProfileID") == ownerID)
                require(value.get("verifiedUID") is String || value.isNull("verifiedUID"))
                if (!value.isNull("verifiedUID")) requireNativeStreamingUID(value.getString("verifiedUID"))
                require(UUID.fromString(value.getString("revision")).toString() == value.getString("revision"))
                val intent = JSONObject(checkNotNull(confirmed(ownerIntentKey(ownerSelector(scope, ownerID), value.getString("revision")))))
                require(intent.keys().asSequence().toSet() == setOf("schemaVersion", "scope", "ownerProfileID", "revision",
                    "previousSelection", "proposedSelection", "credentialRecordSHA256"))
                require(intent.get("schemaVersion") is Number && intent.getDouble("schemaVersion") == 1.0)
                require(intent.getString("scope") == scope && intent.getString("ownerProfileID") == ownerID &&
                    intent.getString("revision") == value.getString("revision") && intent.getString("proposedSelection") == raw)
                require(intent.get("previousSelection") is String || intent.isNull("previousSelection"))
                if (value.isNull("verifiedUID")) require(intent.isNull("credentialRecordSHA256"))
                else {
                    val record = checkNotNull(confirmed(slot(scope, ownerID, value.getString("verifiedUID"), "owner:${value.getString("revision")}")))
                    require(intent.getString("credentialRecordSHA256") == digest(record)) { "Owner credential intent mismatch" }
                }
            }
            OwnerSelection(scope, ownerID, raw, value?.opt("verifiedUID") as? String, value?.getString("revision"))
        }
    }

    fun captureOwner(account: SessionOwnerSnapshot.Account, selection: OwnerSelection,
                     admission: (() -> Boolean) -> Boolean): Capture? = synchronized(lock) {
        require(selection.accountID == "account.${UUID.fromString(account.id).toString().lowercase()}")
        val selector = ownerSelector(selection.accountID, selection.profileID)
        authority(key(account, selection.profileID), admission).withActive {
            check(confirmed(selector) == selection.raw) { "Owner streaming account changed" }
            check(ownerSelection(account, selection.profileID, admission).raw == selection.raw)
            if (selection.verifiedUID == null) return@withActive null
            val capture = checkNotNull(capture(account, selection.profileID, requireNotNull(selection.verifiedUID),
                "owner:${requireNotNull(selection.revision)}", admission)) { "Selected owner credential unavailable" }
            capture.fenced(Authority { action -> capture.authority.withActive {
                confirmed(selector) == selection.raw && action()
            } })
        }
    }

    private fun digest(raw: String) = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    private fun ownerIntentKey(selector: String, revision: String) = "owner-intent." + digest("$selector\u0000$revision")

    /** Caller holds journal/auth/mounted admission. Immutable intent is certified before selection;
     * a pointer alone can never authorize a token on cold reopen. A clear is an intent-bound tombstone. */
    private fun commitOwnerSelection(account: SessionOwnerSnapshot.Account, expected: OwnerSelection, value: JSONObject,
                                     credentialRecord: String?) {
        val selector = ownerSelector(expected.accountID, expected.profileID)
        val raw = value.toString()
        val intentKey = ownerIntentKey(selector, value.getString("revision"))
        val intent = JSONObject().put("schemaVersion", 1).put("scope", expected.accountID).put("ownerProfileID", expected.profileID)
            .put("revision", value.getString("revision")).put("previousSelection", expected.raw ?: JSONObject.NULL)
            .put("proposedSelection", raw).put("credentialRecordSHA256", credentialRecord?.let(::digest) ?: JSONObject.NULL).toString()
        val existing = confirmed(intentKey)
        require(existing == null || existing == intent) { "Immutable owner credential intent changed" }
        check((existing != null || write(intentKey, intent)) && confirmed(intentKey) == intent) { "Owner credential intent could not be stored" }
        // BEFORE attempting publication, even when it installs and its acknowledgement fails.
        generations[key(account, expected.profileID)] = UUID.randomUUID()
        try {
            // Store.write is the durable commit acknowledgement. A redundant fallible read cannot
            // turn a certified successful publication into an ordinary sign-in failure.
            if (!write(selector, raw)) throw NativeOwnerPublicationUncertain()
        } catch (uncertain: NativeOwnerPublicationUncertain) { throw uncertain }
        catch (_: Exception) { throw NativeOwnerPublicationUncertain() }
    }

    /** Caller holds the native session; journal -> auth -> mounted admission spans publication. */
    fun selectOwner(account: SessionOwnerSnapshot.Account, expected: OwnerSelection, candidate: Capture,
                    mountedAdmission: (() -> Boolean) -> Boolean) = candidate.authority.withActive {
        require(expected.accountID == "account.${UUID.fromString(account.id).toString().lowercase()}")
        require(candidate.accountID == expected.accountID && candidate.profileID == expected.profileID)
        val revision = requireNotNull(candidate.transactionID).removePrefix("owner:")
        require(candidate.transactionID == "owner:$revision" && UUID.fromString(revision).toString() == revision)
        val selector = ownerSelector(expected.accountID, expected.profileID)
        check(confirmed(selector) == expected.raw) { "Owner streaming account changed" }
        check(mountedAdmission {
            val value = JSONObject().put("schemaVersion", 2).put("scope", expected.accountID).put("ownerProfileID", expected.profileID)
                .put("verifiedUID", candidate.verifiedUID).put("revision", revision)
            val record = checkNotNull(confirmed(slot(expected.accountID, expected.profileID, candidate.verifiedUID, candidate.transactionID)))
            commitOwnerSelection(account, expected, value, record)
            true
        }) { "Native account changed" }
    }

    fun clearOwner(account: SessionOwnerSnapshot.Account, expected: OwnerSelection,
                   admission: (() -> Boolean) -> Boolean, mountedAdmission: (() -> Boolean) -> Boolean) = synchronized(lock) {
        val key = key(account, expected.profileID)
        require(expected.accountID == "account.${UUID.fromString(account.id).toString().lowercase()}")
        authority(key, admission).withActive {
            val selector = ownerSelector(expected.accountID, expected.profileID)
            check(confirmed(selector) == expected.raw) { "Owner streaming account changed" }
            check(mountedAdmission {
                commitOwnerSelection(account, expected, JSONObject().put("schemaVersion", 2).put("scope", expected.accountID)
                    .put("ownerProfileID", expected.profileID).put("verifiedUID", JSONObject.NULL).put("revision", UUID.randomUUID().toString()), null)
                true
            }) { "Native account changed" }
        }
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

internal class NativeOwnerPublicationUncertain : IllegalStateException("Owner credential update outcome is uncertain; reopen the account to reconcile its durable intent")

internal fun requireNativeStreamingUID(uid: String) {
    require(uid.isNotBlank() && uid == uid.trim() && uid.toByteArray(Charsets.UTF_8).size <= 256 && uid.none(Char::isISOControl)) {
        "Invalid authenticated streaming identity"
    }
}
