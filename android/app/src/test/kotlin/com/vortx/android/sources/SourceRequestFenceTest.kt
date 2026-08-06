package com.vortx.android.sources

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceRequestFenceTest {

    @Test
    fun newerEmptyTargetClearsOldRowsAndRejectsLateOldPublication() {
        val fence = SourceRequestFence("profile-a")
        val old = fence.begin("profile-a", "show:1:1")
        var visible = listOf("old-source")

        val fresh = fence.begin("profile-a", "show:1:2")
        if (fence.accepts(fresh, "profile-a")) visible = emptyList()
        if (fence.accepts(old, "profile-a")) visible = listOf("late-old-source")

        assertTrue(visible.isEmpty())
        assertFalse(fence.accepts(old, "profile-a"))
        assertTrue(fence.accepts(fresh, "profile-a"))
    }

    @Test
    fun profileRoundTripStillSupersedesOriginalGeneration() {
        val fence = SourceRequestFence("profile-a")
        val stale = fence.begin("profile-a", "show:1:1")
        fence.invalidate("profile-b")
        fence.invalidate("profile-a")
        val current = fence.begin("profile-a", "show:1:1")

        assertFalse(fence.accepts(stale, "profile-a"))
        assertTrue(fence.accepts(current, "profile-a"))
        assertEquals("show:1:1", current.targetId)
    }
}
