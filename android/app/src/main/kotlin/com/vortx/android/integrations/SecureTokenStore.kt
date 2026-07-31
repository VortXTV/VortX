package com.vortx.android.integrations

import android.content.Context
import com.vortx.android.security.ConditionalCredentialWrite
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot

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
internal interface CredentialStoreAccess {
    fun string(key: String): String?
    fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot

    /// Single-key compatibility view. An unavailable backend is never reported as cached credential truth.
    fun confirmedString(key: String): String? {
        val snapshot = confirmedSnapshot(key)
        return snapshot.values[key]?.takeIf {
            snapshot.availability == PersistentCredentialAvailability.AVAILABLE && it.isNotEmpty()
        }
    }
    fun set(key: String, value: String?): Boolean
    fun set(values: Map<String, String?>): Boolean
    fun clear(vararg keys: String): Boolean
}

internal enum class CredentialConnectionState {
    CONNECTED,
    DISCONNECTED,
    STORAGE_UNAVAILABLE,
}

internal class SecureTokenStore(context: Context, fileName: String) : CredentialStoreAccess {

    private val store = FailClosedCredentialStore(
        context = context,
        encryptedFileName = fileName,
        tag = TAG,
    )

    /// The stored value for [key], or null when absent/empty (empty is treated as absent, matching the
    /// Apple `Keychain.string(...)?.isEmpty == false` gate).
    override fun string(key: String): String? = store.string(key)?.takeIf { it.isNotEmpty() }

    /// One atomic, exact snapshot of values confirmed in encrypted storage. Structured consumers must
    /// distinguish an absent field from a present empty field; only the single-string views collapse empty.
    override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot =
        projectConfirmedSnapshot(store.confirmedSnapshot(*keys))

    fun setIfConfirmedAbsent(key: String, value: String): ConditionalCredentialWrite =
        store.setIfConfirmedAbsent(key, value)

    /// Persist (or clear, on a null/empty value) a value.
    override fun set(key: String, value: String?): Boolean =
        if (value.isNullOrEmpty()) store.clear(key) else store.set(key, value)

    override fun set(values: Map<String, String?>): Boolean = store.set(values)

    /// Clear every key in [keys] in one edit (the disconnect / sign-out path).
    override fun clear(vararg keys: String): Boolean = store.clear(*keys)

    internal companion object {
        /**
         * Pure projection for local tests of this Android-backed boundary. Structured snapshots preserve
         * persisted values byte-for-byte, including an empty string that single-string compatibility hides.
         */
        fun projectConfirmedSnapshot(snapshot: PersistentCredentialSnapshot): PersistentCredentialSnapshot =
            snapshot

        private const val TAG = "SecureTokenStore"
    }
}
