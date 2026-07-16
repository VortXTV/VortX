package com.vortx.android.model

import org.json.JSONObject

/**
 * As-you-type local search suggestion index. The Android port of Apple `CoreLocalSearchState` /
 * `CoreSearchSuggestion` (in `CoreModels.swift`): the lightweight suggestion shape the engine returns for the
 * search-suggestions field, distinct from the full `CatalogsWithExtra` search results.
 *
 * `fromJson` parsers mirror Apple's `Decodable` conformance, using `org.json` to match the engine JSON-parsing
 * idiom already used across the Android engine seam.
 */
data class CoreSearchSuggestion(
    val id: String,
    val name: String,
    val type: String,
    val poster: String? = null,
    val releaseInfo: String? = null,
) {
    companion object {
        /** Null when the entry has no usable id (Apple `CoreSearchSuggestion` is `Identifiable` on `id`). */
        fun fromJson(o: JSONObject): CoreSearchSuggestion? {
            val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return null
            return CoreSearchSuggestion(
                id = id,
                name = o.optString("name"),
                type = o.optString("type"),
                poster = o.optStringOrNull("poster"),
                releaseInfo = o.optStringOrNull("releaseInfo"),
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) optString(key) else null
    }
}

/** The engine's local-search state: an ordered list of [CoreSearchSuggestion]. Mirrors Apple `CoreLocalSearchState`. */
data class CoreLocalSearchState(
    val searchResults: List<CoreSearchSuggestion> = emptyList(),
) {
    companion object {
        fun fromJson(o: JSONObject): CoreLocalSearchState {
            val arr = o.optJSONArray("searchResults") ?: return CoreLocalSearchState()
            val list = (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let { CoreSearchSuggestion.fromJson(it) }
            }
            return CoreLocalSearchState(list)
        }
    }
}
