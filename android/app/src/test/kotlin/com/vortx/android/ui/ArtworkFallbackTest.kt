package com.vortx.android.ui

import com.vortx.android.ui.components.artworkCandidates
import com.vortx.android.ui.components.nextArtworkCandidate
import org.junit.Assert.assertEquals
import org.junit.Test

class ArtworkFallbackTest {
    @Test fun `blank primary and duplicate fallbacks do not consume retries`() {
        val signed = "https://example.test/image.jpg?a=1&signature=Keep%2BMe"
        assertEquals(listOf(signed, "poster"), artworkCandidates(listOf(null, "", " \n", " $signed ", signed, "poster")))
    }
    @Test fun `each candidate gets only one attempt and stale errors cannot skip the next`() {
        assertEquals(1, nextArtworkCandidate(0, 0, 3))
        assertEquals(1, nextArtworkCandidate(1, 0, 3))
        assertEquals(2, nextArtworkCandidate(1, 1, 3))
        assertEquals(3, nextArtworkCandidate(2, 2, 3))
        assertEquals(3, nextArtworkCandidate(3, 2, 3))
        assertEquals(0, nextArtworkCandidate(0, 0, 0))
    }
}
