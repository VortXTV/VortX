package com.vortx.android.imports

import android.content.Context
import com.vortx.android.BuildConfig
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.metadata.MetadataProviderKeys
import org.json.JSONArray
import org.json.JSONObject

/**
 * The three per-provider list fetchers for [ListImport]. Each returns a [RawList] (list order preserved) and
 * is fail-soft: any error yields an empty list, so the coordinator surfaces a clean "list is empty/private"
 * message rather than crashing. Every URL is built against a FIXED provider host through [ListImport.encodePath]
 * and fetched via [ImportHttp], which runs the private-address guard on the host.
 */

// MARK: - Letterboxd

/**
 * Letterboxd exposes no list API, so a public list is scraped: the list page(s) give ordered film slugs and
 * the list name (og:title), and each film page carries its TMDB and IMDb ids as external links. Film-page
 * resolution is concurrency-bounded and capped. Fail-soft throughout (a film that will not load is dropped).
 * Android port of Apple `LetterboxdImportClient`.
 */
internal object LetterboxdImportClient {
    private const val MAX_PAGES = 12

    suspend fun fetchRawList(user: String, slug: String): RawList {
        val u = ListImport.encodePath(user)
        val s = ListImport.encodePath(slug)
        val base = "https://letterboxd.com/$u/list/$s"

        val slugs = ArrayList<String>()
        val seen = HashSet<String>()
        var listTitle: String? = null

        for (page in 1..MAX_PAGES) {
            val pageUrl = if (page == 1) "$base/" else "$base/page/$page/"
            val html = ImportHttp.fetchText(pageUrl) ?: break
            if (page == 1) listTitle = listName(html)
            var added = 0
            for (filmSlug in filmSlugs(html)) {
                if (seen.add(filmSlug)) {
                    slugs.add(filmSlug)
                    added += 1
                }
            }
            if (added == 0 || slugs.size >= ListImport.MAX_ITEMS) break
        }

        val capped = slugs.take(ListImport.MAX_ITEMS)
        val entries = ListImport.boundedMap(capped, ListImport.CONCURRENCY) { filmEntry(it) }.filterNotNull()
        return RawList(title = listTitle, entries = entries)
    }

    /**
     * Ordered, de-dup-later film slugs from a list page. Letterboxd tags each poster with `data-film-slug` and
     * links to `/film/<slug>/`; both are matched so a markup tweak on one does not break scraping.
     */
    private fun filmSlugs(html: String): List<String> {
        val a = ListImport.allMatches("data-film-slug=\"([^\"]+)\"", html)
        val b = ListImport.allMatches("/film/([a-z0-9][a-z0-9-]*)/", html)
        val ordered = ArrayList<String>()
        val seen = HashSet<String>()
        for (slug in a + b) if (seen.add(slug)) ordered.add(slug)
        return ordered
    }

    /** The list's display name from the page og:title, unescaped. */
    private fun listName(html: String): String? {
        val raw = ListImport.firstMatch("<meta property=\"og:title\" content=\"([^\"]+)\"", html) ?: return null
        return ListImport.unescapeHtml(raw).takeIf { it.isNotEmpty() }
    }

    /**
     * One film page to a raw entry: TMDB id + type from the TMDb link, IMDb id from the IMDb link, and the
     * display name/year from og:title. Fail-soft: a page that yields neither an id nor a title is dropped.
     */
    private suspend fun filmEntry(slug: String): RawListEntry? {
        val filmUrl = "https://letterboxd.com/film/${ListImport.encodePath(slug)}/"
        val html = ImportHttp.fetchText(filmUrl) ?: return null

        val imdb = ListImport.firstMatch("imdb\\.com/title/(tt[0-9]{6,})", html)
        val tmdbType = ListImport.firstMatch("themoviedb\\.org/(movie|tv)/[0-9]+", html)
        val tmdbId = ListImport.firstMatch("themoviedb\\.org/(?:movie|tv)/([0-9]+)", html)?.toIntOrNull()

        var title: String? = null
        var year: Int? = null
        ListImport.firstMatch("<meta property=\"og:title\" content=\"([^\"]+)\"", html)?.let { og ->
            val cleaned = ListImport.unescapeHtml(og)
            year = ListImport.firstMatch("\\(([0-9]{4})\\)\\s*$", cleaned)?.toIntOrNull()
            title = cleaned.replace(Regex("\\s*\\([0-9]{4}\\)\\s*$"), "")
        }
        if (title == null) title = ListImport.humanize(slug)

        if (imdb == null && tmdbId == null && title.isNullOrEmpty()) return null
        val isTv = tmdbType == "tv"
        return RawListEntry(
            imdbId = imdb,
            tmdbId = tmdbId,
            tmdbType = if (isTv) "tv" else "movie",
            title = title,
            year = year,
            typeHint = if (isTv) "series" else "movie",
        )
    }
}

