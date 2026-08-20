package com.vortx.android.catalog

/// Pure decisions used while recovering metadata for catalog ids that the installed meta add-ons cannot
/// answer directly (a `tmdb:`/`tvdb:`/`kitsu:` id whose Cinemeta meta never resolves). The Kotlin port of
/// Apple `app/SourcesShared/DetailMetaRecoveryPolicy.swift`, kept free of app types so it can be reasoned
/// about (and tested) on its own. The detail ViewModel uses [catalogIdShape] to decide an id is a non-`tt`
/// shape worth a one-shot recovery via `TMDBPersonClient.imdbId`, and [Resolution] to describe how the meta
/// load ended.
object DetailMetaRecoveryPolicy {

    /// How a meta request ended for the purposes of the terminal "Details unavailable" decision. Mirrors
    /// Apple `DetailMetaRecoveryPolicy.Resolution`.
    enum class Resolution { READY, PENDING, UNRESOLVED }

    /// The recognised shapes of a detail-page catalog id. Only shapes with an unambiguous lookup path are
    /// parsed; an unknown scheme stays [Unsupported] rather than being guessed onto an unrelated title.
    /// Mirrors Apple `DetailMetaRecoveryPolicy.CatalogIDShape`.
    enum class TmdbMedia { MOVIE, TV }

    sealed interface CatalogIdShape {
        data class Imdb(val id: String) : CatalogIdShape
        data class Tmdb(val id: Int, val media: TmdbMedia?) : CatalogIdShape
        data class Tvdb(val id: Int) : CatalogIdShape
        data class Kitsu(val id: Int) : CatalogIdShape
        data object Unsupported : CatalogIdShape
    }

    /// Parse only catalog id shapes with an unambiguous lookup path (`tt…`, `tmdb:[movie|tv:]N`, `tvdb:N`,
    /// `kitsu:N`, and a bare positive integer treated as a tmdb id). Everything else is [Unsupported].
    /// Mirrors Apple `DetailMetaRecoveryPolicy.catalogIDShape`.
    fun catalogIdShape(raw: String): CatalogIdShape {
        val value = raw.trim()
        if (value.isEmpty()) return CatalogIdShape.Unsupported

        imdbId(value)?.let { return CatalogIdShape.Imdb(it) }

        val parts = value.split(":")
        parts.firstNotNullOfOrNull { imdbId(it) }?.let { return CatalogIdShape.Imdb(it) }

        val lowered = parts.map { it.lowercase() }
        if (lowered.size == 2 && lowered[0] == "tmdb") {
            val id = positiveInteger(lowered[1]) ?: return CatalogIdShape.Unsupported
            return CatalogIdShape.Tmdb(id, media = null)
        }
        if (lowered.size == 3 && lowered[0] == "tmdb") {
            val id = positiveInteger(lowered[2]) ?: return CatalogIdShape.Unsupported
            val kind = tmdbMedia(lowered[1]) ?: return CatalogIdShape.Unsupported
            return CatalogIdShape.Tmdb(id, media = kind)
        }
        if (lowered.size == 2 && lowered[0] == "tvdb") {
            val id = positiveInteger(lowered[1]) ?: return CatalogIdShape.Unsupported
            return CatalogIdShape.Tvdb(id)
        }
        // Strict on purpose, exactly like `tvdb:` above: the SHOW id only. An episode-qualified anime id
        // ("kitsu:460:1:2") is not a detail-page route.
        if (lowered.size == 2 && lowered[0] == "kitsu") {
            val id = positiveInteger(lowered[1]) ?: return CatalogIdShape.Unsupported
            return CatalogIdShape.Kitsu(id)
        }
        if (lowered.size == 1) {
            val id = positiveInteger(lowered[0]) ?: return CatalogIdShape.Unsupported
            return CatalogIdShape.Tmdb(id, media = null)
        }
        return CatalogIdShape.Unsupported
    }

    /// True when [raw] is a non-`tt` id whose shape has an unambiguous recovery lookup path, so the detail
    /// ViewModel should attempt a one-shot `TMDBPersonClient.imdbId` recovery for it rather than sitting on
    /// a permanent skeleton.
    fun isRecoverableNonImdb(raw: String): Boolean = when (catalogIdShape(raw)) {
        is CatalogIdShape.Imdb, CatalogIdShape.Unsupported -> false
        else -> true
    }

    private fun imdbId(raw: String): String? {
        val lowered = raw.lowercase()
        if (!lowered.startsWith("tt") || lowered.length <= 2) return null
        val digits = lowered.drop(2)
        return if (digits.all { it in '0'..'9' }) lowered else null
    }

    private fun tmdbMedia(raw: String): TmdbMedia? = when (raw) {
        "movie" -> TmdbMedia.MOVIE
        "tv" -> TmdbMedia.TV
        else -> null
    }

    private fun positiveInteger(raw: String): Int? {
        if (raw.isEmpty() || !raw.all { it in '0'..'9' }) return null
        val value = raw.toIntOrNull() ?: return null
        return if (value > 0) value else null
    }
}
