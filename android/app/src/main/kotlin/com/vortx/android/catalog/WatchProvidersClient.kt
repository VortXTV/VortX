package com.vortx.android.catalog

import com.vortx.android.model.MediaType

/// One legal streaming provider for a title in the viewer's region, mirroring Apple `TMDBClient.WatchProvider`.
data class WatchProvider(
    val name: String,
    val logoUrl: String?,
)

/// Legal streaming availability for a title in the viewer's region (TMDB watch/providers, JustWatch data).
/// [link] is the JustWatch page for the title (the "See all options" deep link TMDB rides on each region
/// bucket), null when TMDB has none. Mirrors Apple `TMDBClient.WatchAvailability`.
data class WatchAvailability(
    val link: String?,
    val providers: List<WatchProvider>,
)

/// DET-6 "Where to Watch": legal streaming availability for a title in the viewer's region, from TMDB's
/// watch/providers endpoint, routed through the keyless catalogs edge in [CatalogTmdbEdge]. The Android
/// analogue of the Apple detail view's `loadWatchProviders` / `TMDBClient.watchProviders`. Streaming
/// (flatrate) is listed first, then rent, then buy, deduped by provider name.
///
/// FAIL-SOFT by contract: [availability] resolves to null on a non-`tt` id, no region match, no data, or any
/// transport error, so the caller simply omits the section (never blanks or crashes). The rail is also
/// hidden for live content by the caller (a channel has no watch providers).
object WatchProvidersClient {

    /// Availability for [imdbId] in [region] (the caller's effective region -- see [DiscoverRegion], which
    /// honours the user's `vortx.discover.regionPreference` override before the device region). Providers are
    /// best-first (streaming, then rent, then buy), deduped by name; [WatchAvailability.link] is the region's
    /// JustWatch page. null on a non-`tt` id, no tmdb match, no region bucket, or any error.
    suspend fun availability(imdbId: String, type: MediaType, region: String): WatchAvailability? {
        if (!imdbId.startsWith("tt")) return null
        val media = if (type == MediaType.SERIES) "tv" else "movie"
        val found = CatalogTmdbEdge.getJson("/find/$imdbId?external_source=imdb_id") ?: return null
        val resultsKey = if (media == "tv") "tv_results" else "movie_results"
        val tmdbId = found.optJSONArray(resultsKey)?.optJSONObject(0)
            ?.optInt("id", 0)?.takeIf { it > 0 } ?: return null
        val results = CatalogTmdbEdge.getJson("/$media/$tmdbId/watch/providers")?.optJSONObject("results")
            ?: return null
        val here = results.optJSONObject(region) ?: return null
        val link = here.optStringOrNull("link")

        val seen = HashSet<String>()
        val out = ArrayList<WatchProvider>()
        // Streaming first, then rent, then buy; dedupe by provider name, each bucket ordered by TMDB's
        // display_priority (matches Apple's `read` helper).
        for (bucket in listOf("flatrate", "rent", "buy")) {
            val arr = here.optJSONArray(bucket) ?: continue
            val entries = ArrayList<Triple<Int, String, String?>>(arr.length())
            for (i in 0 until arr.length()) {
                val p = arr.optJSONObject(i) ?: continue
                val name = p.optStringOrNull("provider_name") ?: continue
                val logo = p.optStringOrNull("logo_path")?.let { "${CatalogTmdbEdge.IMAGE_BASE}/w92$it" }
                entries += Triple(p.optInt("display_priority", 99), name, logo)
            }
            entries.sortedBy { it.first }.forEach { (_, name, logo) ->
                if (seen.add(name)) out += WatchProvider(name = name, logoUrl = logo)
            }
        }
        if (out.isEmpty()) return null
        return WatchAvailability(link = link, providers = out)
    }
}
