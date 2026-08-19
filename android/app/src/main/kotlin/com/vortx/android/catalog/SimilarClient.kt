package com.vortx.android.catalog

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

/// DET-3 "More Like This": TMDB recommendations for a title, mapped onto the same [MetaItem] cards the
/// hub rails use so each tile opens the normal engine-backed detail + stream path. The Android analogue
/// of the Apple detail view's `loadSimilar` TMDB-recommendations leg (`AddonClient.tmdbSimilar`), routed
/// through the keyless catalogs edge in [CatalogTmdbEdge] so a user with no TMDB key still gets a rail.
///
/// This is the imdb-only leg of Apple's merged rail (TMDB recommendations + add-on genre-similar). The
/// add-on genre-similar merge is not ported here; the TMDB leg alone is the fail-soft fallback Apple keeps
/// for a title whose meta has no genres, and it is enough to populate the rail. Deliberately fail-soft:
/// every path returns [] on a non-`tt` id, no match, no data, or any transport error, so the caller simply
/// omits the section (never blanks or crashes).
object SimilarClient {

    /// Cards recommended for [imdbId], best-first, TMDB-original-language-of-the-seed prioritised (the same
    /// ordering `TMDBPersonClient.recommendations` uses), the seed excluded, deduped by id, entries with no
    /// poster or title dropped, capped at [MAX_SIMILAR]. Ids are `tmdb:<n>` so the caller resolves them to a
    /// `tt` id before opening (exactly as the Person filmography tiles do), which gives the pushed detail its
    /// hero, ratings, and sources.
    suspend fun similar(imdbId: String, type: MediaType): List<MetaItem> {
        if (!imdbId.startsWith("tt")) return emptyList()
        val media = if (type == MediaType.SERIES) "tv" else "movie"
        val found = CatalogTmdbEdge.getJson("/find/$imdbId?external_source=imdb_id") ?: return emptyList()
        val resultsKey = if (media == "tv") "tv_results" else "movie_results"
        val seed = found.optJSONArray(resultsKey)?.optJSONObject(0) ?: return emptyList()
        val seedId = seed.optInt("id", 0).takeIf { it > 0 } ?: return emptyList()
        val seedLanguage = seed.optStringOrNull("original_language")
        val results = CatalogTmdbEdge.getJson("/$media/$seedId/recommendations")?.optJSONArray("results")
            ?: return emptyList()

        val seen = HashSet<String>()
        data class Ranked(val item: MetaItem, val sameLanguage: Boolean, val index: Int)
        val ranked = ArrayList<Ranked>(results.length())
        for (index in 0 until results.length()) {
            val entry = results.optJSONObject(index) ?: continue
            val tid = entry.optInt("id", 0).takeIf { it > 0 } ?: continue
            if (tid == seedId) continue // exclude self
            val name = (entry.optStringOrNull("title") ?: entry.optStringOrNull("name")) ?: continue
            val posterPath = entry.optStringOrNull("poster_path") ?: continue
            val cid = "tmdb:$tid"
            if (!seen.add(cid)) continue
            val date = entry.optStringOrNull("release_date") ?: entry.optStringOrNull("first_air_date") ?: ""
            ranked += Ranked(
                item = MetaItem(
                    id = cid,
                    // TMDB recommendations keep the seed's media type; a movie recommends movies, a series
                    // series, so the seed [type] is the right kind for opening + tmdb->tt resolution.
                    type = type,
                    name = name,
                    poster = "${CatalogTmdbEdge.IMAGE_BASE}/w342$posterPath",
                    year = date.take(4).takeIf { it.length == 4 },
                ),
                sameLanguage = entry.optStringOrNull("original_language") == seedLanguage,
                index = index,
            )
        }
        return ranked
            .sortedWith(compareByDescending<Ranked> { it.sameLanguage }.thenBy { it.index })
            .map { it.item }
            .take(MAX_SIMILAR)
    }

    private const val MAX_SIMILAR = 20
}
