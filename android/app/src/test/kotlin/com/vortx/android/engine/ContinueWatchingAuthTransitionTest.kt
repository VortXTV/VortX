package com.vortx.android.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinueWatchingAuthTransitionTest {
    @Test
    fun `caller terminal closes only its own generation`() {
        val transition = ContinueWatchingAuthTransition()
        val generation = transition.begin()

        assertTrue(transition.inProgress)
        assertFalse(transition.finish(generation + 1L))
        assertTrue(transition.inProgress)

        assertTrue(transition.finish(generation))
        assertFalse(transition.inProgress)
    }

    @Test
    fun `late terminal from prior generation cannot open a newer transition`() {
        val transition = ContinueWatchingAuthTransition()
        val first = transition.begin()
        assertTrue(transition.finish(first))
        val second = transition.begin()

        assertFalse(transition.finish(first))
        assertTrue(transition.inProgress)
        assertTrue(transition.finish(second))
    }

    @Test
    fun `explicit sign out cancels the active generation`() {
        val transition = ContinueWatchingAuthTransition()
        transition.begin()

        assertTrue(transition.cancelActive())
        assertFalse(transition.inProgress)
        assertFalse(transition.cancelActive())
    }
}
