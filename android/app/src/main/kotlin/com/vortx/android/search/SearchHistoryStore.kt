package com.vortx.android.search

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.profile.ProfileStore
import org.json.JSONArray

/// Per-profile recent search terms (last [LIMIT]), the Android port of Apple `SearchHistoryStore.swift`.
/// Plain `SharedPreferences` -- these are NOT secrets (ANDROID-PLAN.md §0 invariant #5 only requires
/// Keystore-backed storage for account/debrid credentials), matching the S04 assignment's explicit
/// call-out that search recents are fine in plain prefs.
///
/// PER-PROFILE (S09): Apple keys its store `stremiox.searchHistory.<profileID-or-"default">`; this port
/// keys the SAME way, bucketing by [ProfileStore.activeID] and falling back to the [DEFAULT_BUCKET] when
/// no profile system is up (@Previews, a single-profile install before ProfileStore binds). The bucket is
/// resolved LAZILY on every read/write via [bucketProvider], so an active-profile switch immediately
/// targets the new profile's list with no reconstruction -- one profile's recents can never leak into
/// another's (the per-profile invariant). Matching Apple's `stremiox.` key prefix keeps the two form
/// factors on the same carriage for the separate VortX-account sync lane that reads these lists.
class SearchHistoryStore(
    context: Context,
    private val bucketProvider: () -> String = { ProfileStore.sharedOrNull()?.activeID ?: DEFAULT_BUCKET },
) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private fun key(): String = KEY_PREFIX + bucketProvider()

    /// The recent terms for the active profile, most-recent first.
    fun load(): List<String> {
        val raw = prefs.getString(key(), null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    /// Record a term the user engaged with (opened a result for), mirroring Apple's `saveToHistory`
    /// (recorded on result-open, not on every keystroke). De-duplicates case-insensitively and keeps
    /// only the most recent [LIMIT] for the ACTIVE profile.
    fun add(query: String) {
        val trimmed = query.trim()
        if (trimmed.length < 2) return
        val updated = listOf(trimmed) + load().filter { !it.equals(trimmed, ignoreCase = true) }
        val array = JSONArray()
        updated.take(LIMIT).forEach { array.put(it) }
        prefs.edit().putString(key(), array.toString()).apply()
    }

    /// Clear the active profile's list only (another profile's recents are untouched).
    fun clear() {
        prefs.edit().remove(key()).apply()
    }

    companion object {
        const val PREFS_FILE = "vortx_search_history"

        /// Apple's exact key prefix (`SearchHistoryStore.storageKey`), so the terms ride the same
        /// cross-device carriage the sync lane already speaks.
        const val KEY_PREFIX = "stremiox.searchHistory."

        /// The Apple `profileID?.uuidString ?? "default"` fallback bucket.
        const val DEFAULT_BUCKET = "default"

        const val LIMIT = 5
    }
}
