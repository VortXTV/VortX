package com.vortx.android.player.mpv.seam

import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

/** Exercises the actual handle gate, not JNI or an invented owner-authority stub. */
class MpvOriginalOwnerLifetimeTest {
    @Test fun boundOwnerCannotBeReplacedEvenByAnotherLiveOwner() {
        val gate = MpvNativeHandleGate(7L)
        assertTrue(gate.bindOriginalOwner(AtomicBoolean(true)))
        assertFalse(gate.bindOriginalOwner(AtomicBoolean(true)))
    }

    @Test fun revocationDeniesEveryFutureNativeLeaseWithoutRunningACallback() {
        val gate = MpvNativeHandleGate(7L)
        val alive = AtomicBoolean(true)
        assertTrue(gate.bindOriginalOwner(alive))
        assertEquals(7L, gate.withHandle(-1L) { it })
        alive.set(false)
        assertEquals(-1L, gate.withHandle(-1L) { error("retired owner reached native") })
        assertFalse(gate.bindOriginalOwner(AtomicBoolean(true)))
    }

    @Test fun alreadyAdmittedWorkFinishesOnlyItsOldHandleAndDestroyStillWaitsForThatLease() {
        val gate = MpvNativeHandleGate(7L)
        val alive = AtomicBoolean(true)
        assertTrue(gate.bindOriginalOwner(alive))
        val destroyed = mutableListOf<Long>()
        val result = gate.withHandle(-1L) { oldHandle ->
            alive.set(false)
            assertEquals(-1L, gate.withHandle(-1L) { error("new lease after retirement") })
            assertNull(gate.requestDestroy(destroyed::add))
            assertTrue(destroyed.isEmpty())
            oldHandle
        }
        assertEquals(7L, result)
        assertEquals(listOf(7L), destroyed)
        assertEquals(-1L, gate.withHandle(-1L) { error("destroyed handle reused") })
        assertNull(gate.requestDestroy(destroyed::add))
    }

    @Test fun bindingAnAlreadyRevokedOriginalCannotBeRepairedByAdoptingANewOne() {
        val gate = MpvNativeHandleGate(7L)
        assertFalse(gate.bindOriginalOwner(AtomicBoolean(false)))
        assertFalse(gate.bindOriginalOwner(AtomicBoolean(true)))
        assertEquals(-1L, gate.withHandle(-1L) { error("failed original binding renewed") })
        val destroyed = mutableListOf<Long>()
        gate.requestDestroy(destroyed::add)!!.invoke()
        assertEquals(listOf(7L), destroyed)
    }
}
