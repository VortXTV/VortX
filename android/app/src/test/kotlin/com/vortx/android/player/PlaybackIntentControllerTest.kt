package com.vortx.android.player

import kotlinx.coroutines.flow.MutableStateFlow
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

    @Test fun `audio focus blocks before request and denial or abandon never clears it`() {
        val subject = PlaybackIntentController()
        subject.onAudioFocusEvent(AudioFocusIntentEvent.REQUESTED)
        assertFalse(subject.snapshot().shouldPlay)
        subject.onAudioFocusEvent(AudioFocusIntentEvent.DENIED_DELAYED_OR_LOST)
        subject.onAudioFocusEvent(AudioFocusIntentEvent.ABANDONED)
        assertFalse(subject.snapshot().shouldPlay)
    }

    @Test fun `only focus grant or gain clears blocker and replacement inherits it`() {
        val subject = PlaybackIntentController()
        subject.onAudioFocusEvent(AudioFocusIntentEvent.REQUESTED)
        subject.bind(RecordingEngine())
        val replacement = RecordingEngine()
        subject.bind(replacement)
        assertEquals("pause", replacement.actions.last())
        subject.onAudioFocusEvent(AudioFocusIntentEvent.GRANTED_OR_GAINED)
        assertEquals("play", replacement.actions.last())
        subject.onAudioFocusEvent(AudioFocusIntentEvent.DENIED_DELAYED_OR_LOST)
        assertEquals("pause", replacement.actions.last())
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
