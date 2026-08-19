package com.vortx.android.player.tuning

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic coverage for the adaptive tuning: the [AdaptiveBufferPlanner] decision and the
 * [LinkSpeedProbe] stability judgement. Neither needs an Android context, so both are exercised directly.
 */
class AdaptiveTuningLogicTest {

    private val mb = 1024L * 1024
    private val ram = 1000L * 1024 * 1024 // a 1000 MB RAM budget (the 4 GB device tier)

    @Test
    fun `BALANCED with no link reproduces the merged RAM-tier baseline`() {
        val plan = AdaptiveBufferPlanner.plan(ram, linkBps = null, intent = BufferIntentProfile.BALANCED)
        assertEquals(ram.toInt(), plan.targetBufferBytes) // fraction 1.0 -> full budget
        assertEquals(40_000, plan.minBufferMs)
        assertEquals(120_000, plan.maxBufferMs)
        assertEquals(300, plan.mpvReadaheadSecs)
        assertEquals(1.0, plan.ramFraction, 0.0001)
    }

    @Test
    fun `FAST with no link takes half the budget and short durations`() {
        val plan = AdaptiveBufferPlanner.plan(ram, linkBps = null, intent = BufferIntentProfile.FAST)
        assertEquals((ram / 2).toInt(), plan.targetBufferBytes)
        assertEquals(15_000, plan.minBufferMs)
        assertEquals(45_000, plan.maxBufferMs)
    }

    @Test
    fun `a very fast link shrinks only the FAST profile below its baseline`() {
        val fastLink = 30L * mb // 30 MB/s -> headroom 3 (>= FAST_LINK_HEADROOM)
        val fast = AdaptiveBufferPlanner.plan(ram, fastLink, BufferIntentProfile.FAST)
        assertTrue("FAST fraction should drop below 0.5", fast.ramFraction < 0.5)

        val balanced = AdaptiveBufferPlanner.plan(ram, fastLink, BufferIntentProfile.BALANCED)
        assertEquals("BALANCED never shrinks on a fast link", 1.0, balanced.ramFraction, 0.0001)
    }

    @Test
    fun `a marginal link deepens the buffer toward the ceiling`() {
        val slowLink = 4L * mb // 4 MB/s -> headroom 0.4 (< 1)
        val fast = AdaptiveBufferPlanner.plan(ram, slowLink, BufferIntentProfile.FAST)
        assertTrue("FAST should deepen to at least 0.85 on a marginal link", fast.ramFraction >= 0.85)
        assertTrue("FAST max buffer should extend to at least 120s", fast.maxBufferMs >= 120_000)
    }

    @Test
    fun `STALL uses the deepest durations and read-ahead`() {
        val plan = AdaptiveBufferPlanner.plan(ram, linkBps = null, intent = BufferIntentProfile.STALL)
        assertEquals(60_000, plan.minBufferMs)
        assertEquals(180_000, plan.maxBufferMs)
        assertEquals(600, plan.mpvReadaheadSecs)
    }

    @Test
    fun `a tiny RAM tier is floored so the target buffer stays usable`() {
        val plan = AdaptiveBufferPlanner.plan(8L * mb, linkBps = null, intent = BufferIntentProfile.FAST)
        assertTrue("target must not collapse below the 24 MiB floor", plan.targetBufferBytes >= 24 * 1024 * 1024)
    }

    @Test
    fun `steady samples read as stable and a spike reads as unstable`() {
        assertTrue(LinkSpeedProbe.isStable(listOf(1_000_000, 1_050_000, 980_000, 1_010_000)))
        assertFalse(LinkSpeedProbe.isStable(listOf(1_000_000, 50_000, 1_000_000, 40_000)))
        assertFalse("fewer than two samples cannot be judged", LinkSpeedProbe.isStable(listOf(1_000_000)))
    }
}
