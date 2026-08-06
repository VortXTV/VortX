package com.vortx.android.trickplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrickplayUploadCoordinatorTest {

    @Test
    fun `same-size endpoint replacement remains uploadable after the cap`() {
        val coordinator = TrickplayUploadCoordinator()
        val progressive = coordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 600, frames = 600)

        coordinator.complete(progressive, TrickplayUploadCoordinator.Outcome.STORED)

        assertEquals(600L, coordinator.deliveredRevision(KEY))
        assertNotNull(coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 601, frames = 600))
    }

    @Test
    fun `failed revision remains retryable and does not advance delivery`() {
        val coordinator = TrickplayUploadCoordinator()
        val first = coordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)

        coordinator.complete(first, TrickplayUploadCoordinator.Outcome.FAILED)

        assertEquals(0L, coordinator.deliveredRevision(KEY))
        val retry = coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 10)
        assertTrue(retry is TrickplayUploadCoordinator.Admission.Start)
    }

    @Test
    fun `teardown during an active push retains and drains one exact final snapshot`() {
        val coordinator = TrickplayUploadCoordinator()
        val progressive = coordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)
        val deferred = coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 11)

        assertTrue(deferred is TrickplayUploadCoordinator.Admission.Deferred)
        assertEquals(deferred?.claim, coordinator.deferredFinal)

        val completion = coordinator.complete(progressive, TrickplayUploadCoordinator.Outcome.STORED)

        assertEquals(deferred?.claim, completion.nextClaim)
        assertEquals(deferred?.claim, coordinator.inFlight)
    }

    @Test
    fun `newer teardown snapshot replaces the single older deferred snapshot`() {
        val coordinator = TrickplayUploadCoordinator()
        val progressive = coordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)
        val older = coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 11)
        val newer = coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 12)

        assertTrue(older is TrickplayUploadCoordinator.Admission.Deferred)
        assertTrue(newer is TrickplayUploadCoordinator.Admission.Deferred)
        assertEquals(newer?.claim, coordinator.deferredFinal)
        assertEquals(
            newer?.claim,
            coordinator.complete(progressive, TrickplayUploadCoordinator.Outcome.STORED).nextClaim,
        )
    }

    @Test
    fun `same revision teardown drains after failure but is dropped after storage`() {
        val retryCoordinator = TrickplayUploadCoordinator()
        val failed = retryCoordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)
        val retry = retryCoordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 10)
        assertEquals(
            retry?.claim,
            retryCoordinator.complete(failed, TrickplayUploadCoordinator.Outcome.FAILED).nextClaim,
        )

        val storedCoordinator = TrickplayUploadCoordinator()
        val stored = storedCoordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)
        storedCoordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 10)
        assertNull(storedCoordinator.complete(stored, TrickplayUploadCoordinator.Outcome.STORED).nextClaim)
        assertNull(storedCoordinator.inFlight)
    }

    @Test
    fun `progressive rejection settles only that revision and permits newer content`() {
        val coordinator = TrickplayUploadCoordinator()
        val rejected = coordinator.start(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 10)

        coordinator.complete(rejected, TrickplayUploadCoordinator.Outcome.REJECTED)

        assertEquals(0L, coordinator.deliveredRevision(KEY))
        assertEquals(10L, coordinator.settledRevision(KEY))
        assertFalse(coordinator.isFinalRejected(KEY))
        assertNull(coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 10))
        assertNotNull(coordinator.request(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 11))
    }

    @Test
    fun `final rejection is terminal without pretending content was delivered`() {
        val coordinator = TrickplayUploadCoordinator()
        val rejected = coordinator.start(TrickplayUploadCoordinator.Kind.FINAL, revision = 10)

        coordinator.complete(rejected, TrickplayUploadCoordinator.Outcome.REJECTED)

        assertEquals(0L, coordinator.deliveredRevision(KEY))
        assertTrue(coordinator.isFinalRejected(KEY))
        assertNull(coordinator.request(TrickplayUploadCoordinator.Kind.PROGRESSIVE, revision = 11))
        assertNull(coordinator.request(TrickplayUploadCoordinator.Kind.FINAL, revision = 11))
    }

    private fun TrickplayUploadCoordinator.start(
        kind: TrickplayUploadCoordinator.Kind,
        revision: Long,
        frames: Int = 10,
    ): TrickplayUploadCoordinator.Claim {
        val admission = request(kind, revision, frames)
        assertTrue(admission is TrickplayUploadCoordinator.Admission.Start)
        return requireNotNull(admission).claim
    }

    private fun TrickplayUploadCoordinator.request(
        kind: TrickplayUploadCoordinator.Kind,
        revision: Long,
        frames: Int = 10,
    ): TrickplayUploadCoordinator.Admission? = request(
        key = KEY,
        kind = kind,
        retainedRevision = revision,
        frameCount = frames,
        existingFrameCount = 0,
        coverageReady = true,
        throttleReady = true,
    )

    private companion object {
        const val KEY = "title-key"
    }
}
