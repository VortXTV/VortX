package com.vortx.android.imports

import android.content.Context
import com.vortx.android.home.ImportedListCatalog
import com.vortx.android.home.ImportedListProvider
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.trickplay.TmdbImdbResolver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.net.URI

/**
 * List import (producer half): paste a public Letterboxd, MDBList, or Trakt list URL and browse it as a
 * native Home row. Android port of Apple `app/SourcesShared/LetterboxdImportClient.swift` (the `ListImport`
 * coordinator + the Letterboxd and Trakt fetchers) plus `MDBListClient.swift`'s public-list extension. The
 * storage/render half is already ported (`com.vortx.android.home.ImportedCatalogs`, the `MetaItem` items and
 * the `vortx.catalog.importedLists` key); this file is the missing producer that fetches a pasted list and
 * resolves every entry to an engine-safe id before handing the catalog to `ImportedCatalogs.register`.
 *
 * SSRF-safe by construction (mirrors Apple): [detect] never trusts the pasted host. It re-asserts the host
 * from the recognized provider and validates each path segment, so a crafted link can only ever reach the
 * provider's real host. Every fetch additionally runs the private/loopback/link-local address guard
 * ([com.vortx.android.engine.PublicAddressPolicy], the Android analogue of Apple `AddonURLGuard`) via
 * [ImportHttp].
 *
 * Fail-soft throughout: a bad URL, a private/empty list, or a network hiccup returns a typed
 * [ImportedListError] whose [ImportedListError.message] is user-facing copy the paste screen shows verbatim,
 * never a crash. Nothing here writes account or library state (invariant): the resolved list lives only in
 * this app's own preferences via `ImportedCatalogs`.
 */

/**
 * A raw list entry parsed from a provider before id normalization. A provider fills whatever it knows (some
 * give an imdb id outright, some only a title), and [ListImport.resolve] turns each into an engine-safe
 * [MetaItem]. Mirrors Apple `RawListEntry`.
 */
internal data class RawListEntry(
    val imdbId: String? = null,
    val tmdbId: Int? = null,
    val tmdbType: String? = null,
    val title: String? = null,
    val year: Int? = null,
    val typeHint: String? = null,
)

/** A fetched list: its display name (when the provider exposes one) plus the raw entries in list order. */
internal data class RawList(
    val title: String?,
    val entries: List<RawListEntry>,
)

/**
 * Why a list import could not complete. [message] is user-facing copy the paste screen can show verbatim (no
 * em dashes, per house style). Mirrors Apple `ImportedListError`.
 */
internal sealed class ImportedListError(override val message: String) : Exception(message) {
    object UnsupportedUrl : ImportedListError(
        "That does not look like a Letterboxd, MDBList, or Trakt list link. Paste the public URL of a list.",
    )

    object Empty : ImportedListError(
        "No titles could be read from that list. Make sure the list is public and try again.",
    )

    data class NotConfigured(val provider: ImportedListProvider) : ImportedListError(
        "${provider.label} list import is not available in this build.",
    )
}

/** Display label for a provider, used only in the [ImportedListError.NotConfigured] copy. */
private val ImportedListProvider.label: String
    get() = when (this) {
        ImportedListProvider.LETTERBOXD -> "Letterboxd"
        ImportedListProvider.MDBLIST -> "MDBList"
        ImportedListProvider.TRAKT -> "Trakt"
    }

/**
 * A parsed, provider-scoped list reference. The host is fixed per provider (never taken from the pasted URL)
 * so a crafted link cannot point the fetch at an arbitrary host (SSRF-safe). Mirrors Apple `ListImport.Detected`.
 */
internal data class Detected(
    val provider: ImportedListProvider,
    val user: String,
    val slug: String,
    val canonicalUrl: String,
)

internal object ListImport {

    /** Hard cap on titles per imported row, so a large list stays a quick browse and the id fan-out is bounded. */
    const val MAX_ITEMS = 150

    /** Bounded id-resolution concurrency, so a big list does not open MAX_ITEMS sockets at once. */
    const val CONCURRENCY = 6

