package com.vortx.android.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * A tiny encrypted credential store that never falls back to disk plaintext.
 *
 * If Android Keystore or EncryptedSharedPreferences is unavailable, new writes remain usable for the current
 * process from memory and disappear on restart. Any legacy plaintext fallback file is purged at initialization
 * and again on removal. Initial-open and read failures remain retryable. An ambiguous encrypted write outcome
 * permanently blocks backend reopening for this process so SharedPreferences' mutated process cache cannot be
 * mistaken for durable credential truth. The encrypted file is always retained across backend failures.
 */
internal class FailClosedCredentialStore(
    context: Context,
    private val encryptedFileName: String,
    private val legacyPlainFileName: String = "${encryptedFileName}_plain",
    private val tag: String,
) {
    private val appContext = context.applicationContext
    private val state: FailClosedCredentialState

    init {
        purgeLegacyPlaintext()
        state = FailClosedCredentialState(
            backend = openBackend(),
            onBackendFailure = { error ->
                Log.e(tag, "Encrypted credential storage failed; using confirmed state", error)
            },
            reopenBackend = ::openBackend,
        )
    }

    private fun openBackend(): CredentialBackend? =
        openCredentialBackendOrNull({
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                appContext,
                encryptedFileName,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            SharedPreferencesCredentialBackend(prefs)
        }) { error ->
            Log.e(tag, "Encrypted credential storage unavailable; using memory only", error)
        }

    fun string(key: String): String? = state.string(key)

    fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot =
        state.confirmedSnapshot(*keys)

    fun setIfConfirmedAbsent(key: String, value: String): ConditionalCredentialWrite =
        state.writeIfConfirmedAbsent(key, value)

    fun set(key: String, value: String?): Boolean = state.write(mapOf(key to value))

    fun set(values: Map<String, String?>): Boolean = state.write(values)

    fun setAndPurgeLegacy(values: Map<String, String?>): Boolean =
        writeThenPurgeLegacy(
            write = { state.write(values) },
            purge = ::purgeLegacyPlaintext,
        )

    fun clear(vararg keys: String): Boolean =
        setAndPurgeLegacy(keys.associateWith { null })

    private fun purgeLegacyPlaintext() {
        val cleared = try {
            appContext.getSharedPreferences(legacyPlainFileName, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .commit()
        } catch (error: Exception) {
            Log.e(tag, "Could not purge legacy plaintext credential storage", error)
            false
        }
        val deleted = try {
            appContext.deleteSharedPreferences(legacyPlainFileName)
        } catch (error: Exception) {
            Log.e(tag, "Could not delete legacy plaintext credential storage", error)
            false
        }
        if (!cleared && !deleted) {
            Log.e(tag, "Legacy plaintext credential storage could not be cleared or deleted")
        }
    }
}

internal fun writeThenPurgeLegacy(
    write: () -> Boolean,
    purge: () -> Unit,
): Boolean {
    return try {
        write()
    } finally {
        purge()
    }
}

internal fun openCredentialBackendOrNull(
    opener: () -> CredentialBackend,
    onFailure: (Exception) -> Unit = {},
): CredentialBackend? = try {
    opener()
} catch (error: Exception) {
    onFailure(error)
    null
}

internal interface CredentialBackend {
    fun string(key: String): String?
    fun write(values: Map<String, String?>): Boolean
}

internal enum class PersistentCredentialAvailability {
    AVAILABLE,
    UNAVAILABLE,
}

internal data class PersistentCredentialSnapshot(
    val availability: PersistentCredentialAvailability,
    val values: Map<String, String?>,
)

internal enum class ConditionalCredentialWrite {
    WRITTEN,
    ALREADY_PRESENT,
    UNAVAILABLE,
    REJECTED,
}

private class SharedPreferencesCredentialBackend(
    private val prefs: SharedPreferences,
) : CredentialBackend {
    override fun string(key: String): String? = prefs.getString(key, null)

    override fun write(values: Map<String, String?>): Boolean {
        val editor = prefs.edit()
        values.forEach { (key, value) ->
            if (value == null) editor.remove(key) else editor.putString(key, value)
        }
        return editor.commit()
    }
}

/**
 * Pure state machine behind [FailClosedCredentialStore]. Keeping this independent of Android makes the
 * secure-open, post-open read, and post-open write failure paths executable in local unit tests.
 */
internal class FailClosedCredentialState(
    backend: CredentialBackend?,
    private val reopenBackend: () -> CredentialBackend? = { null },
    private val onBackendFailure: (Exception) -> Unit = {},
) {
    private var backend: CredentialBackend? = backend
    private var writeFailurePoisoned = false
    private val memory = mutableMapOf<String, String>()
    private val confirmed = mutableMapOf<String, String>()

    val hasPersistentBackend: Boolean
        @Synchronized get() = backend != null

    @Synchronized
    fun string(key: String): String? {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent != null) {
            try {
                val value = persistent.string(key)
                rememberConfirmed(key, value)
                return value
            } catch (error: Exception) {
                disableBackend(error)
            }
        }
        return memory[key]
    }

    @Synchronized
    fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot {
        val requestedKeys = keys.distinct()
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) {
            return unavailableSnapshot(requestedKeys)
        }
        return try {
            val values = requestedKeys.associateWith(persistent::string)
            values.forEach(::rememberConfirmed)
            PersistentCredentialSnapshot(
                availability = PersistentCredentialAvailability.AVAILABLE,
                values = values,
            )
        } catch (error: Exception) {
            disableBackend(error)
            unavailableSnapshot(requestedKeys)
        }
    }

    /**
     * Atomically adopt [value] only after this same persistent backend confirms [key] is absent. This prevents
     * a read outage followed by a successful reopen from overwriting a credential that was durable all along.
     */
    @Synchronized
    fun writeIfConfirmedAbsent(key: String, value: String): ConditionalCredentialWrite {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) return ConditionalCredentialWrite.UNAVAILABLE
        val existing = try {
            persistent.string(key)
        } catch (error: Exception) {
            disableBackend(error)
            return ConditionalCredentialWrite.UNAVAILABLE
        }
        rememberConfirmed(key, existing)
        if (existing != null) {
            return ConditionalCredentialWrite.ALREADY_PRESENT
        }
        val stored = try {
            persistent.write(mapOf(key to value))
        } catch (error: Exception) {
            poisonBackend(error)
            return ConditionalCredentialWrite.UNAVAILABLE
        }
        return if (stored) {
            memory[key] = value
            confirmed[key] = value
            ConditionalCredentialWrite.WRITTEN
        } else {
            poisonBackend(IllegalStateException("Encrypted credential commit was rejected"))
            ConditionalCredentialWrite.REJECTED
        }
    }

    @Synchronized
    fun write(values: Map<String, String?>): Boolean {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) {
            if (!writeFailurePoisoned) apply(memory, values)
            return false
        }
        val previousValues = try {
            values.keys.associateWith(persistent::string)
        } catch (error: Exception) {
            disableBackend(error)
            return false
        }
        previousValues.forEach(::rememberConfirmed)
        val stored = try {
            persistent.write(values)
        } catch (error: Exception) {
            poisonBackend(error)
            return false
        }
        if (!stored) {
            poisonBackend(IllegalStateException("Encrypted credential commit was rejected"))
            return false
        }
        apply(memory, values)
        apply(confirmed, values)
        return true
    }

    private fun reopenPersistentBackend(): CredentialBackend? {
        if (writeFailurePoisoned) return null
        val reopened = try {
            reopenBackend()
        } catch (error: Exception) {
            onBackendFailure(error)
            null
        }
        backend = reopened
        return reopened
    }

    private fun unavailableSnapshot(keys: Collection<String>): PersistentCredentialSnapshot =
        PersistentCredentialSnapshot(
            availability = PersistentCredentialAvailability.UNAVAILABLE,
            values = keys.associateWith(confirmed::get),
        )

    private fun rememberConfirmed(key: String, value: String?) {
        if (value == null) {
            confirmed.remove(key)
            memory.remove(key)
        } else {
            confirmed[key] = value
            memory[key] = value
        }
    }

    private fun apply(target: MutableMap<String, String>, values: Map<String, String?>) {
        values.forEach { (key, value) ->
            if (value == null) target.remove(key) else target[key] = value
        }
    }

    private fun disableBackend(error: Exception) {
        if (backend == null) return
        backend = null
        onBackendFailure(error)
    }

    private fun poisonBackend(error: Exception) {
        backend = null
        writeFailurePoisoned = true
        onBackendFailure(error)
    }
}
