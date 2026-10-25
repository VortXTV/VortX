package com.vortx.android.player

import org.junit.Assert.*
import org.junit.Test

class PlaybackOwnerEpochTest {
    @Test fun originalEpochNeverRenewsAfterSamePublicOwnerOrSourceReturns() {
        val original = PlaybackOwnerEpoch.capture()!!
        PlaybackOwnerEpoch.transition { assertNull(PlaybackOwnerEpoch.capture()) }
        val replacement = PlaybackOwnerEpoch.capture()!!
        assertFalse(original.isActive); assertTrue(replacement.isActive); assertNotSame(original, replacement)
    }

    @Test fun nestedPublicationCannotExposeAnIntermediateOwnerOrReopenTheOldEpoch() {
        val original = PlaybackOwnerEpoch.capture()!!
        PlaybackOwnerEpoch.transition {
            assertFalse(original.isActive); assertNull(PlaybackOwnerEpoch.capture())
            PlaybackOwnerEpoch.transition { assertNull(PlaybackOwnerEpoch.capture()) }
            assertNull(PlaybackOwnerEpoch.capture())
        }
        assertTrue(PlaybackOwnerEpoch.capture()!!.isActive)
        assertFalse(original.isActive)
    }

    @Test fun failedPublicationPreservesCallerFailureButRequiresAFreshEngine() {
        val original = PlaybackOwnerEpoch.capture()!!
        val marker = IllegalStateException("synthetic persistence refusal")
        val failure = runCatching { PlaybackOwnerEpoch.transition<Unit> { throw marker } }.exceptionOrNull()
        assertSame(marker, failure)
        assertFalse(original.isActive)
        assertTrue(PlaybackOwnerEpoch.capture()!!.isActive)
    }

    @Test fun retiredTokenCannotBeMadeCurrentByOpeningAnotherSource() {
        val first = PlaybackOwnerEpoch.capture()!!
        PlaybackOwnerEpoch.invalidate()
        val next = PlaybackOwnerEpoch.capture()!!
        assertFalse(first.nativeLiveness.get()); assertTrue(next.nativeLiveness.get())
        assertNotSame(first.nativeLiveness, next.nativeLiveness)
    }

    @Test fun originalCandidateCannotAdoptANewEpochDuringManagerOrAvailabilityProof() {
        val beforeProof = PlaybackOwnerEpoch.capture()!!
        assertTrue(PlaybackOwnerEpoch.isCurrent(beforeProof))
        PlaybackOwnerEpoch.transition {
            assertNull(PlaybackOwnerEpoch.capture())
            assertFalse(PlaybackOwnerEpoch.isCurrent(beforeProof))
        }
        val afterProof = PlaybackOwnerEpoch.capture()!!
        assertFalse(PlaybackOwnerEpoch.isCurrent(beforeProof))
        assertTrue(PlaybackOwnerEpoch.isCurrent(afterProof))
        assertNotSame(beforeProof, afterProof)
    }
}
