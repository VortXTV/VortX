package com.vortx.android.foryou

import com.vortx.android.home.CollectionsHubHttpTransport
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject

/**
 * Titles for For You rows and smart collections, through the same signed keyless catalog edge as the
 * Collections hub. Every row is resolved to its IMDb `tt` id (like Apple `TMDBClient.resolveRows`), so a
 * card opens and plays like any catalog card and library ownership can be matched. Rows with no IMDb id
 * are dropped rather than shown as a dead card. Fail-soft: an empty list.
 */
internal object ForYouTmdb {
    private const val IMAGE_BASE = "https://image.tmdb.org/t/p"
    private val transport = CollectionsHubHttpTransport()
    /** At most six external-id lookups in flight, so several rows never burst TMDB into rate limiting. */
    private val lookups = Semaphore(6)
    private val appearanceGenres = setOf(10763, 10764, 10767)

    private data class Row(val tmdbId: Int, val series: Boolean, val name: String, val poster: String?,
                           val background: String?, val year: String?)

    suspend fun ruleTitles(movieQuery: String?, tvQuery: String?, limit: Int = 20): List<MetaItem> = coroutineScope {
        val movie = async { movieQuery?.let { page("movie", it) }.orEmpty() }
        val tv = async { tvQuery?.let { page("tv", it) }.orEmpty() }
        resolve(interleave(movie.await(), tv.await()), limit)
    }

    /** A followed person's best-known work: acting plus directing and writing, most-voted first; self
     * appearances and talk, news and reality shows left out (they list every guest spot). */
    suspend fun personTopTitles(id: Int, limit: Int = 20): List<MetaItem> {
        if (id <= 0) return emptyList()
        val root = runCatching { transport.getJson("/person/$id/combined_credits") }.getOrNull() ?: return emptyList()
        val crew = root.optJSONArray("crew").objects().filter { it.optString("department") in setOf("Directing", "Writing") }
        val seen = HashSet<String>()
        val ranked = (root.optJSONArray("cast").objects() + crew).mapNotNull { entry ->
            val media = entry.optString("media_type").takeIf { it == "movie" || it == "tv" } ?: return@mapNotNull null
            val tmdbId = entry.optInt("id", 0).takeIf { it > 0 } ?: return@mapNotNull null
            if (!seen.add("$media:$tmdbId")) return@mapNotNull null
            val character = entry.optString("character").lowercase()
            if (listOf("self", "himself", "herself").any(character::startsWith)) return@mapNotNull null
            val genres = entry.optJSONArray("genre_ids")?.let { array -> (0 until array.length()).map(array::optInt) }.orEmpty()
            if (genres.any(appearanceGenres::contains)) return@mapNotNull null
            row(entry, media == "tv")?.let { it to entry.optInt("vote_count", 0) }
        }
        return resolve(ranked.sortedByDescending { it.second }.map { it.first }, limit)
    }

    private suspend fun page(media: String, query: String): List<Row> {
        val root = runCatching { transport.getJson("/discover/$media?$query&language=en-US&page=1") }.getOrNull() ?: return emptyList()
        return root.optJSONArray("results").objects().mapNotNull { row(it, media == "tv") }
    }

    private fun row(entry: JSONObject, series: Boolean): Row? {
        val id = entry.optInt("id", 0).takeIf { it > 0 } ?: return null
        val name = entry.optString("title").ifBlank { entry.optString("name") }.takeIf { it.isNotBlank() } ?: return null
        val date = entry.optString("release_date").ifBlank { entry.optString("first_air_date") }
        return Row(id, series, name,
            entry.optString("poster_path").takeIf { it.isNotBlank() && it != "null" }?.let { "$IMAGE_BASE/w342$it" },
            entry.optString("backdrop_path").takeIf { it.isNotBlank() && it != "null" }?.let { "$IMAGE_BASE/w780$it" },
            date.take(4).takeIf { it.length == 4 })
    }

    /** Over-fetch two candidates per slot (some have no IMDb id), keep order, de-duplicate, cap. */
    private suspend fun resolve(rows: List<Row>, limit: Int): List<MetaItem> = coroutineScope {
        rows.filter { it.poster != null }.take(limit * 2).map { row ->
            async {
                lookups.withPermit {
                    val ids = runCatching { transport.getJson("/${if (row.series) "tv" else "movie"}/${row.tmdbId}/external_ids") }.getOrNull()
                    ids?.optString("imdb_id")?.takeIf { it.startsWith("tt") }?.let { imdb ->
                        MetaItem(id = imdb, type = if (row.series) MediaType.SERIES else MediaType.MOVIE, name = row.name,
                            poster = row.poster, year = row.year, background = row.background)
                    }
                }
            }
        }.awaitAll().filterNotNull().distinctBy { it.id }.take(limit)
    }

    private fun interleave(first: List<Row>, second: List<Row>): List<Row> = buildList {
        repeat(maxOf(first.size, second.size)) { index ->
            first.getOrNull(index)?.let(::add)
            second.getOrNull(index)?.let(::add)
        }
    }

    private fun JSONArray?.objects(): List<JSONObject> =
        this?.let { array -> (0 until array.length()).mapNotNull(array::optJSONObject) }.orEmpty()
}
