package com.vortx.android.integrations

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/// AES-encrypted-at-rest key/value store for the external-sync OAuth tokens (Trakt, SIMKL). This is the
/// Android analogue of the Apple Keychain those token sets live in (see `TraktAuth.swift` /
/// `SIMKLAuth.swift`, whose invariant is "token lives here, nowhere else"): access/refresh tokens are
/// credentials, so they never sit in plain SharedPreferences.
///
/// Fail-soft by construction, identical to [com.vortx.android.debrid.DebridKeys]: if the
/// security-crypto artifact is missing or the encrypted store fails to open (a known-rare Keystore
/// corruption) we fall back to a plain SharedPreferences file so auth still functions and the app never
/// crashes at the storage boundary. The fallback is logged.
///
/// Each provider opens its own [SecureTokenStore] with a distinct [fileName], so Trakt and SIMKL tokens
/// live in separate encrypted files (a corruption of one never takes the other down).
internal class SecureTokenStore(context: Context, fileName: String) {

    private val prefs: SharedPreferences = openPrefs(context.applicationContext, fileName)

    /// The stored value for [key], or null when absent/empty (empty is treated as absent, matching the
    /// Apple `Keychain.string(...)?.isEmpty == false` gate).
    fun string(key: String): String? = prefs.getString(key, null)?.takeIf { it.isNotEmpty() }

    /// Persist (or clear, on a null/blank value) a value. Writes are `apply()` (async, off the caller's
    /// thread), matching DebridKeys.
    fun set(key: String, value: String?) {
        prefs.edit().apply {
            if (value.isNullOrEmpty()) remove(key) else putString(key, value)
        }.apply()
    }

    /// Clear every key in [keys] in one edit (the disconnect / sign-out path).
    fun clear(vararg keys: String) {
        prefs.edit().apply { keys.forEach { remove(it) } }.apply()
    }

    private companion object {
        const val TAG = "SecureTokenStore"

        /// Open the encrypted store; on any failure (missing artifact, Keystore corruption) fall back to
        /// a plain prefs file (its name suffixed `_plain`) so auth still works. Never throws.
        fun openPrefs(appContext: Context, fileName: String): SharedPreferences = runCatching {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext,
                fileName,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrElse { error ->
            Log.w(TAG, "EncryptedSharedPreferences unavailable for $fileName; falling back to plain prefs", error)
            appContext.getSharedPreferences("${fileName}_plain", Context.MODE_PRIVATE)
        }
    }
}
