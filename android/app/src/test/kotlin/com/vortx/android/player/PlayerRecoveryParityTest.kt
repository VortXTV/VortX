package com.vortx.android.player

import com.vortx.android.model.*
import com.vortx.android.ui.components.episodeRailPageIndex
import com.vortx.android.ui.components.episodeRailTargetIndex
import org.junit.Assert.*
import org.junit.Test

class PlayerRecoveryParityTest {
    private val outgoing = Playable("https://fixture.invalid/old.mkv", "Old")
    private val target = Episode("opaque-next", "Next", 2, 4)
    private val source = StreamSource("source-a", "Fixture", "Fixture")
    private val prefs = TrackPreferences(listOf("en"), listOf("en"), TrackPreferences.ForcedPolicy.OFF, emptyList())
    private fun resolved(gate: PlayerSourceSwitchCommitGate = PlayerSourceSwitchCommitGate(), rejected: () -> Unit = {}) =
        PlayerSourceSwitchResolution(Playable("https://fixture.invalid/new.mkv", "New"), source, gate, { true }, {}, rejected)

    @Test fun `failed episode and rejected commit retain exact target through retry without changing healthy mount`() {
        val initial = PlayerSourceSwitchState(1, outgoing, source)
        val requested = beginPlayerEpisodeSwitch(initial, target, PlayerSourceSwitchAuthority(1, 1))
        val pending = requireNotNull(requested.pendingEpisodeSwitch)
        val failure = completePlayerEpisodeSwitch(requested, pending, Result.failure(IllegalStateException("offline")))
        val failed = applyPlayerEpisodeSwitchCompletion(requested, pending, failure) { true }
        assertEquals(target, failed.failedEpisode); assertSame(outgoing, failed.playable); assertEquals(0L, failed.revision)
        val retry = beginPlayerEpisodeSwitch(failed, requireNotNull(failed.failedEpisode), PlayerSourceSwitchAuthority(1, 2))
        assertEquals(target.id, retry.pendingEpisodeSwitch?.episode?.id); assertEquals(target, retry.failedEpisode)
        val retryPending = requireNotNull(retry.pendingEpisodeSwitch)
        val gate = PlayerSourceSwitchCommitGate().also { it.invalidate() }; var rolledBack = false
        val success = completePlayerEpisodeSwitch(retry, retryPending, Result.success(resolved(gate) { rolledBack = true }))
        val rejected = applyPlayerEpisodeSwitchCompletion(retry, retryPending, success) { true }
        assertTrue(rolledBack); assertEquals(target, rejected.failedEpisode); assertSame(outgoing, rejected.playable)
        val acceptedRequest = beginPlayerEpisodeSwitch(rejected, target, PlayerSourceSwitchAuthority(1, 3))
        val acceptedPending = requireNotNull(acceptedRequest.pendingEpisodeSwitch)
        val accepted = applyPlayerEpisodeSwitchCompletion(acceptedRequest, acceptedPending,
            completePlayerEpisodeSwitch(acceptedRequest, acceptedPending, Result.success(resolved()))) { true }
        assertNull(accepted.failedEpisode); assertEquals(1L, accepted.revision)
    }

    @Test fun `A B A failed completion cannot restore old target or publish into newer request`() {
        val original = PlayerSourceSwitchState(1, outgoing, source)
        val first = beginPlayerEpisodeSwitch(original, target, PlayerSourceSwitchAuthority(1, 1))
        val oldPending = requireNotNull(first.pendingEpisodeSwitch)
        val b = beginPlayerEpisodeSwitch(first, target.copy(id = "opaque-other"), PlayerSourceSwitchAuthority(1, 2))
        val aAgain = beginPlayerEpisodeSwitch(b, target, PlayerSourceSwitchAuthority(1, 3))
        val late = completePlayerEpisodeSwitch(first, oldPending, Result.failure(IllegalStateException("late")))
        assertSame(aAgain, applyPlayerEpisodeSwitchCompletion(aAgain, oldPending, late) { true })
        assertSame(aAgain, applyPlayerEpisodeSwitchCompletion(aAgain, requireNotNull(aAgain.pendingEpisodeSwitch),
            completePlayerEpisodeSwitch(aAgain, requireNotNull(aAgain.pendingEpisodeSwitch), Result.success(resolved()))) { false })
    }

