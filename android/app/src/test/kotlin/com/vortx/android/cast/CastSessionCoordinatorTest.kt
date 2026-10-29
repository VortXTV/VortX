package com.vortx.android.cast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CastSessionCoordinatorTest {
    @Test fun `an observed foreign session grants neither a load nor media authority`() {
        val f = Fixture()
        f.coordinator.observe(f.a, f.ca, "A")
        assertFalse(f.coordinator.isOwned)
        assertFalse(f.coordinator.canControl)
        f.status(f.coordinator.binding!!, "foreign", 1_900_000L)
        assertNull(f.coordinator.point)
        assertNull(f.coordinator.started(f.a, f.ca, "A", 0L, f.a))
        assertNull(f.coordinator.loadId)
        assertTrue(f.events.isEmpty())
    }

    @Test fun `only the chosen already-connected receiver can consume an explicit handoff`() {
        val f = Fixture()
        f.coordinator.observe(f.a, f.ca, "A")
        assertTrue(f.coordinator.chooseRoute("owner", "A", 0L))
        f.coordinator.starting(f.a, "A", 1L)
        val ticket = f.coordinator.started(f.a, f.ca, "A", 2L, f.a)!!
        assertTrue(f.coordinator.begin(ticket, "load-A", 3L))
        assertFalse(f.coordinator.isOwned)
        f.status(f.coordinator.binding!!, "load-A", 300_000L)
        assertTrue(f.coordinator.isOwned)
        assertEquals(300_000L, f.coordinator.point!!.positionMs)
        assertFalse(f.coordinator.begin(ticket, "second-load", 4L))
    }

    @Test fun `first suspension expires even without a resuming callback and repeats cannot extend it`() {
        val f = Fixture().active()
        f.coordinator.suspended(f.a, f.ca, 100L)
        f.coordinator.suspended(f.a, f.ca, 10_000L)
        f.coordinator.resuming(f.a, f.ca, "A", 14_000L)
        assertTrue(f.coordinator.isOwned) // The local CAST blocker remains until the bounded retirement.
        assertFalse(f.coordinator.canControl)
        assertNull(f.coordinator.tick(true, 15_100L))
        assertFalse(f.coordinator.isOwned) // The production adapter publishes this to release CAST.
        assertFalse(f.coordinator.isPlaying)
        assertNull(f.coordinator.takeResume("another-owner"))
        assertEquals(300_000L, f.coordinator.takeResume("owner")!!.positionMs)
    }

    @Test fun `same-client cached UUID and near-end extrapolation cannot restore resume authority`() {
        val f = Fixture().active()
        val before = f.coordinator.point
        f.coordinator.suspended(f.a, f.ca, 100L)
        val cachedNearEnd = status("load-A", 1_999_000L)
        f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
        // A bind/read/progress tick may see cachedNearEnd, but none is a received-status event.
        assertEquals("load-A", cachedNearEnd.receipt)
        repeat(10) { f.coordinator.tick(true, 300L + it) }
        assertFalse(f.coordinator.canControl)
        assertFalse(f.coordinator.isPlaying)
        assertEquals(before, f.coordinator.point)
        f.coordinator.tick(true, 15_100L)
        assertFalse(f.coordinator.isOwned)
        assertEquals(before, f.coordinator.confirmed("owner"))
    }

    @Test fun `a fresh matching post-resume status restores authority in its exact epoch`() {
        val f = Fixture().active()
        val oldBinding = f.coordinator.binding!!
        f.coordinator.suspended(f.a, f.ca, 100L)
        f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
        f.status(oldBinding, "load-A", 1_999_000L, now = 300L)
        assertFalse(f.coordinator.canControl)
        f.status(f.coordinator.binding!!, "load-A", 360_000L, now = 400L)
        assertTrue(f.coordinator.canControl)
        assertTrue(f.coordinator.isPlaying)
        assertEquals(360_000L, f.coordinator.point!!.positionMs)
    }

    @Test fun `fresh paused resumed status stays paused and foreign or ended status retires authority`() {
        for (kind in listOf("paused", "foreign", "ended")) {
            val f = Fixture().active()
            f.coordinator.suspended(f.a, f.ca, 100L)
            f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
            val received = when (kind) {
                "paused" -> status("load-A", 330_000L).copy(playing = false, paused = true)
                "foreign" -> status("foreign", 1_999_000L)
                else -> status("load-A", 1_999_000L).copy(playing = false)
            }
            f.coordinator.freshStatus(f.coordinator.binding!!, received, 300L)
            assertFalse(kind, f.coordinator.isPlaying)
            if (kind == "paused") {
                assertTrue(f.coordinator.canControl)
                assertEquals(330_000L, f.coordinator.point!!.positionMs)
            } else {
                assertFalse(f.coordinator.isOwned)
                assertEquals(300_000L, f.coordinator.confirmed("owner")!!.positionMs)
            }
        }
    }

    @Test fun `fresh status during reconnection is retained but cannot admit before resumed`() {
        val f = Fixture().active()
        f.coordinator.suspended(f.a, f.ca, 100L)
        f.status(f.coordinator.binding!!, "load-A", 350_000L, now = 200L)
        assertFalse(f.coordinator.canControl)
        assertEquals(300_000L, f.coordinator.point!!.positionMs)
        f.coordinator.resumed(f.a, f.ca, "A", 300L, f.a)
        assertTrue(f.coordinator.canControl)
        assertEquals(350_000L, f.coordinator.point!!.positionMs)
    }

    @Test fun `a replacement resume client needs its own post-suspension receipt`() {
        val f = Fixture().active()
        f.coordinator.suspended(f.a, f.ca, 100L)
        val old = f.coordinator.binding!!
        val replacementSession = Any()
        val replacementClient = Any()
        f.coordinator.resuming(replacementSession, replacementClient, "A", 200L)
        f.coordinator.resumed(replacementSession, replacementClient, "A", 300L, replacementSession)
        f.status(old, "load-A", 1_999_000L, now = 400L)
        assertFalse(f.coordinator.canControl)
        f.status(f.coordinator.binding!!, "load-A", 400_000L, now = 500L)
        assertTrue(f.coordinator.canControl)
        assertEquals(400_000L, f.coordinator.point!!.positionMs)
    }

    @Test fun `replacement pair cannot inherit an earlier resumed callback in the same attempt`() {
        for (sameSession in listOf(true, false)) {
            val f = Fixture().active()
            f.coordinator.suspended(f.a, f.ca, 100L)
            f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
            val earlier = f.coordinator.binding!!
            val session = if (sameSession) f.a else Any()
            val client = Any()
            f.coordinator.resuming(session, client, "A", 300L)
            val replacement = f.coordinator.binding!!
            assertFalse(earlier.same(replacement))
            f.status(replacement, "load-A", 350_000L, now = 400L)
            assertFalse("sameSession=$sameSession", f.coordinator.canControl)
            assertEquals(300_000L, f.coordinator.point!!.positionMs)
            // Exact-pair status may be retained, but only this pair's actual resumed admits it.
            f.coordinator.resumed(session, client, "A", 500L, session)
            assertTrue("sameSession=$sameSession", f.coordinator.canControl)
            assertEquals(350_000L, f.coordinator.point!!.positionMs)
            assertEquals("load-A", f.coordinator.loadId)
        }
    }

    @Test fun `repeated resuming retires readiness without extending the first deadline`() {
        val f = Fixture().active()
        f.coordinator.suspended(f.a, f.ca, 100L)
        f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
        f.coordinator.resuming(f.a, f.ca, "A", 14_000L)
        f.status(f.coordinator.binding!!, "load-A", 350_000L, now = 14_001L)
        assertFalse(f.coordinator.canControl)
        assertEquals(300_000L, f.coordinator.point!!.positionMs)
        assertNull(f.coordinator.tick(true, 15_100L)) // Reconnect expiry returns locally without STOP.
        assertFalse(f.coordinator.isOwned)
        assertEquals(300_000L, f.coordinator.takeResume("owner")!!.positionMs)
    }

    @Test fun `repeated real suspension retires both earlier readiness and earlier proof`() {
        for (proofBeforeSecondSuspend in listOf(true, false)) {
            val f = Fixture().active()
            f.coordinator.suspended(f.a, f.ca, 100L)
            if (proofBeforeSecondSuspend) {
                f.status(f.coordinator.binding!!, "load-A", 350_000L, now = 200L)
            } else {
                f.coordinator.resumed(f.a, f.ca, "A", 200L, f.a)
            }
            f.coordinator.suspended(f.a, f.ca, 300L)
            if (proofBeforeSecondSuspend) {
                f.coordinator.resumed(f.a, f.ca, "A", 400L, f.a)
            } else {
                f.status(f.coordinator.binding!!, "load-A", 360_000L, now = 400L)
            }
            assertFalse("proofBeforeSecondSuspend=$proofBeforeSecondSuspend", f.coordinator.canControl)
            assertEquals(300_000L, f.coordinator.point!!.positionMs)
            if (proofBeforeSecondSuspend) {
                f.status(f.coordinator.binding!!, "load-A", 370_000L, now = 500L)
                assertEquals(370_000L, f.coordinator.point!!.positionMs)
            } else {
                f.coordinator.resumed(f.a, f.ca, "A", 500L, f.a)
                assertEquals(360_000L, f.coordinator.point!!.positionMs)
            }
            assertTrue(f.coordinator.canControl)
        }
    }

    @Test fun `a different current receiver resume retires old ownership without adopting foreign media`() {
        val f = Fixture().active()
        assertNull(f.coordinator.resumed(f.b, f.cb, "B", 100L, f.b))
        assertFalse(f.coordinator.isOwned)
        assertFalse(f.coordinator.canControl)
        assertEquals(300_000L, f.coordinator.takeResume("owner")!!.positionMs)
        assertTrue(f.coordinator.binding!!.session === f.b)
    }

    @Test fun `chosen B grant survives both outgoing A teardown callback orders owned and foreign`() {
        for (ownedA in listOf(false, true)) for (startingFirst in listOf(false, true)) {
            val f = if (ownedA) Fixture().active() else Fixture().also { it.coordinator.observe(it.a, it.ca, "A") }
            val oldBinding = f.coordinator.binding!!
            assertTrue(f.coordinator.chooseRoute("owner", "B", 100L))
            if (startingFirst) f.coordinator.starting(f.b, "B", 200L)
            f.coordinator.ended(f.a)
            if (!startingFirst) f.coordinator.starting(f.b, "B", 300L)
            val ticket = f.coordinator.started(f.b, f.cb, "B", 400L, f.b)
            assertNotNull("owned=$ownedA startingFirst=$startingFirst", ticket)
            assertTrue(f.coordinator.begin(ticket!!, "load-B", 500L))
            val boundB = f.coordinator.binding!!
            f.coordinator.ended(f.a)
            assertNull(f.coordinator.started(f.a, f.ca, "A", 600L, f.b))
            f.status(oldBinding, "load-A", 1_999_000L, now = 700L)
            assertEquals("load-B", f.coordinator.loadId)
            f.status(boundB, "load-B", 0L, now = 800L)
            assertTrue(f.coordinator.isOwned)
            assertEquals(0L, f.coordinator.point!!.positionMs)
        }
    }

    @Test fun `wrong route or unrelated session cannot consume the pending selected route grant`() {
        val f = Fixture()
        assertTrue(f.coordinator.chooseRoute("owner", "B", 0L))
        f.coordinator.starting(f.a, "A", 100L)
        assertNull(f.coordinator.started(f.a, f.ca, "A", 200L, f.a))
        f.coordinator.starting(f.b, "B", 300L)
        assertNull(f.coordinator.started(f.b, f.cb, "B", 400L, f.a))
        assertNotNull(f.coordinator.started(f.b, f.cb, "B", 500L, f.b))
    }

    @Test fun `intentional continuation exit precedes admission invalidation and never requests stop`() {
        val f = Fixture().active()
        val old = f.coordinator.binding!!
        f.coordinator.leavePlayer("owner") // The real host invokes this before playerExitRequested.
        val writesAtExit = f.events.size
        assertFalse(f.coordinator.isOwned)
        assertNull(f.coordinator.tick(false, 1_000L))
        f.status(old, "load-A", 1_999_000L, now = 1_001L)
        f.coordinator.detach()
        assertEquals(writesAtExit, f.events.size)
        assertEquals(300_000L, f.coordinator.confirmed("owner")!!.positionMs)
    }

    @Test fun `account or source revocation remains distinct from intentional continuation`() {
        val account = Fixture().active()
        assertNotNull(account.coordinator.tick(false, 100L))
        assertFalse(account.coordinator.isOwned)
        val source = Fixture().active()
        assertNotNull(source.coordinator.select("other-episode"))
        assertFalse(source.coordinator.isOwned)
        assertNull(source.coordinator.confirmed("other-episode"))
    }

    @Test fun `unconfirmed near-end seek is never the final history or local resume point`() {
        val f = Fixture().active()
        assertEquals(1_999_000L, f.coordinator.seek(1_999_000L, 100L))
        f.status(f.coordinator.binding!!, "load-A", 301_000L, now = 200L)
        assertFalse(f.coordinator.isPlaying)
        assertEquals(300_000L, f.coordinator.point!!.positionMs)
        f.coordinator.retire(false)
        assertEquals(300_000L, f.coordinator.takeResume("owner")!!.positionMs)
        assertEquals(300_000L, f.events.last().point!!.positionMs)
    }

    @Test fun `confirmed rewind to zero remains a valid final point and exact owner resume`() {
        val f = Fixture().active()
        f.coordinator.seek(0L, 100L)
        f.status(f.coordinator.binding!!, "load-A", 0L, now = 200L)
        f.coordinator.retire(false)
        assertNull(f.coordinator.takeResume("other-owner"))
        assertEquals(0L, f.coordinator.takeResume("owner")!!.positionMs)
        assertEquals(0L, f.coordinator.confirmed("owner")!!.positionMs)
    }

    @Test fun `same URL episode replacement and expired grants cannot inherit old proof`() {
        val f = Fixture().active()
        val old = f.coordinator.binding!!
        f.coordinator.select("same-url-other-episode")
        f.status(old, "load-A", 1_999_000L, now = 100L)
        assertFalse(f.coordinator.isOwned)
        assertTrue(f.coordinator.chooseRoute("same-url-other-episode", "B", 200L))
        f.coordinator.starting(f.b, "B", 60_201L)
        assertNull(f.coordinator.started(f.b, f.cb, "B", 60_202L, f.b))
        assertNull(f.coordinator.confirmed("same-url-other-episode"))
    }

    @Test fun `foreign and idle transitional status before first echo preserve one pending explicit load`() {
        val f = Fixture()
        f.coordinator.observe(f.a, f.ca, "A") // The selected receiver was already playing foreign media.
        assertTrue(f.coordinator.chooseRoute("owner", "A", 0L))
        f.coordinator.starting(f.a, "A", 1L)
        val ticket = f.coordinator.started(f.a, f.ca, "A", 2L, f.a)!!
        assertTrue(f.coordinator.begin(ticket, "new-load", 3L))
        val binding = f.coordinator.binding!!
        f.status(binding, "foreign-old-load", 1_999_000L, now = 4L)
        f.coordinator.freshStatus(binding, status("foreign-old-load", 0L).copy(playing = false), 5L)
        f.coordinator.freshStatus(binding, status("new-load", 0L).copy(playing = false), 6L)
        assertEquals("new-load", f.coordinator.loadId)
        assertFalse(f.coordinator.isOwned)
        assertFalse(f.coordinator.canControl)
        assertFalse(f.coordinator.isPlaying)
        assertTrue(f.events.isEmpty())
        assertFalse(f.coordinator.begin(ticket, "duplicate-request", 7L))
        f.status(binding, "new-load", 60_000L, now = 8L)
        assertTrue(f.coordinator.isOwned)
        assertEquals("new-load", f.coordinator.loadId)
        assertEquals(60_000L, f.coordinator.point!!.positionMs)
        f.status(binding, "foreign-replacement", 1_999_000L, now = 9L)
        assertFalse(f.coordinator.isOwned) // Foreign status still retires an already-confirmed load.
        assertEquals(60_000L, f.coordinator.confirmed("owner")!!.positionMs)
    }

    @Test fun `unconfirmed load still ends on explicit failure revoked owner or bounded expiry`() {
        for (resolution in listOf("failure", "revoked", "timeout")) {
            val f = Fixture()
            assertTrue(f.coordinator.chooseRoute("owner", "A", 0L))
            f.coordinator.starting(f.a, "A", 1L)
            val ticket = f.coordinator.started(f.a, f.ca, "A", 2L, f.a)!!
            assertTrue(f.coordinator.begin(ticket, "pending", 3L))
            val binding = f.coordinator.binding!!
            f.status(binding, "old", 1_999_000L, now = 4L)
            val stop = when (resolution) {
                "failure" -> f.coordinator.retire(stopReceiver = true) // actual SDK result-failure path
                "revoked" -> f.coordinator.tick(false, 100L)
                else -> f.coordinator.tick(true, 60_003L)
            }
            assertNotNull(resolution, stop)
            assertNull(f.coordinator.loadId)
            assertFalse(f.coordinator.isOwned)
            f.status(binding, "pending", 1_999_000L, now = 60_004L)
            assertFalse(f.coordinator.isOwned)
            assertTrue(f.events.none { it.point != null })
        }
    }

    private class Fixture {
        val events = mutableListOf<CastTimelineUpdate>()
        val coordinator = CastSessionCoordinator { events += it }
        val a = Any(); val ca = Any(); val b = Any(); val cb = Any()
        init { coordinator.select("owner") }
        fun active(): Fixture {
            check(coordinator.chooseRoute("owner", "A", 0L))
            coordinator.starting(a, "A", 1L)
            check(coordinator.begin(coordinator.started(a, ca, "A", 2L, a)!!, "load-A", 3L))
            status(coordinator.binding!!, "load-A", 300_000L, now = 4L)
            return this
        }
        fun status(binding: CastSessionCoordinator.Binding, id: String, position: Long, now: Long = 10L) {
            coordinator.freshStatus(binding, CastSessionCoordinatorTest.status(id, position), now)
        }
    }
    companion object {
        private fun status(id: String, position: Long) = CastSessionCoordinator.Status(id, position, 2_000_000L,
            playing = true, paused = false, buffering = false)
    }
}
