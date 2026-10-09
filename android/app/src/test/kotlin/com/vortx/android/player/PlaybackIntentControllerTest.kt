package com.vortx.android.player

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackIntentControllerTest {
    @Test fun `pause survives background foreground`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(engine)
        subject.userPause()
        subject.setBlocked(PlaybackBlocker.BACKGROUND, true)
        subject.setBlocked(PlaybackBlocker.BACKGROUND, false)
        assertFalse(subject.snapshot().shouldPlay)
        assertEquals("pause", engine.actions.last())
    }

    @Test fun `focus gain clears only focus ownership`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(engine)
        subject.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
        subject.userPause()
        subject.setBlocked(PlaybackBlocker.AUDIO_FOCUS, false)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `cast and foreground remain independently blocked`() {
        val subject = PlaybackIntentController()
        subject.setBlocked(PlaybackBlocker.BACKGROUND, true)
        subject.setBlocked(PlaybackBlocker.CAST, true)
        subject.setBlocked(PlaybackBlocker.BACKGROUND, false)
        assertFalse(subject.snapshot().shouldPlay)
        subject.setBlocked(PlaybackBlocker.CAST, false)
        assertTrue(subject.snapshot().shouldPlay)
    }

    @Test fun `replacement engine immediately receives derived cast pause`() {
        val first = RecordingEngine()
        val second = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(first)
        subject.setBlocked(PlaybackBlocker.CAST, true)
        subject.bind(second)
        assertEquals(listOf("pause"), second.actions)
    }

    @Test fun `still watching remains applied across replacement`() {
        val subject = PlaybackIntentController()
        subject.setBlocked(PlaybackBlocker.STILL_WATCHING, true)
        val replacement = RecordingEngine()
        subject.bind(replacement)
        assertEquals(listOf("pause"), replacement.actions)
    }

    @Test fun `media session and pip pauses are durable user intent`() {
        val subject = PlaybackIntentController()
        subject.userPause()
        subject.setBlocked(PlaybackBlocker.SYSTEM, true)
        subject.setBlocked(PlaybackBlocker.SYSTEM, false)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `accepted replacement clears only the old terminal verdict and preserves a manual pause`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(engine)
        subject.userPause()
        subject.setSourceTerminal(true)

        subject.beginReplacementSource()

        assertFalse(subject.snapshot().userWantsPlay)
        assertFalse(subject.snapshot().sourceTerminal)
        assertFalse(subject.snapshot().shouldPlay)
        assertEquals("pause", engine.actions.last())
    }

    @Test fun `accepted replacement resumes only when the viewer had wanted playback`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(engine)
        subject.setSourceTerminal(true)

        subject.beginReplacementSource()

        assertTrue(subject.snapshot().userWantsPlay)
        assertFalse(subject.snapshot().sourceTerminal)
        assertTrue(subject.snapshot().shouldPlay)
        assertEquals("play", engine.actions.last())
    }

    @Test fun `toggle follows displayed pause while focus blocker hides user intent`() {
        val subject = PlaybackIntentController()
        subject.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
        subject.userToggle(currentlyPaused = true)
        assertTrue(subject.snapshot().userWantsPlay)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `toggle follows displayed pause while still watching blocks playback`() {
        val subject = PlaybackIntentController(PlaybackIntentState(userWantsPlay = false))
        subject.setBlocked(PlaybackBlocker.STILL_WATCHING, true)
        subject.userToggle(currentlyPaused = true)
        assertTrue(subject.snapshot().userWantsPlay)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `multiple blockers clear independently`() {
        val subject = PlaybackIntentController()
        subject.setBlocked(PlaybackBlocker.CAST, true)
        subject.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
        subject.setBlocked(PlaybackBlocker.CAST, false)
        assertFalse(subject.snapshot().shouldPlay)
        subject.setBlocked(PlaybackBlocker.AUDIO_FOCUS, false)
        assertTrue(subject.snapshot().shouldPlay)
    }

    @Test fun `delayed engine arriving in background cannot autoplay`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        prepareAndLoadEngine(
            engine = engine,
            playable = com.vortx.android.model.Playable("https://example.invalid/video.mkv", "Video"),
            lifecycleStarted = { false },
            pausePlaybackInBackground = { true },
            playbackIntent = subject,
            refreshAudioRoute = { engine.actions += "route" },
        )
        assertTrue(engine.actions.indexOf("background") < engine.actions.indexOf("load"))
        assertEquals("pause", engine.actions.last())
        subject.setBlocked(PlaybackBlocker.BACKGROUND, false)
        assertEquals("play", engine.actions.last())
    }

    @Test fun `background playback preference avoids transport blocker but keeps resource hook`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        prepareAndLoadEngine(
            engine,
            com.vortx.android.model.Playable("https://example.invalid/video.mkv", "Video"),
            lifecycleStarted = { false },
            pausePlaybackInBackground = { false },
            playbackIntent = subject,
        )
        assertTrue("resource hook must still run", "background" in engine.actions)
        assertTrue(subject.snapshot().shouldPlay)
        assertEquals("play", engine.actions.last())
    }

    @Test fun `stopped transition during async load wins before publication`() {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        var sample = 0
        prepareAndLoadEngine(
            engine,
            com.vortx.android.model.Playable("https://example.invalid/video.mkv", "Video"),
            lifecycleStarted = { sample++ == 0 },
            pausePlaybackInBackground = { true },
            playbackIntent = subject,
        )
        assertFalse(subject.snapshot().shouldPlay)
        assertEquals("pause", engine.actions.last())
        assertTrue(engine.actions.lastIndexOf("background") > engine.actions.indexOf("load"))
    }

    @Test fun `audio focus authority blocks initial engine before request completes`() {
        val subject = PlaybackIntentController()
        val focus = AudioFocusIntentAuthority(subject)
        val generation = focus.beginRequest()
        val engine = RecordingEngine()
        subject.bind(engine)
        assertEquals("pause", engine.actions.last())
        focus.onDeniedDelayedOrLost(generation)
        focus.abandon(generation)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `replacement gap retains focus blocker until current generation gains`() {
        val subject = PlaybackIntentController()
        val focus = AudioFocusIntentAuthority(subject)
        val generation = focus.beginRequest()
        subject.bind(RecordingEngine())
        val replacement = RecordingEngine()
        subject.bind(replacement)
        assertEquals("pause", replacement.actions.last())
        focus.onGrantedOrGained(generation)
        assertEquals("play", replacement.actions.last())
        focus.onDeniedDelayedOrLost(generation)
        assertEquals("pause", replacement.actions.last())
    }

    @Test fun `stale focus callbacks cannot mutate successor generation`() {
        val subject = PlaybackIntentController()
        val focus = AudioFocusIntentAuthority(subject)
        val stale = focus.beginRequest()
        val current = focus.beginRequest()
        focus.onGrantedOrGained(stale)
        assertFalse(subject.snapshot().shouldPlay)
        focus.onDeniedDelayedOrLost(stale)
        focus.abandon(stale)
        assertFalse(subject.snapshot().shouldPlay)
        focus.onGrantedOrGained(current)
        assertTrue(subject.snapshot().shouldPlay)
    }

    @Test fun `stop at explicit publication suspension is reconciled before exposure`() = runBlocking {
        val engine = RecordingEngine()
        val subject = PlaybackIntentController()
        val atBoundary = CompletableDeferred<Unit>()
        val releaseBoundary = CompletableDeferred<Unit>()
        var started = true
        var published = false
        val job = launch {
            reconcileAndPublishEngine(
                engine = engine,
                lifecycleStarted = { started },
                pausePlaybackInBackground = { true },
                playbackIntent = subject,
                beforePublication = {
                    atBoundary.complete(Unit)
                    releaseBoundary.await()
                },
                publish = { published = true },
            )
        }
        atBoundary.await()
        started = false
        releaseBoundary.complete(Unit)
        job.join()
        assertTrue(published)
        assertFalse(subject.snapshot().shouldPlay)
        assertEquals("pause", engine.actions.last())
        assertTrue("resource hook precedes publication", "background" in engine.actions)
    }

    @Test fun `private candidate preparation cannot rebind commands from the published successor`() {
        val stale = RecordingEngine()
        val successor = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(successor)
        subject.userPause()
        prepareAndLoadEngine(stale,
            com.vortx.android.model.Playable("https://example.invalid/video.mkv", "Video"),
            { true }, { true }, subject, bindForCommands = false)
        val staleActions = stale.actions.toList()

        subject.userPlay()
        subject.userPause()

        assertEquals(staleActions, stale.actions)
        assertEquals(listOf("play", "pause"), successor.actions.takeLast(2))
        assertEquals("pause", stale.actions.last())
    }

    @Test fun `retiring an old engine cannot unbind its successor`() {
        val stale = RecordingEngine()
        val successor = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(stale)
        subject.bind(successor)
        subject.unbindIfCurrent(stale)
        subject.userPause()
        assertEquals("pause", successor.actions.last())
        subject.unbindIfCurrent(successor)
        val actions = successor.actions.toList()
        subject.userPlay()
        assertEquals(actions, successor.actions)
    }

    @Test fun `private background candidate cannot pause a live foreground successor`() {
        val successor = RecordingEngine()
        val candidate = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(successor)
        val before = successor.actions.toList()
        prepareAndLoadEngine(candidate,
            com.vortx.android.model.Playable("https://example.invalid/video.mkv", "Video"),
            { false }, { true }, subject, bindForCommands = false)

        assertTrue(subject.snapshot().shouldPlay)
        assertEquals(before, successor.actions)
        assertEquals("pause", candidate.actions.last())
        assertTrue("background" in candidate.actions)
    }

    @Test fun `cancellation at publication boundary never binds or exposes a prepared engine`() = runBlocking {
        val successor = RecordingEngine()
        val candidate = RecordingEngine()
        val subject = PlaybackIntentController()
        subject.bind(successor)
        var published = false
        val job = launch {
            reconcileAndPublishEngine(candidate, { true }, { true }, subject,
                beforePublication = { currentCoroutineContext().cancel() },
                publish = { published = true })
        }
        job.join()
        assertTrue(job.isCancelled)
        assertFalse(published)
        assertTrue(candidate.actions.isEmpty())
        subject.userPause()
        assertEquals("pause", successor.actions.last())
        Unit
    }

    private class RecordingEngine : PlayerEngine {
        override val state = MutableStateFlow(PlayerState())
        val actions = mutableListOf<String>()
        override fun load(playable: com.vortx.android.model.Playable) { actions += "load" }
        override fun play() { actions += "play" }
        override fun pause() { actions += "pause" }
        override fun togglePause() = Unit
        override fun seekTo(positionMs: Long) = Unit
        override fun setPlaybackSpeed(speed: Float) = Unit
        override fun selectAudioTrack(id: Int) = Unit
        override fun selectSubtitleTrack(id: Int?) = Unit
        override fun addExternalSubtitle(url: String) = Unit
        override fun setSubtitleDelay(seconds: Double) = Unit
        override fun onEnterBackground() { actions += "background" }
        override fun onEnterForeground() = Unit
        override fun release() = Unit
        @androidx.compose.runtime.Composable
        override fun VideoSurface(
            modifier: androidx.compose.ui.Modifier,
            emberArgb: Int,
            scaleMode: VideoScaleMode,
        ) = Unit
    }
}