    /**
     * A browser-like User-Agent. Several of these hosts (Cinemeta, Letterboxd) reject the default agent, the
     * same lesson the add-on and libmpv fetches already learned. Mirrors Apple `ListImport.browserUA`.
     */
    const val BROWSER_UA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"

    private const val CINEMETA = "https://v3-cinemeta.strem.io"

    /**
     * Detect the provider and pull the `<user>` / `<slug>` (or list id) out of a pasted URL. Returns null for
     * any URL that is not a recognized public-list link. Only the path segments are trusted; the host is
     * re-asserted from the provider, so the fetch always targets the provider's real host. Mirrors Apple
     * `ListImport.detect`.
     */
    fun detect(urlString: String): Detected? {
        val trimmed = urlString.trim()
        if (trimmed.isEmpty()) return null
        val withScheme = if (trimmed.startsWith("http", ignoreCase = true)) trimmed else "https://$trimmed"
        val uri = runCatching { URI(withScheme) }.getOrNull() ?: return null
        val rawHost = uri.host?.lowercase() ?: return null
        val host = if (rawHost.startsWith("www.")) rawHost.removePrefix("www.") else rawHost
        val parts = (uri.path ?: "").split("/").filter { it.isNotEmpty() }

        fun matches(base: String): Boolean = host == base || host.endsWith(".$base")

        // Letterboxd: /<user>/list/<slug>/...
        if (matches("letterboxd.com") && parts.size >= 3 && parts[1].equals("list", ignoreCase = true)) {
            val user = parts[0]
            val slug = parts[2]
            if (!isSafeSegment(user) || !isSafeSegment(slug)) return null
            return Detected(
                ImportedListProvider.LETTERBOXD, user, slug,
                "https://letterboxd.com/$user/list/$slug/",
            )
        }
        // MDBList: /lists/<user>/<slug>
        if (matches("mdblist.com") && parts.size >= 3 && parts[0].equals("lists", ignoreCase = true)) {
            val user = parts[1]
            val slug = parts[2]
            if (!isSafeSegment(user) || !isSafeSegment(slug)) return null
            return Detected(
                ImportedListProvider.MDBLIST, user, slug,
                "https://mdblist.com/lists/$user/$slug",
            )
        }
        // Trakt: /users/<user>/lists/<slug>  (also the shorter /lists/<id> form)
        if (matches("trakt.tv")) {
            if (parts.size >= 4 && parts[0].equals("users", ignoreCase = true) &&
                parts[2].equals("lists", ignoreCase = true)
            ) {
                val user = parts[1]
                val slug = parts[3]
                if (!isSafeSegment(user) || !isSafeSegment(slug)) return null
                return Detected(
                    ImportedListProvider.TRAKT, user, slug,
                    "https://trakt.tv/users/$user/lists/$slug",
                )
            }
            if (parts.size >= 2 && parts[0].equals("lists", ignoreCase = true)) {
                val slug = parts[1]
                if (!isSafeSegment(slug)) return null
                return Detected(
                    ImportedListProvider.TRAKT, "", slug,
                    "https://trakt.tv/lists/$slug",
                )
            }
        }
        return null
    }

    /**
     * Fetch + resolve a pasted list URL into an un-persisted catalog. Fail-soft to a typed [ImportedListError]
     * the paste screen can surface. Does NOT persist; the caller registers it with `ImportedCatalogs`. Mirrors
     * Apple `ListImport.importList`.
     */
    suspend fun importList(context: Context, urlString: String): Result<ImportedListCatalog> {
        val detected = detect(urlString) ?: return Result.failure(ImportedListError.UnsupportedUrl)

        val raw = when (detected.provider) {
            ImportedListProvider.MDBLIST -> MdbListImportClient.fetchRawList(context, detected.user, detected.slug)
            ImportedListProvider.LETTERBOXD -> LetterboxdImportClient.fetchRawList(detected.user, detected.slug)
            ImportedListProvider.TRAKT -> {
                // Public paste-a-URL path stays unauthenticated (no bearer), so pasting a link never silently
                // reaches into the connected account for a list the link itself could not open. Dormant until
                // the build carries Trakt creds, matching the Trakt/SIMKL "not available in this build" rule.
                if (!TraktListImportClient.isConfigured) return Result.failure(ImportedListError.NotConfigured(ImportedListProvider.TRAKT))
                TraktListImportClient.fetchRawList(detected.user, detected.slug)
            }
        }

        if (raw.entries.isEmpty()) return Result.failure(ImportedListError.Empty)
        val items = resolve(context, raw.entries.take(MAX_ITEMS))
        if (items.isEmpty()) return Result.failure(ImportedListError.Empty)

        val title = raw.title?.trim()?.takeIf { it.isNotEmpty() } ?: humanize(detected.slug)
        val catalog = ImportedListCatalog(
            id = stableId(detected),
            title = title,
            provider = detected.provider,
            sourceUrl = detected.canonicalUrl,
            items = items,
        )
        return Result.success(catalog)
    }

