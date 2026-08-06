package com.vortx.android.skip

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.integrations.SecureTokenStore

/// The Android analogue of the Apple skip stack's `UserDefaults` provider key + `ApiKeys.skipDBKey()` /
/// `ApiKeys.customSkipURL()` / `ApiKeys.customSkipKey()` accessors. Backs the crowd provider selection and
/// the OPTIONAL best-effort legs (community skipdb.tv + a user's custom SkipDB-compatible mirror).
///
/// FAIL-SOFT / DORMANT by default: with no credentials configured, the community + custom keys resolve to
/// null and those legs make zero network calls, exactly like the Apple actors when `ApiKeys` returns nil.
/// The provider choice remains a preference. API keys and the custom endpoint use encrypted storage, matching
/// the Apple Keychain boundary. [init] is idempotent and migrates the three legacy preference values in place.
object SkipConfig {

    /// Values: "theintrodb" | "skipdb" | "both". Matches the Apple `SkipTimestampService.providerKey`
    /// string ("stremiox.skipProvider"). The getter's DEFAULT is "both", byte-for-byte with the Apple
    /// getter `UserDefaults.standard.string(forKey: providerKey) ?? "both"` (the value the code returns;
    /// the "theintrodb" in the Apple doc comment is stale relative to the code).
    const val PROVIDER_KEY = "stremiox.skipProvider"

    private const val PREFS_FILE = "vortx_skip"
    private const val CREDENTIALS_FILE = "vortx_skip_credentials"

    internal val credentialKeys = listOf(
        SkipCredentialKey("vortx.apikey.skipdb", "vortx.skip.skipdbKey"),
        SkipCredentialKey("vortx.skip.customurl", "vortx.skip.customUrl"),
        SkipCredentialKey("vortx.apikey.customskip", "vortx.skip.customKey"),
    )

    @Volatile private var prefs: SharedPreferences? = null
    @Volatile private var credentials: SecureTokenStore? = null

    /// Idempotent init: wire the preferences file. Safe to call from every entry point (the player skip
    /// fetch, a later Streams-settings screen). Cheap and network-free.
    fun init(context: Context) {
        if (prefs == null || credentials == null) {
            synchronized(this) {
                if (prefs == null || credentials == null) {
                    val appContext = context.applicationContext
                    val loadedPrefs = appContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                    val loadedCredentials = SecureTokenStore(appContext, CREDENTIALS_FILE)
                    migrateLegacyCredentials(loadedPrefs, loadedCredentials)
                    prefs = loadedPrefs
                    credentials = loadedCredentials
                }
            }
        }
    }

    /// The chosen crowd provider, default "both". Mirrors Apple `SkipTimestampService.provider`.
    val provider: String
        get() = prefs?.getString(PROVIDER_KEY, "both") ?: "both"

    fun setProvider(value: String) {
        prefs?.edit()?.putString(PROVIDER_KEY, value)?.apply()
    }

    /// The user's optional skipdb.tv API key (Apple `ApiKeys.skipDBKey()`). null (dormant) when unset.
    fun skipDBKey(): String? = nonEmpty(credentials?.string(credentialKeys[0].current))

    /// The user's optional custom SkipDB-compatible mirror base URL (Apple `ApiKeys.customSkipURL()`).
    fun customSkipURL(): String? = nonEmpty(credentials?.string(credentialKeys[1].current))

    /// The optional key for the custom mirror (Apple `ApiKeys.customSkipKey()`); some mirrors are keyless.
    fun customSkipKey(): String? = nonEmpty(credentials?.string(credentialKeys[2].current))

    private fun migrateLegacyCredentials(prefs: SharedPreferences, credentials: SecureTokenStore) {
        credentialKeys.forEach { key ->
            val legacyValue = nonEmpty(prefs.getString(key.legacy, null)) ?: return@forEach
            val destinationReady = credentials.string(key.current) != null || credentials.set(key.current, legacyValue)
            if (destinationReady) prefs.edit().remove(key.legacy).apply()
        }
    }

    private fun nonEmpty(s: String?): String? = s?.trim()?.takeIf { it.isNotEmpty() }
}

internal data class SkipCredentialKey(val current: String, val legacy: String)

/// The user's optional custom SkipDB-compatible provider. Shared by the read path
/// ([SkipTimestampService] custom leg) and the submit path ([SkipDBClient] custom leg). Mirrors Apple
/// `CustomSkipProvider`.
object CustomSkipProvider {

    /// The configured base URL, normalized (trailing slash stripped) and validated as http(s). Returns null
    /// when unset or not a valid http(s) URL, so callers fail-soft / silently skip. Mirrors Apple
    /// `CustomSkipProvider.baseURL()`.
    fun baseURL(): String? {
        val raw = SkipConfig.customSkipURL() ?: return null
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val base = if (trimmed.endsWith("/")) trimmed.dropLast(1) else trimmed
        val parsed = runCatching { java.net.URL(base) }.getOrNull() ?: return null
        val scheme = parsed.protocol?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        if (parsed.host.isNullOrEmpty()) return null
        return base
    }

    /// The host of the configured base URL, for the cache-prefix namespacing in the read path.
    fun host(): String? = baseURL()?.let { runCatching { java.net.URL(it).host }.getOrNull() }
}
