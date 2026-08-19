package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-ladder coverage for [DeviceMemoryTier]. The RAM read itself needs a [android.content.Context], but
 * the ladder and the warning-ceiling derivation are pure, so they are exercised directly here.
 */
class DeviceMemoryTierTest {

    private val gb = 1024L * 1024 * 1024

    @Test
    fun `unknown or non-positive RAM falls back to the 2 GB tier`() {
        assertEquals(DeviceMemoryTier.FALLBACK_BUFFER_MB, DeviceMemoryTier.bufferMbForTotalBytes(0L))
        assertEquals(DeviceMemoryTier.FALLBACK_BUFFER_MB, DeviceMemoryTier.bufferMbForTotalBytes(-1L))
        assertEquals(250, DeviceMemoryTier.FALLBACK_BUFFER_MB)
    }

    @Test
    fun `ladder returns the exact budget at each boundary`() {
        assertEquals(150, DeviceMemoryTier.bufferMbForTotalBytes(1 * gb))
        assertEquals(200, DeviceMemoryTier.bufferMbForTotalBytes(3 * gb / 2)) // 1.5 GB
        assertEquals(250, DeviceMemoryTier.bufferMbForTotalBytes(2 * gb))
        assertEquals(500, DeviceMemoryTier.bufferMbForTotalBytes(3 * gb))
        assertEquals(1000, DeviceMemoryTier.bufferMbForTotalBytes(4 * gb))
        assertEquals(1600, DeviceMemoryTier.bufferMbForTotalBytes(6 * gb))
        assertEquals(2000, DeviceMemoryTier.bufferMbForTotalBytes(8 * gb))
    }

    @Test
    fun `ladder steps up just past each boundary`() {
        assertEquals(200, DeviceMemoryTier.bufferMbForTotalBytes(1 * gb + 1))
        assertEquals(250, DeviceMemoryTier.bufferMbForTotalBytes(3 * gb / 2 + 1))
        assertEquals(500, DeviceMemoryTier.bufferMbForTotalBytes(2 * gb + 1))
        assertEquals(1000, DeviceMemoryTier.bufferMbForTotalBytes(3 * gb + 1))
        assertEquals(1600, DeviceMemoryTier.bufferMbForTotalBytes(4 * gb + 1))
        assertEquals(2000, DeviceMemoryTier.bufferMbForTotalBytes(6 * gb + 1))
    }

    @Test
    fun `real totalMem values report slightly under nominal and still land on the right rung`() {
        // ActivityManager.totalMem reports less than the nominal amount, so a nominally N GB device sits
        // just below N GB and must still fall on the N GB rung.
        assertEquals(250, DeviceMemoryTier.bufferMbForTotalBytes((1.9 * gb).toLong())) // "2 GB" device
        assertEquals(1000, DeviceMemoryTier.bufferMbForTotalBytes((3.7 * gb).toLong())) // "4 GB" device
        assertEquals(1600, DeviceMemoryTier.bufferMbForTotalBytes((5.6 * gb).toLong())) // "6 GB" device
        assertEquals(2000, DeviceMemoryTier.bufferMbForTotalBytes((7.4 * gb).toLong())) // "8 GB" device
    }

    @Test
    fun `warning ceiling is 1_5x the safe budget`() {
        assertEquals(225, DeviceMemoryTier.warningCeilingForBufferMb(150))
        assertEquals(375, DeviceMemoryTier.warningCeilingForBufferMb(250))
        assertEquals(1500, DeviceMemoryTier.warningCeilingForBufferMb(1000))
        assertEquals(3000, DeviceMemoryTier.warningCeilingForBufferMb(2000))
    }
}
