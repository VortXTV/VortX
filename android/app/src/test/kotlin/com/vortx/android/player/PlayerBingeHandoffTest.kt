package com.vortx.android.player

import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

class PlayerBingeHandoffTest {
    @Test fun `source pick cannot supersede pending cold episode before noncooperative cancellation retires its context`() = runBlocking {
        val coordinator = PlayerSourceSwitchCoordinator()
        val outer = coordinator.replaceOuterSession()
        val e2 = Episode("episode-2", "E2", 1, 2)
        val e3 = Episode("episode-3", "E3", 1, 3)
        val source = StreamSource("e2-source", "Fixture", "E2 source", url = "https://fixture.invalid/e2")
        var outgoingCloses = 0
        var staleCloses = 0
        var acceptedCloses = 0
        var sourceOnlyCloses = 0
        var sourceResolves = 0
        var ambientEpisode = "E2" // The cold VM selected E2 before waiting for its candidate.
        val history = mutableListOf<String>()
        val outgoing = Playable("https://fixture.invalid/e1", "E1", startPositionMs = 900,
            playbackLease = AutoCloseable { outgoingCloses++ })
        var host = beginPlayerEpisodeSwitch(PlayerSourceSwitchState(outer, outgoing, null), e2,
            requireNotNull(coordinator.beginRequest(outer)), automatic = true)
        val pendingE2 = requireNotNull(host.pendingEpisodeSwitch)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val staleJob = launch {
            resolveAndApplyPlayerEpisodeSwitch(coordinator, pendingE2, resolver = {
                withContext(NonCancellable) { entered.complete(Unit); release.await() }
                Result.success(PlayerSourceSwitchResolution(
                    Playable("https://fixture.invalid/e2", "E2", playbackLease = AutoCloseable { staleCloses++ }), source,
                    PlayerSourceSwitchCommitGate(), { ambientEpisode == "E2" }, {},
                    commitRejected = { if (ambientEpisode == "E2") ambientEpisode = "E1" }))
            }, currentState = { host }, publishState = { accepted, acknowledge ->
                host = accepted; acknowledge(); history += accepted.playable.title
            })
        }
        entered.await()
        val before = host
        host = requestPlayerSourceSwitch(host, source, coordinator)
        val retainedAuthority = coordinator.isCurrent(pendingE2.authority)
        host.pendingSwitch?.let { pending ->
            staleJob.cancel() // Mirrors disposal of the old pending-episode LaunchedEffect.
            resolveAndApplyPlayerSourceSwitch(coordinator, pending, resolver = {
                sourceResolves++
                Result.success(PlayerSourceSwitchResolution(
                    Playable("https://fixture.invalid/e2-other", ambientEpisode,
                        playbackLease = AutoCloseable { sourceOnlyCloses++ }),
                    commitGate = PlayerSourceSwitchCommitGate(), commitAuthorityIsCurrent = { true }, commitAccepted = {}))
            }, currentState = { host }, latestPositionMs = { 900 }, publishState = { accepted, acknowledge ->
                val previous = host
                host = accepted; acknowledge()
                previous.playable.playbackLease?.close()
            })
        }
        val afterSource = host
        val outgoingBeforeAcceptedEpisode = outgoingCloses
        // A different episode remains available and owns the successor even while E2 ignores cancellation.
        host = beginPlayerEpisodeSwitch(host, e3, requireNotNull(coordinator.beginRequest(outer)))
        staleJob.cancel()
        ambientEpisode = "E3"
        resolveAndApplyPlayerEpisodeSwitch(coordinator, requireNotNull(host.pendingEpisodeSwitch), resolver = {
            Result.success(PlayerSourceSwitchResolution(
                Playable("https://fixture.invalid/e3", "E3", startPositionMs = 888,
                    playbackLease = AutoCloseable { acceptedCloses++ }), source.copy(id = "e3-source"),
                PlayerSourceSwitchCommitGate(), { true }, {}))
        }, currentState = { host }, publishState = { accepted, acknowledge ->
            val previous = host
            host = accepted; acknowledge()
            history += accepted.playable.title
            previous.playable.playbackLease?.close() // Mounted disposal follows, never precedes, acknowledgment.
        })
        release.complete(Unit); staleJob.join()
        host.playable.playbackLease?.close()
        assertEquals(0, sourceResolves)
        assertSame(before, afterSource)
        assertTrue(retainedAuthority)
        assertEquals(0, outgoingBeforeAcceptedEpisode)
        assertEquals(1, outgoingCloses)
        assertEquals("E3", ambientEpisode)
        assertEquals("E3", host.playable.title)
        assertEquals(0L, host.playable.startPositionMs)
        assertEquals(1L, host.revision)
        assertEquals(listOf("E3"), history)
        assertEquals(1, staleCloses)
        assertEquals(1, acceptedCloses)
        assertEquals(0, sourceOnlyCloses)
    }

