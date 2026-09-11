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
            // Decode each path component once, keeping '+' literal and rejecting encoded slashes.
            fun decode(value: String): String? = runCatching { URI("x://local/$value").path.removePrefix("/") }.getOrNull()
            val rawType = decode(parts[1])?.lowercase(Locale.ROOT) ?: return null
            // Android's typed detail router cannot yet preserve custom types (including "anime").
            // Anime add-ons using the standard series route and namespaced IDs work unchanged.
            val type = when (rawType) { "movie" -> MediaType.MOVIE; "series" -> MediaType.SERIES; else -> return null }
            val id = decode(parts[2]) ?: return null
            if (id.isBlank() || id.any { it == '/' || it == '?' || it == '#' || it.isISOControl() }) return null
            return MediaRelation(kind, MetaItem(id = id, type = type, name = name.trim()))
        }

        fun visible(relations: List<MediaRelation>, selfIds: Set<String>): List<MediaRelation> =
            relations.filterNot { it.item.id in selfIds }.distinctBy { it.item.type to it.item.id }
    }
}
