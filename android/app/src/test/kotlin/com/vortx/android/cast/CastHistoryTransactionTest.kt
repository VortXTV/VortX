package com.vortx.android.cast

import com.vortx.android.data.PlaybackSessionLifecycle
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.model.Playable
import com.vortx.android.player.PlaybackProgressCache
import com.vortx.android.player.PlayerEpisodeHistoryIdentity
import com.vortx.android.player.PlayerProgressSnapshot
import com.vortx.android.player.PlayerProgressTimeline
import com.vortx.android.player.PlayerState
import com.vortx.android.player.canReportPlayerProgress
import com.vortx.android.ui.tv.TvPlaybackHistorySession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CastHistoryTransactionTest {
    @Test fun `phone and TV exit retain minute30 remote point instead of minute5 paused local snapshot`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start()
            f.status(1_800_000L)
            // No five-second progress tick. The production coordinator already forwarded this received point.
            assertEquals(1_800_000L, f.last()!!.positionMs)
            assertNull(f.coordinator.prepareExit(OWNER, f.admitted))
            f.timeline.finish(300_000L, DURATION)
            f.timeline.close() // This is the synchronous host hook, before invalidating the exit gate.
            f.admitted = false
            assertNull(f.coordinator.tick(false, 1_000L))
            f.status(7_199_000L)
            f.timeline.local(300_000L, DURATION)
            f.timeline.finish(300_000L, DURATION)
            f.coordinator.detach()
            f.end(); advanceUntilIdle()
            assertEquals(OWNER, f.last()!!.owner)
            assertEquals(1_800_000L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `phone and TV pause or stop before periodic tick save the last confirmed position and duration`() = runTest {
        for (tv in listOf(false, true)) for (stop in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start()
            f.status(1_800_000L, paused = true)
            if (stop) f.coordinator.retire(false)
            f.timeline.finish(300_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_800_000L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `phone and TV pending near-end seek and stale resumed cache cannot mark watched`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(1_800_000L)
            f.coordinator.seek(7_199_000L, 100L)
            f.status(1_801_000L) // Fresh but not the requested seek: it cannot replace confirmed progress.
            f.coordinator.suspended(f.session, f.client, 200L)
            f.coordinator.resumed(f.session, f.client, "receiver", 300L, f.session)
            // Cached media still says playing near EOF, but the real adapter does not call freshStatus for it.
            f.coordinator.tick(true, 400L)
            f.coordinator.leavePlayer(OWNER)
            f.timeline.finish(300_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_800_000L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `phone and TV confirmed zero is retained while stale local final writes are suppressed`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(0L)
            f.coordinator.retire(false)
            assertEquals(0L, f.coordinator.takeResume(OWNER)!!.positionMs)
            f.timeline.finish(300_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(0L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `local history resumes only after the returned confirmed point is actually observed`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(1_800_000L)
            f.coordinator.retire(false)
            f.timeline.local(300_000L, DURATION)
            f.timeline.local(1_800_000L, DURATION, buffering = true)
            assertEquals(1_800_000L, f.last()!!.positionMs)
            val engine = Any()
            val baseline = PlayerState(positionMs = 300_000L, durationMs = DURATION, isPaused = true)
            val ticket = f.timeline.beginLocalResume(engine, baseline)!!
            val accepted = PlayerState(positionMs = 1_801_000L, durationMs = DURATION)
            assertTrue(f.timeline.acknowledgeLocalResume(ticket, engine, OWNER, accepted,
                accepted.positionMs, accepted.durationMs, accepted.isBuffering))
            f.timeline.local(1_801_000L, DURATION)
            f.timeline.finish(1_802_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_802_000L to DURATION, f.final.single())
        }
    }

    @Test fun `foreign owner revocation and junk-duration status cannot poison either final cache`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(1_800_000L)
            f.timeline.remote(CastConfirmedProgress("other-owner", 7_199_000L, DURATION), true, null)
            f.status(9_999L, duration = 10_000L)
            assertEquals(1_800_000L, f.last()!!.positionMs)
            f.admitted = false
            f.coordinator.tick(false, 100L)
            f.timeline.finish(300_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_800_000L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `buffering receipt without any confirmed remote point does not suppress local history forever`() = runTest {
        val f = Fixture(this, false)
        f.begin(); runCurrent()
        f.timeline.local(300_000L, DURATION)
        f.start()
        f.coordinator.freshStatus(f.coordinator.binding!!,
            CastSessionCoordinator.Status("load", 7_199_000L, DURATION, false, false, true), 20L)
        f.coordinator.retire(false)
        f.timeline.local(301_000L, DURATION)
        f.end(); advanceUntilIdle()
        assertEquals(301_000L to DURATION, f.final.single())
        assertFalse(f.watched)
    }

    @Test fun `owner cleanup at100ms revokes synchronously before the1sCast timer on both hosts`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(1_800_000L)
            val oldBinding = f.coordinator.binding!!
            val writesBeforeRevocation = f.emitted.size
            f.admitted = false // originalPlaybackOwner.isActive changed before the host's 100 ms poll.
            advanceTimeBy(100L)
            val exactStop = f.coordinator.prepareExit(OWNER, f.admitted)!!
            assertTrue(exactStop.binding.session === f.session)
            assertTrue(exactStop.binding.client === f.client)
            assertEquals("load", exactStop.loadId)
            f.timeline.finish(300_000L, DURATION)
            f.timeline.close()
            assertNull(f.coordinator.tick(false, 1_000L)) // The later Cast clock cannot send a second stop.
            f.coordinator.freshStatus(oldBinding,
                CastSessionCoordinator.Status("load", 7_199_000L, DURATION, true, false, false), 1_001L)
            f.coordinator.detach()
            assertEquals(writesBeforeRevocation, f.emitted.size)
            f.end(); advanceUntilIdle()
            assertEquals(1_800_000L to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `real engine telemetry accepts handback between5s history ticks including zero on both hosts`() = runTest {
        for (tv in listOf(false, true)) for (target in listOf(0L, 1_800_000L)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.timeline.local(300_000L, DURATION)
            f.start(); f.status(target)
            val engine = Any()
            val baseline = PlayerState(positionMs = if (target == 0L) 0L else 300_000L,
                durationMs = DURATION, isPaused = true)
            val telemetry = MutableStateFlow(baseline)
            val observer = launch {
                telemetry.collect { sample ->
                    f.timeline.localResumeTicket?.let { ticket ->
                        f.timeline.acknowledgeLocalResume(ticket, engine, OWNER, sample,
                            sample.positionMs, sample.durationMs, sample.isBuffering)
                    }
                }
            }
            runCurrent() // The existing collector observed the pre-seek state before handback.
            f.timeline.local(baseline.positionMs, DURATION) // history tick at t=0 while Cast owns it.
            advanceTimeBy(1L)
            f.coordinator.retire(false) // Disconnect immediately after the history tick.
            val staleTicket = f.timeline.beginLocalResume(engine, baseline)!!
            val ticket = f.timeline.beginLocalResume(engine, baseline)!! // current mounted seek generation
            val atTarget = PlayerState(positionMs = target, durationMs = DURATION)
            assertFalse(f.timeline.acknowledgeLocalResume(staleTicket, engine, OWNER, atTarget, target, DURATION, false))
            assertFalse(f.timeline.acknowledgeLocalResume(ticket, Any(), OWNER, atTarget, target, DURATION, false))
            assertFalse(f.timeline.acknowledgeLocalResume(ticket, engine, "old-mount", atTarget, target, DURATION, false))
            assertFalse(f.timeline.acknowledgeLocalResume(ticket, engine, OWNER, baseline, target, DURATION, false))
            telemetry.value = atTarget.copy(isBuffering = true)
            runCurrent()
            assertTrue(f.timeline.localResumeTicket === ticket)
            advanceTimeBy(99L)
            telemetry.value = atTarget // real current-engine acknowledgement at t=100 ms, independent of reporting
            runCurrent()
            assertNull(f.timeline.localResumeTicket)
            advanceTimeBy(4_900L)
            telemetry.value = PlayerState(positionMs = target + 5_000L, durationMs = DURATION)
            runCurrent()
            f.timeline.local(telemetry.value.positionMs, telemetry.value.durationMs) // first next 5 s tick
            assertEquals(target + 5_000L, f.last()!!.positionMs)
            f.timeline.finish(target + 6_000L, DURATION)
            observer.cancel(); runCurrent()
            f.end(); advanceUntilIdle()
            assertEquals((target + 6_000L) to DURATION, f.final.single())
            assertFalse(f.watched)
        }
    }

    @Test fun `a5s periodic sample cannot substitute for a missing current engine acknowledgement`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.start(); f.status(1_800_000L)
            f.coordinator.retire(false)
            val engine = Any()
            val baseline = PlayerState(positionMs = 300_000L, durationMs = DURATION)
            f.timeline.beginLocalResume(engine, baseline)
            advanceTimeBy(5_000L)
            f.timeline.local(1_805_000L, DURATION)
            f.timeline.finish(300_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_800_000L to DURATION, f.final.single())
        }
    }

    @Test fun `failed unconfirmed retry cannot replay an old Cast point over resumed local history`() = runTest {
        for (tv in listOf(false, true)) {
            val f = Fixture(this, tv)
            f.begin(); runCurrent()
            f.start(); f.status(1_800_000L)
            f.coordinator.retire(false)
            val engine = Any()
            val baseline = PlayerState(positionMs = 300_000L, durationMs = DURATION)
            val ticket = f.timeline.beginLocalResume(engine, baseline)!!
            val sample = PlayerState(positionMs = 1_800_000L, durationMs = DURATION)
            assertTrue(f.timeline.acknowledgeLocalResume(ticket, engine, OWNER, sample,
                sample.positionMs, sample.durationMs, sample.isBuffering))
            f.timeline.local(1_805_000L, DURATION)
            f.start() // explicit retry has not received its own matching playable status
            f.coordinator.retire(false)
            assertEquals(1_805_000L, f.last()!!.positionMs)
            f.timeline.finish(1_806_000L, DURATION)
            f.end(); advanceUntilIdle()
            assertEquals(1_806_000L to DURATION, f.final.single())
        }
    }

    private class Fixture(scope: CoroutineScope, tv: Boolean) {
        var admitted = true
        var watched = false
        val final = mutableListOf<Pair<Long, Long>>()
        val emitted = mutableListOf<PlayerProgressSnapshot>()
        private val playable = Playable("https://media.example/movie.mp4", "Movie", expectedDurationMs = DURATION)
        private val lifecycle = PlaybackSessionLifecycle(scope,
            beginSession = { _, _ -> PlaybackSessionToken(1L) },
            reportSession = { _, _, _ -> },
            endSession = { _, pos, dur ->
                final += pos to dur
                watched = dur > 0L && pos.toDouble() / dur >= 0.90
                null
            }, nanoClock = { 0L }) // Report throttling cannot conceal or substitute the final transaction.
        private val handle = lifecycle.newHandle()
        private val phone = if (!tv) PlaybackProgressCache(lifecycle, handle) else null
        private val television = if (tv) TvPlaybackHistorySession(PlayerEpisodeHistoryIdentity(playable), lifecycle, null) else null
        val timeline = PlayerProgressTimeline(OWNER, { admitted },
            { pos, dur -> canReportPlayerProgress(playable, pos, dur) },
            { point -> emitted += point; phone?.report(point) ?: television!!.report(point) })
        val coordinator = CastSessionCoordinator(validProgress = { pos, dur -> canReportPlayerProgress(playable, pos, dur) }) {
            timeline.remote(it.point, it.remoteActive, it.resumePositionMs)
        }
        val session = Any(); val client = Any()
        init { coordinator.select(OWNER) }
        fun begin() { if (phone != null) lifecycle.begin(handle) else television!!.begin() }
        fun end() { if (phone != null) phone.end() else television!!.end() }
        fun last(): PlayerProgressSnapshot? = phone?.snapshot ?: television?.lastProgress
        fun start() {
            check(coordinator.chooseRoute(OWNER, "receiver", 0L))
            coordinator.starting(session, "receiver", 1L)
            check(coordinator.begin(coordinator.started(session, client, "receiver", 2L, session)!!, "load", 3L))
        }
        fun status(position: Long, duration: Long = DURATION, paused: Boolean = false) {
            val binding = coordinator.binding ?: return
            coordinator.freshStatus(binding, CastSessionCoordinator.Status("load", position, duration,
                playing = !paused, paused = paused, buffering = false), 50L)
        }
    }
    companion object { private const val OWNER = "mounted-title"; private const val DURATION = 7_200_000L }
}
