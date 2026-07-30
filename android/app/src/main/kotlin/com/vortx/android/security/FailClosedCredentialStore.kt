package com.vortx.android.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * A tiny encrypted credential store that never falls back to disk plaintext.
 *
 * If Android Keystore or EncryptedSharedPreferences is unavailable, credentials remain usable for the
 * current process from memory and disappear on restart. Any legacy plaintext fallback file is purged at
 * initialization and again on removal. Reads and writes also fail closed if an opened encrypted store later
 * becomes unreadable.
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
        val backend = openCredentialBackendOrNull({
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

        state = FailClosedCredentialState(backend) { error ->
            Log.e(tag, "Encrypted credential storage failed; using memory only", error)
            try {
                appContext.deleteSharedPreferences(encryptedFileName)
            } catch (error: Exception) {
                Log.e(tag, "Could not delete failed encrypted credential storage", error)
            }
        }
    }

    fun string(key: String): String? = state.string(key)

    fun set(key: String, value: String?): Boolean = state.write(mapOf(key to value))

    fun set(values: Map<String, String?>): Boolean = state.write(values)

    fun clear(vararg keys: String): Boolean {
        val result = state.write(keys.associateWith { null })
        purgeLegacyPlaintext()
        if (!state.hasPersistentBackend) {
            try {
                appContext.deleteSharedPreferences(encryptedFileName)
            } catch (error: Exception) {
                Log.e(tag, "Could not delete unavailable encrypted credential storage", error)
            }
        }
        return result
    }

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
    private val onBackendFailure: (Exception) -> Unit = {},
) {
    private var backend: CredentialBackend? = backend
    private val memory = mutableMapOf<String, String>()

    val hasPersistentBackend: Boolean
        @Synchronized get() = backend != null

    @Synchronized
    fun string(key: String): String? {
        val persistent = backend
        if (persistent != null) {
            try {
                val value = persistent.string(key)
                if (value == null) memory.remove(key) else memory[key] = value
                return value
            } catch (error: Exception) {
                disableBackend(error)
            }
        }
        return memory[key]
    }

    @Synchronized
    fun write(values: Map<String, String?>): Boolean {
        values.forEach { (key, value) ->
            if (value == null) memory.remove(key) else memory[key] = value
        }

        val persistent = backend ?: return false
        try {
            if (persistent.write(values)) return true
            disableBackend(IllegalStateException("Encrypted credential commit was rejected"))
        } catch (error: Exception) {
            disableBackend(error)
        }
        return false
    }

    private fun disableBackend(error: Exception) {
        if (backend == null) return
        backend = null
        onBackendFailure(error)
    }
}
