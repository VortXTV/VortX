package com.vortx.android.search

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray

/// Recent search terms (last [LIMIT]), the Android port of Apple `SearchHistoryStore.swift`. Plain
/// `SharedPreferences` -- these are NOT secrets (ANDROID-PLAN.md §0 invariant #5 only requires
/// Keystore-backed storage for account/debrid credentials), matching the S04 assignment's explicit
/// call-out that search recents are fine in plain prefs.
///
/// Per-profile scoping (the Apple store keys by `profileID`) is deferred to S09 (Profiles); until then
/// every recent search shares one list, which is exactly what a single-profile install already behaves
/// like on Apple.
class SearchHistoryStore(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /// The recent terms, most-recent first.
    fun load(): List<String> {
        val raw = prefs.getString(KEY_HISTORY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    /// Record a term the user engaged with (opened a result for), mirroring Apple's `saveToHistory`
    /// (recorded on result-open, not on every keystroke). De-duplicates case-insensitively and keeps
    /// only the most recent [LIMIT].
    fun add(query: String) {
        val trimmed = query.trim()
        if (trimmed.length < 2) return
        val updated = listOf(trimmed) + load().filter { !it.equals(trimmed, ignoreCase = true) }
        val array = JSONArray()
        updated.take(LIMIT).forEach { array.put(it) }
        prefs.edit().putString(KEY_HISTORY, array.toString()).apply()
    }

    fun clear() {
        prefs.edit().remove(KEY_HISTORY).apply()
    }

    private companion object {
        const val PREFS_FILE = "vortx_search_history"
        const val KEY_HISTORY = "recent_terms"
        const val LIMIT = 5
    }
}
