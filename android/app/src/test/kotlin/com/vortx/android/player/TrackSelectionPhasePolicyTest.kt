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

    @Test
    fun `pool waits for settled addon lookup and respects existing track admission`() {
        val initial = TrackSelectionPhases()
        val afterAudio = initial.apply(AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false))
        assertFalse(initial.mayAttemptPool(false, addonLookupSettled = true, hasPreferredAddon = false))
        assertFalse(afterAudio.mayAttemptPool(false, addonLookupSettled = false, hasPreferredAddon = false))
        assertFalse(afterAudio.mayAttemptPool(false, addonLookupSettled = true, hasPreferredAddon = true))
        assertFalse(afterAudio.mayAttemptPool(true, addonLookupSettled = true, hasPreferredAddon = false))
        assertFalse(afterAudio.recordAddonAttempt().mayAttemptPool(false, true, false))
        assertFalse(afterAudio.holdSubtitle().mayAttemptPool(false, true, false))
        assertTrue(afterAudio.mayAttemptPool(false, addonLookupSettled = true, hasPreferredAddon = false))
        val embeddedDefault = afterAudio.apply(AutomaticTrackDefaults(selectAudio = false, selectSubtitle = true))
        assertTrue(embeddedDefault.mayAttemptPool(true, addonLookupSettled = true, hasPreferredAddon = false))
    }

    @Test
    fun `pool reservation is once per load and does not change the subtitle effect phase`() {
        val eligible = TrackSelectionPhases().apply(
            AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false),
        )
        val reserved = eligible.recordPoolSelection()
        assertTrue(reserved.poolAttempted)
        assertFalse(reserved.addonAttempted)
        assertEquals(eligible.subtitle, reserved.subtitle)
        assertEquals(eligible.audio, reserved.audio)
        assertFalse(reserved.automaticDefaults(true, true).selectSubtitle)
        assertFalse(reserved.mayAttemptAddon(hasSelectableSubtitle = false))
        assertFalse(reserved.mayAttemptAddon(hasSelectableSubtitle = true))
        assertFalse(reserved.mayAttemptPool(false, true, false))
        assertEquals(reserved, reserved.recordPoolSelection())
    }

    @Test
    fun `reserved pool does not block independent audio defaults`() {
        val reserved = TrackSelectionPhases().recordPoolSelection()
        val defaults = reserved.automaticDefaults(hasSelectableAudio = true, hasSelectableSubtitle = true)
        assertEquals(AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false), defaults)
        val applied = reserved.apply(defaults)
        assertEquals(DefaultTrackPhase.DEFAULT_APPLIED, applied.audio)
        assertEquals(DefaultTrackPhase.WAITING_FOR_INVENTORY, applied.subtitle)
        assertTrue(applied.poolAttempted)
    }

    @Test
    fun `explicit holds still deny pool and a fresh loaded engine resets its reservation`() {
        val old = TrackSelectionPhases()
            .apply(AutomaticTrackDefaults(selectAudio = true, selectSubtitle = false))
            .recordPoolSelection()
            .holdSubtitle()
        assertEquals(DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION, old.subtitle)
        assertFalse(old.automaticDefaults(true, true).selectSubtitle)
        assertFalse(old.mayAttemptPool(false, true, false))
        val fresh = TrackSelectionPhases()
        assertFalse(fresh.poolAttempted)
        assertFalse(fresh.addonAttempted)
        assertEquals(DefaultTrackPhase.WAITING_FOR_INVENTORY, fresh.subtitle)
        assertTrue(fresh.apply(AutomaticTrackDefaults(true, false)).mayAttemptPool(false, true, false))
    }
}
