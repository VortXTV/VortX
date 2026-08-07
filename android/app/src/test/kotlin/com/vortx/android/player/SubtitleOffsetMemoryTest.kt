package com.vortx.android.player

import com.vortx.android.model.MediaRef
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleOffsetMemoryTest {
    @Test
    fun contentKeyMatchesAppleMovieAndEpisodeShape() {
        assertEquals(
            "imdb:tt0111161",
            subtitleOffsetContentKey(MediaRef(isSeries = false, imdb = "imdb:tt0111161")),
        )
        assertEquals(
            "imdb:tt0903747:0:0",
            subtitleOffsetContentKey(
                MediaRef(isSeries = true, imdb = "0903747", season = 0, episode = 0),
            ),
        )
        assertNull(subtitleOffsetContentKey(MediaRef(isSeries = false, imdb = "tmdb:1399")))
        assertNull(
            subtitleOffsetContentKey(
                MediaRef(isSeries = true, imdb = "tt0903747", season = 1, episode = null),
            ),
        )
    }

    @Test
    fun saveRoundsToPlayerGridAndResetForgetsTitle() {
        val stored = mutateSubtitleOffsetJson(
            raw = null,
            contentKey = "imdb:tt0111161",
            seconds = 1.26,
            updated = 10.0,
        )
        assertEquals(1.3, savedSubtitleOffset(stored, "imdb:tt0111161")!!, 0.0)

        val cleared = mutateSubtitleOffsetJson(
            raw = stored,
            contentKey = "imdb:tt0111161",
            seconds = 0.0,
            updated = 11.0,
        )
        assertNull(savedSubtitleOffset(cleared, "imdb:tt0111161"))
        assertFalse(JSONObject(cleared).has("imdb:tt0111161"))
    }

    @Test
    fun corruptAndUnsafeValuesFailSoft() {
        assertNull(savedSubtitleOffset("not json", "imdb:tt1"))
        assertNull(
            savedSubtitleOffset(
                """{"imdb:tt1":{"seconds":121.0,"updated":1.0}}""",
                "imdb:tt1",
            ),
        )
        assertNull(
            savedSubtitleOffset(
                """{"imdb:tt1":{"seconds":0.0,"updated":1.0}}""",
                "imdb:tt1",
            ),
        )

        val invalidWrite = mutateSubtitleOffsetJson(
            raw = """{"imdb:tt1":{"seconds":1.0,"updated":1.0}}""",
            contentKey = "imdb:tt1",
            seconds = Double.POSITIVE_INFINITY,
            updated = 2.0,
        )
        assertNull(savedSubtitleOffset(invalidWrite, "imdb:tt1"))
    }

    @Test
    fun capacityEvictsLeastRecentlySavedEntries() {
        var raw: String? = null
        repeat(SubtitleOffsetMemory.MAX_ENTRIES + 1) { index ->
            raw = mutateSubtitleOffsetJson(
                raw = raw,
                contentKey = "imdb:tt${index.toString().padStart(7, '0')}",
                seconds = 0.5,
                updated = index.toDouble(),
            )
        }

        val root = JSONObject(raw!!)
        assertEquals(SubtitleOffsetMemory.MAX_ENTRIES, root.length())
        assertFalse(root.has("imdb:tt0000000"))
        assertTrue(root.has("imdb:tt0000600"))
    }

    @Test
    fun `accepted source switch keeps episode offset while using the completion playhead`() {
        val episode = MediaRef(isSeries = true, imdb = "tt0903747", season = 3, episode = 7)
        val contentKey = requireNotNull(subtitleOffsetContentKey(episode))
        val stored = mutateSubtitleOffsetJson(
            raw = null,
            contentKey = contentKey,
            seconds = 1.26,
            updated = 10.0,
        )
        val coordinator = PlayerSourceSwitchCoordinator()
        val sessionId = coordinator.replaceOuterSession()
        val initial = PlayerSourceSwitchState(
            outerSessionId = sessionId,
            playable = Playable(
                url = "https://cdn.example/episode-web.mkv",
                title = "Episode WEB",
                mediaRef = episode,
            ),
            currentSource = source("episode#web", "Episode WEB"),
        )
        val pendingState = beginPlayerSourceSwitch(
            state = initial,
            source = source("episode#remux", "Episode REMUX"),
            authority = requireNotNull(coordinator.beginRequest(sessionId)),
        )
        val pending = requireNotNull(pendingState.pendingSwitch)
        var commits = 0

        val completion = completePlayerSourceSwitch(
            state = pendingState,
            pending = pending,
            result = Result.success(
                PlayerSourceSwitchResolution(
                    playable = Playable(
                        url = "https://cdn.example/episode-remux.mkv",
                        title = "Episode REMUX",
                        startPositionMs = 12_000L,
                        mediaRef = episode,
                    ),
                    commitGate = PlayerSourceSwitchCommitGate(),
                    commitAuthorityIsCurrent = { true },
                    commitAccepted = { commits++ },
                ),
            ),
            latestPositionMs = 73_250L,
        )
        val applied = applyPlayerSourceSwitchCompletion(pendingState, pending, completion) {
            coordinator.isCurrent(pending.authority)
        }
        val switchedContentKey = requireNotNull(subtitleOffsetContentKey(applied.playable.mediaRef))

        assertEquals(73_250L, applied.playable.startPositionMs)
        assertTrue(applied.playable.userForcedSource)
        assertEquals(1, commits)
        assertNotEquals(initial.sessionKey, applied.sessionKey)
        assertEquals(contentKey, switchedContentKey)
        assertEquals(1.3, savedSubtitleOffset(stored, switchedContentKey)!!, 0.0)
    }

    @Test
    fun `stale same-handle completion cannot replace a newer episode or its offset`() {
        val firstEpisode = MediaRef(isSeries = true, imdb = "tt0903747", season = 3, episode = 7)
        val nextEpisode = firstEpisode.copy(episode = 8)
        val firstKey = requireNotNull(subtitleOffsetContentKey(firstEpisode))
        val nextKey = requireNotNull(subtitleOffsetContentKey(nextEpisode))
        val firstStored = mutateSubtitleOffsetJson(null, firstKey, 1.0, updated = 10.0)
        val stored = mutateSubtitleOffsetJson(firstStored, nextKey, -0.7, updated = 11.0)
        val coordinator = PlayerSourceSwitchCoordinator()
        val firstSessionId = coordinator.replaceOuterSession()
        val stalePending = requireNotNull(
            beginPlayerSourceSwitch(
                state = PlayerSourceSwitchState(
                    outerSessionId = firstSessionId,
                    playable = Playable(
                        url = "https://cdn.example/episode-seven.mkv",
                        title = "Episode 7",
                        mediaRef = firstEpisode,
                    ),
                    currentSource = null,
                ),
                source = source("same#episode-seven", "Episode 7 alternate"),
                authority = requireNotNull(coordinator.beginRequest(firstSessionId)),
            ).pendingSwitch,
        )

        val nextSessionId = coordinator.replaceOuterSession()
        val currentState = beginPlayerSourceSwitch(
            state = PlayerSourceSwitchState(
                outerSessionId = nextSessionId,
                playable = Playable(
                    url = "https://cdn.example/episode-eight.mkv",
                    title = "Episode 8",
                    startPositionMs = 8_000L,
                    mediaRef = nextEpisode,
                ),
                currentSource = null,
            ),
            source = source("same#episode-eight", "Episode 8 alternate"),
            authority = requireNotNull(coordinator.beginRequest(nextSessionId)),
        )
        var commits = 0
        val staleCompletion = completePlayerSourceSwitch(
            state = currentState,
            pending = stalePending,
            result = Result.success(
                PlayerSourceSwitchResolution(
                    playable = Playable(
                        url = "https://cdn.example/stale-episode-seven.mkv",
                        title = "Stale episode 7",
                        mediaRef = firstEpisode,
                    ),
                    commitGate = PlayerSourceSwitchCommitGate(),
                    commitAuthorityIsCurrent = { true },
                    commitAccepted = { commits++ },
                ),
            ),
            latestPositionMs = 99_000L,
        )
        val applied = applyPlayerSourceSwitchCompletion(currentState, stalePending, staleCompletion) {
            coordinator.isCurrent(stalePending.authority)
        }
        val activeKey = requireNotNull(subtitleOffsetContentKey(applied.playable.mediaRef))

        assertFalse(staleCompletion.requestAccepted)
        assertEquals(currentState, applied)
        assertEquals(0, commits)
        assertEquals(nextKey, activeKey)
        assertEquals(-0.7, savedSubtitleOffset(stored, activeKey)!!, 0.0)
        assertEquals(8_000L, applied.playable.startPositionMs)
        assertFalse(applied.playable.userForcedSource)
    }

    @Test
    fun `player integration keeps subtitle memory and live appearance on corrected switch authority`() {
        val screen = readProjectFile("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")
        val chrome = readProjectFile("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")
        val switching = readProjectFile("src/main/kotlin/com/vortx/android/player/PlayerSourceSwitching.kt")
        val screenRequirements = listOf(
            "val sourceSwitchCoordinator = remember { PlayerSourceSwitchCoordinator() }",
            "sourceSwitchCoordinator.replaceOuterSession()",
            "sourceSwitchCoordinator.invalidateIfCurrent(outerPlaybackSessionId)",
            "val subtitleContentKey = remember(playbackSessionKey)",
            "SubtitleOffsetMemory.savedOffset(context, subtitleContentKey)",
            "SubtitleOffsetMemory.save(context, subtitleDelaySeconds, subtitleContentKey)",
            "SubtitleStyle.save(context, next)",
            "engine.applySubtitleStyle()",
            "LaunchedEffect(pendingSourceSwitch?.authority)",
            "resolveAndApplyPlayerSourceSwitch(",
            "latestPositionMs = { latestState.positionMs }",
        )
        val chromeRequirements = listOf(
            "subtitleStyle: SubtitleStyle",
            "onChangeSubtitleStyle: (SubtitleStyle) -> Unit",
            "style = subtitleStyle",
            "onChangeStyle = onChangeSubtitleStyle",
            "SubtitleStyle.brightnessLevels.forEach",
            "SubtitleStyle.backgrounds.forEach",
        )

        assertTrue(subtitlePlayerIntegrationIsComplete(screen, chrome, switching))
        screenRequirements.forEach { requirement ->
            assertFalse(
                "screen contract must reject removal of $requirement",
                subtitlePlayerIntegrationIsComplete(
                    screen.replace(requirement, "REMOVED_SCREEN_REQUIREMENT"),
                    chrome,
                    switching,
                ),
            )
        }
        chromeRequirements.forEach { requirement ->
            assertFalse(
                "chrome contract must reject removal of $requirement",
                subtitlePlayerIntegrationIsComplete(
                    screen,
                    chrome.replace(requirement, "REMOVED_CHROME_REQUIREMENT"),
                    switching,
                ),
            )
        }
        assertFalse(
            "source switching must mark an accepted manual choice as forced",
            subtitlePlayerIntegrationIsComplete(
                screen,
                chrome,
                switching.replace(".copy(userForcedSource = true)", ".copy(userForcedSource = false)"),
            ),
        )
    }

    private fun subtitlePlayerIntegrationIsComplete(
        screen: String,
        chrome: String,
        switching: String,
    ): Boolean {
        val screenRequirements = listOf(
            "val sourceSwitchCoordinator = remember { PlayerSourceSwitchCoordinator() }",
            "sourceSwitchCoordinator.replaceOuterSession()",
            "sourceSwitchCoordinator.invalidateIfCurrent(outerPlaybackSessionId)",
            "val subtitleContentKey = remember(playbackSessionKey)",
            "SubtitleOffsetMemory.savedOffset(context, subtitleContentKey)",
            "SubtitleOffsetMemory.save(context, subtitleDelaySeconds, subtitleContentKey)",
            "SubtitleStyle.save(context, next)",
            "engine.applySubtitleStyle()",
            "LaunchedEffect(pendingSourceSwitch?.authority)",
            "resolveAndApplyPlayerSourceSwitch(",
            "latestPositionMs = { latestState.positionMs }",
        )
        val chromeRequirements = listOf(
            "subtitleStyle: SubtitleStyle",
            "onChangeSubtitleStyle: (SubtitleStyle) -> Unit",
            "style = subtitleStyle",
            "onChangeStyle = onChangeSubtitleStyle",
            "SubtitleStyle.brightnessLevels.forEach",
            "SubtitleStyle.backgrounds.forEach",
        )
        return screenRequirements.all(screen::contains) &&
            chromeRequirements.all(chrome::contains) &&
            switching.contains(".copy(userForcedSource = true)")
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }

    private fun source(id: String, title: String): StreamSource = StreamSource(
        id = id,
        addon = "Provider",
        title = title,
        url = "https://cdn.example/$id",
    )
}
