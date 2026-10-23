package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.json.JSONObject

/**
 * Titles watched or started on the active profile, for the Library: every title watched stays in the Library
 * until the viewer removes it. Twin of Apple `VortxNativePreviouslyWatched`. Pure: built from the native
 * playback projection.
 */
internal object NativePreviouslyWatched {
    /** The engine's own type for a watched or started title, which keys its Library removal record. */
    fun type(playback: JSONObject, id: String): String? {
        for (key in listOf("continueWatching", "history")) {
            val rows = playback.optJSONArray(key) ?: continue
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.optString("metaId") == id) row.optString("type").takeIf { it.isNotEmpty() }?.let { return it }
            }
        }
        return null
    }

    /**
     * Every title in Continue Watching or the watch history, once, newest first. Titles in [excluding] are left
     * out (the Library lists them already), and so is a title whose Library removal (seconds, the native clock)
     * is at or after its last watch: the viewer removed it, and only watching it again brings it back.
     */
    fun titles(playback: JSONObject, excluding: Set<String>, removedAt: (type: String, id: String) -> Long?): List<MetaItem> {
        val latest = LinkedHashMap<String, Triple<Long, String, MetaItem>>()
        for (key in listOf("continueWatching", "history")) {
            val rows = playback.optJSONArray(key) ?: continue
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.optString("metaId").takeIf { it.isNotEmpty() && it !in excluding } ?: continue
                val type = row.optString("type").takeIf { it.isNotEmpty() } ?: continue
                val at = row.optLong("updatedAt", 0)
                val prior = latest[id]
                if (prior != null && prior.first >= at) continue
                val name = row.optString("name").takeIf { it.isNotEmpty() } ?: id
                val poster = row.optString("poster").takeIf { row.has("poster") && !row.isNull("poster") && it.isNotEmpty() }
                latest[id] = Triple(at, type, MetaItem(id, MediaType.fromId(type), name, poster = poster))
            }
        }
        return latest.values.filter { (at, type, item) ->
            val removed = removedAt(type, item.id)?.takeIf { it > 0 } ?: return@filter true
            removed < at
        }.sortedWith(compareByDescending<Triple<Long, String, MetaItem>> { it.first }.thenBy { it.third.id }).map { it.third }
    }
}
