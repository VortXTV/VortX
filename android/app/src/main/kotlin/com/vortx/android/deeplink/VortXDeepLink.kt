package com.vortx.android.deeplink

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

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

/**
 * One delivery latch for Activity intents. Accepted URLs are consumed once per delivery identity; an
 * invalid URL does not poison the latch. Persist [consumedDeliveryId] in Activity instance state so a
 * recreation rejects the retained Intent while a genuinely new cold or warm Intent remains eligible,
 * even when it carries the same URL.
 */
class DeepLinkDeliveryState(restoredConsumedDeliveryId: String? = null) {
    var consumedDeliveryId: String? = restoredConsumedDeliveryId
        private set

    fun isConsumed(deliveryId: String): Boolean = consumedDeliveryId == deliveryId

    fun consume(deliveryId: String, rawUrl: String?): VortXDeepLink? {
        if (isConsumed(deliveryId)) return null
        return VortXDeepLinks.parse(rawUrl)?.also { consumedDeliveryId = deliveryId }
    }
}

object VortXDeepLinks {
    fun parse(rawUrl: String?): VortXDeepLink? = runCatching {
        val uri = URI(rawUrl ?: return null)
        // Android manifest matching for custom schemes and hosts is case-sensitive. Keep the parser's
        // public contract identical to the only form the exported intent filter can actually receive.
        if (uri.isOpaque || uri.scheme != "vortx" || uri.host != "open") return null

        val parameters = firstQueryValues(uri.rawQuery ?: return null)
        val type = when (parameters["type"]?.trim()) {
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

    /** RFC 3986 query-component decoding: `+` is data, never form-urlencoded space. */
    private fun decode(value: String): String {
        val output = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            if (value[index] != '%') {
                output.append(value[index++])
                continue
            }

            val bytes = ByteArrayOutputStream()
            while (index < value.length && value[index] == '%') {
                if (index + 2 >= value.length) throw IllegalArgumentException("Incomplete percent escape")
                val high = Character.digit(value[index + 1], 16)
                val low = Character.digit(value[index + 2], 16)
                if (high < 0 || low < 0) throw IllegalArgumentException("Invalid percent escape")
                bytes.write((high shl 4) or low)
                index += 3
            }

            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            output.append(decoder.decode(ByteBuffer.wrap(bytes.toByteArray())))
        }
        return output.toString()
    }

    private const val MAX_ID_LENGTH = 256
}
