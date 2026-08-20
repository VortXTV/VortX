package com.vortx.android.catalog

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/// DET-3 "More Like This", the ADD-ON genre-similar leg: items similar to a title from the installed
/// Cinemeta catalogs (up to 3 genre-filtered top catalogs plus, when the title looks like a franchise
/// member, a keyword search for the series name), the Android port of Apple `AddonClient.similar`. Merged
/// BEHIND the deduped TMDB recommendations by the caller (recommendations first, this fills in), so the
/// rail is richer once the title's genres are known. Results are ranked by how "like this" they really
/// are: a franchise (keyword) hit first, then GENRE OVERLAP (how many of the seed's genre lists an item
/// appears in), then popularity as a tie-breaker. Fail-soft: [] with no genres or on any transport error.
object AddonSimilarClient {

    private const val CINEMETA = "https://v3-cinemeta.strem.io"
    private const val TIMEOUT_MS = 20_000

    /// One Cinemeta card carrying the popularity read off its meta (kept beside the [MetaItem] so the card
    /// model is not widened), used only to break ranking ties.
    private data class RankedItem(val item: MetaItem, val popularity: Double)

    /// Cards similar to a title, from up to three of its [genres] plus a franchise-keyword search derived
    /// from [title], with [excludingId] (the seed) dropped. [] when no genres are known (the TMDB
    /// recommendations leg still populates the rail on its own). Mirrors Apple `AddonClient.similar`.
    suspend fun genreSimilar(
        type: MediaType,
        excludingId: String,
        genres: List<String>,
        title: String,
    ): List<MetaItem> {
        val genresToQuery = genres.take(3)
        if (genresToQuery.isEmpty()) return emptyList()
        val keyword = franchiseKeyword(title)

        data class Bucket(val isKeyword: Boolean, val items: List<RankedItem>)
        val buckets = coroutineScope {
            val genreJobs = genresToQuery.map { genre ->
                async { Bucket(isKeyword = false, items = topCatalog(type, "genre", genre)) }
            }
            val keywordJob = keyword?.let { kw ->
                async { Bucket(isKeyword = true, items = topCatalog(type, "search", kw)) }
            }
            (genreJobs + listOfNotNull(keywordJob)).awaitAll()
        }

        val byId = LinkedHashMap<String, MetaItem>()
        val keywordIds = HashSet<String>()
        val genreHits = HashMap<String, Int>()
        val popularity = HashMap<String, Double>()
        for (bucket in buckets) {
            for (ranked in bucket.items) {
                val item = ranked.item
                if (item.id == excludingId) continue
                byId[item.id] = item
                popularity[item.id] = maxOf(popularity[item.id] ?: 0.0, ranked.popularity)
                if (bucket.isKeyword) {
                    keywordIds.add(item.id)
                } else {
                    genreHits[item.id] = (genreHits[item.id] ?: 0) + 1
                }
            }
        }
        // Rank: franchise (keyword) match is the strongest same-series signal; then GENRE OVERLAP; popularity
        // only breaks ties within a tier. Mirrors Apple `AddonClient.similar`'s comparator.
        return byId.values.sortedWith(
            compareByDescending<MetaItem> { it.id in keywordIds }
                .thenByDescending { genreHits[it.id] ?: 0 }
                .thenByDescending { popularity[it.id] ?: 0.0 },
        )
    }

    /// Extract a franchise keyword from a title when it signals a series: anything before a colon
    /// ("Title: Subtitle" -> "Title"), or the base name with a trailing number stripped ("Title 3" ->
    /// "Title"). Null for a standalone title (a keyword search would just return the same item). Mirrors
    /// Apple `AddonClient.franchiseKeyword`.
    private fun franchiseKeyword(title: String): String? {
        val colon = title.indexOf(':')
        if (colon > 0) {
            val before = title.substring(0, colon).trim()
            if (before.isNotEmpty()) return before
        }
        val words = title.split(" ").filter { it.isNotBlank() }
        val last = words.lastOrNull()
        if (last != null && last.toIntOrNull() != null && words.size > 1) {
            return words.dropLast(1).joinToString(" ")
        }
        return null
    }

    /// One Cinemeta top catalog (`/catalog/{type}/top/{pivot}={value}.json`), parsed into ranked cards.
    /// [pivot] is "genre" or "search". Fail-soft: [] on a non-200 or any transport / decode error.
    private suspend fun topCatalog(type: MediaType, pivot: String, value: String): List<RankedItem> =
        withContext(Dispatchers.IO) {
            var connection: HttpURLConnection? = null
            try {
                val encoded = URLEncoder.encode(value, "UTF-8")
                val url = URL("$CINEMETA/catalog/${type.id}/top/$pivot=$encoded.json")
                connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    useCaches = true
                    setRequestProperty("accept", "application/json")
                }
                if (connection.responseCode != 200) return@withContext emptyList()
                val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                val metas = runCatching { JSONObject(text) }.getOrNull()?.optJSONArray("metas")
                    ?: return@withContext emptyList()
                val out = ArrayList<RankedItem>(metas.length())
                for (i in 0 until metas.length()) {
                    val meta = metas.optJSONObject(i) ?: continue
                    val id = meta.optStringOrNull("id")?.takeIf { it.startsWith("tt") } ?: continue
                    val name = meta.optStringOrNull("name") ?: continue
                    val resolvedType = MediaType.fromId(meta.optString("type", type.id))
                    val pop = meta.optDouble("popularity", Double.NaN).takeIf { !it.isNaN() } ?: 0.0
                    out += RankedItem(
                        item = MetaItem(
                            id = id,
                            type = resolvedType,
                            name = name,
                            poster = meta.optStringOrNull("poster"),
                            year = meta.optStringOrNull("releaseInfo")?.take(4)?.takeIf { it.length == 4 },
                        ),
                        popularity = pop,
                    )
                }
                out
            } catch (_: IOException) {
                emptyList()
            } finally {
                connection?.disconnect()
            }
        }
}
