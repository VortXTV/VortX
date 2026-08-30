package com.vortx.android.player

import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class MpvEngineFactoryTest {
    @Test fun `missing native library falls back`() {
        assertNull(MpvEngineFactory.createSafely { throw UnsatisfiedLinkError("missing") })
    }

    @Test fun `native class initializer failure falls back`() {
        assertNull(MpvEngineFactory.createSafely { throw ExceptionInInitializerError("init") })
    }

    @Test fun `ordinary construction failure falls back`() {
        assertNull(MpvEngineFactory.createSafely { throw IllegalStateException("init") })
    }

    @Test fun `null remains unavailable`() {
        assertNull(MpvEngineFactory.createSafely { null })
    }

    @Test fun `successful engine is returned unchanged`() {
        val expected = StubEngine()
        assertSame(expected, MpvEngineFactory.createSafely { expected })
    }

    private class StubEngine : PlayerEngine {
        override val state = MutableStateFlow(PlayerState())
        override fun load(playable: com.vortx.android.model.Playable) = Unit
        override fun play() = Unit
        override fun pause() = Unit
        override fun togglePause() = Unit
        override fun seekTo(positionMs: Long) = Unit
        override fun setPlaybackSpeed(speed: Float) = Unit
        override fun selectAudioTrack(id: Int) = Unit
        override fun selectSubtitleTrack(id: Int?) = Unit
        override fun addExternalSubtitle(url: String) = Unit
        override fun setSubtitleDelay(seconds: Double) = Unit
        override fun onEnterBackground() = Unit
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
