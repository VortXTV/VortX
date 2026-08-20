package com.vortx.android.catalog

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem

/// DET "Collection / franchise": the TMDB collection a MOVIE belongs to (`belongs_to_collection` on
/// /movie/{id}) with every entry resolved to a card in RELEASE ORDER, the Android port of Apple
/// `TMDBClient.movieCollection` / the detail view's collection rail. Routed through the keyless catalogs
/// edge in [CatalogTmdbEdge] (no user key). Movies only (TMDB tags no franchise on TV). Parts carry
/// `tmdb:` ids so a tapped card opens through the detail view's existing tmdb->tt resolution, exactly like
/// the person filmography and the More-Like-This rail. Fail-soft: null on a series / a standalone film with
/// no collection / no data / any error.
object CollectionClient {

    /// A movie's franchise: the collection's display name plus every entry as an engine-openable card, in
    /// release order. Mirrors Apple `TMDBClient.CollectionResult`.
    data class MovieCollection(val id: Int, val name: String, val parts: List<MetaItem>)

    /// The collection for [imdbId], or null with a series / a non-`tt` id / a standalone film / no data.
    /// Entries with no poster are KEPT (the card shows a placeholder) so the row lists the WHOLE set.
    /// Mirrors Apple `TMDBClient.movieCollection`.
    suspend fun collection(imdbId: String, isSeries: Boolean): MovieCollection? {
        if (isSeries || !imdbId.startsWith("tt")) return null
        val found = CatalogTmdbEdge.getJson("/find/$imdbId?external_source=imdb_id") ?: return null
        val tmdbId = found.optJSONArray("movie_results")?.optJSONObject(0)
            ?.optInt("id", 0)?.takeIf { it > 0 } ?: return null
        val movie = CatalogTmdbEdge.getJson("/movie/$tmdbId") ?: return null
        val belongs = movie.optJSONObject("belongs_to_collection") ?: return null
        val collectionId = belongs.optInt("id", 0).takeIf { it > 0 } ?: return null
        val payload = CatalogTmdbEdge.getJson("/collection/$collectionId") ?: return null
        val parts = payload.optJSONArray("parts") ?: return null
        val name = payload.optStringOrNull("name") ?: belongs.optStringOrNull("name") ?: ""

        // Release order: ISO `release_date` sorts lexicographically == chronologically; a dated entry sorts
        // before an undated (unreleased / TBA) one, which lands at the end. Mirrors Apple's sort.
        data class Part(val entryIndex: Int, val date: String, val item: MetaItem)
        val seen = HashSet<String>()
        val collected = ArrayList<Part>(parts.length())
        for (index in 0 until parts.length()) {
            val entry = parts.optJSONObject(index) ?: continue
            val tid = entry.optInt("id", 0).takeIf { it > 0 } ?: continue
            val title = (entry.optStringOrNull("title") ?: entry.optStringOrNull("name")) ?: continue
            val cid = "tmdb:$tid"
            if (!seen.add(cid)) continue
            val date = entry.optStringOrNull("release_date") ?: ""
            val posterPath = entry.optStringOrNull("poster_path")
            collected += Part(
                entryIndex = index,
                date = date,
                item = MetaItem(
                    id = cid,
                    type = MediaType.MOVIE,
                    name = title,
                    poster = posterPath?.let { "${CatalogTmdbEdge.IMAGE_BASE}/w342$it" },
                    year = date.take(4).takeIf { it.length == 4 },
                ),
            )
        }
        if (collected.isEmpty()) return null
        val ordered = collected
            .sortedWith(
                compareByDescending<Part> { it.date.isNotEmpty() }
                    .thenBy { it.date }
                    .thenBy { it.entryIndex },
            )
            .map { it.item }
        return MovieCollection(id = collectionId, name = name, parts = ordered)
    }

    /// The framed "Part of the <X> Collection" header from a TMDB collection name. TMDB names already end in
    /// "Collection" and usually start with "The" (e.g. "The Dark Knight Collection"), so strip both before
    /// re-framing: "Part of the Dark Knight Collection", NOT "...The Dark Knight Collection Collection".
    /// Mirrors Apple `TMDBClient.collectionRowTitle`.
    fun collectionRowTitle(name: String): String {
        var base = name.trim()
        if (base.lowercase().endsWith(" collection")) {
            base = base.dropLast(" collection".length).trim()
        }
        if (base.lowercase().startsWith("the ")) base = base.drop(4)
        return if (base.isEmpty()) "Part of the Collection" else "Part of the $base Collection"
    }
}
