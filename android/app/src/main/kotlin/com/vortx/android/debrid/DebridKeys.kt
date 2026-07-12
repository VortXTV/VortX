package com.vortx.android.debrid

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/// A debrid service VortX can hold an API key for. A debrid key turns cached torrents into instant
/// direct links, so cached torrents play straight from the user's own debrid account without a debrid
/// add-on. Mirrors the Apple `DebridService` (app/SourcesShared/DebridKeys.swift): the raw values are
/// the SAME on-disk identifiers so a future cross-platform key sync lines up field for field.
enum class DebridService(val id: String, val displayName: String) {
    REAL_DEBRID("realDebrid", "Real-Debrid"),
    ALL_DEBRID("allDebrid", "AllDebrid"),
    PREMIUMIZE("premiumize", "Premiumize"),
    TOR_BOX("torBox", "TorBox");

    /// Storage key this service's API key is persisted under. Matches the Apple keychain-account tail
    /// (`vortx.debrid.<rawValue>`) so the value maps 1:1 across platforms.
    val storageKey: String get() = "vortx.debrid.$id"
}

/// The user's debrid API keys, stored AES-encrypted at rest via [EncryptedSharedPreferences]. This is
/// the Android analogue of the Apple `DebridKeys` (which is Keychain-backed): debrid keys are
/// credentials, so they never sit in plain SharedPreferences.
///
/// Fail-soft by construction: if the security-crypto artifact is missing or the encrypted store fails
/// to open (a known-rare Keystore corruption), we fall back to a plain SharedPreferences file so the
/// resolver still functions and the app never crashes at the storage boundary. The fallback is logged.
///
/// A single instance is enough (keys are tiny and read on demand); [DebridResolver] builds one from the
/// app context. Reads are synchronous and cheap; writes are `apply()` (async, off the caller's thread).
class DebridKeys(context: Context) {

    private val prefs: SharedPreferences = openPrefs(context.applicationContext)

    /// The stored key for [service], or an empty string when none is set.
    fun key(service: DebridService): String = prefs.getString(service.storageKey, null).orEmpty()

    /// True when [service] has a non-empty key configured.
    fun isConfigured(service: DebridService): Boolean = key(service).isNotEmpty()

    /// Persist (or clear, on a blank value) a service's key. Trims surrounding whitespace, matching the
    /// Apple `setKey`.
    fun setKey(service: DebridService, value: String) {
        val trimmed = value.trim()
        prefs.edit().apply {
            if (trimmed.isEmpty()) remove(service.storageKey) else putString(service.storageKey, trimmed)
        }.apply()
    }

    /// Services with a key set, in preference order (Real-Debrid first, the most common), mirroring the
    /// Apple `configuredServices`.
    fun configuredServices(): List<DebridService> = DebridService.entries.filter(::isConfigured)

    /// True when any debrid key is configured; the resolver's zero-cost gate (no key -> torrents keep
    /// today's behavior).
    fun hasAnyKey(): Boolean = configuredServices().isNotEmpty()

    /// The first configured service + key, for the single-debrid resolve path the resolver uses.
    fun primary(): Pair<DebridService, String>? =
        configuredServices().firstOrNull()?.let { it to key(it) }

    private companion object {
        const val TAG = "DebridKeys"
        const val ENCRYPTED_FILE = "vortx_debrid_keys"
        const val PLAIN_FALLBACK_FILE = "vortx_debrid_keys_plain"

        /// Open the encrypted store; on any failure (missing artifact, Keystore corruption) fall back to
        /// a plain prefs file so the resolver still works. Never throws.
        fun openPrefs(appContext: Context): SharedPreferences = runCatching {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext,
                ENCRYPTED_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrElse { error ->
            Log.w(TAG, "EncryptedSharedPreferences unavailable; falling back to plain prefs", error)
            appContext.getSharedPreferences(PLAIN_FALLBACK_FILE, Context.MODE_PRIVATE)
        }
    }
}
