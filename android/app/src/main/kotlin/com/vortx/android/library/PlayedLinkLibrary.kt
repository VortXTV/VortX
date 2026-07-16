package com.vortx.android.library

import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Issue #81: when a user plays a magnet / torrent from "Play a link", try to recognise WHAT it is (clean
 * the torrent name, match it to a real Cinemeta title) and save THAT to the library, so the thing they just
 * watched shows up in their library like any catalog item. Android port of
 * `app/SourcesShared/PlayedLinkLibrary.swift`.
 *
 * Hard invariant (CLAUDE.md "Never write app data into libraryItem", + the Apple SavedLinksStore/ProfileSync
 * note): a raw magnet has no catalog meta id, and injecting a synthetic item into the stremio-core library
 * corrupts account-wide sync for the official Stremio clients. So we ONLY ever add a *resolved* item (a real
 * `tt…` / `tmdb:…` id from Cinemeta), and we add it through the engine's OWN AddToLibrary dispatch
 * ([CatalogRepository.addToLibrary]) -- the same account-syncing path the manual Library button uses, never
 * an app-side libraryItem write. If nothing matches, we add nothing.
 *
 * Per-profile note: Apple routes overlay profiles to a private local overlay and only the main profile to
 * the engine. Android has no profile-overlay layer yet (see [com.vortx.android.search.SearchHistoryStore]'s
 * S09 deferral); until it lands, this is single-profile (engine/account) behavior, which is exactly what a
 * single-profile Apple install does. Wiring the overlay branch is a follow-up for the profile layer.
 *
 * Best-effort + fail-soft throughout: any search/network miss simply leaves the raw link unsaved.
 */
object PlayedLinkLibrary {

    /** Default metadata add-on (public), matching Apple `AddonClient.cinemeta`. */
    private const val CINEMETA = "https://v3-cinemeta.strem.io"
    private const val TIMEOUT_MS = 20_000

    /** The edit-distance confidence bar a non-exact, non-prefix match must clear (Apple's 0.82). */
    private const val SIMILARITY_BAR = 0.82

    /**
     * Resolve [displayName] (a magnet `dn=` / torrent file name) to a Cinemeta title and save it to the
     * active library. No-op on no confident match. [repo] is the engine seam (Android's analogue of Apple's
     * `CoreBridge`). Mirrors Apple `savePlayedTorrent`.
     */
    suspend fun savePlayedTorrent(repo: CatalogRepository, displayName: String) {
        val parsed = cleanTitle(displayName)
        if (parsed.query.length < 2 || isPlaceholder(parsed.query)) return

        // Filenames misclassify, so try the guessed type first, then the other.
        val primary = if (parsed.isSeries) "series" else "movie"
        val secondary = if (parsed.isSeries) "movie" else "series"

        // #81: accept a hit ONLY when its title confidently matches the cleaned torrent name (see
        // [matchScore]). No confident match -> add nothing.
        val preview = bestMatch(search(primary, parsed.query), parsed.query)
            ?: bestMatch(search(secondary, parsed.query), parsed.query)
            ?: return

        // A real Cinemeta catalog id, safe for official-client account sync. The engine re-derives the rest
        // of the library item from the id (its AddToLibrary reducer only needs id/type/name/poster).
        repo.addToLibrary(
            MetaItem(
                id = preview.id,
                type = MediaType.fromId(preview.type),
                name = preview.name,
                poster = preview.poster,
            ),
        )
    }

    /** A Cinemeta search result (grid card), the fields #81 matching needs. Mirrors Apple `MetaPreview`. */
    data class CinemetaPreview(val id: String, val type: String, val name: String, val poster: String?)

    /** The cleaned title + a movie-vs-series guess. Mirrors Apple `cleanTitle`'s tuple return. */
    data class CleanedTitle(val query: String, val isSeries: Boolean)

