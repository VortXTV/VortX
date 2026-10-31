package com.vortx.android.player.subtitles

import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.TrackOutput
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

/** These tests never decode a Parcel: they exercise real byte forwarding and dangling-tail admission. */
@UnstableApi
class Media3ReferenceTrackOutputTest {
    private class RecordingOutput : TrackOutput {
        var byteCount = 0
        var lastFormat: Format? = null
        override fun format(format: Format) { lastFormat = format }
        override fun sampleData(input: DataReader, length: Int, allowEndOfInput: Boolean, sampleDataPart: Int): Int {
            val actual = input.read(ByteArray(length), 0, length)
            if (actual > 0) byteCount += actual
            return actual
        }
        override fun sampleData(data: ParsableByteArray, length: Int, sampleDataPart: Int) {
            data.skipBytes(length)
            byteCount += length
        }
        override fun sampleMetadata(timeUs: Long, flags: Int, size: Int, offset: Int, cryptoData: TrackOutput.CryptoData?) {}
    }

    private class Fixture {
        val load = Any()
        val extractor = Any()
        val capture = Media3EmbeddedReferenceCapture(load, AtomicBoolean(true))
        val output = RecordingOutput()
        val tee: Media3ReferenceTrackOutput
        init {
            val response = Any()
            capture.dataSourceCreationStarted()
            capture.dataSourceCreated(response)
            capture.responseOpened(response, 0, Media3EmbeddedReferenceCapture.UNBOUNDED_LENGTH)
            capture.responseOpenSucceeded(response)
            check(capture.initialize(extractor))
            val track = requireNotNull(capture.track(extractor, 42))
            tee = Media3ReferenceTrackOutput(output, capture, track)
            tee.format(Format.Builder().setId("real-track").setLanguage("en")
                .setSampleMimeType(MimeTypes.APPLICATION_MEDIA3_CUES).setCodecs(MimeTypes.APPLICATION_SUBRIP).build())
            capture.beginRead(extractor, 0)
            capture.sample(track, 1_000_000, 500_000, 8)
        }
        fun complete() {
            tee.endOfInput()
            capture.endRead(extractor, 100, Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT)
        }
        fun snapshot() = capture.snapshot(load, "real-track")
    }

    @Test fun danglingFutureSampleMustNotBecomeACompleteReferenceAtExtractorEos() {
        val f = Fixture()
        val bytes = ParsableByteArray(byteArrayOf(1, 2, 3))
        f.tee.sampleData(bytes, 3, TrackOutput.SAMPLE_DATA_PART_MAIN)
        assertEquals(3, bytes.position)
        assertEquals(3, f.output.byteCount)
        f.complete()
        assertNull(f.snapshot())
    }

    @Test fun completeControlWithNoPendingBytesRetainsEvidenceAndOriginalFormat() {
        val f = Fixture()
        assertEquals("real-track", f.output.lastFormat?.id)
        f.complete()
        assertNotNull(f.snapshot())
    }

    @Test fun failedOptionalCaptureStillForwardsUnsupportedPartBytes() {
        val f = Fixture()
        val bytes = ParsableByteArray(byteArrayOf(4, 5, 6, 7))
        f.tee.sampleData(bytes, 4, TrackOutput.SAMPLE_DATA_PART_SUPPLEMENTAL)
        assertEquals(4, bytes.position)
        assertEquals(4, f.output.byteCount)
        f.complete()
        assertNull(f.snapshot())
    }

    @Test fun pendingByteBudgetDoesNotTruncateThePlaybackDelegate() {
        val f = Fixture()
        val bytes = ParsableByteArray(ByteArray(128 * 1024 + 1))
        f.tee.sampleData(bytes, 128 * 1024 + 1, TrackOutput.SAMPLE_DATA_PART_MAIN)
        assertEquals(128 * 1024 + 1, f.output.byteCount)
        assertEquals(128 * 1024 + 1, bytes.position)
        f.complete()
        assertNull(f.snapshot())
    }
}
