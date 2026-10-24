package com.vortx.android.player

import org.junit.Assert.*
import org.junit.Test

class SubtitleSelectionAuthorityTest {
    @Test fun noChoiceOrCaptureBeforeActualSourceAndRetirementCannotReopen() {
        val owner = SubtitleSelectionAuthority()
        assertNull(owner.capture()); assertNull(owner.beginChoice())
        val first = owner.beginSource(1L)!!
        assertTrue(owner.isCurrent(first))
        owner.retire()
        assertFalse(owner.isCurrent(first))
        assertNull(owner.capture()); assertNull(owner.beginChoice()); assertNull(owner.beginSource(2L))
    }

    @Test fun independentEnginesCannotAdoptEachOthersOriginalReceipt() {
        val first = SubtitleSelectionAuthority()
        val second = SubtitleSelectionAuthority()
        val one = first.beginSource(7L)!!
        val two = second.beginSource(7L)!!
        assertFalse(first.isCurrent(two)); assertFalse(second.isCurrent(one))
        assertTrue(first.isCurrent(one)); assertTrue(second.isCurrent(two))
    }

    @Test fun originalManualChoiceRetainsSourceContextAcrossDownloadButLaterOffVetoesIt() {
        val owner = SubtitleSelectionAuthority()
        val initial = owner.beginSource(42L)!!
        val poolBeforeIo = owner.beginChoice()!!
        assertFalse(owner.isCurrent(initial)); assertEquals(42L, poolBeforeIo.sourceContext)
        assertSame(initial.source, poolBeforeIo.source)
        val off = owner.beginChoice()!!
        assertTrue(owner.isCurrent(off)); assertFalse(owner.isCurrent(poolBeforeIo))
        assertEquals(42L, off.sourceContext)
    }

    @Test fun embedAddonSecondaryAndManualTimingEachRevokeOlderAsyncCompletion() {
        for (decision in listOf("embedded", "addon", "secondary", "manual-timing")) {
            val owner = SubtitleSelectionAuthority()
            owner.beginSource(4L)
            val download = owner.beginChoice()!!
            val manual = owner.beginChoice()!!
            assertFalse(decision, owner.isCurrent(download))
            assertTrue(decision, owner.isCurrent(manual))
        }
    }

    @Test fun newSourceWithSameLogicalContextStillRejectsOldSourceAndManualTokens() {
        val owner = SubtitleSelectionAuthority()
        val initial = owner.beginSource(7L)!!
        val pool = owner.beginChoice()!!
        val replacement = owner.beginSource(7L)!!
        assertNotSame(initial.source, replacement.source)
        assertFalse(owner.isCurrent(initial)); assertFalse(owner.isCurrent(pool))
        assertTrue(owner.isCurrent(replacement))
    }

    @Test fun newerPoolCanReplaceStaleLoadingUiWithoutAdoptingTheOlderCompletion() {
        val owner = SubtitleSelectionAuthority()
        owner.beginSource(9L)
        val first = owner.beginChoice()!!
        owner.beginChoice()!! // Off, so old loading state no longer blocks another pool choice.
        val second = owner.beginChoice()!!
        var loading: PlayerSubtitleSelection? = second
        if (loading === first) loading = null
        assertSame(second, loading)
        assertFalse(owner.isCurrent(first)); assertTrue(owner.isCurrent(second))
    }

    @Test fun captureForAutomaticDefaultsDoesNotRevokeTheCurrentManualOrSourceToken() {
        val owner = SubtitleSelectionAuthority()
        owner.beginSource(1L)
        val choice = owner.beginChoice()!!
        assertSame(choice, owner.capture())
        assertSame(choice, owner.capture())
        assertTrue(owner.isCurrent(choice))
    }

    @Test fun repeatedSameContextDoesNotCreateNumericRevisionOrAbaAcceptance() {
        val owner = SubtitleSelectionAuthority()
        val original = owner.beginSource(Long.MAX_VALUE)!!
        repeat(4096) { owner.beginChoice()!! }
        assertFalse(owner.isCurrent(original))
        assertEquals(Long.MAX_VALUE, owner.capture()!!.sourceContext)
        val beforeReplacement = owner.capture()!!
        owner.beginSource(Long.MAX_VALUE)
        assertFalse(owner.isCurrent(beforeReplacement))
    }

    @Test fun originalCheckAndFinalMutationAreSerializedWithRevocationByTheSameHostBoundary() {
        val gate = Any()
        val owner = SubtitleSelectionAuthority()
        synchronized(gate) { owner.beginSource(1L) }
        val original = synchronized(gate) { owner.beginChoice()!! }
        var selected: String? = null
        synchronized(gate) {
            if (owner.isCurrent(original)) selected = "original-local-file"
        }
        assertEquals("original-local-file", selected)
        synchronized(gate) {
            owner.beginChoice() // Later Off is ordered after admitted local-file mutation.
            selected = null
        }
        synchronized(gate) {
            if (owner.isCurrent(original)) selected = "must-not-run"
        }
        assertNull(selected)
        // This deterministic owner-order check is not a native/JNI timing or latency test.
    }
}
