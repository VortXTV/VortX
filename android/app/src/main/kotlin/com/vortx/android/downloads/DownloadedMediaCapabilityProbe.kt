package com.vortx.android.downloads

import android.media.MediaExtractor
import android.media.MediaFormat
import com.vortx.android.model.DownloadRecord
import java.io.File

/**
 * Capabilities proven by inspecting a completed local media file.
 *
 * This deliberately records Atmos only for E-AC3 JOC. A TrueHD MIME value alone does not
 * expose evidence that the Atmos extension is present.
 */
data class DownloadedMediaCapabilities(
    val isDolbyVision: Boolean,
    val isAtmos: Boolean,
)

/** Blocking probe seam. Callers must invoke it off the UI thread. */
fun interface DownloadedMediaCapabilityProbe {
    /**
     * Returns null when the file could not be inspected completely. Null preserves unknown
     * capability state so a later play can retry rather than persisting an invented false.
     */
    fun probe(file: File): DownloadedMediaCapabilities?
}

/** Android framework implementation used for legacy downloads whose old index has no capability fields. */
object AndroidDownloadedMediaCapabilityProbe : DownloadedMediaCapabilityProbe {
    override fun probe(file: File): DownloadedMediaCapabilities? {
        if (!file.isFile) return null

        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.absolutePath)
            if (extractor.trackCount <= 0) return null

            val trackMimes = (0 until extractor.trackCount).map { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                    ?: return null
            }
            downloadedMediaCapabilitiesFromMimeTypes(trackMimes)
        } catch (_: Exception) {
            null
        } finally {
            extractor.release()
        }
    }
}

internal fun downloadedMediaCapabilitiesFromMimeTypes(
    trackMimes: List<String>,
): DownloadedMediaCapabilities? {
    if (trackMimes.isEmpty()) return null
    return DownloadedMediaCapabilities(
        isDolbyVision = trackMimes.any { it.equals("video/dolby-vision", ignoreCase = true) },
        isAtmos = trackMimes.any { it.equals("audio/eac3-joc", ignoreCase = true) },
    )
}

data class DownloadedMediaCapabilityResolution(
    val record: DownloadRecord,
    /** True only when a successful probe supplied at least one previously unknown field. */
    val shouldPersist: Boolean,
)

/**
 * Resolves legacy unknowns without overwriting capability decisions already persisted for new downloads.
 * Kept pure apart from the injected probe so JVM tests can cover routing truth and failure behavior.
 */
object DownloadedMediaCapabilityResolver {
    fun resolve(
        record: DownloadRecord,
        file: File,
        probe: DownloadedMediaCapabilityProbe,
        persistResolved: (DownloadRecord) -> Unit = {},
    ): DownloadedMediaCapabilityResolution {
        if (record.isDolbyVision != null && record.isAtmos != null) {
            return DownloadedMediaCapabilityResolution(record = record, shouldPersist = false)
        }

        val detected = probe.probe(file)
            ?: return DownloadedMediaCapabilityResolution(record = record, shouldPersist = false)
        val resolved = record.copy(
            isDolbyVision = record.isDolbyVision ?: detected.isDolbyVision,
            isAtmos = record.isAtmos ?: detected.isAtmos,
        )
        persistResolved(resolved)
        return DownloadedMediaCapabilityResolution(
            record = resolved,
            shouldPersist = true,
        )
    }
}
