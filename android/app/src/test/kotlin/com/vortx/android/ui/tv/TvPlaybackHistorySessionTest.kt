package com.vortx.android.ui.tv

import com.vortx.android.data.PlaybackSessionLifecycle
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.model.Playable
import com.vortx.android.player.PlayerEpisodeHistoryIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TvPlaybackHistorySessionTest {
    @Test
    fun `near complete trailer cannot overwrite or finish resident movie or episode`() = runTest {
        listOf("movie", "episode").forEach { residentKind ->
            val events = mutableListOf<String>()
            var residentResumeMs = 37_000L
            var residentWatched = false
            var generation = 0L
            val lifecycle = PlaybackSessionLifecycle(
                scope = this,
                beginSession = {
                    val token = PlaybackSessionToken(++generation)
                    events += "begin-${token.generation}"
                    token
                },
                reportSession = { token, positionMs, durationMs ->
                    events += "report-${token.generation}-$positionMs-$durationMs"
                    residentResumeMs = positionMs
                },
                endSession = { token, positionMs, durationMs ->
                    events += "end-${token.generation}-$positionMs-$durationMs"
                    residentResumeMs = positionMs
                    residentWatched = durationMs > 0L &&
                        positionMs.toDouble() / durationMs.toDouble() >= 0.90
                },
            )
            val trailer = TvPlaybackHistorySession(
                historyIdentity = PlayerEpisodeHistoryIdentity(
                    playable(title = "$residentKind trailer", isTrailer = true),
                ),
                playbackSessions = lifecycle,
            )

            trailer.begin()
            trailer.report(positionMs = 60_000L, durationMs = 120_000L)
            trailer.report(positionMs = 119_000L, durationMs = 120_000L)
            trailer.end()
            advanceUntilIdle()

            assertEquals("$residentKind history calls", emptyList<String>(), events)
            assertEquals("$residentKind resume", 37_000L, residentResumeMs)
            assertFalse("$residentKind watched", residentWatched)
        }
    }

    @Test
    fun `ordinary playback keeps ordered replacement and rejects a stale report`() = runTest {
        val events = mutableListOf<String>()
        val allowFirstEnd = CompletableDeferred<Unit>()
        val allowStaleReport = CompletableDeferred<Unit>()
        var activeToken: PlaybackSessionToken? = null
        var generation = 0L
        val lifecycle = PlaybackSessionLifecycle(
            scope = this,
            beginSession = {
                val token = PlaybackSessionToken(++generation)
                activeToken = token
                events += "begin-${token.generation}"
                token
            },
            reportSession = { token, positionMs, durationMs ->
                events += "report-${token.generation}-start"
                if (token.generation == 1L) allowStaleReport.await()
                if (token == activeToken) {
                    events += "report-${token.generation}-accepted-$positionMs-$durationMs"
                } else {
                    events += "report-${token.generation}-rejected"
                }
            },
            endSession = { token, positionMs, durationMs ->
                events += "end-${token.generation}-start-$positionMs-$durationMs"
                if (token.generation == 1L) allowFirstEnd.await()
                if (token == activeToken) activeToken = null
                events += "end-${token.generation}-finish"
            },
        )
        val first = TvPlaybackHistorySession(
            historyIdentity = PlayerEpisodeHistoryIdentity(
                playable(title = "resident movie", isTrailer = false),
            ),
            playbackSessions = lifecycle,
        )
        val replacement = TvPlaybackHistorySession(
            historyIdentity = PlayerEpisodeHistoryIdentity(
                playable(title = "resident episode", isTrailer = false),
            ),
            playbackSessions = lifecycle,
        )

        first.begin()
        runCurrent()
        first.report(positionMs = 40_000L, durationMs = 100_000L)
        runCurrent()
        first.end()
        replacement.begin()
        runCurrent()

        assertEquals(
            listOf(
                "begin-1",
                "report-1-start",
                "end-1-start-40000-100000",
            ),
            events,
        )

        allowFirstEnd.complete(Unit)
        runCurrent()
        assertEquals(
            listOf(
                "begin-1",
                "report-1-start",
                "end-1-start-40000-100000",
                "end-1-finish",
                "begin-2",
            ),
            events,
        )

        allowStaleReport.complete(Unit)
        advanceUntilIdle()
        replacement.report(positionMs = 91_000L, durationMs = 100_000L)
        advanceUntilIdle()
        replacement.end()
        advanceUntilIdle()

        assertEquals(
            listOf(
                "begin-1",
                "report-1-start",
                "end-1-start-40000-100000",
                "end-1-finish",
                "begin-2",
                "report-1-rejected",
                "report-2-start",
                "report-2-accepted-91000-100000",
                "end-2-start-91000-100000",
                "end-2-finish",
            ),
            events,
        )
        assertEquals(null, activeToken)
    }

    private fun playable(title: String, isTrailer: Boolean): Playable = Playable(
        url = "https://example.invalid/${title.replace(' ', '-')}",
        title = title,
        isTrailer = isTrailer,
    )
}
