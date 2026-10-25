package com.vortx.android.player.queue

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackQueueRouteRetirementTest {
    @Test fun `retire invokes the attached outgoing resolver`() {
        val owner = PlaybackQueueRouteRetirement()
        var retired = 0
        owner.attach { retired += 1 }
        owner.retire()
        assertEquals(1, retired)
    }

    @Test fun `old cleanup cannot detach a successor resolver`() {
        val owner = PlaybackQueueRouteRetirement()
        var outgoing = 0
        var successor = 0
        val oldCleanup = owner.attach { outgoing += 1 }
        owner.attach { successor += 1 }
        oldCleanup()
        owner.retire()
        assertEquals(0, outgoing)
        assertEquals(1, successor)
    }

    @Test fun `current cleanup stops subsequent retire calls`() {
        val owner = PlaybackQueueRouteRetirement()
        var retired = 0
        val cleanup = owner.attach { retired += 1 }
        owner.retire()
        cleanup()
        owner.retire()
        cleanup()
        owner.retire()
        assertEquals(1, retired)
    }

    @Test fun `retirement remains attached so retry work can be revoked again`() {
        val owner = PlaybackQueueRouteRetirement()
        var retirements = 0
        owner.attach { retirements += 1 }
        owner.retire()
        owner.retire()
        assertEquals(2, retirements)
    }
}
