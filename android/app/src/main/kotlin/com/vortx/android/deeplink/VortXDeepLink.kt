package com.vortx.android.deeplink

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

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
 * Intent admission and UI acknowledgement are separate. A delivered Intent cannot replay after
 * recreation, and its validated plain title remains pending until the shell opens Detail.
 */
internal class DeepLinkDeliveryState(
    restoredConsumedDeliveryId: String? = null,
    restoredPendingType: String? = null,
    restoredPendingId: String? = null,
    restoredPendingSequence: Long = 0L,
    restoredLaunchFingerprint: String? = null,
    restoredLatestFingerprint: String? = null,
) {
    sealed interface IntentAdmission {
        data class Accepted(val event: VortXDeepLinkEvent) : IntentAdmission
        data object Replay : IntentAdmission
        data object Invalid : IntentAdmission
    }

    var consumedDeliveryId: String? = restoredConsumedDeliveryId?.takeIf { it.isNotBlank() }
        private set
    var launchFingerprint: String? = restoredLaunchFingerprint?.takeIf(::isTitleFingerprint)
        private set
    var latestFingerprint: String? = restoredLatestFingerprint?.takeIf(::isTitleFingerprint)
        private set

    var pendingEvent: VortXDeepLinkEvent? =
        if (consumedDeliveryId != null && restoredPendingSequence > 0L) {
            VortXDeepLinks.validatedTitle(restoredPendingType, restoredPendingId)?.let {
                VortXDeepLinkEvent(it, restoredPendingSequence)
            }
        } else null
        private set

    private var sequence = pendingEvent?.sequence ?: 0L

    fun route(
        deliveryId: String,
        rawUrl: String?,
        coldLaunch: Boolean = false,
        retainedDeliveryId: String? = null,
    ): IntentAdmission {
        if (consumedDeliveryId == deliveryId ||
            (coldLaunch && retainedDeliveryId != null && consumedDeliveryId == retainedDeliveryId)) {
            return IntentAdmission.Replay
        }
        val title = VortXDeepLinks.parse(rawUrl) ?: return IntentAdmission.Invalid
        val fingerprint = titleFingerprint(title)
        // Android may recreate from the original raw launch Intent without our private marker.
        // Keep the cold launch fingerprint even when a newer warm Intent replaces the pending title.
        if (coldLaunch && consumedDeliveryId != null &&
            (latestFingerprint == null || fingerprint == launchFingerprint || fingerprint == latestFingerprint)) {
            return IntentAdmission.Replay
        }
        if (sequence == Long.MAX_VALUE) return IntentAdmission.Invalid
        val event = VortXDeepLinkEvent(title, ++sequence)
        if (coldLaunch) launchFingerprint = fingerprint
        latestFingerprint = fingerprint
        consumedDeliveryId = deliveryId
        pendingEvent = event
        return IntentAdmission.Accepted(event)
    }

    fun acknowledge(event: VortXDeepLinkEvent): Boolean {
        if (pendingEvent !== event) return false
        pendingEvent = null
        return true
    }
}

private fun isTitleFingerprint(value: String): Boolean =
    value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

private fun titleFingerprint(title: VortXDeepLink): String {
    val canonical = (title.type.id + ':' + title.id).toByteArray(StandardCharsets.UTF_8)
    return MessageDigest.getInstance("SHA-256").digest(canonical).joinToString("") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}

object VortXDeepLinks {
    fun parse(rawUrl: String?): VortXDeepLink? = runCatching {
        val uri = URI(rawUrl ?: return null)
        // Android manifest matching for custom schemes and hosts is case-sensitive. Keep the parser's
        // public contract identical to the only form the exported intent filter can actually receive.
        if (uri.isOpaque || uri.scheme != "vortx" || uri.host != "open") return null

        val parameters = firstQueryValues(uri.rawQuery ?: return null)
        validatedTitle(parameters["type"]?.trim(), parameters["id"]?.trim())
    }.getOrNull()

    /** The same plain title validation applies to fresh and restored deliveries. */
    internal fun validatedTitle(rawType: String?, id: String?): VortXDeepLink? {
        val type = when (rawType) {
            "movie" -> MediaType.MOVIE
            "series" -> MediaType.SERIES
            else -> return null
        }
        if (id.isNullOrEmpty() || id != id.trim() || id.codePointCount(0, id.length) > MAX_ID_LENGTH) return null
        return VortXDeepLink(type, id)
    }

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