    /**
     * Resolve raw entries to engine-safe items, in list order, de-duplicated by `type:id`. Bounded concurrency
     * so a large list does not open a socket per entry. Mirrors Apple `ListImport.resolve`.
     */
    suspend fun resolve(context: Context, entries: List<RawListEntry>): List<MetaItem> {
        val resolved = boundedMap(entries, CONCURRENCY) { resolveOne(context, it) }.filterNotNull()
        val seen = HashSet<String>()
        return resolved.filter { seen.add("${it.type.id}:${it.id}") }
    }

    /**
     * One entry to one item. Preference order for the id, best-first: a provider IMDb id, then a TMDB id
     * converted to IMDb through the keyless edge ([TmdbImdbResolver], cached), then a Cinemeta title search.
     * Every branch yields a `tt…` id where possible so the poster is the deterministic metahub image and the
     * card taps through the engine. Returns null when nothing resolves. Mirrors Apple `ListImport.resolveOne`.
     */
    private suspend fun resolveOne(context: Context, entry: RawListEntry): MetaItem? {
        val type = entry.typeHint ?: if (entry.tmdbType == "tv") "series" else "movie"
        val mediaType = MediaType.fromId(type)

        normalizedTt(entry.imdbId)?.let { tt ->
            return MetaItem(id = tt, type = mediaType, name = entry.title ?: tt, poster = metahubPoster(tt))
        }
        entry.tmdbId?.let { tmdb ->
            val tt = TmdbImdbResolver.resolveImdbId(context, "tmdb:$tmdb", seriesHint = type == "series")
            if (tt != null) {
                return MetaItem(id = tt, type = mediaType, name = entry.title ?: tt, poster = metahubPoster(tt))
            }
        }
        val title = entry.title
        if (!title.isNullOrEmpty()) {
            searchCinemeta(title, type)?.let { hit ->
                val poster = hit.poster ?: metahubPoster(hit.id).takeIf { hit.id.startsWith("tt") }
                return hit.copy(poster = poster)
            }
        }
        return null
    }

    /**
     * Best Cinemeta search hit for a title: an exact case-insensitive name match when present, else the first
     * (Cinemeta ranks by relevance). Fail-soft to null. Mirrors Apple `ListImport.searchCinemeta` /
     * `AddonClient.search` (`/catalog/{type}/top/search={q}.json`).
     */
    private suspend fun searchCinemeta(title: String, type: String): MetaItem? {
        val query = encodePath(title)
        val text = ImportHttp.fetchText("$CINEMETA/catalog/$type/top/search=$query.json") ?: return null
        val metas = runCatching { org.json.JSONObject(text).optJSONArray("metas") }.getOrNull() ?: return null
        val hits = ArrayList<MetaItem>(metas.length())
        for (index in 0 until metas.length()) {
            val obj = metas.optJSONObject(index) ?: continue
            val id = obj.optString("id").takeIf { it.isNotBlank() } ?: continue
            hits.add(
                MetaItem(
                    id = id,
                    type = MediaType.fromId(obj.optString("type", type)),
                    name = obj.optString("name").ifBlank { id },
                    poster = obj.optString("poster").takeIf { it.isNotBlank() },
                ),
            )
        }
        if (hits.isEmpty()) return null
        return hits.firstOrNull { it.name.equals(title, ignoreCase = true) } ?: hits.first()
    }

    // MARK: Helpers

