package com.vortx.android.ratings

import java.util.Locale

/// ONE consistent formatting for cross-provider ratings across the Android detail surface, the Kotlin port
/// of Apple `app/SourcesShared/RatingsFormat.swift`. IMDb leads with an accent star (its label dropped), then
/// Rotten Tomatoes, then Metacritic, then TMDB, formatted once here so the hero token strip and any future
/// card badge never disagree about how a score reads. The model is [MdbListRatings] (IMDb on its native 0-10
/// scale, RT / TMDB as 0-100 percentages, Metacritic as a bare 0-100 metascore), so the same shape drives
/// both the keyless VortX ratings service and a user's own MDBList key.
object RatingsFormat {

    /// A single provider score: which service ([kind], drawn as that service's mark), the printed value
    /// ("84%"), the service's name for the spoken label, and the raw [score] the marks read (Rotten Tomatoes
    /// turns rotten below 60, the Metacritic square takes its colour from the score). Mirrors Apple
    /// `RatingsFormat.Token`.
    enum class Kind { IMDB, ROTTEN_TOMATOES, METACRITIC, TMDB, MY_ANIME_LIST, KITSU, POPCORN, LETTERBOXD, TRAKT, SIMKL }

    data class Token(val kind: Kind, val label: String, val value: String, val score: Double) {
        val isImdb: Boolean get() = kind == Kind.IMDB
    }

    /// IMDb on its native 0-10 scale, one decimal ("8.3"). Locale-fixed (US) so the decimal separator matches
    /// the baked poster's `toFixed(1)` regardless of device locale. Mirrors Apple `RatingsFormat.imdb`.
    fun imdb(value: Double): String = String.format(Locale.US, "%.1f", value)

    /// A score on a small native scale (Letterboxd 0-5, MyAnimeList 0-10), one decimal. A value above the
    /// scale is read as the 0-100 form of the same score. Mirrors Apple `RatingsFormat.scaled`.
    fun scaled(value: Double, max: Double): Double? {
        if (!value.isFinite() || value <= 0) return null
        val native = if (value > max) value * max / 100 else value
        return Math.round(native * 10) / 10.0
    }

    /// Ordered tokens for every score present: the four headline scores first (IMDb -> RT -> MC -> TMDB), the anime
    /// scores next (MAL -> Kitsu), then Popcorn -> Letterboxd -> Trakt -> SIMKL. A card badge drops tokens from the
    /// END when its card is too narrow, so the order is also the priority. [limit] caps the count outright.
    /// Per-score fail-soft: a title carrying only IMDb yields exactly one token. Mirrors Apple
    /// `RatingsFormat.tokens`.
    fun tokens(r: MdbListRatings, limit: Int? = null): List<Token> {
        val out = ArrayList<Token>(8)
        r.imdb?.let { out += Token(Kind.IMDB, "IMDb", imdb(it), it) }
        r.rottenTomatoes?.let { out += Token(Kind.ROTTEN_TOMATOES, "Rotten Tomatoes", "$it%", it.toDouble()) }
        r.metacritic?.let { out += Token(Kind.METACRITIC, "Metacritic", "$it", it.toDouble()) }
        r.tmdb?.let { out += Token(Kind.TMDB, "TMDB", "$it%", it.toDouble()) }
        r.mal?.let { out += Token(Kind.MY_ANIME_LIST, "MyAnimeList", String.format(Locale.US, "%.1f", it), it) }
        r.kitsu?.let { out += Token(Kind.KITSU, "Kitsu", "$it%", it.toDouble()) }
        r.rtAudience?.let { out += Token(Kind.POPCORN, "Popcornmeter", "$it%", it.toDouble()) }
        r.letterboxd?.let { out += Token(Kind.LETTERBOXD, "Letterboxd", String.format(Locale.US, "%.1f", it), it) }
        r.trakt?.let { out += Token(Kind.TRAKT, "Trakt", "$it%", it.toDouble()) }
        r.simkl?.let { out += Token(Kind.SIMKL, "SIMKL", String.format(Locale.US, "%.1f", it), it) }
        if (limit != null && limit >= 0 && out.size > limit) return out.take(limit)
        return out
    }

    /// The joined text form ("IMDb 8.3  ·  Rotten Tomatoes 84%  ·  Metacritic 69"), or null when no score is
    /// present, for plain-text surfaces that cannot draw the marks. Mirrors Apple `RatingsFormat.joined`.
    fun joined(r: MdbListRatings): String? {
        val parts = tokens(r).map { "${it.label} ${it.value}" }
        return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
    }
}
