package com.vortx.android.player

import androidx.media3.common.MimeTypes
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExoPlayerEngineStatePolicyTest {
    @Test
    fun `error then healthy load starts from fresh per-item state`() {
        val failed = PlayerState(
            positionMs = 42_000L,
            durationMs = 90_000L,
            bufferedPositionMs = 60_000L,
            isBuffering = true,
            hasEnded = true,
            audioTracks = listOf(PlayerTrack(1, "Old audio")),
        ).withPlaybackError()

        assertTrue(failed.hasError)
        val healthy = freshPlayerStateForLoad().withPlaybackStatus(buffering = false, ended = false)

        assertEquals(PlayerState(), healthy)
        assertFalse(healthy.hasError)
        assertFalse(healthy.hasEnded)
        assertTrue(healthy.audioTracks.isEmpty())
    }

    @Test
    fun `ended and error transitions are mutually exclusive`() {
        val error = PlayerState(hasEnded = true, isBuffering = true).withPlaybackError()
        assertTrue(error.hasError)
        assertFalse(error.hasEnded)
        assertFalse(error.isBuffering)

        val ended = error.withPlaybackStatus(buffering = true, ended = true)
        assertTrue(ended.hasEnded)
        assertFalse(ended.hasError)
        assertFalse(ended.isBuffering)
    }

    @Test
    fun `repeated mute and unmute preserve the desired volume`() {
        val firstMute = ExoMuteState().transitionTo(requestedMuted = true, currentVolume = 0.72f)
        val changedWhileMuted = firstMute.state.withRequestedVolume(0.44f)
        val repeatedMute = changedWhileMuted.state.transitionTo(
            requestedMuted = true,
            currentVolume = changedWhileMuted.outputVolume,
        )
        val firstUnmute = repeatedMute.state.transitionTo(requestedMuted = false, currentVolume = repeatedMute.outputVolume)
        val repeatedUnmute = firstUnmute.state.transitionTo(requestedMuted = false, currentVolume = firstUnmute.outputVolume)

        assertEquals(0f, firstMute.outputVolume, 0f)
        assertEquals(0f, changedWhileMuted.outputVolume, 0f)
        assertEquals(0.44f, repeatedMute.state.restoreVolume, 0f)
        assertEquals(0.44f, firstUnmute.outputVolume, 0f)
        assertEquals(0.44f, repeatedUnmute.outputVolume, 0f)
    }

    @Test
    fun `resume admission uses one strict five-second floor`() {
        assertNull(admittedResumePosition(-1L))
        assertNull(admittedResumePosition(0L))
        assertNull(admittedResumePosition(5_000L))
        assertEquals(5_001L, admittedResumePosition(5_001L))
        assertEquals(45_000L, admittedResumePosition(45_000L))
    }

    @Test
    fun `load and callbacks stay wired to state resume and subtitle policies`() {
        val source = readSource("ExoPlayerEngine.kt")
        val loadStart = source.indexOf("override fun load(playable: Playable)")
        val loadEnd = source.indexOf("override fun play()", startIndex = loadStart)
        val load = source.substring(loadStart, loadEnd)
        val adaptiveBranch = load.indexOf("if (playable.audioUrl != null)")

        assertTrue(load.indexOf("_state.value = freshPlayerStateForLoad()") in 0 until adaptiveBranch)
        assertEquals(2, load.split("admittedResumePosition(playable.startPositionMs)").size - 1)
        assertTrue(load.indexOf("val subtitleConfigs =") in 0 until adaptiveBranch)
        assertTrue(source.contains("_state.value = _state.value.withPlaybackError()"))
        assertTrue(source.contains("_state.value = _state.value.withPlaybackStatus("))
    }

    @Test
    fun `trusted ordinary Media3 streams use a redirect-capable default factory`() {
        val source = readSource("ExoPlayerEngine.kt")
        val loadStart = source.indexOf("override fun load(playable: Playable)")
        val loadEnd = source.indexOf("override fun play()", startIndex = loadStart)
        val load = source.substring(loadStart, loadEnd)

        assertTrue(source.contains("val http = DefaultHttpDataSource.Factory().apply"))
        assertTrue(source.contains("setAllowCrossProtocolRedirects(true)"))
        assertTrue(source.contains("DefaultDataSource.Factory(appContext, http)"))
        assertTrue(source.contains("CommunityJsMedia3DataSourceFactory(rootUrl, scopedHeaders)"))
        assertFalse(source.contains("DefaultDataSource.Factory(appContext, CommunityJsMedia3DataSourceFactory"))
        assertTrue(load.contains("val videoDataSource = media3DataSourceFactory"))
        assertTrue(load.contains("SingleSampleMediaSource") || source.contains("SingleSampleMediaSource.Factory"))
        assertFalse(load.contains("else {\n            DefaultMediaSourceFactory(appContext)"))
    }

    @Test
    fun `signed and declared extensionless subtitle urls resolve safely`() {
        assertEquals(
            MimeTypes.APPLICATION_SUBRIP,
            externalSubtitleMimeDecision("https://cdn.example/subtitle.srt?X-Amz-Signature=abc").mimeType,
        )
        assertEquals(
            MimeTypes.TEXT_VTT,
            externalSubtitleMimeDecision("https://cdn.example/subtitle?id=7&format=vtt&sig=abc").mimeType,
        )
        assertEquals(
            MimeTypes.APPLICATION_SUBRIP,
            externalSubtitleMimeDecision(
                "https://cdn.example/download?response-content-disposition=attachment%3B%20filename%3Dmovie.srt&sig=abc",
            ).mimeType,
        )
        assertEquals(
            MimeTypes.APPLICATION_SUBRIP,
            externalSubtitleMimeDecision("https://cdn.example/subtitle.srt?format=vtt&sig=abc").mimeType,
        )
    }

    @Test
    fun `unsafe or opaque extensionless subtitle is rejected with an explicit reason`() {
        listOf(
            "https://cdn.example/subtitle/opaque-token?sig=abc",
            "https://cdn.example/subtitle.xml?sig=abc",
            "https://cdn.example/subtitle?format=%broken",
        ).forEach { url ->
            val decision = externalSubtitleMimeDecision(url)
            assertNull(decision.mimeType)
            assertNotNull(decision.rejectionReason)
        }
    }

    @Test
    fun `capability policy stays explicit and chrome gates unsupported controls`() {
        val engineContract = readSource("PlayerEngine.kt")
        val chrome = readSource("PlayerChrome.kt")

        listOf(
            "subtitleDelayAvailable",
            "audioDelayAvailable",
            "audioOutputModeAvailable",
            "hdrToneMapAvailable",
            "secondarySubtitleAvailable",
            "hardwareDecodingAvailable",
        ).forEach { capability ->
            assertTrue("$capability must default closed", engineContract.contains("val $capability: Boolean get() = false"))
        }
        assertTrue(chrome.contains("if (hardwareDecodingAvailable)"))
        assertTrue(chrome.contains("if (hdrToneMapAvailable)"))
        assertTrue(chrome.contains("if (secondarySubtitleAvailable && state.subtitleTracks.size >= 2)"))
        assertTrue(visibleAudioOutputModes(available = false).isEmpty())
        assertEquals(AudioOutputMode.entries, visibleAudioOutputModes(available = true))
    }

    private fun readSource(name: String): String {
        val sourcePath = sequenceOf(
            Path.of("src/main/kotlin/com/vortx/android/player/$name"),
            Path.of("app/src/main/kotlin/com/vortx/android/player/$name"),
        ).first(Files::exists)
        return String(Files.readAllBytes(sourcePath), StandardCharsets.UTF_8)
    }
}
