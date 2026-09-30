package com.vortx.android.model

import java.net.URI
import java.util.Locale

/** Internal add-on links only. Never open arbitrary URLs or guess an unsupported content type. */
data class MediaRelation(val kind: Kind, val item: MetaItem) {
    enum class Kind(val label: String) { PREQUEL("Prequel"), SEQUEL("Sequel"), RELATED("Related") }

    companion object {
        fun parse(category: String, name: String, url: String): MediaRelation? {
            val kind = Kind.entries.firstOrNull { it.name.lowercase(Locale.ROOT) == category.trim().lowercase(Locale.ROOT) }
                ?: return null
            if (name.isBlank()) return null
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            if (uri.rawUserInfo != null || uri.port != -1 || uri.rawQuery != null) return null
            val path = when {
                uri.scheme.equals("stremio", true) && uri.rawAuthority == null && uri.rawFragment == null -> uri.rawPath
                uri.scheme.equals("https", true) && uri.host.equals("web.stremio.com", true) &&
                    uri.rawPath in listOf("", "/") -> uri.rawFragment
                else -> return null
            } ?: return null
            val parts = path.removePrefix("/").split('/')
            if (parts.size != 3 || !parts[0].equals("detail", true)) return null
            if (parts.any { '?' in it || '#' in it }) return null
            // Decode each path component once, keeping '+' literal. An encoded slash is still rejected
            // after decoding so an opaque id cannot escape its one route component.
            fun decode(value: String): String? = runCatching { URI("x://local/$value").path.removePrefix("/") }.getOrNull()
            val rawType = decode(parts[1])?.lowercase(Locale.ROOT) ?: return null
            // Match Apple's route-token contract before applying Android's typed normalization. This keeps
            // a malformed token such as `custom type` from becoming a valid anime route merely because its
            // id happens to use a recognized scheme.
            if (rawType.isEmpty() || rawType.any { !(it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-') }) {
                return null
            }
            val id = decode(parts[2]) ?: return null
            if (id.isBlank() || id.any { it == '/' || it.isISOControl() }) return null
            val type = normalizeType(rawType, id) ?: return null
            return MediaRelation(kind, MetaItem(id = id, type = type, name = name.trim()))
        }

        /**
         * The shared Apple route keeps the add-on's type token verbatim. Android's detail route is typed,
         * so normalize only values whose meaning is explicit or whose id carries an unambiguous scheme.
         * In particular, an arbitrary custom type must not fall through to MOVIE: IMDb and bare TMDB ids do
         * not tell us whether the target is a film or a show. Anime is a series in the detail/player model,
         * matching Apple's anime-through-the-series-path behavior.
         */
        private fun normalizeType(rawType: String, id: String): MediaType? {
            when (rawType) {
                "movie" -> return MediaType.MOVIE
                "series", "anime" -> return MediaType.SERIES
                "channel", "channels" -> return MediaType.CHANNEL
                "tv", "events", "event", "sport", "sports", "live", "linear", "iptv" -> {
                    return MediaType.TV
                }
            }

            val loweredId = id.lowercase(Locale.ROOT)
            return when {
                ANIME_ID_SCHEMES.any(loweredId::startsWith) -> MediaType.SERIES
                loweredId.startsWith("tvdb:") -> MediaType.SERIES
                loweredId.startsWith("tmdb:movie:") -> MediaType.MOVIE
                loweredId.startsWith("tmdb:tv:") -> MediaType.SERIES
                else -> null
            }
        }

        private val ANIME_ID_SCHEMES = listOf("kitsu:", "anilist:", "mal:", "anidb:")

        fun visible(relations: List<MediaRelation>, selfIds: Set<String>): List<MediaRelation> =
            relations.filterNot { it.item.id in selfIds }.distinctBy { it.item.type to it.item.id }
    }
}
