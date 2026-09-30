package com.vortx.android.skip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoSkipCountdownPolicyTest {
    private val intro = SkipSegment(SkipSegment.Kind.INTRO, start = 5.0, end = 42.0)

    @Test
    fun `five active playback seconds produce one skip and no initial seek`() {
        val state = AutoSkipCountdownState()
        val first = AutoSkipCountdownPolicy.advance(
            state = state,
            mediaId = "episode-1",
            segment = intro,
            positionMs = 5_000,
            playbackActive = true,
            delaySeconds = 5.0,
        )
        assertEquals(AutoSkipCountdownDecision.Prompt(AutoSkipSegmentKey(intro), 5.0), first)

        (6..9).forEach { position ->
            val decision = AutoSkipCountdownPolicy.advance(
                state, "episode-1", intro, position * 1_000L, playbackActive = true, delaySeconds = 5.0,
            )
            assertTrue(decision is AutoSkipCountdownDecision.Prompt)
        }
        val completed = AutoSkipCountdownPolicy.advance(
            state, "episode-1", intro, 10_000, playbackActive = true, delaySeconds = 5.0,
        )
        assertEquals(
            AutoSkipCountdownDecision.Skip(AutoSkipSegmentKey(intro), 42_000, state.epoch),
            completed,
        )
        assertFalse(state.isSuppressed(intro))
    }

    @Test
    fun `skip candidate is not completed until the guarded seek commits`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-commit", intro, 5_000, playbackActive = true, delaySeconds = 1.0)
        val candidate = AutoSkipCountdownPolicy.advance(
            state,
            "episode-commit",
            intro,
            6_000,
            playbackActive = true,
            delaySeconds = 1.0,
        )
        assertTrue(candidate is AutoSkipCountdownDecision.Skip)
        assertFalse(state.isSuppressed(intro))
        assertTrue(
            AutoSkipCountdownPolicy.completeIfCurrent(
                state,
                intro,
                (candidate as AutoSkipCountdownDecision.Skip).epoch,
            ),
        )
        assertTrue(state.isSuppressed(intro))
    }

    @Test
    fun `detached policy copy leaves the observable source state untouched`() {
        val source = AutoSkipCountdownState(mediaId = "episode-copy")
        val working = source.detachedCopy()

        AutoSkipCountdownPolicy.cancel(working, intro)

        assertFalse(source.isSuppressed(intro))
        assertTrue(working.isSuppressed(intro))
        assertNotEquals(source, working)
    }

    @Test
    fun `pause and buffering do not spend countdown`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-pause", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
        val paused = AutoSkipCountdownPolicy.advance(state, "episode-pause", intro, 5_000, playbackActive = false, delaySeconds = 5.0)
        assertEquals(AutoSkipCountdownDecision.Prompt(AutoSkipSegmentKey(intro), 5.0), paused)
        val buffering = AutoSkipCountdownPolicy.advance(state, "episode-pause", intro, 5_000, playbackActive = false, delaySeconds = 5.0)
        assertEquals(AutoSkipCountdownDecision.Prompt(AutoSkipSegmentKey(intro), 5.0), buffering)
    }

    @Test
    fun `pause after an eligible candidate keeps a prompt and never commits`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-paused-candidate", intro, 5_000, playbackActive = true, delaySeconds = 1.0)
        assertTrue(
            AutoSkipCountdownPolicy.advance(
                state,
                "episode-paused-candidate",
                intro,
                6_000,
                playbackActive = true,
                delaySeconds = 1.0,
            ) is AutoSkipCountdownDecision.Skip,
        )
        val paused = AutoSkipCountdownPolicy.advance(
            state,
            "episode-paused-candidate",
            intro,
            6_000,
            playbackActive = false,
            delaySeconds = 1.0,
        )
        assertTrue(paused is AutoSkipCountdownDecision.Prompt)
        assertFalse(state.isSuppressed(intro))
    }

    @Test
    fun `cancel suppresses segment even after a manual seek back`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-cancel", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
        AutoSkipCountdownPolicy.cancel(state, intro)
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(state, "episode-cancel", intro, 6_000, playbackActive = true, delaySeconds = 5.0),
        )
        AutoSkipCountdownPolicy.invalidatePending(state, 5_000)
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(state, "episode-cancel", intro, 5_000, playbackActive = true, delaySeconds = 5.0),
        )
    }

    @Test
    fun `seek outside invalidates stale pending action`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-seek", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
        val oldEpoch = state.epoch
        AutoSkipCountdownPolicy.invalidatePending(state, 60_000)
        assertTrue(state.epoch != oldEpoch)
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(state, "episode-seek", null, 60_000, playbackActive = true, delaySeconds = 5.0),
        )
        val reentry = AutoSkipCountdownPolicy.advance(state, "episode-seek", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
        assertEquals(AutoSkipCountdownDecision.Prompt(AutoSkipSegmentKey(intro), 5.0), reentry)
    }

    @Test
    fun `stale owner epoch cannot commit an identical segment after seek and reentry`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-identical", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
        val staleEpoch = state.epoch
        AutoSkipCountdownPolicy.invalidatePending(state, 90_000)
        AutoSkipCountdownPolicy.advance(state, "episode-identical", intro, 5_000, playbackActive = true, delaySeconds = 1.0)

        assertFalse(AutoSkipCountdownPolicy.completeIfCurrent(state, intro, staleEpoch))
        assertFalse(state.isSuppressed(intro))
    }

    @Test
    fun `automatic target is clamped to media duration`() {
        val longIntro = intro.copy(end = 110.0)
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-end", longIntro, 5_000, 100_000, playbackActive = true, delaySeconds = 1.0)
        val decision = AutoSkipCountdownPolicy.advance(state, "episode-end", longIntro, 6_000, 100_000, playbackActive = true, delaySeconds = 1.0)
        assertEquals(AutoSkipCountdownDecision.Skip(AutoSkipSegmentKey(longIntro), 100_000, state.epoch), decision)
        assertFalse(state.isSuppressed(longIntro))
    }

    @Test
    fun `source rebind retains completion while new media resets it`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.bindMedia(state, "episode-source-swap")
        AutoSkipCountdownPolicy.complete(state, intro)
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(state, "episode-source-swap", intro, 5_000, playbackActive = true, delaySeconds = 5.0),
        )
        AutoSkipCountdownPolicy.bindMedia(state, "episode-new")
        assertTrue(
            AutoSkipCountdownPolicy.advance(state, "episode-new", intro, 5_000, playbackActive = true, delaySeconds = 5.0)
                is AutoSkipCountdownDecision.Prompt,
        )
    }

    @Test
    fun `same media source rebind retains cancellation while a new episode resets it`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(
            state,
            "episode-cancel-rebind",
            intro,
            5_000,
            playbackActive = true,
            delaySeconds = 5.0,
        )
        AutoSkipCountdownPolicy.cancel(state, intro)
        AutoSkipCountdownPolicy.bindMedia(state, "episode-cancel-rebind")
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(
                state,
                "episode-cancel-rebind",
                intro,
                6_000,
                playbackActive = true,
                delaySeconds = 5.0,
            ),
        )
        AutoSkipCountdownPolicy.bindMedia(state, "episode-cancel-new")
        assertTrue(
            AutoSkipCountdownPolicy.advance(
                state,
                "episode-cancel-new",
                intro,
                5_000,
                playbackActive = true,
                delaySeconds = 5.0,
            ) is AutoSkipCountdownDecision.Prompt,
        )
    }

    @Test
    fun `saved false and Off delay do not auto-skip`() {
        val state = AutoSkipCountdownState()
        assertEquals(
            AutoSkipCountdownDecision.Idle,
            AutoSkipCountdownPolicy.advance(state, "episode-off", intro, 5_000, playbackActive = true, delaySeconds = 0.0),
        )
        assertEquals(
            AutoSkipCountdownDecision.Prompt(AutoSkipSegmentKey(intro), 5.0),
            AutoSkipCountdownPolicy.advance(state, "episode-default", intro, 5_000, playbackActive = true, delaySeconds = 5.0),
        )
    }

    @Test
    fun `manual completion remains available when automatic delay is Off`() {
        val state = AutoSkipCountdownState()
        AutoSkipCountdownPolicy.advance(state, "episode-manual-off", intro, 5_000, playbackActive = true, delaySeconds = 0.0)
        AutoSkipCountdownPolicy.complete(state, intro)
        assertTrue(state.isSuppressed(intro))
    }
}
