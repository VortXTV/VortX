package com.vortx.android.catalog

import org.json.JSONArray
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Locale

/// DET "Release dates": a movie's theatrical (TMDB release type 3) + digital (type 4) dates from
/// /movie/{id}/release_dates, resolved from an IMDb id through the keyless catalogs edge in
/// [CatalogTmdbEdge]. The Android port of Apple `TMDBClient.releaseDates` / the detail view's
/// `releaseDatesRow`. Movies only (TMDB carries no TV release dates). Region-aware: the caller's effective
/// region first (see [DiscoverRegion]), then a US fallback PER FIELD. Fail-soft: null on a series / a
/// non-`tt` id / neither date found / any error, so the caller omits the row.
object ReleaseDatesClient {

    /// Theatrical + digital dates, already pretty-printed ("Mar 1, 2024"), either field null when TMDB has
    /// none. Mirrors Apple `TMDBClient.ReleaseDates`.
    data class ReleaseDates(val theatrical: String?, val digital: String?)

    /// Release dates for [imdbId] in [region] (device / override region), each field falling back to US.
    /// Null with a series / a non-`tt` id / neither date found. Mirrors Apple
    /// `TMDBClient.releaseDates(imdbID:type:)`.
    suspend fun releaseDates(imdbId: String, isSeries: Boolean, region: String): ReleaseDates? {
        if (isSeries || !imdbId.startsWith("tt")) return null
        val found = CatalogTmdbEdge.getJson("/find/$imdbId?external_source=imdb_id") ?: return null
        val tmdbId = found.optJSONArray("movie_results")?.optJSONObject(0)
            ?.optInt("id", 0)?.takeIf { it > 0 } ?: return null
        val results = CatalogTmdbEdge.getJson("/movie/$tmdbId/release_dates")?.optJSONArray("results")
            ?: return null

        var theatrical: String? = null
        var digital: String? = null
        entriesForRegion(results, region)?.let { local ->
            theatrical = dateOfType(local, 3)
            digital = dateOfType(local, 4)
        }
        if (theatrical == null || digital == null) {
            entriesForRegion(results, "US")?.let { us ->
                theatrical = theatrical ?: dateOfType(us, 3)
                digital = digital ?: dateOfType(us, 4)
            }
        }
        if (theatrical == null && digital == null) return null
        return ReleaseDates(theatrical = prettyDate(theatrical), digital = prettyDate(digital))
    }

    /// "In theaters Mar 1, 2024  ·  Digital Apr 12, 2024" -- each half present only when its date is. Null
    /// when neither is present. Mirrors Apple `releaseDatesText`.
    fun releaseDatesText(d: ReleaseDates): String? {
        val parts = ArrayList<String>(2)
        d.theatrical?.let { parts += "In theaters $it" }
        d.digital?.let { parts += "Digital $it" }
        return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
    }

    private fun entriesForRegion(results: JSONArray, code: String): JSONArray? {
        for (i in 0 until results.length()) {
            val entry = results.optJSONObject(i) ?: continue
            if (entry.optString("iso_3166_1") == code) return entry.optJSONArray("release_dates")
        }
        return null
    }

    private fun dateOfType(entries: JSONArray, type: Int): String? {
        for (i in 0 until entries.length()) {
            val entry = entries.optJSONObject(i) ?: continue
            if (entry.optInt("type", -1) == type) {
                return entry.optString("release_date").takeIf { it.isNotEmpty() }
            }
        }
        return null
    }

    /// TMDB sends "2024-03-01T00:00:00.000Z" (or "2024-03-01"); render the date part as "Mar 1, 2024".
    /// Locale-aware output like Apple's medium date style; null for a null / too-short / unparseable value.
    private fun prettyDate(iso: String?): String? {
        if (iso == null || iso.length < 10) return null
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val date = runCatching { parser.parse(iso.take(10)) }.getOrNull() ?: return null
        return DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.getDefault()).format(date)
    }
}
