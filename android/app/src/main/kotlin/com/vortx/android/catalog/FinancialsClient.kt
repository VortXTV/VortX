package com.vortx.android.catalog

import java.util.Locale

/// DET "Financials": a movie's budget + box office (revenue), the Android port of Apple
/// `TMDBClient.details` / the detail view's `financialsRow`. Resolved from an IMDb id through the keyless
/// catalogs edge in [CatalogTmdbEdge] (/find -> /movie/{id}), so a user with no TMDB key still gets the
/// figures. Movies only (TMDB carries no TV financials). Fail-soft by contract: null on a non-`tt` id, a
/// series, no match, no data, both values zero, or any transport error, so the caller simply omits the row.
object FinancialsClient {

    /// A movie's budget + box-office revenue in whole USD (TMDB reports these as integers that reach the
    /// billions, so [Long]). Mirrors Apple `TMDBClient.Financials`.
    data class Financials(val budget: Long, val revenue: Long)

    /// Budget + revenue for [imdbId]. Null with a series / a non-`tt` id / nothing found / both values zero.
    /// Mirrors Apple `TMDBClient.details(imdbID:type:)`.
    suspend fun financials(imdbId: String, isSeries: Boolean): Financials? {
        if (isSeries || !imdbId.startsWith("tt")) return null
        val found = CatalogTmdbEdge.getJson("/find/$imdbId?external_source=imdb_id") ?: return null
        val tmdbId = found.optJSONArray("movie_results")?.optJSONObject(0)
            ?.optInt("id", 0)?.takeIf { it > 0 } ?: return null
        val movie = CatalogTmdbEdge.getJson("/movie/$tmdbId") ?: return null
        val budget = movie.optLong("budget", 0L)
        val revenue = movie.optLong("revenue", 0L)
        if (budget <= 0L && revenue <= 0L) return null
        return Financials(budget = budget, revenue = revenue)
    }

    /// "Budget $200M  ·  Box Office $1.4B  ·  Profit 7.0x" -- both values (each hidden when zero) plus a
    /// profit multiple when both are positive. Null when neither value formats. Mirrors Apple
    /// `financialsText`.
    fun financialsText(f: Financials): String? {
        val parts = ArrayList<String>(3)
        shortMoney(f.budget)?.let { parts += "Budget $it" }
        shortMoney(f.revenue)?.let { parts += "Box Office $it" }
        if (f.budget > 0L && f.revenue > 0L) {
            parts += String.format(Locale.US, "Profit %.1fx", f.revenue.toDouble() / f.budget.toDouble())
        }
        return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
    }

    /// Compact USD for the facts row: "$1.5K" / "$200M" / "$2.4B". Null for a non-positive amount.
    /// Locale-fixed (US) so the "$" and decimal read the same on every device. Mirrors Apple
    /// `TMDBClient.shortMoney`.
    fun shortMoney(value: Long): String? {
        if (value <= 0L) return null
        val v = value.toDouble()
        return when {
            v >= 1_000_000_000 -> String.format(Locale.US, "$%.1fB", v / 1_000_000_000)
            v >= 1_000_000 -> String.format(Locale.US, "$%.0fM", v / 1_000_000)
            v >= 1_000 -> String.format(Locale.US, "$%.0fK", v / 1_000)
            else -> "$$value"
        }
    }
}
