package com.vortx.android.ratings

/// Cross-provider ratings, the Android analogue of the Apple `MDBListRatings` model. VortX's ratings
/// service maps into this SAME shape so the detail ratings row renders unchanged regardless of source.
/// [imdb] is on IMDb's native 0-10 scale; [rottenTomatoes] / [metacritic] / [tmdb] are 0-100 percentages
/// (matching the VortX service's `imdb` / `rt` / `metacritic` / `tmdb` fields). Any field may be absent.
data class MdbListRatings(
    val imdb: Double? = null,
    val rottenTomatoes: Int? = null,
    val metacritic: Int? = null,
    val tmdb: Int? = null,
    /// Rotten Tomatoes audience (Popcornmeter) percentage 0-100.
    val rtAudience: Int? = null,
    /// Letterboxd average on its native 0-5 scale.
    val letterboxd: Double? = null,
    /// Trakt community percentage 0-100.
    val trakt: Int? = null,
    /// MyAnimeList score on its native 0-10 scale, for anime.
    val mal: Double? = null,
    /// SIMKL community score on its native 0-10 scale.
    val simkl: Double? = null,
    /// Kitsu average percentage 0-100, for anime.
    val kitsu: Int? = null,
) {
    /// True when at least one provider returned a score, so a fully-empty result is dropped (returns null)
    /// rather than rendering an empty ratings row. Mirrors Apple `MDBListRatings.hasAny`.
    val hasAny: Boolean
        get() = imdb != null || rottenTomatoes != null || metacritic != null || tmdb != null ||
            rtAudience != null || letterboxd != null || trakt != null || mal != null || simkl != null || kitsu != null
}

/// One episode's scores: IMDb on its 0-10 scale, TMDB and Trakt as 0-100. Mirrors Apple `EpisodeScores`.
data class EpisodeScores(val imdb: Double? = null, val tmdb: Int? = null, val trakt: Int? = null) {
    val ratings: MdbListRatings get() = MdbListRatings(imdb = imdb, tmdb = tmdb, trakt = trakt)

    /// The score a season's "Top rated" pick ranks by, on a 0-10 scale: IMDb, else TMDB, else Trakt.
    val headline: Double? get() = imdb ?: tmdb?.let { it / 10.0 } ?: trakt?.let { it / 10.0 }
}