    @Test fun `episode busy rows block source choices while source and episode supersession remain available`() {
        assertFalse(playerReplacementChoiceEnabled(selected = false, episodeSwitchPending = true))
        assertFalse(playerReplacementChoiceEnabled(selected = true, episodeSwitchPending = true))
        assertTrue(playerReplacementChoiceEnabled(selected = false)) // Episode rows do not receive the source-only guard.
        assertFalse(playerReplacementChoiceEnabled(selected = true))
        val coordinator = PlayerSourceSwitchCoordinator()
        val outer = coordinator.replaceOuterSession()
        val outgoing = Playable("https://fixture.invalid/e1", "E1", startPositionMs = 900)
        val a = StreamSource("a", "Fixture", "A", url = "https://fixture.invalid/a")
        val b = a.copy(id = "b", title = "B", url = "https://fixture.invalid/b")
        val first = requestPlayerSourceSwitch(PlayerSourceSwitchState(outer, outgoing, null), a, coordinator)
        val second = requestPlayerSourceSwitch(first, b, coordinator)
        assertFalse(coordinator.isCurrent(requireNotNull(first.pendingSwitch).authority))
        assertTrue(coordinator.isCurrent(requireNotNull(second.pendingSwitch).authority))
        assertEquals(b, second.pendingSwitch?.source)
        assertSame(outgoing, second.playable)
        assertEquals(0L, second.revision)
        val e2 = beginPlayerEpisodeSwitch(second, Episode("e2", "E2", 1, 2),
            requireNotNull(coordinator.beginRequest(outer)))
        val e3 = beginPlayerEpisodeSwitch(e2, Episode("e3", "E3", 1, 3),
            requireNotNull(coordinator.beginRequest(outer)))
        assertFalse(coordinator.isCurrent(requireNotNull(e2.pendingEpisodeSwitch).authority))
        assertTrue(coordinator.isCurrent(requireNotNull(e3.pendingEpisodeSwitch).authority))
        assertSame(outgoing, e3.playable)
        assertNull(e3.pendingSwitch)
        assertEquals(0L, e3.revision)
        coordinator.invalidateIfCurrent(outer)
        assertSame(second, requestPlayerSourceSwitch(second, a, coordinator)) // An obsolete outer host also stays untouched.
    }

    @Test fun `automatic and manual requests share accepted revision and zero start while rejects preserve outgoing`() = runBlocking {
        for (automatic in listOf(false, true)) for (accepted in listOf(false, true)) {
            val coordinator = PlayerSourceSwitchCoordinator()
            val outer = coordinator.replaceOuterSession()
            var outgoingCloses = 0
            var incomingCloses = 0
            val outgoing = Playable("https://fixture.invalid/old", "Old", startPositionMs = 900,
                playbackLease = AutoCloseable { outgoingCloses++ })
            val request = PlayerEpisodeHandoffRequest(1, Episode("next", "Next", 1, 2), automatic)
            var host = beginPlayerEpisodeSwitch(PlayerSourceSwitchState(outer, outgoing, null), request.episode,
                requireNotNull(coordinator.beginRequest(outer)), request.automatic)
            val pending = requireNotNull(host.pendingEpisodeSwitch)
            assertEquals(automatic, pending.automatic)
            var history = 0
            var automaticAccepted = 0
            val resolution = PlayerSourceSwitchResolution(
                Playable("https://fixture.invalid/next", "Next", startPositionMs = 45,
                    playbackLease = AutoCloseable { incomingCloses++ }),
                resolvedSource = StreamSource("next", "Fixture", "Next", url = "https://fixture.invalid/next"),
                commitGate = PlayerSourceSwitchCommitGate(), commitAuthorityIsCurrent = { accepted }, commitAccepted = {})
            resolveAndApplyPlayerEpisodeSwitch(coordinator, pending, { Result.success(resolution) }, { host }) { replacement, acknowledge ->
                val previous = host
                assertEquals(0, outgoingCloses)
                host = replacement
                acknowledge()
                if (acceptedEpisodeReplacement(previous, replacement) != null) {
                    history++
                    if (pending.automatic) automaticAccepted++
                }
            }
            assertEquals(0, outgoingCloses)
            assertEquals(if (accepted) 1L else 0L, host.revision)
            assertEquals(if (accepted) 1 else 0, history)
            assertEquals(if (accepted && automatic) 1 else 0, automaticAccepted)
            if (accepted) {
                assertEquals(0L, host.playable.startPositionMs)
                resolution.discard()
                assertEquals(0, incomingCloses)
                host.playable.playbackLease!!.close()
            } else {
                assertSame(outgoing, host.playable)
                assertEquals(request.episode, host.failedEpisode)
            }
            assertEquals(1, incomingCloses)
        }
    }

    @Test fun `semantic audio follows language and role with different ids on the next file`() {
        val selected = PlayerTrack(4, "English Commentary", "eng")
        val intent = PlaybackAudioIntent.fromTrack(selected)
        assertEquals("en", intent.language) // The source ranker's language keys use canonical two-letter codes.
        val next = listOf(PlayerTrack(4, "French Main", "fr"), PlayerTrack(17, "English Main", "en"),
            PlayerTrack(23, "English Commentary", "en"), PlayerTrack(25, "English Audio Description", "en"))
        assertEquals(listOf(23), intent.matchingTracks(next).map { it.id })
        assertEquals(listOf(25), PlaybackAudioIntent.fromTrack(PlayerTrack(9, "English Audio Description", "eng"))
            .matchingTracks(next).map { it.id })
        assertEquals(listOf(17), PlaybackAudioIntent.fromTrack(PlayerTrack(11, "English Main", "en"))
            .matchingTracks(next).map { it.id })
        assertTrue(intent.matchingTracks(next.filterNot { it.id == 23 }).isEmpty())
        assertTrue(PlaybackAudioIntent.fromTrack(PlayerTrack(1, "Unknown")).matchingTracks(next).isEmpty())
    }
}