    /**
     * Order-preserving, concurrency-bounded async map. Every index is dispatched once and drained once, so the
     * result covers `items.indices` with no gaps. Mirrors Apple `ListImport.boundedMap`.
     */
    suspend fun <T, R> boundedMap(
        items: List<T>,
        concurrency: Int,
        transform: suspend (T) -> R,
    ): List<R> = coroutineScope {
        if (items.isEmpty()) return@coroutineScope emptyList()
        val slots = Semaphore(concurrency.coerceAtLeast(1))
        items.mapIndexed { index, item ->
            async(Dispatchers.IO) { index to slots.withPermit { transform(item) } }
        }.awaitAll().sortedBy { it.first }.map { it.second }
    }

    /**
     * The standard Stremio metahub poster for an IMDb id (keyless, deterministic). Mirrors Apple
     * `ListImport.metahubPoster`.
     */
    fun metahubPoster(tt: String): String = "https://images.metahub.space/poster/medium/$tt/img"

    /** A validated IMDb id ("tt" + digits) or null, so a malformed value never rides into an engine id. */
    fun normalizedTt(raw: String?): String? {
        val value = raw?.trim() ?: return null
        if (!value.startsWith("tt")) return null
        val digits = value.drop(2)
        return if (digits.isNotEmpty() && digits.all(Char::isDigit)) value else null
    }

    /**
     * A stable per-list id so re-importing the same list updates the existing row rather than duplicating it.
     * THE one id format for imported rows (`imported:<provider>:<user>:<slug>`, lowercased), matching Apple
     * `ListImport.stableID`.
     */
    fun stableId(detected: Detected): String =
        "imported:${detected.provider.wire}:${detected.user}:${detected.slug}".lowercase()

    /**
     * Turn a URL slug into a readable title ("official-top-250" -> "Official Top 250") as a fallback when the
     * provider exposes no list name. Mirrors Apple `ListImport.humanize`.
     */
    fun humanize(slug: String): String {
        val joined = slug.replace("_", "-")
            .split("-")
            .filter { it.isNotEmpty() }
            .joinToString(" ") { part -> part.replaceFirstChar { it.uppercaseChar() } }
            .trim()
        return joined.ifEmpty { "Imported list" }
    }

    /**
     * A path segment is safe when it is a single non-empty component with no traversal or separators (the URL
     * parser already split on "/", this rejects the pathological rest). Mirrors Apple `ListImport.isSafeSegment`.
     */
    private fun isSafeSegment(s: String): Boolean =
        s.isNotEmpty() && s != "." && s != ".." && !s.contains("/") && !s.contains("\\")

    /**
     * Percent-encode a path segment for insertion into a fixed-host URL. Over-encoding a path-safe character
     * is harmless; the goal is that a segment can never break out of its position. Mirrors Apple
     * `ListImport.encodePath`.
     */
    fun encodePath(s: String): String =
        java.net.URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    /** First capture group of [pattern] in [text], or null. Mirrors Apple `ListImport.firstMatch`. */
    fun firstMatch(pattern: String, text: String, group: Int = 1): String? =
        Regex(pattern, RegexOption.IGNORE_CASE).find(text)?.groupValues?.getOrNull(group)?.takeIf { it.isNotEmpty() }

    /** All first-capture-group matches of [pattern] in [text], in document order. Mirrors Apple `allMatches`. */
    fun allMatches(pattern: String, text: String, group: Int = 1): List<String> =
        Regex(pattern, RegexOption.IGNORE_CASE).findAll(text).mapNotNull {
            it.groupValues.getOrNull(group)?.takeIf { value -> value.isNotEmpty() }
        }.toList()

    /** Unescape the handful of HTML entities that show up in scraped titles. Mirrors Apple `unescapeHTML`. */
    fun unescapeHtml(s: String): String {
        var out = s
        val map = mapOf(
            "&amp;" to "&", "&#39;" to "'", "&#x27;" to "'", "&quot;" to "\"",
            "&lt;" to "<", "&gt;" to ">", "&nbsp;" to " ",
        )
        for ((entity, value) in map) out = out.replace(entity, value)
        return out.trim()
    }
}