    /**
     * GET Cinemeta's search catalog for [type]/[query], fail-soft to [] on any error. Endpoint matches Apple
     * `AddonClient.search`: `{cinemeta}/catalog/{type}/top/search={q}.json` -> `{ metas: [...] }`.
     */
    private suspend fun search(type: String, query: String): List<CinemetaPreview> = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val q = URLEncoder.encode(query, "UTF-8").replace("+", "%20")
            connection = (URL("$CINEMETA/catalog/$type/top/search=$q.json").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                setRequestProperty("accept", "application/json")
            }
            if (connection.responseCode != 200) return@withContext emptyList()
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val metas = runCatching { JSONObject(text) }.getOrNull()?.optJSONArray("metas")
                ?: return@withContext emptyList()
            val out = ArrayList<CinemetaPreview>(metas.length())
            for (i in 0 until metas.length()) {
                val entry = metas.optJSONObject(i) ?: continue
                val id = entry.optStringOrNull("id") ?: continue
                val type2 = entry.optStringOrNull("type") ?: continue
                val name = entry.optStringOrNull("name") ?: continue
                out += CinemetaPreview(id = id, type = type2, name = name, poster = entry.optStringOrNull("poster"))
            }
            out
        } catch (_: IOException) {
            emptyList()
        } finally {
            connection?.disconnect()
        }
    }

    /**
     * Turn a torrent / magnet display name into a searchable title and a movie-vs-series guess. The clean
     * title is whatever precedes the earliest "junk" marker (release year, resolution, source, codec) or
     * season/episode marker. Mirrors Apple `cleanTitle` (same pattern set, same earliest-cut rule).
     */
    fun cleanTitle(raw: String): CleanedTitle {
        var s = raw
        // Drop a trailing file extension (".mkv", ".mp4", …): a dot within 5 chars of the end whose tail is
        // all letters/digits.
        val dot = s.lastIndexOf('.')
        if (dot >= 0 && s.length - dot <= 5) {
            val ext = s.substring(dot + 1)
            if (ext.isNotEmpty() && ext.all { it.isLetterOrDigit() }) s = s.substring(0, dot)
        }
        // Separators -> spaces.
        s = s.map { if (it in SEPARATORS) ' ' else it }.joinToString("")

        var cut = s.length
        var isSeries = false
        fun scan(patterns: List<Regex>, markSeries: Boolean) {
            for (re in patterns) {
                val m = re.find(s) ?: continue
                if (markSeries) isSeries = true
                if (m.range.first < cut) cut = m.range.first
            }
        }
        scan(SERIES_PATTERNS, markSeries = true)
        scan(JUNK_PATTERNS, markSeries = false)

        val title = s.substring(0, cut)
            .split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")
            .trim()
        return CleanedTitle(query = title, isSeries = isSeries)
    }

    /** Generic placeholders the magnet resolver hands back when it has no real name. Mirrors Apple `isPlaceholder`. */
    private fun isPlaceholder(q: String): Boolean =
        q.lowercase() in setOf("torrent", "file", "stream", "video", "magnet link")

    /**
     * The result whose title confidently matches the cleaned torrent name, highest score first; null when
     * nothing clears the bar. This is the #81 guard: a fan-sub magnet must not adopt an unrelated catalog
     * title just because it was the first search hit. Mirrors Apple `bestMatch`.
     */
    fun bestMatch(results: List<CinemetaPreview>, query: String): CinemetaPreview? {
        val q = normalize(query)
        if (q.isEmpty()) return null
        return results
            .mapNotNull { p -> matchScore(q, normalize(p.name))?.let { p to it } }
            .maxByOrNull { it.second }
            ?.first
    }

    /**
     * A confidence score in (0, 1] when [name] is a trustworthy match for the already-normalized query [q],
     * else null. Exact match = 1; otherwise an edit-distance similarity must clear [SIMILARITY_BAR].
     *
     * #81: a bare prefix match is NOT enough on its own. A prefix is trusted ONLY when the tail it omits is
     * trivial (a year, a colon, an edition word folded to a few chars): the absolute gap must be tiny
     * (<= 2 chars) AND the shorter must still be the dominant share (>= 88%). Anything looser falls through
     * to the edit-distance bar, which a real sequel title cannot clear against a bare franchise root, so an
     * unmatched franchise magnet stays unsaved rather than poisoning the library. Ported EXACTLY from Apple
     * `matchScore` (this is load-bearing string logic).
     */
    private fun matchScore(q: String, name: String): Double? {
        if (q.isEmpty() || name.isEmpty()) return null
        if (q == name) return 1.0
        val shorter = if (q.length <= name.length) q else name
        val longer = if (q.length <= name.length) name else q
        if (longer.startsWith(shorter)) {
            if (longer.length - shorter.length <= 2 && shorter.length.toDouble() >= 0.88 * longer.length.toDouble()) {
                return 0.95
            }
            return null
        }
        val sim = similarity(q, name)
        return if (sim >= SIMILARITY_BAR) sim else null
    }

    /**
     * Lowercased, non-alphanumerics folded to single spaces, trimmed, so "Kamen.Rider_Gavv" and
     * "kamen rider gavv" compare equal. Mirrors Apple `normalize`.
     */
    private fun normalize(s: String): String {
        val mapped = s.lowercase().map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("")
        return mapped.split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** 1 - (Levenshtein distance / longer length), in [0, 1]. Mirrors Apple `similarity`. */
    private fun similarity(a: String, b: String): Double {
        val maxLen = maxOf(a.length, b.length)
        if (maxLen == 0) return 1.0
        return 1.0 - levenshtein(a, b).toDouble() / maxLen.toDouble()
    }

    /**
     * Classic edit distance, two-row variant (cheap on short title strings). Ported EXACTLY from Apple
     * `levenshtein` (this is load-bearing string logic).
     */
    private fun levenshtein(a: String, b: String): Int {
        val x = a.toCharArray()
        val y = b.toCharArray()
        if (x.isEmpty()) return y.size
        if (y.isEmpty()) return x.size
        var prev = IntArray(y.size + 1) { it }
        var cur = IntArray(y.size + 1)
        for (i in 1..x.size) {
            cur[0] = i
            for (j in 1..y.size) {
                val cost = if (x[i - 1] == y[j - 1]) 0 else 1
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            val swap = prev; prev = cur; cur = swap
        }
        return prev[y.size]
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    /** Characters treated as word separators before scanning (Apple's `._[](){}+-` set). */
    private val SEPARATORS = "._[](){}+-".toSet()
    private val WHITESPACE = Regex("\\s+")

    /**
     * Series markers (S01E02, 1x02, "Season"); the earliest also cuts the title. IGNORE_CASE on every
     * pattern because Apple compiles the whole set with `.caseInsensitive` (so `1X02` matches too). Mirrors
     * Apple `seriesPatterns`.
     */
    private val SERIES_PATTERNS = listOf(
        Regex("[sS][0-9]{1,2} ?[eE][0-9]{1,2}", RegexOption.IGNORE_CASE),
        Regex("\\b[0-9]{1,2}x[0-9]{1,2}\\b", RegexOption.IGNORE_CASE),
        Regex("\\b[sS]eason\\b", RegexOption.IGNORE_CASE),
    )

    /** Release-junk markers (year, resolution, source, codec, edition); the earliest cuts the title. Mirrors `junkPatterns`. */
    private val JUNK_PATTERNS = listOf(
        Regex("\\b(19|20)[0-9]{2}\\b"),
        Regex("\\b(480p|576p|720p|1080p|1440p|2160p|4k|uhd)\\b", RegexOption.IGNORE_CASE),
        Regex("\\b(bluray|blu ?ray|brrip|bdrip|webrip|web ?dl|web|hdrip|dvdrip|hdtv|hdcam|cam|ts)\\b", RegexOption.IGNORE_CASE),
        Regex("\\b(x264|x265|h264|h265|hevc|avc|xvid|divx|aac|ac3|dts|ddp?5 1|atmos)\\b", RegexOption.IGNORE_CASE),
        Regex("\\b(remux|proper|repack|extended|unrated|imax|multi|dual)\\b", RegexOption.IGNORE_CASE),
    )
}
