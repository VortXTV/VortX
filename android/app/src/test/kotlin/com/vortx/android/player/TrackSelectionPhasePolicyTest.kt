package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackSelectionPhasePolicyTest {
    @Test
    fun `audio first still admits the later subtitle default`() {
        val initial = TrackSelectionPhases()
        val audioOnly = initial.automaticDefaults(hasSelectableAudio = true, hasSelectableSubtitle = false)
        assertEquals(AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false), audioOnly)

        val afterAudio = initial.apply(audioOnly)
        assertEquals(
            AutomaticTrackDefaults(selectAudio = false, selectSubtitle = true),
            afterAudio.automaticDefaults(hasSelectableAudio = true, hasSelectableSubtitle = true),
        )
    }

    @Test
    fun `subtitle first still admits the later audio default`() {
        val initial = TrackSelectionPhases()
        val subtitleOnly = initial.automaticDefaults(hasSelectableAudio = false, hasSelectableSubtitle = true)
        assertEquals(AutomaticTrackDefaults(selectAudio = false, selectSubtitle = true), subtitleOnly)

        val afterSubtitle = initial.apply(subtitleOnly)
        assertEquals(
            AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false),
            afterSubtitle.automaticDefaults(hasSelectableAudio = true, hasSelectableSubtitle = true),
        )
    }

    @Test
    fun `manual off or external subtitle holds against late inventory`() {
        val afterAudio = TrackSelectionPhases().apply(
            AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false),
        )
        val manualOff = afterAudio.holdSubtitle()
        val externalSelection = afterAudio.holdSubtitle()

        assertFalse(manualOff.automaticDefaults(true, true).selectSubtitle)
        assertFalse(externalSelection.automaticDefaults(true, true).selectSubtitle)
        assertFalse(manualOff.mayAttemptAddon(hasSelectableSubtitle = true))
        assertFalse(externalSelection.mayAttemptAddon(hasSelectableSubtitle = false))
    }

    @Test
    fun `a replacement receives fresh per-engine selection phases`() {
        val oldEngine = TrackSelectionPhases()
            .apply(AutomaticTrackDefaults(selectAudio = true, selectSubtitle = true))
            .holdSubtitle()
            .recordAddonAttempt()

        assertEquals(DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION, oldEngine.subtitle)
        assertTrue(oldEngine.addonAttempted)

        val replacement = TrackSelectionPhases()
        assertEquals(DefaultTrackPhase.WAITING_FOR_INVENTORY, replacement.audio)
        assertEquals(DefaultTrackPhase.WAITING_FOR_INVENTORY, replacement.subtitle)
        assertFalse(replacement.addonAttempted)
    }

    @Test
    fun `add-on fallback is bounded, held, and does not wait forever for absent embedded subtitles`() {
        val afterAudio = TrackSelectionPhases().apply(
            AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false),
        )

        assertTrue(afterAudio.mayAttemptAddon(hasSelectableSubtitle = false))
        val afterAddon = afterAudio.recordAddonSelection()
        assertFalse(afterAddon.mayAttemptAddon(hasSelectableSubtitle = false))
        assertFalse(afterAddon.mayAttemptAddon(hasSelectableSubtitle = true))
        assertEquals(DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION, afterAddon.subtitle)
        assertFalse(afterAddon.automaticDefaults(true, true).selectSubtitle)
    }
}
