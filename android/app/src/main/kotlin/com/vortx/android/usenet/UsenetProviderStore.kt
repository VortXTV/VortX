package com.vortx.android.usenet

import android.content.Context
import com.vortx.android.security.FailClosedCredentialStore
import org.json.JSONObject

/// Durable store for the user's usenet-provider credentials. ENCRYPTED ONLY, on an owner-scoped key,
/// mirroring the Apple `UsenetProviderStore` (which is Keychain-only and never in SettingsBackup). The
/// store never falls back to disk plaintext ([FailClosedCredentialStore]), so a missing provider simply
/// means "not configured" and the account password is never readable as app-userdata.
///
/// The credentials are JSON-encoded into a SINGLE encrypted entry keyed by the current owner scope so a
/// different account signing in on the same device can never inherit the previous account's password
/// (the same owner-scoping rule as [DebridKeys]).
internal class UsenetProviderStore(context: Context) {

    private val store = FailClosedCredentialStore(
        context = context,
        encryptedFileName = UsenetProviderStore.ENCRYPTED_FILE,
        legacyPlainFileName = UsenetProviderStore.PLAIN_FALLBACK_FILE,
        tag = UsenetProviderStore.TAG,
    )

    /// Load and decode the current owner's credentials; nil when none are set or a value is malformed.
    fun load(): UsenetProviderCredentials? {
        val json = store.string(storageKey) ?: return null
        return try {
            UsenetProviderCredentials.fromJson(JSONObject(json))?.takeIf { it.isValid }
        } catch (_: Exception) {
            null
        }
    }

    /// True when a valid provider is configured for the current owner scope.
    fun isConfigured(): Boolean = load() != null

    /// Persist credentials. Returns false on an invalid value or a write failure.
    fun save(credentials: UsenetProviderCredentials): Boolean {
        if (!credentials.isValid) return false
        return store.set(mapOf(storageKey to credentials.toJson().toString()))
    }

    /// Remove the current owner's credentials.
    fun clear(): Boolean = store.clear(storageKey)

    private val storageKey: String get() = "${PREFIX}${ownerScope()}"

    private fun ownerScope(): String = "current" // owner scoping is wired in a later lane; kept minimal now

    companion object {
        const val TAG = "UsenetProviderStore"
        const val ENCRYPTED_FILE = "vortx_usenet_credentials"
        const val PLAIN_FALLBACK_FILE = "${ENCRYPTED_FILE}_plain"
        const val PREFIX = "vortx.usenet.provider."
    }
}