// MARK: - MDBList

/**
 * A public MDBList list. MDBList exposes a keyless JSON export at `mdblist.com/lists/<user>/<slug>/json` for
 * PUBLIC lists; when the user has set an MDBList key (Settings > Metadata keys) the authenticated API is also
 * tried, which additionally covers their private lists. Each item already carries `imdb_id` and a TMDB `id`,
 * so little resolution is needed downstream. Fail-soft to an empty list. Android port of Apple
 * `MDBListClient.fetchRawList` (the public-list extension).
 */
internal object MdbListImportClient {
    private const val API_HOST = "https://api.mdblist.com"

    suspend fun fetchRawList(context: Context, user: String, slug: String): RawList {
        val u = ListImport.encodePath(user)
        val s = ListImport.encodePath(slug)

        // 1) Keyless public JSON export.
        ImportHttp.fetchText("https://mdblist.com/lists/$u/$s/json")?.let { text ->
            val entries = collectItems(text).mapNotNull(::entry)
            if (entries.isNotEmpty()) return RawList(title = null, entries = entries)
        }
        // 2) Authenticated API when a key is present (covers private lists too).
        val key = runCatching { MetadataProviderKeys(context).value(MetadataProviderKeys.Slot.MDBLIST) }
            .getOrNull().orEmpty()
        if (key.isNotEmpty()) {
            val encKey = ListImport.encodePath(key)
            ImportHttp.fetchText("$API_HOST/lists/$u/$s/items?apikey=$encKey")?.let { text ->
                val entries = collectItems(text).mapNotNull(::entry)
                if (entries.isNotEmpty()) return RawList(title = null, entries = entries)
            }
        }
        return RawList(title = null, entries = emptyList())
    }

    /**
     * Flatten MDBList's several list shapes into a flat array of item objects: a bare array, an object with
     * `movies`/`shows` arrays, or an object with an `items`/`results` array.
     */
    private fun collectItems(text: String): List<JSONObject> {
        runCatching { JSONArray(text) }.getOrNull()?.let { return it.objects() }
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return emptyList()
        val out = ArrayList<JSONObject>()
        for (key in listOf("movies", "shows", "items", "results")) {
            obj.optJSONArray(key)?.let { out.addAll(it.objects()) }
        }
        return out
    }

    /**
     * One MDBList item object to a raw entry, tolerant of key-name variance across the export and the API
     * (`id`/`tmdb_id` for the TMDB id, `imdb_id`/`imdbid`, `mediatype`/`type`).
     */
    private fun entry(obj: JSONObject): RawListEntry? {
        val imdb = obj.optStringOrNull("imdb_id") ?: obj.optStringOrNull("imdbid")
        val tmdb = intVal(obj, "id") ?: intVal(obj, "tmdb_id") ?: intVal(obj, "tmdbid")
        val media = (obj.optStringOrNull("mediatype") ?: obj.optStringOrNull("media_type")
            ?: obj.optStringOrNull("type")).orEmpty().lowercase()
        val title = obj.optStringOrNull("title") ?: obj.optStringOrNull("name")
        val year = intVal(obj, "release_year") ?: intVal(obj, "year")
        if (imdb == null && tmdb == null && title.isNullOrEmpty()) return null
        val isShow = media == "show" || media == "series" || media == "tv"
        return RawListEntry(
            imdbId = imdb,
            tmdbId = tmdb,
            tmdbType = if (isShow) "tv" else "movie",
            title = title,
            year = year,
            typeHint = if (isShow) "series" else "movie",
        )
    }

