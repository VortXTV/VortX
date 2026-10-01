package com.vortx.android.nzb

import java.net.URI
import java.util.UUID

/** Public, non-secret metadata for a direct Newznab indexer. API keys never leave the secure document. */
data class NzbIndexerConfig(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val endpoint: String,
    val enabled: Boolean = true,
)

/** Immutable input for Newznab's typed movie/tv endpoints. */
data class NzbSearch(
    val title: String,
    val movieImdbId: String? = null,
    val seriesImdbId: String? = null,
    val year: Int? = null,
    val season: Int? = null,
    val episode: Int? = null,
) {
    val isEpisode: Boolean get() = season != null || episode != null

    fun isValid(): Boolean = title.trim().isNotEmpty() && title.toByteArray().size <= MAX_TITLE_BYTES &&
        (year == null || year in 0..MAX_YEAR) &&
        (season == null && episode == null || season != null && episode != null && season in 0..MAX_SEASON && episode in 1..MAX_EPISODE) &&
        imdbDigits(movieImdbId) != INVALID_IMDB && imdbDigits(seriesImdbId) != INVALID_IMDB

    companion object {
        const val MAX_TITLE_BYTES = 512
        const val MAX_YEAR = 9_999
        const val MAX_SEASON = 10_000
        const val MAX_EPISODE = 100_000
        internal const val INVALID_IMDB = "!"

        /** Newznab wants an IMDb numeric id; callers may pass either tt123 or 123. */
        fun imdbDigits(raw: String?): String? {
            raw ?: return null
            val value = raw.trim().removePrefix("tt").removePrefix("TT")
            return when {
                value.isEmpty() -> null
                value.all(Char::isDigit) -> value
                else -> INVALID_IMDB
            }
        }
    }
}

data class NzbRelease(
    val title: String,
    /** Short-lived NZB download URL only; never a search request URL. */
    val enclosureUrl: String,
    val sizeBytes: Long?,
)

object NzbIndexerEndpointPolicy {
    enum class Error { MALFORMED, NOT_HTTPS, USER_INFO, FRAGMENT, MISSING_HOST, QUERY_FORBIDDEN }

    fun validate(raw: String): Result<URI> = runCatching { URI(raw.trim()) }.fold(
        onSuccess = ::validate,
        onFailure = { Result.failure(IllegalArgumentException(Error.MALFORMED.name)) },
    )

    fun validate(uri: URI): Result<URI> {
        val error = when {
            !uri.scheme.equals("https", ignoreCase = true) -> Error.NOT_HTTPS
            uri.userInfo != null -> Error.USER_INFO
            uri.fragment != null -> Error.FRAGMENT
            uri.host.isNullOrBlank() -> Error.MISSING_HOST
            !uri.rawQuery.isNullOrEmpty() -> Error.QUERY_FORBIDDEN
            else -> null
        }
        return if (error == null) Result.success(uri.normalize())
        else Result.failure(IllegalArgumentException(error.name))
    }

    /** Safe for status copy and diagnostics: it intentionally excludes path/query/credentials. */
    fun hostOnly(raw: String): String? = runCatching { URI(raw.trim()).host }.getOrNull()
}

internal fun NzbIndexerConfig.isValidMetadata(): Boolean =
    id.isNotBlank() && id.length <= 128 && name.trim().isNotEmpty() && name.toByteArray().size <= 100 &&
        endpoint.toByteArray().size <= 4_096 && NzbIndexerEndpointPolicy.validate(endpoint).isSuccess
