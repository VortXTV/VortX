package com.vortx.android.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamingServerProbeOwnerTest {
    @Test fun `a newer probe cannot adopt an older completion`() {
        val owner = StreamingServerProbeOwner()
        val old = owner.begin()
        val current = owner.begin()
        assertFalse(owner.owns(old))
        assertTrue(owner.owns(current))
    }

    @Test fun `editing and returning to the same address does not revive a probe`() {
        val owner = StreamingServerProbeOwner()
        val original = owner.begin()
        owner.invalidate()
        val next = owner.begin()
        assertFalse(owner.owns(original))
        assertTrue(owner.owns(next))
        owner.invalidate() // The same invalidation runs when Use on-device server is chosen.
        assertFalse(owner.owns(next))
    }

    @Test(expected = IllegalStateException::class)
    fun `disposed settings cannot publish a late result or start another probe`() {
        val owner = StreamingServerProbeOwner()
        val original = owner.begin()
        owner.dispose()
        assertFalse(owner.owns(original))
        owner.begin()
    }
}
