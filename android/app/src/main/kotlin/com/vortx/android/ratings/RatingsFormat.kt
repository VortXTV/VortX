package com.vortx.android.ratings

import java.util.Locale

/// ONE consistent formatting for cross-provider ratings across the Android detail surface, the Kotlin port
/// of Apple `app/SourcesShared/RatingsFormat.swift`. IMDb leads with an accent star (its label dropped), then
/// Rotten Tomatoes, then Metacritic, then TMDB, formatted once here so the hero token strip and any future
/// card badge never disagree about how a score reads. The model is [MdbListRatings] (IMDb on its native 0-10
/// scale, RT / TMDB as 0-100 percentages, Metacritic as a bare 0-100 metascore), so the same shape drives
/// both the keyless VortX ratings service and a user's own MDBList key.
object RatingsFormat {

    /// A single provider score as a label + value, e.g. ("RT", "84%"). [isImdb] marks the primary score that
    /// leads with the accent star (its label is dropped in favour of the star); every other token prints its
    /// label verbatim. Mirrors Apple `RatingsFormat.Token`.
    data class Token(val label: String, val value: String, val isImdb: Boolean)

    /// IMDb on its native 0-10 scale, one decimal ("8.3"). Locale-fixed (US) so the decimal separator matches
    /// the baked poster's `toFixed(1)` regardless of device locale. Mirrors Apple `RatingsFormat.imdb`.
    fun imdb(value: Double): String = String.format(Locale.US, "%.1f", value)

    /// Ordered tokens for every score present, IMDb -> RT -> MC -> TMDB. Empty when nothing is present.
    /// [limit] caps how many tokens a size-constrained surface renders (null = all four). Per-score
    /// fail-soft by construction: a title carrying only IMDb yields exactly one token. Mirrors Apple
    /// `RatingsFormat.tokens`.
    fun tokens(r: MdbListRatings, limit: Int? = null): List<Token> {
        val out = ArrayList<Token>(4)
        r.imdb?.let { out += Token("IMDb", imdb(it), isImdb = true) }
        r.rottenTomatoes?.let { out += Token("RT", "$it%", isImdb = false) }
        r.metacritic?.let { out += Token("MC", "$it", isImdb = false) }
        r.tmdb?.let { out += Token("TMDB", "$it%", isImdb = false) }
        if (limit != null && limit >= 0 && out.size > limit) return out.take(limit)
        return out
    }

    /// The joined detail-row string ("IMDb 8.3  ·  RT 84%  ·  MC 69  ·  TMDB 81%"), or null when no score is
    /// present. Mirrors Apple `RatingsFormat.joined`.
    fun joined(r: MdbListRatings): String? {
        val parts = tokens(r).map { "${it.label} ${it.value}" }
        return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
    }
}
