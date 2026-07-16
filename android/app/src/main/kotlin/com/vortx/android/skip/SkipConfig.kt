package com.vortx.android.skip

import android.content.Context
import android.content.SharedPreferences

/// The Android analogue of the Apple skip stack's `UserDefaults` provider key + `ApiKeys.skipDBKey()` /
/// `ApiKeys.customSkipURL()` / `ApiKeys.customSkipKey()` accessors. Backs the crowd provider selection and
/// the OPTIONAL best-effort legs (community skipdb.tv + a user's custom SkipDB-compatible mirror).
///
/// FAIL-SOFT / DORMANT by default: with no settings surface wired yet, the community + custom keys resolve
/// to null and those legs make zero network calls, exactly like the Apple actors when `ApiKeys` returns nil.
/// The authoritative, keyless skip.vortx.tv leg needs none of this. [init] is idempotent; the store is a
/// plain preferences file (these are user preferences, not secrets, mirroring the Apple `UserDefaults` use).
object SkipConfig {

    /// Values: "theintrodb" | "skipdb" | "both". Matches the Apple `SkipTimestampService.providerKey`
    /// string ("stremiox.skipProvider"). The getter's DEFAULT is "both", byte-for-byte with the Apple
    /// getter `UserDefaults.standard.string(forKey: providerKey) ?? "both"` (the value the code returns;
    /// the "theintrodb" in the Apple doc comment is stale relative to the code).
    const val PROVIDER_KEY = "stremiox.skipProvider"

    private const val PREFS_FILE = "vortx_skip"
    private const val KEY_SKIPDB = "vortx.skip.skipdbKey"
    private const val KEY_CUSTOM_URL = "vortx.skip.customUrl"
    private const val KEY_CUSTOM_KEY = "vortx.skip.customKey"

    @Volatile private var prefs: SharedPreferences? = null

    /// Idempotent init: wire the preferences file. Safe to call from every entry point (the player skip
    /// fetch, a later Streams-settings screen). Cheap and network-free.
    fun init(context: Context) {
        if (prefs == null) {
            synchronized(this) {
                if (prefs == null) prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
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
    fun skipDBKey(): String? = nonEmpty(prefs?.getString(KEY_SKIPDB, null))

    /// The user's optional custom SkipDB-compatible mirror base URL (Apple `ApiKeys.customSkipURL()`).
    fun customSkipURL(): String? = nonEmpty(prefs?.getString(KEY_CUSTOM_URL, null))

    /// The optional key for the custom mirror (Apple `ApiKeys.customSkipKey()`); some mirrors are keyless.
    fun customSkipKey(): String? = nonEmpty(prefs?.getString(KEY_CUSTOM_KEY, null))

    private fun nonEmpty(s: String?): String? = s?.trim()?.takeIf { it.isNotEmpty() }
}

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
