package com.vortx.android.player

import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PlayerBingeHandoffTest {
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
