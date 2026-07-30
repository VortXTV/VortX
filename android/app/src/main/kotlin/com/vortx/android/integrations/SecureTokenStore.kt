package com.vortx.android.integrations

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore

/// AES-encrypted-at-rest key/value store for the external-sync OAuth tokens (Trakt, SIMKL). This is the
/// Android analogue of the Apple Keychain those token sets live in (see `TraktAuth.swift` /
/// `SIMKLAuth.swift`, whose invariant is "token lives here, nowhere else"): access/refresh tokens are
/// credentials, so they never sit in plain SharedPreferences.
///
/// If Keystore cannot open, tokens remain memory-only for the current process. They are never written to
/// plain SharedPreferences.
///
/// Each provider opens its own [SecureTokenStore] with a distinct [fileName], so Trakt and SIMKL tokens
/// live in separate encrypted files (a corruption of one never takes the other down).
internal class SecureTokenStore(context: Context, fileName: String) {

    private val store = FailClosedCredentialStore(
        context = context,
        encryptedFileName = fileName,
        tag = TAG,
    )

    /// The stored value for [key], or null when absent/empty (empty is treated as absent, matching the
    /// Apple `Keychain.string(...)?.isEmpty == false` gate).
    fun string(key: String): String? = store.string(key)?.takeIf { it.isNotEmpty() }

    /// Persist (or clear, on a null/blank value) a value.
    fun set(key: String, value: String?): Boolean =
        if (value.isNullOrEmpty()) store.clear(key) else store.set(key, value)

    fun set(values: Map<String, String?>): Boolean = store.set(values)

    /// Clear every key in [keys] in one edit (the disconnect / sign-out path).
    fun clear(vararg keys: String): Boolean = store.clear(*keys)

    private companion object {
        const val TAG = "SecureTokenStore"
    }
}