    @Test fun `labelled French only file rejects automatic English but unknown and manual choices are preserved`() {
        val french = listOf(PlayerTrack(1, lang = "fr", title = "French"))
        assertTrue(knownWrongAutomaticAudio(french, prefs, false))
        assertFalse(knownWrongAutomaticAudio(french, prefs, false, manualAudio = true))
        assertFalse(knownWrongAutomaticAudio(french, prefs, false, manualSource = true))
        assertFalse(knownWrongAutomaticAudio(emptyList(), prefs, false))
        assertFalse(knownWrongAutomaticAudio(french + PlayerTrack(2, title = "Unknown", lang = null), prefs, false))
        assertFalse(knownWrongAutomaticAudio(french + PlayerTrack(2, title = "English", lang = "eng"), prefs, false))
        assertFalse(knownWrongAutomaticAudio(listOf(PlayerTrack(1, title = "Unknown", lang = "und")), prefs, false))
        assertFalse(knownWrongAutomaticAudio(listOf(PlayerTrack(1, title = "Unknown", lang = "zzz")), prefs, false))
    }

    @Test fun `automatic audio alternates are three total sources and cannot revisit ABA source`() {
        val b = source.copy(id = "source-b"); val c = source.copy(id = "source-c"); val d = source.copy(id = "source-d")
        val ledger = AutomaticAudioAlternates()
        assertEquals(b, ledger.next(source, listOf(source, b, c)))
        assertEquals(c, ledger.next(b, listOf(source, b, c)))
        assertNull(ledger.next(c, listOf(source, b, c, d)))
        val initial = PlayerSourceSwitchState(1, outgoing, source)
        val auto = beginPlayerSourceSwitch(initial, b, PlayerSourceSwitchAuthority(1, 1), automatic = true)
        val manual = beginPlayerSourceSwitch(initial, b, PlayerSourceSwitchAuthority(1, 2))
        assertFalse(completePlayerSourceSwitch(auto, auto.pendingSwitch!!, Result.success(resolved()), 0).state.playable.userForcedSource)
        assertTrue(completePlayerSourceSwitch(manual, manual.pendingSwitch!!, Result.success(resolved()), 0).state.playable.userForcedSource)
    }

    @Test fun `tiny cast duration cannot report a near end ratio including short metadata and manual file`() {
        assertFalse(canReportPlayerProgress(outgoing, 1_000, 1_000))
        assertFalse(canReportPlayerProgress(outgoing.copy(expectedDurationMs = 300_000), 1_000, 1_000))
        assertFalse(canReportPlayerProgress(outgoing.copy(userForcedSource = true), 1_000, 1_000))
        assertFalse(canReportPlayerProgress(outgoing.copy(isTrailer = true), 60_000, 120_000))
        assertTrue(canReportPlayerProgress(outgoing, 1_000, 2_700_000))
        assertTrue(canReportPlayerProgress(outgoing.copy(expectedDurationMs = 300_000), 1_000, 300_000))
    }

    @Test fun `episode rails restore opaque current target and clamp page boundaries`() {
        val ids = List(100) { "opaque-$it" }
        assertEquals(87, episodeRailTargetIndex(ids, "opaque-87")); assertNull(episodeRailTargetIndex(ids, "missing"))
        assertEquals(92, episodeRailPageIndex(87, 5, 100, true)); assertEquals(82, episodeRailPageIndex(87, 5, 100, false))
        assertEquals(0, episodeRailPageIndex(0, 0, 100, false)); assertEquals(99, episodeRailPageIndex(99, 5, 100, true))
        assertEquals(0, episodeRailPageIndex(5, 5, 0, true))
    }
}
