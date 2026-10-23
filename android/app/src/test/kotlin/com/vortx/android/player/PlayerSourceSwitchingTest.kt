package com.vortx.android.player

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
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
import java.io.File

class PlayerSourceSwitchingTest {
    @Test
    fun `a pending replacement leaves another source and episode choice available to supersede it`() {
        assertTrue(playerReplacementChoiceEnabled(selected = false))
        assertFalse(playerReplacementChoiceEnabled(selected = true))

        val coordinator = PlayerSourceSwitchCoordinator()
        val outer = coordinator.replaceOuterSession()
        val first = coordinator.request(outer)
        val replacement = coordinator.request(outer)

        assertFalse(coordinator.isCurrent(first))
        assertTrue(coordinator.isCurrent(replacement))
    }

    @Test
    fun `terminal from an old source stays quarantined when its replacement fails`() {
        val fence = PlayerTerminalFence()

        assertTrue(fence.suppress(revision = 4L, replacementPending = true, terminal = true))
        // The unsuccessful replacement leaves revision 4 mounted. Its EOF must remain unable to
        // advance the episode after the picker returns to the old source.
        assertTrue(fence.suppress(revision = 4L, replacementPending = false, terminal = true))
        // An accepted replacement owns revision 5 and may report its own terminal normally.
        assertFalse(fence.suppress(revision = 5L, replacementPending = false, terminal = true))
    }

    @Test
    fun `manual retry reopens a quarantined revision before the next replacement starts`() {
        val fence = PlayerTerminalFence()
        assertTrue(fence.suppress(revision = 4L, replacementPending = true, terminal = true))
        assertTrue(fence.suppress(revision = 4L, replacementPending = false, terminal = true))

        fence.reopenManualRetry(revision = 4L)

        assertFalse(fence.suppress(revision = 4L, replacementPending = false, terminal = true))
    }

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
                publishState = { accepted, acknowledge -> hostState = accepted; acknowledge() },
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
            publishState = { accepted, acknowledge -> hostState = accepted; acknowledge() },
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

