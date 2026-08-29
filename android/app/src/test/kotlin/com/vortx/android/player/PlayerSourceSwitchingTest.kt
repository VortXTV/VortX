package com.vortx.android.player

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerSourceSwitchingTest {
    @Test
    fun `replacement playable preserves the captured position`() {
        val replacement = Playable(url = "https://cdn.example/new.mkv", title = "New")

        assertEquals(83_421L, replacement.atSourceSwitchPosition(83_421L).startPositionMs)
        assertEquals(0L, replacement.atSourceSwitchPosition(-50L).startPositionMs)
    }

    @Test
    fun `current source checkmark survives cache decoration`() {
        val current = source("https://cdn.example/movie.mkv#name", "Movie 1080p WEB")
        val decorated = current.copy(id = "https://cdn.example/movie.mkv\u0000cached")
        val alternate = source("https://cdn.example/alternate.mkv", "Movie 720p WEB")

        val choices = playerSourceChoices(listOf(decorated, alternate), current)

        assertTrue(choices.first().selected)
        assertFalse(choices.last().selected)
    }

    @Test
    fun `quality choices use the ranked best source per resolution`() {
        val web1080 = source("web-1080", "Movie 1080p WEB")
        val remux1080 = source("remux-1080", "Movie 1080p REMUX 18 GB")
        val web4k = source("web-4k", "Movie 2160p WEB 9 GB")
        val options = StreamRanking.resolutionOptions(
            listOf(StreamGroup("Provider", listOf(web1080, remux1080, web4k))),
        )

        assertEquals("remux-1080", options.single { it.first == "1080p" }.second.id)
        val choices = playerQualityChoices(options, remux1080)
        assertTrue(choices.single { it.label == "1080p" }.selected)
        assertFalse(choices.single { it.label == "4K" }.selected)
    }

    @Test
    fun `source audio hint reorders conservatively without hiding sources or inventing tracks`() {
        val french = source("fr", "Movie 1080p French WEB")
        val unknown = source("unknown", "Movie 1080p WEB")
        val english = source("en", "Movie 1080p English WEB")

        val ranked = playerSourceChoices(listOf(french, unknown, english), currentSource = null, audioLanguageHint = "en")

        assertEquals(listOf("en", "unknown", "fr"), ranked.map { it.source.id })
        assertEquals(setOf("en", "unknown", "fr"), ranked.map { it.source.id }.toSet())
        val actual = TrackSelector.select(
            audio = listOf(PlayerTrack(id = 7, lang = "fr", title = "French")),
            subtitles = emptyList(),
            preferences = com.vortx.android.model.TrackPreferences(
                audioLanguages = listOf("en"),
                subtitleLanguages = listOf("en"),
                forcedPolicy = com.vortx.android.model.TrackPreferences.ForcedPolicy.OFF,
                rejectTerms = emptyList(),
            ),
        )
        assertNull(actual.audioId)
    }

    @Test
    fun `failed switch retains the playing source and session key`() {
        val current = source("current", "Movie 1080p")
        val alternate = source("alternate", "Movie 4K")
        val playable = Playable(url = "https://cdn.example/current.mkv", title = "Current")
        val authorities = PlayerSourceSwitchCoordinator()
        val sessionId = authorities.replaceOuterSession()
        val initial = PlayerSourceSwitchState(sessionId, playable, current)
        val pendingState = beginPlayerSourceSwitch(initial, alternate, authorities.request(sessionId))
        val pending = requireNotNull(pendingState.pendingSwitch)

        val failed = completePlayerSourceSwitch(
            state = pendingState,
            pending = pending,
            result = Result.failure(IllegalStateException("resolver offline")),
            latestPositionMs = 91_000L,
        )
        val applied = applyPlayerSourceSwitchCompletion(pendingState, pending, failed) { true }

        assertSame(playable, applied.playable)
        assertSame(current, applied.currentSource)
        assertEquals(initial.sessionKey, applied.sessionKey)
        assertEquals("resolver offline", applied.errorMessage)
    }

    @Test
    fun `successful switch rekeys engine state even for the same resolved url`() {
        val current = source("current", "Movie 1080p WEB")
        val alternate = source("alternate", "Movie 1080p REMUX")
        val playable = Playable(url = "https://cdn.example/shared.mkv", title = "Current")
        val authorities = PlayerSourceSwitchCoordinator()
        val sessionId = authorities.replaceOuterSession()
        val initial = PlayerSourceSwitchState(sessionId, playable, current)
        val replacement = playable.copy(title = "Alternate")
        val pendingState = beginPlayerSourceSwitch(initial, alternate, authorities.request(sessionId))
        val pending = requireNotNull(pendingState.pendingSwitch)

        val completion = completePlayerSourceSwitch(
            state = pendingState,
            pending = pending,
            result = Result.success(resolution(replacement)),
            latestPositionMs = 42_000L,
        )
        val switched = applyPlayerSourceSwitchCompletion(pendingState, pending, completion) { true }

        assertEquals(replacement.copy(startPositionMs = 42_000L, userForcedSource = true), switched.playable)
        assertSame(alternate, switched.currentSource)
        assertEquals(1L, switched.revision)
        assertNotEquals(initial.sessionKey, switched.sessionKey)
    }

    @Test
    fun `old same-handle completion cannot enter a newer outer session or request`() {
        val authorities = PlayerSourceSwitchCoordinator()
        val sameHandle = source("same#old", "Movie 1080p")
        val firstSessionId = authorities.replaceOuterSession()
        val firstPendingState = beginPlayerSourceSwitch(
            PlayerSourceSwitchState(
                firstSessionId,
                Playable("https://cdn.example/first.mkv", "First"),
                currentSource = null,
            ),
            sameHandle,
            authorities.request(firstSessionId),
        )
        val stalePending = requireNotNull(firstPendingState.pendingSwitch)

        val secondSessionId = authorities.replaceOuterSession()
        val newerPendingState = beginPlayerSourceSwitch(
            PlayerSourceSwitchState(
                secondSessionId,
                Playable("https://cdn.example/second.mkv", "Second"),
                currentSource = null,
            ),
            sameHandle.copy(id = "same#new"),
            authorities.request(secondSessionId),
        )
        var commits = 0
        val stale = completePlayerSourceSwitch(
            state = newerPendingState,
            pending = stalePending,
            result = Result.success(
                resolution(Playable("https://cdn.example/stale.mkv", "Stale")) { commits++ },
            ),
            latestPositionMs = 73_000L,
        )

        assertFalse(stale.requestAccepted)
        assertNull(stale.resolution)
        assertEquals(newerPendingState, applyPlayerSourceSwitchCompletion(newerPendingState, stalePending, stale) { true })
        assertEquals(0, commits)
        assertEquals(1L, stalePending.authority.requestId)
        assertEquals(2L, requireNotNull(newerPendingState.pendingSwitch).authority.requestId)
        assertEquals(stalePending.sourceHandle, newerPendingState.pendingSwitch?.sourceHandle)
    }

    @Test
    fun `accepted old completion cannot commit after a newer outer session replaces it`() {
        val authorities = PlayerSourceSwitchCoordinator()
        val sameHandle = source("same#old", "Movie 1080p")
        val firstSessionId = authorities.replaceOuterSession()
        val firstPendingState = beginPlayerSourceSwitch(
            PlayerSourceSwitchState(
                firstSessionId,
                Playable("https://cdn.example/first.mkv", "First"),
                currentSource = null,
            ),
            sameHandle,
            authorities.request(firstSessionId),
        )
        val stalePending = requireNotNull(firstPendingState.pendingSwitch)
        var commits = 0
        val acceptedBeforeReplacement = completePlayerSourceSwitch(
            state = firstPendingState,
            pending = stalePending,
            result = Result.success(
                resolution(Playable("https://cdn.example/stale.mkv", "Stale")) { commits++ },
            ),
            latestPositionMs = 73_000L,
        )

        val secondSessionId = authorities.replaceOuterSession()
        val secondState = PlayerSourceSwitchState(
            outerSessionId = secondSessionId,
            playable = Playable("https://cdn.example/second.mkv", "Second"),
            currentSource = sameHandle.copy(id = "same#new"),
            revision = 7L,
        )

        assertEquals(
            secondState,
            applyPlayerSourceSwitchCompletion(secondState, stalePending, acceptedBeforeReplacement) { true },
        )
        assertEquals(0, commits)
    }

    @Test
    fun `non cooperative resolver cannot mutate replacement host with the same source handle`() = runBlocking {
        val coordinator = PlayerSourceSwitchCoordinator()
        val sourceA = source("same#session-a", "Session A source")
        val sourceB = source("same#session-b", "Session B source")
        assertEquals(playerSourceHandle(sourceA), playerSourceHandle(sourceB))

        val outerA = coordinator.replaceOuterSession()
        val stateA = beginPlayerSourceSwitch(
            PlayerSourceSwitchState(
                outerSessionId = outerA,
                playable = Playable("https://cdn.example/session-a.mkv", "Session A"),
                currentSource = null,
            ),
            sourceA,
            coordinator.request(outerA),
        )
        val pendingA = requireNotNull(stateA.pendingSwitch)
        var hostState = stateA
        var resolverReturns = 0
        var commitCallbacks = 0
        var stickyWrites = 0
        var lastPlayedSource: StreamSource? = sourceB
        val resolverStarted = CompletableDeferred<Unit>()
        val releaseResolver = CompletableDeferred<Unit>()
        val staleResolution = PlayerSourceSwitchResolution(
            playable = Playable("https://cdn.example/stale-a.mkv", "Stale A"),
            commitGate = PlayerSourceSwitchCommitGate(),
            commitAuthorityIsCurrent = { true },
            commitAccepted = {
                commitCallbacks++
                lastPlayedSource = sourceA
                stickyWrites++
            },
        )
        val resolverJob = launch {
            resolveAndApplyPlayerSourceSwitch(
                coordinator = coordinator,
                pending = pendingA,
                resolver = {
                    try {
                        withContext(NonCancellable) {
                            resolverStarted.complete(Unit)
                            releaseResolver.await()
                        }
                    } catch (_: CancellationException) {
                        // Deliberately swallow host cancellation to model a hostile resolver.
                    }
                    resolverReturns++
                    Result.success(staleResolution)
                },
                currentState = { hostState },
                latestPositionMs = { 44_000L },
                publishState = { hostState = it },
            )
        }
        withTimeout(5_000L) { resolverStarted.await() }

        val outerB = coordinator.replaceOuterSession()
        val stateB = PlayerSourceSwitchState(
            outerSessionId = outerB,
            playable = Playable("https://cdn.example/session-b.mkv", "Session B"),
            currentSource = sourceB,
            revision = 7L,
        )
        hostState = stateB
        resolverJob.cancel()
        releaseResolver.complete(Unit)
        withTimeout(5_000L) { resolverJob.join() }

        assertEquals(1, resolverReturns)
        assertEquals(stateB.playable, hostState.playable)
        assertSame(stateB.currentSource, hostState.currentSource)
        assertEquals(stateB.revision, hostState.revision)
        assertEquals(0, commitCallbacks)
        assertSame(sourceB, lastPlayedSource)
        assertEquals(0, stickyWrites)

        val sourceBReplacement = source("replacement-b", "Session B replacement")
        hostState = beginPlayerSourceSwitch(hostState, sourceBReplacement, coordinator.request(outerB))
        val pendingB = requireNotNull(hostState.pendingSwitch)
        resolveAndApplyPlayerSourceSwitch(
            coordinator = coordinator,
            pending = pendingB,
            resolver = {
                Result.success(
                    resolution(Playable("https://cdn.example/replacement-b.mkv", "Replacement B")) {
                        commitCallbacks++
                        lastPlayedSource = sourceBReplacement
                        stickyWrites++
                    },
                )
            },
            currentState = { hostState },
            latestPositionMs = { 52_000L },
            publishState = { hostState = it },
        )

        assertEquals(8L, hostState.revision)
        assertSame(sourceBReplacement, hostState.currentSource)
        assertEquals(52_000L, hostState.playable.startPositionMs)
        assertTrue(hostState.playable.userForcedSource)
        assertEquals(1, commitCallbacks)
        assertSame(sourceBReplacement, lastPlayedSource)
        assertEquals(1, stickyWrites)
    }

    @Test
    fun `authority completion is one shot and stale disposal cannot invalidate its replacement`() {
        val coordinator = PlayerSourceSwitchCoordinator()
        val outerA = coordinator.replaceOuterSession()
        val requestA = coordinator.request(outerA)
        var commits = 0

        assertTrue(coordinator.finishIfCurrent(requestA) { commits++ })
        assertFalse(coordinator.finishIfCurrent(requestA) { commits++ })
        assertEquals(1, commits)

        val outerB = coordinator.replaceOuterSession()
        val requestB = coordinator.request(outerB)
        coordinator.invalidateIfCurrent(outerA)
        assertTrue(coordinator.isCurrent(requestB))

        coordinator.invalidateIfCurrent(outerB)
        assertFalse(coordinator.isCurrent(requestB))
    }

    @Test
    fun `old same-handle completion cannot enter a newer request in the same session`() {
        val authorities = PlayerSourceSwitchCoordinator()
        val sessionId = authorities.replaceOuterSession()
        val base = PlayerSourceSwitchState(
            sessionId,
            Playable("https://cdn.example/current.mkv", "Current"),
            currentSource = null,
        )
        val source = source("same#one", "Movie 4K")
        val oldPending = requireNotNull(
            beginPlayerSourceSwitch(base, source, authorities.request(sessionId)).pendingSwitch,
        )
        val currentState = beginPlayerSourceSwitch(
            base,
            source.copy(id = "same#two"),
            authorities.request(sessionId),
        )

        val stale = completePlayerSourceSwitch(
            state = currentState,
            pending = oldPending,
            result = Result.success(resolution(Playable("https://cdn.example/stale.mkv", "Stale"))),
            latestPositionMs = 1L,
        )

        assertFalse(stale.requestAccepted)
        assertEquals(currentState, applyPlayerSourceSwitchCompletion(currentState, oldPending, stale) { true })
    }

    @Test
    fun `stale view model identity cannot mutate source identity or sticky state`() {
        val authorities = PlayerSourceSwitchCoordinator()
        val sessionId = authorities.replaceOuterSession()
        val initial = PlayerSourceSwitchState(
            sessionId,
            Playable("https://cdn.example/current.mkv", "Current"),
            source("current", "Current 1080p"),
        )
        val pendingState = beginPlayerSourceSwitch(
            initial,
            source("alternate", "Alternate 4K"),
            authorities.request(sessionId),
        )
        val pending = requireNotNull(pendingState.pendingSwitch)
        val gate = PlayerSourceSwitchCommitGate()
        var vmIdentityCurrent = true
        var sourceIdentityWrites = 0
        var stickyWrites = 0
        val resolved = PlayerSourceSwitchResolution(
            playable = Playable("https://cdn.example/alternate.mkv", "Alternate"),
            commitGate = gate,
            commitAuthorityIsCurrent = { vmIdentityCurrent },
            commitAccepted = {
                sourceIdentityWrites++
                stickyWrites++
            },
        )
        val completion = completePlayerSourceSwitch(
            pendingState,
            pending,
            Result.success(resolved),
            latestPositionMs = 8_000L,
        )
        vmIdentityCurrent = false
        gate.invalidate()

        val applied = applyPlayerSourceSwitchCompletion(pendingState, pending, completion) { true }

        assertEquals(initial.playable, applied.playable)
        assertEquals(initial.currentSource, applied.currentSource)
        assertEquals(initial.sessionKey, applied.sessionKey)
        assertEquals(0, sourceIdentityWrites)
        assertEquals(0, stickyWrites)
    }

    @Test
    fun `accepted replacement uses advancing completion playhead and is user forced`() {
        val authorities = PlayerSourceSwitchCoordinator()
        val sessionId = authorities.replaceOuterSession()
        val initial = PlayerSourceSwitchState(
            sessionId,
            Playable("https://cdn.example/current.mkv", "Current"),
            source("current", "Current 1080p"),
        )
        val pendingState = beginPlayerSourceSwitch(
            initial,
            source("alternate", "Alternate 4K"),
            authorities.request(sessionId),
        )
        val pending = requireNotNull(pendingState.pendingSwitch)

        val completion = completePlayerSourceSwitch(
            pendingState,
            pending,
            Result.success(
                resolution(
                    Playable(
                        "https://cdn.example/alternate.mkv",
                        "Alternate",
                        startPositionMs = 12_000L,
                        userForcedSource = false,
                    ),
                ),
            ),
            latestPositionMs = 19_750L,
        )
        val applied = applyPlayerSourceSwitchCompletion(pendingState, pending, completion) { true }

        assertEquals(19_750L, applied.playable.startPositionMs)
        assertTrue(applied.playable.userForcedSource)
    }

    private fun resolution(
        playable: Playable,
        onCommit: () -> Unit = {},
    ): PlayerSourceSwitchResolution = PlayerSourceSwitchResolution(
        playable = playable,
        commitGate = PlayerSourceSwitchCommitGate(),
        commitAuthorityIsCurrent = { true },
        commitAccepted = onCommit,
    )

    private fun PlayerSourceSwitchCoordinator.request(outerSessionId: Long): PlayerSourceSwitchAuthority =
        requireNotNull(beginRequest(outerSessionId))

    private fun source(id: String, title: String): StreamSource = StreamSource(
        id = id,
        addon = "Provider",
        title = title,
        url = "https://cdn.example/$id",
    )
}
