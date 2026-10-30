package com.vortx.android.home

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class CuratedCatalogBodyTest {
    @Test fun acceptsEmptyAndExactBudgetBodies() {
        assertArrayEquals(byteArrayOf(), readCuratedCatalogBody(ByteArrayInputStream(byteArrayOf()), 64))
        val bytes = ByteArray(64) { it.toByte() }
        assertArrayEquals(bytes, readCuratedCatalogBody(ByteArrayInputStream(bytes), 64))
    }

    @Test fun preservesUtf8AcrossSingleByteReads() {
        val bytes = "Caf\u00e9 \uD83C\uDFAC".toByteArray(Charsets.UTF_8)
        val input = object : ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, minOf(length, 1))
        }
        assertArrayEquals(bytes, readCuratedCatalogBody(input, bytes.size))
    }

    @Test fun overflowConsumesOnlyOneExtraByteAndLeavesTheTailUnread() {
        val input = CountingInput(10_000)
        assertNull(readCuratedCatalogBody(input, 64))
        assertEquals(65, input.consumed)
    }

    @Test fun enforcesTheRealDefaultBudgetWithoutBufferingTheOversizedTail() {
        val input = CountingInput(Int.MAX_VALUE)
        assertNull(readCuratedCatalogBody(input))
        assertEquals(MAX_CURATED_CATALOG_BYTES + 1, input.consumed)
    }

    @Test fun cancellationAfterBlockingReadPreventsAResult() {
        val input = CountingInput(64)
        val cancelled = CancellationException("synthetic cancellation")
        var checks = 0
        try {
            readCuratedCatalogBody(input, 64) { if (++checks == 2) throw cancelled }
            fail("Cancellation must propagate")
        } catch (actual: CancellationException) {
            assertSame(cancelled, actual)
            assertEquals(64, input.consumed)
        }
    }

    @Test fun invalidBudgetsAreRejectedBeforeReading() {
        for (limit in listOf(0, -1, MAX_CURATED_CATALOG_BYTES + 1, Int.MAX_VALUE)) {
            val input = CountingInput(1)
            try {
                readCuratedCatalogBody(input, limit)
                fail("Invalid budget must fail")
            } catch (_: IllegalArgumentException) {
                assertEquals(0, input.consumed)
            }
        }
    }

    @Test fun nonProgressAndReadFailuresDoNotRetryForever() {
        var reads = 0
        val stalled = object : InputStream() {
            override fun read(): Int = error("bulk read expected")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int { reads++; return 0 }
        }
        assertNull(readCuratedCatalogBody(stalled, 64))
        assertEquals(1, reads)
        val failure = IOException("synthetic read refusal")
        val failed = object : InputStream() { override fun read(): Int = throw failure }
        try {
            readCuratedCatalogBody(failed, 64)
            fail("Read failure must propagate to the transport")
        } catch (actual: IOException) { assertSame(failure, actual) }
    }

    private class CountingInput(private val length: Int) : InputStream() {
        var consumed = 0
            private set
        override fun read(): Int = if (consumed < length) { consumed++; 1 } else -1
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (consumed == this.length) return -1
            val count = minOf(length, this.length - consumed)
            buffer.fill(1, offset, offset + count)
            consumed += count
            return count
        }
    }
}
