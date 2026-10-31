package com.vortx.android.player.subtitles

import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.text.CueDecoder

/**
 * Transparent tee AFTER Media3's extraction-time text transcoder, before selection/SampleQueue.
 * Downstream gets the original bytes, metadata, part flags, return value and errors. Reference failure
 * only disables this optional witness. This class never fetches a URL, selects a track or changes time.
 */
@UnstableApi
internal class Media3ReferenceTrackOutput(
    private val delegate: TrackOutput,
    private val capture: Media3EmbeddedReferenceCapture,
    private val originalTrack: Media3EmbeddedReferenceCapture.Track,
) : TrackOutput {
    private var previousFormat: Format? = null
    private var pending = ByteArray(0)
    private var pendingSize = 0
    private val decoder = CueDecoder()

    override fun durationUs(durationUs: Long) = delegate.durationUs(durationUs)

    override fun format(format: Format) {
        delegate.format(format)
        val previous = previousFormat
        if (previous != null && previous != format) disable()
        previousFormat = format
        if (format.sampleMimeType != MimeTypes.APPLICATION_MEDIA3_CUES) {
            disable()
            return
        }
        capture.format(originalTrack, format.id, format.language, format.codecs)
    }

    override fun sampleData(input: DataReader, length: Int, allowEndOfInput: Boolean, sampleDataPart: Int): Int {
        if (!capture.acceptsSamples(originalTrack)) return delegate.sampleData(input, length, allowEndOfInput, sampleDataPart)
        if (sampleDataPart != TrackOutput.SAMPLE_DATA_PART_MAIN) {
            disable()
            return delegate.sampleData(input, length, allowEndOfInput, sampleDataPart)
        }
        val observingInput = DataReader { buffer, offset, count ->
            input.read(buffer, offset, count).also { actual -> if (actual > 0) append(buffer, offset, actual) }
        }
        return delegate.sampleData(observingInput, length, allowEndOfInput, sampleDataPart)
    }

    override fun sampleData(data: ParsableByteArray, length: Int, sampleDataPart: Int) {
        if (capture.acceptsSamples(originalTrack)) {
            if (sampleDataPart != TrackOutput.SAMPLE_DATA_PART_MAIN) disable()
            else append(data.data, data.position, length)
        }
        delegate.sampleData(data, length, sampleDataPart)
    }

    override fun sampleMetadata(timeUs: Long, flags: Int, size: Int, offset: Int, cryptoData: TrackOutput.CryptoData?) {
        delegate.sampleMetadata(timeUs, flags, size, offset, cryptoData)
        if (!capture.acceptsSamples(originalTrack)) { clear(); return }
        if (cryptoData != null || flags and C.BUFFER_FLAG_ENCRYPTED != 0 || size < 0 || offset < 0 ||
            offset > pendingSize || size > pendingSize - offset) {
            disable()
            return
        }
        val start = pendingSize - offset - size
        if (start != 0) { disable(); return } // Unaccounted preceding bytes cannot certify a lossless sample stream.
        try {
            val decoded = decoder.decode(timeUs, pending, start, size)
            if (decoded.cues.size > 1) { disable(); return } // Do not count rendered overlap fragments as authored occurrences.
            var occurrences = 0
            for (cue in decoded.cues) {
                val text = cue.text
                if (cue.bitmap != null || text == null || text.length > MAX_TEXT_CHARS) { disable(); return }
                if (text.any { !it.isWhitespace() }) occurrences++
            }
            capture.sample(originalTrack, decoded.startTimeUs, decoded.durationUs, occurrences)
        } catch (_: RuntimeException) {
            disable()
            return
        }
        // TrackOutput.offset denotes already-written bytes belonging to a FUTURE sample.
        if (offset != 0) pending.copyInto(pending, 0, pendingSize - offset, pendingSize)
        pendingSize = offset
    }

    /** The owning wrapper calls this BEFORE certifying real extractor EOS. */
    fun endOfInput() {
        if (pendingSize != 0) disable()
    }

    fun release() = clear()

    private fun append(source: ByteArray, offset: Int, length: Int) {
        if (!capture.acceptsSamples(originalTrack)) return
        if (length < 0 || offset < 0 || offset > source.size || length > source.size - offset ||
            length > MAX_PENDING_BYTES - pendingSize) {
            disable()
            return
        }
        val required = pendingSize + length
        if (pending.size < required) pending = pending.copyOf(maxOf(required, minOf(MAX_PENDING_BYTES, maxOf(1024, pending.size * 2))))
        source.copyInto(pending, pendingSize, offset, offset + length)
        pendingSize = required
    }

    private fun disable() { capture.reject(originalTrack); clear() }
    private fun clear() { pending = ByteArray(0); pendingSize = 0 }

    private companion object {
        const val MAX_PENDING_BYTES = 128 * 1024
        const val MAX_TEXT_CHARS = 128 * 1024
    }
}
