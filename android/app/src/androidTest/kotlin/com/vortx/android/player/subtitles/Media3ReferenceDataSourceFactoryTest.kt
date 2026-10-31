package com.vortx.android.player.subtitles

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real wrapper calls with fake IO only. Android runtime is needed for Uri/DataSpec; no network. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class Media3ReferenceDataSourceFactoryTest {
    private class FakeSource : DataSource {
        val actualUri: Uri = Uri.parse("https://example.invalid/synthetic-media")
        var headers: Map<String, List<String>> = mapOf("Synthetic-Header" to listOf("synthetic-value"))
        var headerError: Exception? = null
        var onHeaders: (() -> Unit)? = null
        var listener: TransferListener? = null
        var opened: DataSpec? = null
        var opens = 0
        var closes = 0
        var openError: IOException? = null
        var readError: IOException? = null
        var closeError: IOException? = null
        var onOpen: (() -> Unit)? = null
        var onClose: (() -> Unit)? = null
        var lastBuffer: ByteArray? = null
        var lastOffset = -1
        var lastLength = -1
        var readResult = 1
        override fun addTransferListener(transferListener: TransferListener) { listener = transferListener }
        override fun getUri(): Uri = actualUri
        override fun getResponseHeaders(): Map<String, List<String>> {
            onHeaders?.invoke()
            headerError?.let { throw it }
            return headers
        }
        override fun open(dataSpec: DataSpec): Long {
            opens++; opened = dataSpec; onOpen?.invoke()
            openError?.let { throw it }
            return 73L
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            lastBuffer = buffer; lastOffset = offset; lastLength = length
            readError?.let { throw it }
            if (readResult > 0 && length > 0) buffer[offset] = 7
            return readResult
        }
        override fun close() {
            closes++; onClose?.invoke()
            closeError?.let { throw it }
        }
    }

    private class FakeFactory(val source: FakeSource) : DataSource.Factory {
        var creates = 0
        var onCreate: (() -> Unit)? = null
        var failure: RuntimeException? = null
        override fun createDataSource(): DataSource {
            creates++; onCreate?.invoke()
            failure?.let { throw it }
            return source
        }
    }

    private class Fixture {
        val load = Any()
        val capture = Media3EmbeddedReferenceCapture(load, AtomicBoolean(true))
        val actual = FakeSource()
        val delegateFactory = FakeFactory(actual)
        val factory = Media3ReferenceDataSourceFactory(delegateFactory, capture)
        val source = factory.createDataSource()
        fun spec(position: Long = 0, length: Long = C.LENGTH_UNSET.toLong(), uriOffset: Long = 0): DataSpec =
            DataSpec.Builder().setUri(actual.actualUri).setPosition(position).setLength(length)
                .setUriPositionOffset(uriOffset).build()
        fun ready(): Media3EmbeddedReferenceCapture.Snapshot {
            source.open(spec())
            val extractor = Any()
            check(capture.initialize(extractor))
            val track = requireNotNull(capture.track(extractor, 42))
            capture.format(track, "actual-format", "en", "application/x-subrip")
            capture.beginRead(extractor, 0)
            capture.sample(track, 1_000_000, 500_000, 8)
            capture.endRead(extractor, 73, Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT)
            return requireNotNull(capture.snapshot(load, "actual-format"))
        }
    }

    private fun listener() = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {}
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
    }

    @Test fun requestPropertiesListenerAndIoResultsAreForwardedWithoutReplacement() {
        val f = Fixture()
        val originalSpec = f.spec()
        val originalListener = listener()
        f.source.addTransferListener(originalListener)
        assertSame(originalListener, f.actual.listener)
        assertEquals(73L, f.source.open(originalSpec))
        assertSame(originalSpec, f.actual.opened)
        assertSame(f.actual.actualUri, f.source.uri)
        assertSame(f.actual.headers, f.source.responseHeaders)
        val buffer = ByteArray(9)
        assertEquals(1, f.source.read(buffer, 3, 5))
        assertSame(buffer, f.actual.lastBuffer)
        assertEquals(3, f.actual.lastOffset)
        assertEquals(5, f.actual.lastLength)
        assertEquals(7, buffer[3].toInt())
        f.actual.readResult = 0
        assertEquals(0, f.source.read(buffer, 0, 0))
        f.actual.readResult = C.RESULT_END_OF_INPUT
        assertEquals(C.RESULT_END_OF_INPUT, f.source.read(buffer, 0, 9))
        assertFalse(f.capture.isComplete) // DataSource -1 is not an extractor-EOS certificate.
        f.source.close()
        assertEquals(1, f.actual.closes)
    }

    @Test fun rejectedRangesStillReachPlaybackAsTheSameOriginalRequest() {
        for ((position, length, offset) in listOf(Triple(1L, -1L, 0L), Triple(0L, 12L, 0L), Triple(0L, -1L, 100L))) {
            val f = Fixture()
            val originalSpec = f.spec(position, length, offset)
            assertEquals(73L, f.source.open(originalSpec))
            assertSame(originalSpec, f.actual.opened)
            assertTrue(f.capture.isUnavailable)
            f.source.close()
        }
    }

    @Test fun retryOpenInvalidatesIssuedWitnessBeforeDelegateOpenCallbacks() {
        val f = Fixture()
        val snapshot = f.ready()
        var observed: Boolean? = null
        f.actual.onOpen = { observed = f.capture.isCurrent(snapshot) }
        assertEquals(73L, f.source.open(f.spec()))
        assertEquals(false, observed)
        assertFalse(f.capture.isCurrent(snapshot))
        assertEquals(2, f.actual.opens)
    }

    @Test fun secondCreationInvalidatesBeforeFactoryCallbacksEvenIfItReturnsSameDelegate() {
        val f = Fixture()
        val snapshot = f.ready()
        var observed: Boolean? = null
        f.delegateFactory.onCreate = { observed = f.capture.isCurrent(snapshot) }
        val anotherWrapper = f.factory.createDataSource()
        assertEquals(false, observed)
        assertFalse(f.capture.isCurrent(snapshot))
        assertEquals(73L, anotherWrapper.open(f.spec()))
        assertEquals(2, f.delegateFactory.creates)
    }

    @Test fun factoryFailureIsTheOriginalThrowableAndCannotPreserveOldWitness() {
        val f = Fixture()
        val snapshot = f.ready()
        val failure = IllegalStateException("synthetic factory failure")
        f.delegateFactory.failure = failure
        try { f.factory.createDataSource(); fail("Expected factory failure") }
        catch (actual: IllegalStateException) { assertSame(failure, actual) }
        assertFalse(f.capture.isCurrent(snapshot))
    }

    @Test fun openFailureIsForwardedAndCloseStillReachesTheOriginalSource() {
        val f = Fixture()
        val failure = IOException("synthetic open failure")
        val originalSpec = f.spec()
        f.actual.openError = failure
        try { f.source.open(originalSpec); fail("Expected open failure") }
        catch (actual: IOException) { assertSame(failure, actual) }
        assertSame(originalSpec, f.actual.opened)
        assertTrue(f.capture.isUnavailable)
        f.source.close()
        assertEquals(1, f.actual.closes)
    }

    @Test fun readFailureIsForwardedAndInvalidatesAnIssuedWitness() {
        val f = Fixture()
        val snapshot = f.ready()
        val failure = IOException("synthetic read failure")
        f.actual.readError = failure
        try { f.source.read(ByteArray(1), 0, 1); fail("Expected read failure") }
        catch (actual: IOException) { assertSame(failure, actual) }
        assertFalse(f.capture.isCurrent(snapshot))
    }

    @Test fun earlyCloseRejectsBeforeDelegateCallbacksAndCannotBecomeReadyLater() {
        val f = Fixture()
        f.source.open(f.spec())
        var observed: Boolean? = null
        f.actual.onClose = { observed = f.capture.isUnavailable }
        f.source.close()
        assertEquals(true, observed)
        assertTrue(f.capture.isUnavailable)
        assertEquals(1, f.actual.closes)
    }

    @Test fun safeCloseAfterActualExtractorEosRetainsWitnessButLaterReopenRejectsIt() {
        val f = Fixture()
        val snapshot = f.ready()
        f.source.close()
        assertTrue(f.capture.isCurrent(snapshot))
        assertEquals(1, f.actual.closes)
        assertEquals(73L, f.source.open(f.spec()))
        assertFalse(f.capture.isCurrent(snapshot))
    }

    @Test fun closeFailureIsForwardedAndRetiresEvenPreviouslyCompleteEvidence() {
        val f = Fixture()
        val snapshot = f.ready()
        val failure = IOException("synthetic close failure")
        f.actual.closeError = failure
        try { f.source.close(); fail("Expected close failure") }
        catch (actual: IOException) { assertSame(failure, actual) }
        assertEquals(1, f.actual.closes)
        assertFalse(f.capture.isCurrent(snapshot))
    }

    @Test fun anyContentRangeRejectsOptionalCaptureEvenForPositionZeroAndWholeEntityRanges() {
        for ((name, values) in listOf(
            "Content-Range" to listOf("bytes 0-9/100"),
            "content-range" to listOf("bytes 0-99/100"),
            "cOnTeNt-RaNgE" to emptyList(),
            "CONTENT-RANGE" to listOf("malformed"),
            " Content-Range \t" to listOf("bytes 0-9/100"),
        )) {
            val f = Fixture()
            f.actual.headers = mapOf(name to values)
            val request = f.spec()
            assertEquals(73L, f.source.open(request))
            assertSame(request, f.actual.opened)
            assertTrue(f.capture.isUnavailable)
            assertFalse(f.capture.initialize(Any()))
            assertEquals(1, f.actual.opens)
        }
    }

    @Test fun contentRangeCannotHideAmongCaseVariantDuplicateHeaderNames() {
        val f = Fixture()
        f.actual.headers = linkedMapOf(
            "Synthetic-Header" to listOf("synthetic-value"),
            "content-range" to listOf("bytes 0-9/100"),
            "Content-Range" to listOf("bytes 0-99/100"),
        )
        assertEquals(73L, f.source.open(f.spec()))
        assertTrue(f.capture.isUnavailable)
    }

    @Test fun explicitRangeRequestIsForwardedButNeverCertifiedWhateverItsCaseOrValue() {
        for ((name, value) in listOf("Range" to "bytes=0-9", "rAnGe" to "bytes=0-", "RANGE" to "", " Range \t" to "bytes=0-9")) {
            val f = Fixture()
            val request = f.spec().buildUpon().setHttpRequestHeaders(mapOf(name to value)).build()
            assertEquals(73L, f.source.open(request))
            assertSame(request, f.actual.opened)
            assertTrue(f.capture.isUnavailable)
        }
    }

    @Test fun responseHeaderInspectionFailureDoesNotReplaceSuccessfulPlaybackOpen() {
        for (failure in listOf(IllegalStateException("synthetic optional metadata failure"), IOException("synthetic optional metadata IO failure"))) {
            val f = Fixture()
            f.actual.headerError = failure
            val request = f.spec()
            assertEquals(73L, f.source.open(request))
            assertSame(request, f.actual.opened)
            assertTrue(f.capture.isUnavailable)
            f.source.close()
            assertEquals(1, f.actual.closes)
        }
    }

    @Suppress("UNCHECKED_CAST") // Deliberate malformed Java-boundary fixtures, never production coercion.
    @Test fun malformedResponseHeaderTypesRejectOnlyOptionalEvidence() {
        for (malformed in listOf<Map<*, *>>(
            mapOf(null to listOf("value")),
            mapOf(7 to listOf("value")),
            mapOf("Synthetic-Header" to "not-a-list"),
            mapOf("Synthetic-Header" to listOf(7)),
        )) {
            val f = Fixture()
            f.actual.headers = malformed as Map<String, List<String>>
            assertEquals(73L, f.source.open(f.spec()))
            assertTrue(f.capture.isUnavailable)
        }
    }

    @Test fun excessiveHeaderMetadataRejectsOptionalWitnessWithoutAffectingPlayback() {
        val f = Fixture()
        f.actual.headers = (0..256).associate { "Synthetic-$it" to listOf("value") }
        assertEquals(73L, f.source.open(f.spec()))
        assertTrue(f.capture.isUnavailable)
    }

    @Test fun responseIsNotAdmittedDuringHeaderInspectionBeforeTheGuardCompletes() {
        val f = Fixture()
        var attempted = false
        var obtainedTrack = false
        var observed: Media3EmbeddedReferenceCapture.Snapshot? = null
        f.actual.onHeaders = {
            attempted = true
            val extractor = Any()
            f.capture.initialize(extractor)
            val track = f.capture.track(extractor, 42)
            if (track != null) {
                obtainedTrack = true
                f.capture.format(track, "header-callback-track", "en", "application/x-subrip")
                f.capture.beginRead(extractor, 0)
                f.capture.sample(track, 1_000_000, 500_000, 8)
                f.capture.endRead(extractor, 73, Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT)
                observed = f.capture.snapshot(f.load, "header-callback-track")
            }
        }
        f.actual.headers = mapOf("Content-Range" to listOf("bytes 0-9/100"))
        assertEquals(73L, f.source.open(f.spec()))
        assertTrue(attempted)
        assertTrue(obtainedTrack)
        assertNull(observed)
        assertTrue(f.capture.isUnavailable)
    }

    @Suppress("UNCHECKED_CAST") // Deliberate malformed Java-boundary request metadata.
    @Test fun malformedRequestHeaderTypesDoNotPreventPlaybackOpen() {
        for (malformed in listOf<Map<*, *>>(mapOf(null to "value"), mapOf(7 to "value"), mapOf("X-Synthetic" to 7))) {
            val f = Fixture()
            val request = f.spec().buildUpon().setHttpRequestHeaders(malformed as Map<String, String>).build()
            assertEquals(73L, f.source.open(request))
            assertSame(request, f.actual.opened)
            assertTrue(f.capture.isUnavailable)
        }
    }
}
