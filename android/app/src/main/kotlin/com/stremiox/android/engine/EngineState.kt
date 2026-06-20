package com.stremiox.android.engine

import com.stremiox.android.model.Catalog
import com.stremiox.android.model.Episode
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.MetaItem
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
import org.json.JSONArray
import org.json.JSONObject

/// Decoders that turn the engine's JSON state (as returned by [StremioXCore.getState]) into the
/// Android domain models the Compose UI renders. The shapes mirror the Apple `CoreModels` Codable
/// structs exactly (same serde output): `_id`, `posterShape`, snake_case nested keys, and the
/// `Loadable` wrapper `{ "type": "Ready", "content": ... }`.
///
/// All parsing is defensive: malformed or missing fields degrade to empty/null rather than throwing,
/// because engine state can be mid-load (a `Loading` Loadable) when a field is pulled.
internal object EngineState {

    /// Parse the `board`/`search` field (a `CatalogsWithExtra`) into UI [Catalog] rows. Each catalog
    /// is `{ request, content: Loadable<[meta]> }`; the engine nests them as `catalogs: [[page]]`
    /// (outer = catalog, inner = pages). We flatten pages and title each row from its request.
    fun parseCatalogs(json: String): List<Catalog> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val catalogs = root.optJSONArray("catalogs") ?: return emptyList()
        val rows = mutableListOf<Catalog>()
        for (catalogIdx in 0 until catalogs.length()) {
            val pages = catalogs.optJSONArray(catalogIdx) ?: continue
            val items = mutableListOf<MetaItem>()
            var title: String? = null
            var rowId: String? = null
            for (pageIdx in 0 until pages.length()) {
                val page = pages.optJSONObject(pageIdx) ?: continue
                if (title == null) {
                    val request = page.optJSONObject("request")
                    rowId = catalogRowId(request, catalogIdx)
                    title = catalogTitle(request)
                }
                val content = page.readyArray("content") ?: continue
                for (metaIdx in 0 until content.length()) {
                    content.optJSONObject(metaIdx)?.let { items += parseMetaPreview(it) }
                }
            }
            if (items.isNotEmpty()) {
                rows += Catalog(id = rowId ?: "row-$catalogIdx", title = title ?: "Catalog", items = items)
            }
        }
        return rows
    }

    /// Parse a `LibraryWithFilters` (`catalog: [libraryItem]`) into UI [MetaItem]s.
    fun parseLibrary(json: String): List<MetaItem> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val catalog = root.optJSONArray("catalog") ?: return emptyList()
        val items = mutableListOf<MetaItem>()
        for (i in 0 until catalog.length()) {
            catalog.optJSONObject(i)?.let { items += parseLibraryItem(it) }
        }
        return items
    }

    /// Parse the `meta_details` field into a UI [MetaDetail] plus its grouped [StreamGroup]s. The meta
    /// lives in `metaItems: [{ request, content: Loadable<metaItem> }]` (first Ready wins); streams
    /// live in `streams: [{ request, content: Loadable<[stream]> }]` grouped by the source add-on.
    fun parseMetaDetail(json: String): MetaDetail? {
        val root = json.toJsonObjectOrNull() ?: return null
        val metaItems = root.optJSONArray("metaItems") ?: return null
        var meta: JSONObject? = null
        for (i in 0 until metaItems.length()) {
            val ready = metaItems.optJSONObject(i)?.readyObject("content")
            if (ready != null) {
                meta = ready
                break
            }
        }
        val metaObj = meta ?: return null
        val type = MediaType.fromId(metaObj.optString("type", "movie"))
        return MetaDetail(
            id = metaObj.optString("id"),
            type = type,
            name = metaObj.optString("name"),
            poster = metaObj.optStringOrNull("poster"),
            background = metaObj.optStringOrNull("background"),
            description = metaObj.optStringOrNull("description"),
            releaseInfo = metaObj.optStringOrNull("releaseInfo"),
            runtime = metaObj.optStringOrNull("runtime"),
            imdbRating = metaObj.optStringOrNull("imdbRating"),
            genres = parseGenres(metaObj),
            videos = parseVideos(metaObj),
        )
    }

    /// Parse the stream source groups from `meta_details.streams`. One [StreamGroup] per source add-on
    /// (named by the request base host), best-effort, in engine order.
    fun parseStreamGroups(json: String): List<StreamGroup> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val streams = root.optJSONArray("streams") ?: return emptyList()
        val groups = mutableListOf<StreamGroup>()
        for (i in 0 until streams.length()) {
            val entry = streams.optJSONObject(i) ?: continue
            val addon = addonName(entry.optJSONObject("request"))
            val content = entry.readyArray("content") ?: continue
            val sources = mutableListOf<StreamSource>()
            for (s in 0 until content.length()) {
                content.optJSONObject(s)?.let { sources += parseStream(it, addon) }
            }
            if (sources.isNotEmpty()) groups += StreamGroup(addon = addon, streams = sources)
        }
        return groups
    }

    // ---- element parsers ----

    private fun parseMetaPreview(obj: JSONObject): MetaItem = MetaItem(
        id = obj.optString("_id").ifEmpty { obj.optString("id") },
        type = MediaType.fromId(obj.optString("type", "movie")),
        name = obj.optString("name"),
        poster = obj.optStringOrNull("poster"),
        year = obj.optStringOrNull("releaseInfo"),
        description = obj.optStringOrNull("description"),
    )

    private fun parseLibraryItem(obj: JSONObject): MetaItem = MetaItem(
        id = obj.optString("_id").ifEmpty { obj.optString("id") },
        type = MediaType.fromId(obj.optString("type", "movie")),
        name = obj.optString("name"),
        poster = obj.optStringOrNull("poster"),
    )

    private fun parseVideos(meta: JSONObject): List<Episode> {
        val videos = meta.optJSONArray("videos") ?: return emptyList()
        val out = mutableListOf<Episode>()
        for (i in 0 until videos.length()) {
            val v = videos.optJSONObject(i) ?: continue
            out += Episode(
                id = v.optString("id"),
                title = v.optStringOrNull("title") ?: "Episode ${v.optInt("episode", i + 1)}",
                season = v.optInt("season", 0),
                episode = v.optInt("episode", 0),
                overview = v.optStringOrNull("overview"),
                thumbnail = v.optStringOrNull("thumbnail"),
                released = v.optStringOrNull("released"),
            )
        }
        return out
    }

    /// Genres come from `links` entries categorized as genre (the engine stops emitting a top-level
    /// `genres` array for previews; `links` is the durable source, matching CoreMetaItem.genres).
    private fun parseGenres(meta: JSONObject): List<String> {
        val links = meta.optJSONArray("links") ?: return emptyList()
        val genres = mutableListOf<String>()
        for (i in 0 until links.length()) {
            val link = links.optJSONObject(i) ?: continue
            val category = link.optString("category").lowercase()
            if (category == "genre" || category == "genres") {
                link.optStringOrNull("name")?.let { genres += it }
            }
        }
        return genres
    }

    private fun parseStream(obj: JSONObject, addon: String): StreamSource {
        val url = obj.optStringOrNull("url")
        val infoHash = obj.optStringOrNull("infoHash")
        val externalUrl = obj.optStringOrNull("externalUrl")
        val isTorrent = url == null && infoHash != null
        // Stable id matching CoreStream.id: (url|externalUrl|infoHash) + "#" + name + description.
        val handle = url ?: externalUrl ?: infoHash ?: "?"
        val name = obj.optStringOrNull("name")
        val description = obj.optStringOrNull("description")
        return StreamSource(
            id = handle + "#" + (name ?: "") + (description ?: ""),
            addon = addon,
            title = name ?: description ?: addon,
            description = description,
            quality = null,
            isTorrent = isTorrent,
        )
    }

    // ---- request -> human label helpers ----

    private fun catalogTitle(request: JSONObject?): String {
        val path = request?.optJSONObject("path") ?: return "Catalog"
        val id = path.optString("id").replaceFirstChar { it.uppercaseChar() }
        val type = path.optString("type").replaceFirstChar { it.uppercaseChar() }
        return listOf(id, type).filter { it.isNotBlank() }.joinToString(" ").ifBlank { "Catalog" }
    }

    private fun catalogRowId(request: JSONObject?, fallbackIndex: Int): String {
        val path = request?.optJSONObject("path") ?: return "row-$fallbackIndex"
        val base = request.optString("base")
        return listOf(base, path.optString("type"), path.optString("id"))
            .filter { it.isNotBlank() }
            .joinToString("|")
            .ifBlank { "row-$fallbackIndex" }
    }

    private fun addonName(request: JSONObject?): String {
        val base = request?.optString("base").orEmpty()
        // The base is the add-on's transport URL; show its host as a stable, human-ish label until a
        // manifest-name lookup is wired (CoreBridge resolves the manifest name; the preview shows host).
        return runCatching { java.net.URI(base).host ?: base }.getOrDefault(base).ifBlank { "Source" }
    }

    // ---- JSON helpers ----

    private fun String.toJsonObjectOrNull(): JSONObject? =
        runCatching { JSONObject(this) }.getOrNull()

    /// Unwrap a `Loadable<[T]>` JSON value at [key] (`{ "type": "Ready", "content": [...] }`),
    /// returning the inner array only when Ready.
    private fun JSONObject.readyArray(key: String): JSONArray? {
        val loadable = optJSONObject(key) ?: return null
        if (loadable.optString("type") != "Ready") return null
        return loadable.optJSONArray("content")
    }

    /// Unwrap a `Loadable<T>` JSON object at [key], returning the inner object only when Ready.
    private fun JSONObject.readyObject(key: String): JSONObject? {
        val loadable = optJSONObject(key) ?: return null
        if (loadable.optString("type") != "Ready") return null
        return loadable.optJSONObject("content")
    }

    /// Like `optString` but returns null (not "") for missing or JSON-null values, so optional UI
    /// fields stay genuinely absent.
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }
}
