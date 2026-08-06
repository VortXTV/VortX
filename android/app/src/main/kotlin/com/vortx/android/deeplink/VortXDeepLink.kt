package com.vortx.android.deeplink

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

data class VortXDeepLink(
    val type: MediaType,
    val id: String,
) {
    fun toMetaItem(): MetaItem = MetaItem(id = id, type = type, name = id)
}

data class VortXDeepLinkEvent(
    val target: VortXDeepLink,
    val sequence: Long,
)

object VortXDeepLinks {
    fun parse(rawUrl: String?): VortXDeepLink? = runCatching {
        val uri = URI(rawUrl ?: return null)
        if (uri.isOpaque || !uri.scheme.equals("vortx", ignoreCase = true)) return null
        if (!uri.host.equals("open", ignoreCase = true)) return null

        val parameters = firstQueryValues(uri.rawQuery ?: return null)
        val type = when (parameters["type"]?.trim()?.lowercase(Locale.ROOT)) {
            "movie" -> MediaType.MOVIE
            "series" -> MediaType.SERIES
            else -> return null
        }
        val id = parameters["id"]?.trim().orEmpty()
        if (id.isEmpty() || id.codePointCount(0, id.length) > MAX_ID_LENGTH) return null

        VortXDeepLink(type = type, id = id)
    }.getOrNull()

    private fun firstQueryValues(rawQuery: String): Map<String, String> = buildMap {
        rawQuery.split('&').forEach { field ->
            val separator = field.indexOf('=')
            val rawName = if (separator >= 0) field.substring(0, separator) else field
            val rawValue = if (separator >= 0) field.substring(separator + 1) else ""
            val name = decode(rawName)
            if (name !in this) put(name, decode(rawValue))
        }
    }

    private fun decode(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8.name())

    private const val MAX_ID_LENGTH = 256
}
