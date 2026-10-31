package com.vortx.android.trickplay

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TrickplayDownloadInputTest {
    @Test
    fun `exact limit and empty unknown-length input retain original bytes`() {
        val payload = byteArrayOf(0, 1, -1, 7)
        assertArrayEquals(payload, TrickplayDownloadInput.read(ByteArrayInputStream(payload), 4))
        assertArrayEquals(byteArrayOf(), TrickplayDownloadInput.read(ByteArrayInputStream(byteArrayOf()), 4))
    }

    @Test
    fun `declared oversized input is rejected without reading`() {
        val forbidden = object : InputStream() {
            override fun read(): Int = throw AssertionError("oversized body must not be read")
        }
        assertNull(TrickplayDownloadInput.read(forbidden, 32, declaredLength = 33))
        assertNull(TrickplayDownloadInput.read(forbidden, 32, declaredLength = Long.MAX_VALUE))
    }

    @Test
    fun `unknown or dishonest length consumes only one overflow witness`() {
        for (length in listOf(-1L, 1L)) {
            var consumed = 0
            val infinite = object : InputStream() {
                override fun read(): Int { consumed += 1; return 65 }
                override fun read(target: ByteArray, offset: Int, count: Int): Int {
                    target.fill(65.toByte(), offset, offset + count)
                    consumed += count
                    return count
                }
            }
            assertNull(TrickplayDownloadInput.read(infinite, 10_000, declaredLength = length))
            assertEquals(10_001, consumed)
        }
    }

    @Test
    fun `cancellation before and during a read never returns bytes`() {
        var active = false
        val forbidden = object : InputStream() {
            override fun read(): Int = throw AssertionError("cancelled work must not read")
        }
        assertNull(TrickplayDownloadInput.read(forbidden, 32, isActive = { active }))
        active = true
        var consumed = 0
        val cancelling = object : ByteArrayInputStream(byteArrayOf(1, 2, 3)) {
            override fun read(target: ByteArray, offset: Int, count: Int): Int {
                consumed += 1
                active = false
                return super.read(target, offset, count)
            }
        }
        assertNull(TrickplayDownloadInput.read(cancelling, 32, isActive = { active }))
        assertEquals(1, consumed)
    }

    @Test
    fun `a zero-length wrapper read makes finite progress without losing a byte`() {
        val payload = byteArrayOf(11, 12, 13)
        val occasionalZero = object : ByteArrayInputStream(payload) {
            var first = true
            override fun read(target: ByteArray, offset: Int, count: Int): Int {
                if (first) { first = false; return 0 }
                return super.read(target, offset, count)
            }
        }
        assertArrayEquals(payload, TrickplayDownloadInput.read(occasionalZero, 3))
    }

    @Test(expected = IOException::class)
    fun `transport read failures remain failures for the fetch boundary`() {
        val failing = object : InputStream() {
            override fun read(): Int = throw IOException("synthetic read failure")
        }
        TrickplayDownloadInput.read(failing, 32)
    }

    @Test
    fun `caller use closes rejected input and invalid limits fail early`() {
        var closed = false
        val input = object : ByteArrayInputStream(byteArrayOf(1)) {
            override fun close() { closed = true; super.close() }
        }
        input.use { assertNull(TrickplayDownloadInput.read(it, 1, declaredLength = 2)) }
        assertTrue(closed)
        for (limit in listOf(0, -1, Int.MAX_VALUE)) {
            try {
                TrickplayDownloadInput.read(ByteArrayInputStream(byteArrayOf()), limit)
                fail("invalid byte limit must be rejected")
            } catch (_: IllegalArgumentException) {
                // The production call sites supply finite positive constants.
            }
        }
    }

    @Test
    fun `normal partial-row padded and fleet maximum sheets fit without rescaling`() {
        assertTrue(TrickplaySpriteGeometry.permits(2_880, 1_620, 80, 9, 320, 180))
        assertTrue(TrickplaySpriteGeometry.permits(2_560, 1_440, 63, 8, 320, 180))
        assertTrue(TrickplaySpriteGeometry.permits(2_576, 1_456, 63, 8, 320, 180))
        assertTrue(TrickplaySpriteGeometry.permits(6_400, 3_600, 400, 20, 320, 180))
        assertTrue(TrickplaySpriteGeometry.permits(4_320, 2_430, 80, 9, 480, 270))
    }

    @Test
    fun `truncated grids and compressed image-bomb dimensions reject before allocation`() {
        assertFalse(TrickplaySpriteGeometry.permits(2_559, 1_440, 63, 8, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(2_560, 1_439, 63, 8, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(2_560, 1_440, 65, 8, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(100_000, 100_000, 1, 1, 1, 1))
        assertFalse(TrickplaySpriteGeometry.permits(Int.MAX_VALUE, Int.MAX_VALUE, 1, 1, 1, 1))
    }

    @Test
    fun `invalid and overflow-sized metadata cannot wrap into an admitted grid`() {
        assertFalse(TrickplaySpriteGeometry.permits(0, 180, 1, 1, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(320, 180, 0, 1, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(320, 180, 1, 0, 320, 180))
        assertFalse(TrickplaySpriteGeometry.permits(320, 180, 1, 1, -1, 180))
        assertFalse(TrickplaySpriteGeometry.permits(320, 180, Int.MAX_VALUE, Int.MAX_VALUE, Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(TrickplaySpriteGeometry.permits(320, 180, Int.MAX_VALUE, 1, 320, Int.MAX_VALUE))
    }
}
