package com.vortx.android.engine

import com.vortx.android.model.LibraryGenreFacts
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import org.json.JSONArray
import org.json.JSONObject

/** Public Library array adapter. No private fields or inferred metadata are consumed. */
internal fun nativeSavedLibraryItem(row: JSONObject): MetaItem {
    require(row.getString("kind") == "standard")
    return MetaItem(row.getString("id"), MediaType.fromId(row.getString("type")), row.getString("name"),
        poster = if (row.isNull("poster") || !row.has("poster")) null else row.getString("poster"),
        genres = LibraryGenreFacts.publicArray(row.opt("genres")))
}

/** Called inside the existing captured-owner Library action. Cache admission is supplied by that
 * exact owner read; the helper additionally requires the same typed identity before using it. */
internal fun nativeLibraryItemPayload(item: MetaItem, acceptedCached: MetaDetail? = null): JSONObject {
    val cached = acceptedCached?.takeIf { it.id == item.id && it.type == item.type }
    val genres = LibraryGenreFacts.normalized(item.genres)
        .ifEmpty { LibraryGenreFacts.normalized(cached?.genres.orEmpty()) }
    return JSONObject().put("kind", "standard").put("id", item.id).put("type", item.type.id)
        .put("name", item.name).put("poster", item.poster).apply {
            // MetaItem's default-empty list does not prove a known empty fact. Omit it entirely.
            if (genres.isNotEmpty()) put("genres", JSONArray(genres))
        }
}
