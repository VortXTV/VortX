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
) {
    /// True when at least one provider returned a score, so a fully-empty result is dropped (returns null)
    /// rather than rendering an empty ratings row. Mirrors Apple `MDBListRatings.hasAny`.
    val hasAny: Boolean
        get() = imdb != null || rottenTomatoes != null || metacritic != null || tmdb != null
}
