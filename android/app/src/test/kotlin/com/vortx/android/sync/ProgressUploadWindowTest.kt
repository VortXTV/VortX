package com.vortx.android.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressUploadWindowTest {
    private val urgent = 2_500L

    @Test fun `a real edit keeps the ordinary cadence`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = false, nowMs = 0)
        assertEquals(UploadWait(urgent, progressWindow = false), window.nextDelayMs(0, urgent, null))
        assertEquals(UploadWait(10_000, progressWindow = false), window.nextDelayMs(0, urgent, 10_000))
    }

    @Test fun `no recorded window, as after a restart, keeps the ordinary cadence`() {
        assertEquals(UploadWait(urgent, progressWindow = false), ProgressUploadWindow().nextDelayMs(0, urgent, null))
    }

    @Test fun `progress waits for fifteen quiet seconds`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = true, nowMs = 0)
        window.record(2, progressOnly = true, nowMs = 5_000)
        assertEquals(UploadWait(15_000, progressWindow = true), window.nextDelayMs(5_000, urgent, null))
        assertEquals(UploadWait(0, progressWindow = true), window.nextDelayMs(21_000, urgent, null))
    }

    @Test fun `continuous progress uploads at most sixty seconds after the first report`() {
        val window = ProgressUploadWindow()
        for (t in 0L..55_000L step 5_000L) window.record(t / 5_000 + 1, progressOnly = true, nowMs = t)
        assertEquals(5_000L, window.nextDelayMs(55_000, urgent, null).delayMs)
    }

    @Test fun `a real edit during progress returns to the ordinary cadence`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = true, nowMs = 0)
        window.record(2, progressOnly = false, nowMs = 1_000)
        assertTrue(window.hasUrgent)
        assertEquals(UploadWait(urgent, progressWindow = false), window.nextDelayMs(1_000, urgent, null))
    }

    @Test fun `a failed upload's backoff is never shortened by a due window`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = true, nowMs = 0)
        assertEquals(UploadWait(20_000, progressWindow = true), window.nextDelayMs(30_000, urgent, 20_000))
    }

    @Test fun `progress during an accepted upload opens a fresh window from that report`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = false, nowMs = 0)
        window.record(2, progressOnly = true, nowMs = 1_000) // arrived while generation 1 was uploading
        window.acknowledge(uploaded = 1, current = 2)
        assertFalse(window.hasUrgent)
        assertEquals(UploadWait(15_000, progressWindow = true), window.nextDelayMs(1_000, urgent, null))
        window.acknowledge(uploaded = 2, current = 2)
        assertEquals(UploadWait(urgent, progressWindow = false), window.nextDelayMs(1_000, urgent, null))
    }

    @Test fun `a real edit made during an upload stays urgent`() {
        val window = ProgressUploadWindow()
        window.record(1, progressOnly = true, nowMs = 0)
        window.record(2, progressOnly = false, nowMs = 1_000)
        window.acknowledge(uploaded = 1, current = 2)
        assertTrue(window.hasUrgent)
    }
}