    @Test
    fun `late successful source and episode resolutions discard exactly once after A B A requests`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            val fixture = LeaseFixture(episodeSwitch)
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val result = fixture.resolution()
            val job = launch {
                fixture.resolve {
                    started.complete(Unit)
                    release.await()
                    Result.success(result)
                }
            }
            withTimeout(5_000L) { started.await() }
            val a = fixture.pendingState
            fixture.coordinator.beginRequest(a.outerSessionId) // B.
            val newer = requireNotNull(fixture.coordinator.beginRequest(a.outerSessionId)) // A again.
            fixture.state = if (episodeSwitch) beginPlayerEpisodeSwitch(a, fixture.episode, newer)
                else beginPlayerSourceSwitch(a, fixture.source, newer)
            val expected = fixture.state
            release.complete(Unit)
            withTimeout(5_000L) { job.join() }
            assertSame(expected, fixture.state)
            fixture.assertRejected()
        }
    }

    @Test
    fun `cancelled noncooperative resolver cannot adopt even while host request remains current`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            val fixture = LeaseFixture(episodeSwitch)
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val result = fixture.resolution()
            val job = launch {
                fixture.resolve {
                    try {
                        withContext(NonCancellable) { started.complete(Unit); release.await() }
                    } catch (_: CancellationException) {
                        // Deliberately return a resource after the producing job was cancelled.
                    }
                    Result.success(result)
                }
            }
            withTimeout(5_000L) { started.await() }
            job.cancel()
            release.complete(Unit)
            withTimeout(5_000L) { job.join() }
            assertSame(fixture.pendingState, fixture.state)
            fixture.assertRejected()
        }
    }

    @Test
    fun `invalid producer gate authority and malformed successes close new resource and retain outgoing`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            for (rejection in listOf("gate", "owner", "blank") + if (episodeSwitch) listOf("source") else emptyList()) {
                val fixture = LeaseFixture(episodeSwitch)
                val gate = PlayerSourceSwitchCommitGate().also { if (rejection == "gate") it.invalidate() }
                fixture.resolve {
                    Result.success(fixture.resolution(gate, current = rejection != "owner",
                        blank = rejection == "blank", missingSource = rejection == "source"))
                }
                assertSame(fixture.outgoing, fixture.state.playable)
                assertEquals(0L, fixture.state.revision)
                if (episodeSwitch) assertEquals(fixture.episode, fixture.state.failedEpisode)
                fixture.assertRejected()
            }
        }
    }

    @Test
    fun `completion rejected after resolution rolls back and closes once across duplicate delivery`() {
        for (episodeSwitch in listOf(false, true)) {
            val fixture = LeaseFixture(episodeSwitch)
            val result = Result.success(fixture.resolution())
            if (episodeSwitch) {
                val pending = requireNotNull(fixture.pendingState.pendingEpisodeSwitch)
                val completion = completePlayerEpisodeSwitch(fixture.pendingState, pending, result)
                repeat(2) {
                    fixture.state = applyPlayerEpisodeSwitchCompletion(fixture.state, pending, completion) { false }
                }
            } else {
                val pending = requireNotNull(fixture.pendingState.pendingSwitch)
                val completion = completePlayerSourceSwitch(fixture.pendingState, pending, result, 100)
                repeat(2) {
                    fixture.state = applyPlayerSourceSwitchCompletion(fixture.state, pending, completion) { false }
                }
            }
            assertSame(fixture.pendingState, fixture.state)
            fixture.assertRejected()
        }
    }

    @Test
    fun `accepted resolution adopts once and late duplicate cannot close the player lease`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            val fixture = LeaseFixture(episodeSwitch)
            val result = fixture.resolution()
            fixture.resolve { Result.success(result) }
            val accepted = fixture.state
            assertEquals(1L, accepted.revision)
            assertEquals(if (episodeSwitch) 0L else 42_000L, accepted.playable.startPositionMs)
            assertSame(fixture.incomingLease, accepted.playable.playbackLease)
            assertEquals(1, fixture.commits)
            assertFalse("A resolution is one shot", result.commitIfCurrent { true })
            fixture.resolve { Result.success(result) }
            assertSame(accepted, fixture.state)
            assertEquals(1, fixture.commits)
            assertEquals(0, fixture.rollbacks)
            assertEquals(0, fixture.incomingLease.closes)
            assertEquals(0, fixture.outgoingLease.closes)
            // The mounted player, not the completed resolver task, now owns final disposal.
            accepted.playable.playbackLease?.close()
            assertEquals(1, fixture.incomingLease.closes)
        }
    }

    @Test
    fun `failed and throwing resolvers never release outgoing resource`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            for (throws in listOf(false, true)) {
                val fixture = LeaseFixture(episodeSwitch)
                fixture.resolve {
                    if (throws) throw IllegalStateException("Synthetic failure")
                    Result.failure(IllegalStateException("Synthetic failure"))
                }
                assertSame(fixture.outgoing, fixture.state.playable)
                assertEquals(0L, fixture.state.revision)
                assertEquals(0, fixture.outgoingLease.closes)
                assertEquals(0, fixture.commits)
                assertEquals(0, fixture.rollbacks)
                if (episodeSwitch) assertEquals(fixture.episode, fixture.state.failedEpisode)
            }
        }
    }

    @Test
    fun `host publication failure releases the unmounted lease and rolls back once`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            val fixture = LeaseFixture(episodeSwitch)
            fixture.beforePublish = { throw IllegalStateException("Synthetic publication failure") }
            val result = fixture.resolution()
            val failure = runCatching { fixture.resolve { Result.success(result) } }.exceptionOrNull()
            assertEquals("Synthetic publication failure", failure?.message)
            assertSame(fixture.pendingState, fixture.state)
            assertEquals(1, fixture.incomingLease.closes)
            assertEquals(1, fixture.rollbacks)
            assertEquals(0, fixture.outgoingLease.closes)
            result.discard()
            assertEquals(1, fixture.incomingLease.closes)
            assertEquals(1, fixture.rollbacks)
        }
    }

    @Test
    fun `episode history notification failure preserves the already mounted lease`() = runBlocking {
        assertPostPublicationFailure(episodeSwitch = true)
    }

    @Test
    fun `source post-publication failure preserves the already mounted lease`() = runBlocking {
        assertPostPublicationFailure(episodeSwitch = false)
    }

    @Test
    fun `reentrant replacement and disposal before notification throws cannot revoke adoption`() = runBlocking {
        for (episodeSwitch in listOf(false, true)) {
            for (replaceOuter in listOf(false, true)) {
                val fixture = LeaseFixture(episodeSwitch)
                val expectedFailure = IllegalStateException("Synthetic reentrant notification failure")
                val newerLease = CountingLease()
                lateinit var newerAuthority: PlayerSourceSwitchAuthority
                lateinit var newerState: PlayerSourceSwitchState
                var notifications = 0
                fixture.beforePublish = {
                    assertSame(fixture.outgoing, fixture.state.playable)
                    assertEquals(0, fixture.outgoingLease.closes)
                    assertEquals(0, fixture.incomingLease.closes)
                }
                fixture.afterPublish = { accepted ->
                    assertSame(accepted, fixture.state)
                    notifications++
                    // Model mounted effect retirement after publication, followed by a reentrant
                    // request/outer replacement. Exception-time state readback cannot see adoption.
                    fixture.outgoing.playbackLease?.close()
                    accepted.playable.playbackLease?.close()
                    val outer = if (replaceOuter) fixture.coordinator.replaceOuterSession() else accepted.outerSessionId
                    newerAuthority = requireNotNull(fixture.coordinator.beginRequest(outer))
                    newerState = beginPlayerSourceSwitch(
                        PlayerSourceSwitchState(outer,
                            Playable("https://fixture.invalid/newest", "Newest", playbackLease = newerLease),
                            fixture.source, revision = accepted.revision + 1),
                        fixture.source, newerAuthority,
                    )
                    fixture.state = newerState
                    throw expectedFailure
                }
                val result = fixture.resolution()
                val failure = runCatching { fixture.resolve { Result.success(result) } }.exceptionOrNull()
                assertSame(expectedFailure, failure)
                assertSame("Old completion must not overwrite reentrant publication", newerState, fixture.state)
                assertTrue("Old finish must not retire the newer request", fixture.coordinator.isCurrent(newerAuthority))
                assertEquals(1, notifications)
                assertEquals(1, fixture.commits)
                assertEquals(0, fixture.rollbacks)
                assertEquals("Mounted disposal already released the adopted resource", 1, fixture.incomingLease.closes)
                assertEquals(1, fixture.outgoingLease.closes)
                result.discard()
                fixture.resolve { Result.success(result) }
                assertSame(newerState, fixture.state)
                assertTrue(fixture.coordinator.isCurrent(newerAuthority))
                assertEquals(1, notifications)
                assertEquals(0, fixture.rollbacks)
                assertEquals(1, fixture.incomingLease.closes)
                assertEquals(0, newerLease.closes)
                newerState.playable.playbackLease?.close()
                assertEquals(1, newerLease.closes)
            }
        }
    }

    @Test
    fun `missing publication acknowledgment discards once and late acknowledgment cannot revive it`() {
        val fixture = LeaseFixture(episodeSwitch = true)
        val result = fixture.resolution()
        lateinit var lateAcknowledgment: () -> Unit
        val failure = runCatching {
            result.commitIfCurrent({ true }) { acknowledge -> lateAcknowledgment = acknowledge }
        }.exceptionOrNull()
        assertEquals("Player replacement publication was not acknowledged", failure?.message)
        assertSame(fixture.outgoing, fixture.state.playable)
        assertEquals(1, fixture.rollbacks)
        assertEquals(1, fixture.incomingLease.closes)
        assertEquals(0, fixture.outgoingLease.closes)
        lateAcknowledgment()
        result.discard()
        assertFalse(result.commitIfCurrent { true })
        assertEquals(1, fixture.commits)
        assertEquals(1, fixture.rollbacks)
        assertEquals(1, fixture.incomingLease.closes)
    }

    @Test
    fun `duplicate acknowledgment and reentrant acceptance do not duplicate producer commit`() {
        val fixture = LeaseFixture(episodeSwitch = false)
        val result = fixture.resolution()
        assertTrue(result.commitIfCurrent({ true }) { acknowledge ->
            assertFalse(result.commitIfCurrent { true })
            assertEquals(1, fixture.commits)
            acknowledge()
            acknowledge()
            result.discard()
        })
        assertEquals(1, fixture.commits)
        assertEquals(0, fixture.rollbacks)
        assertEquals(0, fixture.incomingLease.closes)
        result.playable.playbackLease?.close()
        assertEquals(1, fixture.incomingLease.closes)
    }

    @Test
    fun `actual player callbacks acknowledge directly after assignment before episode notification`() {
        val screen = File("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt").readText()
        val sourceCallback = screen.substringAfter("publishState = { replacement, acknowledgePublished ->")
            .substringBefore("// In-player EPISODE")
        assertTrue(Regex("sourceSwitchState = replacement\\s+acknowledgePublished\\(\\)").containsMatchIn(sourceCallback))
        assertTrue(sourceCallback.indexOf("engine.pause()") < sourceCallback.indexOf("sourceSwitchState = replacement"))
        val episodeCallback = screen.substringAfter("publishState = { accepted, acknowledgePublished ->")
            .substringBefore("var chapters")
        assertTrue(Regex("sourceSwitchState = accepted\\s+acknowledgePublished\\(\\)").containsMatchIn(episodeCallback))
        assertTrue(episodeCallback.indexOf("engine.pause()") < episodeCallback.indexOf("sourceSwitchState = accepted"))
        assertTrue(episodeCallback.indexOf("acknowledgePublished()") < episodeCallback.indexOf("currentOnEpisodeSwitched("))
    }

    private suspend fun assertPostPublicationFailure(episodeSwitch: Boolean) {
        val fixture = LeaseFixture(episodeSwitch)
        val expectedFailure = IllegalStateException("Synthetic post-publication notification failure")
        var notifications = 0
        fixture.beforePublish = {
            assertSame(fixture.outgoing, fixture.state.playable)
            assertEquals(0, fixture.outgoingLease.closes)
            assertEquals(0, fixture.incomingLease.closes)
        }
        fixture.afterPublish = { accepted ->
            // Actual PlayerScreen order: state assignment precedes the episode history callback.
            assertSame(accepted, fixture.state)
            if (episodeSwitch) {
                val history = requireNotNull(acceptedEpisodeReplacement(fixture.pendingState, accepted))
                assertSame(accepted.playable, history.playable)
                assertEquals(accepted.revision, history.revision)
            }
            notifications++
            throw expectedFailure
        }
        val result = fixture.resolution()
        val failure = runCatching { fixture.resolve { Result.success(result) } }.exceptionOrNull()
        assertSame("Notification errors still propagate", expectedFailure, failure)
        val accepted = fixture.state
        assertEquals(1L, accepted.revision)
        assertSame(fixture.incomingLease, accepted.playable.playbackLease)
        assertEquals(if (episodeSwitch) 0L else 42_000L, accepted.playable.startPositionMs)
        assertNull(accepted.pendingSwitch)
        assertNull(accepted.pendingEpisodeSwitch)
        assertNull(accepted.failedEpisode)
        assertEquals(1, notifications)
        assertEquals(1, fixture.commits)
        assertEquals("Published state cannot roll back its producer", 0, fixture.rollbacks)
        assertEquals("Mounted resource remains player-owned", 0, fixture.incomingLease.closes)
        assertEquals(0, fixture.outgoingLease.closes)
        val authority = fixture.pendingState.pendingSwitch?.authority
            ?: requireNotNull(fixture.pendingState.pendingEpisodeSwitch).authority
        assertFalse("Published request must be retired despite notification failure", fixture.coordinator.isCurrent(authority))
        result.discard()
        fixture.resolve { Result.success(result) }
        assertSame(accepted, fixture.state)
        assertEquals(1, notifications)
        assertEquals(0, fixture.rollbacks)
        assertEquals(0, fixture.incomingLease.closes)
        accepted.playable.playbackLease?.close()
        assertEquals("Mounted disposal is the only incoming close", 1, fixture.incomingLease.closes)
    }

    /** Intentionally non-idempotent: production must supply one-shot disposal. */
    private class CountingLease : AutoCloseable {
        var closes = 0
        override fun close() { closes++ }
    }

    private class LeaseFixture(private val episodeSwitch: Boolean) {
        val coordinator = PlayerSourceSwitchCoordinator()
        val source = StreamSource("next", "Fixture", "Next", url = "https://fixture.invalid/next")
        val episode = Episode("episode-2", "Second", 1, 2)
        val outgoingLease = CountingLease()
        val incomingLease = CountingLease()
        val outgoing = Playable("https://fixture.invalid/outgoing", "Outgoing", playbackLease = outgoingLease)
        private val outer = coordinator.replaceOuterSession()
        private val authority = requireNotNull(coordinator.beginRequest(outer))
        val pendingState = PlayerSourceSwitchState(outer, outgoing, null).let {
            if (episodeSwitch) beginPlayerEpisodeSwitch(it, episode, authority)
            else beginPlayerSourceSwitch(it, source, authority)
        }
        var state = pendingState
        var commits = 0
        var rollbacks = 0
        var beforePublish: () -> Unit = {}
        var afterPublish: (PlayerSourceSwitchState) -> Unit = {}

        fun resolution(gate: PlayerSourceSwitchCommitGate = PlayerSourceSwitchCommitGate(),
            current: Boolean = true, blank: Boolean = false, missingSource: Boolean = false) =
            PlayerSourceSwitchResolution(
                Playable(if (blank) "" else "https://fixture.invalid/incoming", "Incoming", startPositionMs = 999,
                    playbackLease = incomingLease),
                resolvedSource = source.takeUnless { missingSource },
                commitGate = gate,
                commitAuthorityIsCurrent = { current },
                commitAccepted = { commits++ },
                commitRejected = { rollbacks++ },
            )

        suspend fun resolve(resolver: suspend () -> Result<PlayerSourceSwitchResolution>) {
            val publish: (PlayerSourceSwitchState, () -> Unit) -> Unit = { accepted, acknowledge ->
                beforePublish()
                state = accepted
                acknowledge()
                afterPublish(accepted)
            }
            if (episodeSwitch) resolveAndApplyPlayerEpisodeSwitch(coordinator,
                requireNotNull(pendingState.pendingEpisodeSwitch), { resolver() }, { state }, publish)
            else resolveAndApplyPlayerSourceSwitch(coordinator,
                requireNotNull(pendingState.pendingSwitch), { resolver() }, { state }, { 42_000L }, publish)
        }

        fun assertRejected() {
            assertEquals("New resource must close once", 1, incomingLease.closes)
            assertEquals("Outgoing resource remains mounted", 0, outgoingLease.closes)
            assertEquals("Owned rollback runs once", 1, rollbacks)
            assertEquals("Rejected result cannot commit", 0, commits)
        }
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