    private fun JSONArray.objects(): List<JSONObject> =
        (0 until length()).mapNotNull { optJSONObject(it) }

    private fun intVal(obj: JSONObject, key: String): Int? {
        if (!obj.has(key) || obj.isNull(key)) return null
        return when (val any = obj.opt(key)) {
            is Int -> any
            is Long -> any.toInt()
            is Double -> any.toInt()
            is Number -> any.toInt()
            is String -> any.toIntOrNull()
            else -> null
        }
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).takeIf { it.isNotBlank() }
    }
}

// MARK: - Trakt

/**
 * A Trakt list read through the documented API. Public lists need only the app's `trakt-api-key` (client id)
 * header, no OAuth. Each item carries `ids.imdb` and `ids.tmdb` directly, so no title search is needed.
 * Fail-soft to an empty list on any error. The public paste-a-URL path is UNAUTHENTICATED (no bearer), so a
 * pasted link never reaches into the connected account for a list the link itself could not open. Android
 * port of Apple `TraktListImportClient` (the `authorized: false` path).
 */
internal object TraktListImportClient {

    /** True once the build carries a Trakt client id, mirroring Apple's `!TraktAuth.clientID.isEmpty` gate. */
    val isConfigured: Boolean get() = clientId.isNotEmpty()

    private val clientId: String get() = BuildConfig.TRAKT_CLIENT_ID.trim()

    suspend fun fetchRawList(user: String, slug: String): RawList {
        if (!isConfigured) return RawList(title = null, entries = emptyList())
        val path = if (user.isEmpty()) {
            "/lists/${ListImport.encodePath(slug)}/items/movie,show"
        } else {
            "/users/${ListImport.encodePath(user)}/lists/${ListImport.encodePath(slug)}/items/movie,show"
        }
        val url = "${TraktAuth.API_BASE}$path?extended=full"
        val text = ImportHttp.fetchText(
            url,
            headers = mapOf(
                "trakt-api-version" to "2",
                "trakt-api-key" to clientId,
                "Content-Type" to "application/json",
            ),
        ) ?: return RawList(title = null, entries = emptyList())

        val array = runCatching { JSONArray(text) }.getOrNull() ?: return RawList(title = null, entries = emptyList())
        val entries = ArrayList<RawListEntry>(array.length())
        for (index in 0 until array.length()) {
            val element = array.optJSONObject(index) ?: continue
            val listType = element.optString("type").lowercase().ifEmpty { "movie" }
            val key = if (listType == "show") "show" else "movie"
            val media = element.optJSONObject(key) ?: continue
            val ids = media.optJSONObject("ids")
            val imdb = ids?.optStringOrNull("imdb")
            val tmdb = ids?.let { intVal(it, "tmdb") }
            val title = media.optStringOrNull("title")
            val year = intVal(media, "year")
            if (imdb == null && tmdb == null && title.isNullOrEmpty()) continue
            val isShow = key == "show"
            entries.add(
                RawListEntry(
                    imdbId = imdb,
                    tmdbId = tmdb,
                    tmdbType = if (isShow) "tv" else "movie",
                    title = title,
                    year = year,
                    typeHint = if (isShow) "series" else "movie",
                ),
            )
        }
        return RawList(title = null, entries = entries)
    }

    private fun intVal(obj: JSONObject, key: String): Int? {
        if (!obj.has(key) || obj.isNull(key)) return null
        return when (val any = obj.opt(key)) {
            is Int -> any
            is Long -> any.toInt()
            is Double -> any.toInt()
            is Number -> any.toInt()
            is String -> any.toIntOrNull()
            else -> null
        }
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).takeIf { it.isNotBlank() }
    }
}
