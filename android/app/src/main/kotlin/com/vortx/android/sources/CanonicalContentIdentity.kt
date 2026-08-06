package com.vortx.android.sources

private val CANONICAL_IMDB_ID = Regex("""^tt[0-9]{6,10}$""")

/**
 * The one Android identity boundary for a movie or series episode that can be shared with source services.
 * A movie has no coordinates. An episode must have both coordinates, and zero is meaningful for specials,
 * so S0/E0 is preserved while partial and negative coordinates fail closed.
 */
object CanonicalContentIdentity {
    fun imdb(imdbId: String?, season: Int? = null, episode: Int? = null): String? {
        if (imdbId == null || !CANONICAL_IMDB_ID.matches(imdbId)) return null
        if ((season == null) != (episode == null)) return null
        if (season == null) return imdbId
        if (season < 0 || episode!! < 0) return null
        return "$imdbId:$season:$episode"
    }
}
