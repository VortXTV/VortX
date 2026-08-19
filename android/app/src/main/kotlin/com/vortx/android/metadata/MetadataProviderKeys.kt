package com.vortx.android.metadata

import android.content.Context
import com.vortx.android.integrations.SecureTokenStore

/**
 * User-supplied metadata-provider credentials (SET-2), the Android port of the metadata slots in Apple
 * `app/SourcesShared/ApiKeys.swift`. Kept in ENCRYPTED storage (they are credentials, exactly like the skip
 * and debrid keys), under Apple's EXACT account strings `vortx.apikey.tmdb` / `vortx.apikey.mdblist` /
 * `vortx.apikey.fanart` so the values ride the same cross-device carriage as the Apple apps.
 *
 * ANDROID DIVERGENCE (documented, honest): unlike Apple, Android has no per-user "your key -> TMDB direct"
 * branch. Every metadata call on Android already runs through VortX's KEYLESS, edge-signed catalog proxy
 * (`catalogs.vortx.tv/3`, credential injected server-side; see `com.vortx.android.person.TMDBPersonClient`
 * / `com.vortx.android.home.CollectionsHubModel` / `com.vortx.android.trickplay.TmdbImdbResolver`). So a
 * value stored here is NOT consumed on this device today; it is persisted on the exact key so it SYNCS to
 * platforms that call these providers directly, and is ready for a future Android direct-provider path. The
 * screen states this plainly rather than implying the value is in use locally.
 *
 * Fail-soft: a blocked encrypted backend degrades to memory-for-this-process without ever crashing or
 * blanking the screen (see [SecureTokenStore] / [com.vortx.android.security.FailClosedCredentialStore]).
 */
class MetadataProviderKeys(context: Context) {

    private val store = SecureTokenStore(context.applicationContext, CREDENTIALS_FILE)

    /** The three metadata slots, each carrying Apple's exact storage key + user-facing copy. */
    enum class Slot(val key: String, val displayName: String, val hint: String) {
        TMDB(
            "vortx.apikey.tmdb",
            "TMDB",
            "Recommendations, cast and artwork.",
        ),
        MDBLIST(
            "vortx.apikey.mdblist",
            "MDBList",
            "Ratings and imported lists.",
        ),
        FANART(
            "vortx.apikey.fanart",
            "fanart.tv",
            "Logos and extra artwork.",
        ),
    }

    /** The stored value for [slot], or empty when unset. The value never leaves the secure store otherwise. */
    fun value(slot: Slot): String = store.string(slot.key) ?: ""

    fun hasValue(slot: Slot): Boolean = value(slot).isNotEmpty()

    /**
     * Store (or, with a blank value, clear) [slot]. Returns whether the secure write was DURABLE: a false
     * means the encrypted backend is unavailable and the value is only in-process, which the caller surfaces
     * rather than reporting a durable save that did not happen.
     */
    fun set(slot: Slot, value: String): Boolean {
        val trimmed = value.trim()
        return store.set(slot.key, trimmed.ifEmpty { null })
    }

    companion object {
        private const val CREDENTIALS_FILE = "vortx_metadata_credentials"
    }
}
