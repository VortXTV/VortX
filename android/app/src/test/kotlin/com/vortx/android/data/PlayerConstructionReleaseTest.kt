package com.vortx.android.data

import org.junit.Assert.*
import org.junit.Test

/** Actual release gate only; no fake decoder, Android host, JNI or teardown timing claim. */
class PlayerConstructionReleaseTest {
    @Test fun disposalWhileFactoryHasNoHolderWaitsForConstructionAndExactDecoderRelease() {
        val gate = PlayerResourceReleaseGate()
        var releases = 0
        gate.registerReleaseCallback("original") { releases += 1 }
        assertTrue(gate.beginConstruction())
        gate.sessionDisposed()
        assertEquals(0, releases)
        assertTrue(gate.decoderBound()) // count BEFORE exposing the delayed engine holder
        gate.endConstruction()
        assertEquals(0, releases)
        gate.decoderReleased()
        assertEquals(1, releases)
        gate.decoderReleased(); gate.sessionDisposed()
        assertEquals(1, releases)
        assertFalse(gate.beginConstruction())
        assertFalse(gate.decoderBound())
    }

    @Test fun failedOrCancelledFactoryClosesItsReservationWithoutInventingADecoder() {
        val gate = PlayerResourceReleaseGate()
        var releases = 0
        gate.registerReleaseCallback("cancelled") { releases += 1 }
        assertTrue(gate.beginConstruction())
        gate.sessionDisposed()
        assertEquals(0, releases)
        gate.endConstruction()
        assertEquals(1, releases)
        assertFalse(gate.beginConstruction())
        assertFalse(gate.decoderBound())
    }

    @Test fun setupFailureReleaseBeforeConstructionCloseCannotReclaimEarly() {
        val gate = PlayerResourceReleaseGate()
        var releases = 0
        gate.registerReleaseCallback("setup-failure") { releases += 1 }
        assertTrue(gate.beginConstruction())
        assertTrue(gate.decoderBound())
        gate.sessionDisposed()
        gate.decoderReleased()
        assertEquals(0, releases)
        gate.endConstruction()
        assertEquals(1, releases)
    }

    @Test fun oldAndReplacementReservationsAndLeaseMustAllFinish() {
        val gate = PlayerResourceReleaseGate()
        var releases = 0
        gate.registerReleaseCallback("old") { releases += 1 }
        assertTrue(gate.beginConstruction())
        gate.registerReleaseCallback("replacement") { releases += 1 }
        assertTrue(gate.beginConstruction())
        gate.leaseBound()
        gate.sessionDisposed()
        gate.endConstruction()
        assertEquals(0, releases)
        assertTrue(gate.decoderBound())
        gate.endConstruction()
        gate.leaseReleased()
        assertEquals(0, releases)
        gate.decoderReleased()
        assertEquals(2, releases)
    }
}
