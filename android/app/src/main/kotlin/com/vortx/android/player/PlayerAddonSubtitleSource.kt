package com.vortx.android.player

import androidx.media3.common.util.UnstableApi
import com.vortx.android.player.subtitles.Media3AddonSubtitleParser
import com.vortx.android.player.subtitles.SubtitleCuePresentation
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext

/** Guarded, immutable subtitle bytes and parsed presentation owned by one installed add-on row. */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
class PlayerAddonSubtitleSource private constructor(
    val identityUrl: String,
    private val permitsUse: () -> Boolean,
    private val prepared: Media3AddonSubtitleParser.Parsed,
) {
    @androidx.annotation.OptIn(markerClass = [UnstableApi::class])
    @OptIn(UnstableApi::class)
    internal class Snapshot internal constructor(
        val presentation: SubtitleCuePresentation,
        private val canonicalSnapshot: () -> ByteArray,
        private val alignmentSnapshot: () -> ByteArray?,
        private val freshness: () -> Boolean,
    ) {
        fun canonicalSrtBytes(): ByteArray = canonicalSnapshot()
        fun alignmentSrtBytes(): ByteArray? = alignmentSnapshot()
        fun isCurrent(): Boolean = runCatching { freshness() }.getOrDefault(false)
    }

    /** Liveness is the original player/owner witness, independent of the completed prep Job. */
    internal fun isCurrent(): Boolean = runCatching { permitsUse() }.getOrDefault(false)
    internal fun snapshotIfCurrent(): Snapshot? {
        if (!isCurrent()) return null
        return Snapshot(prepared.presentation, prepared::canonicalSrtBytes,
            prepared::alignmentSrtBytes, permitsUse).takeIf { it.isCurrent() }
    }

    companion object {
        internal fun createGuarded(url: String, permitsUse: () -> Boolean, parsed: Media3AddonSubtitleParser.Parsed) =
            PlayerAddonSubtitleSource(url, permitsUse, parsed)
    }
}

/** The sole producer of guarded app-owned subtitle payloads. */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
internal object AddonSubtitleFileClient {
    suspend fun fetch(
        subtitle: AddonSubtitle,
        permitsUse: () -> Boolean,
        isCancelled: () -> Boolean,
    ): PlayerAddonSubtitleSource? {
        val preparationJob = currentCoroutineContext()[Job]
        fun preparationCancelled() = runCatching {
            isCancelled() || preparationJob?.isActive == false
        }.getOrDefault(true)
        fun live() = runCatching { permitsUse() && !preparationCancelled() }.getOrDefault(false)
        if (!live()) return null
        val installed = subtitle.originalInstalledBase?.takeIf { it.isNotBlank() } ?: return null
        // Require both provenance fields populated by the actual index service; index URI is not authority.
        if (subtitle.actualFinalIndexUri?.toHttpUrlOrNull() == null) return null
        val resource = subtitle.url.toHttpUrlOrNull() ?: return null
        val deadline = AddonSubtitleIndexTransport.deadlineAfterTimeout()
        val response = AddonSubtitleIndexTransport.getFile(
            subtitle.url, installed, deadline, permitsUse, ::preparationCancelled,
        ) ?: return null
        if (!live() || response.status !in 200..299) return null
        val bytes = response.body ?: return null
        val format = formatFor(resource.encodedPath, response.contentType, subtitle.releaseName,
            response.contentDisposition) ?: return null
        val finalPath = URI(response.finalFileUri).path.orEmpty()
        val finalExtensions = extensionFormats(finalPath, subtitle.releaseName.orEmpty(), response.contentDisposition.orEmpty())
        if (finalExtensions.size > 1 || (finalExtensions.singleOrNull() != null && finalExtensions.single() != format)) return null
        val mime = response.contentType?.substringBefore(';')?.trim()?.lowercase()
        val mimeFormat = when (mime) {
            "text/vtt" -> Media3AddonSubtitleParser.Format.VTT
            "text/x-ssa", "text/x-ass" -> Media3AddonSubtitleParser.Format.ASS
            "application/x-subrip", "application/x-srt" -> Media3AddonSubtitleParser.Format.SRT
            null, "text/plain", "application/octet-stream" -> null
            else -> return null
        }
        if (mimeFormat != null && mimeFormat != format) return null
        val parsed = withContext(Dispatchers.Default) {
            PARSE_MUTEX.withLock {
                if (!live()) null else Media3AddonSubtitleParser.parse(bytes, format, permitsUse, ::preparationCancelled)
            }
        } ?: return null
        if (!live()) return null
        return PlayerAddonSubtitleSource.createGuarded(response.finalFileUri, permitsUse, parsed)
    }

    private fun formatFor(path: String, contentType: String?, releaseName: String?, disposition: String? = null): Media3AddonSubtitleParser.Format? {
        val extensionFormats = extensionFormats(path, releaseName.orEmpty(), disposition.orEmpty())
        if (extensionFormats.size > 1) return null
        val extensionFormat = extensionFormats.firstOrNull()
        val mime = contentType?.substringBefore(';')?.trim()?.lowercase()
        val mimeFormat = when (mime) {
            "text/vtt" -> Media3AddonSubtitleParser.Format.VTT
            "text/x-ssa", "text/x-ass" -> Media3AddonSubtitleParser.Format.ASS
            "application/x-subrip", "application/x-srt" -> Media3AddonSubtitleParser.Format.SRT
            null, "text/plain", "application/octet-stream" -> null
            else -> return null
        }
        if (extensionFormat != null && mimeFormat != null && extensionFormat != mimeFormat) return null
        return extensionFormat ?: mimeFormat
    }

    private fun extensionFormats(vararg values: String): Set<Media3AddonSubtitleParser.Format> =
        values.mapNotNull { value ->
            val filename = Regex("(?i)filename\\*?=(?:UTF-8''|\\\")?([^;\\\"]+)")
                .find(value)?.groupValues?.getOrNull(1)?.trim(' ', '\'')
            val basename = filename ?: value.substringBefore('?').substringAfterLast('/')
            val extension = basename.substringAfterLast('.', "").lowercase()
            when (extension) {
                "srt" -> Media3AddonSubtitleParser.Format.SRT
                "vtt", "webvtt" -> Media3AddonSubtitleParser.Format.VTT
                "ass", "ssa" -> Media3AddonSubtitleParser.Format.ASS
                else -> null
            }
        }.toSet()

    private val PARSE_MUTEX = Mutex()
}
