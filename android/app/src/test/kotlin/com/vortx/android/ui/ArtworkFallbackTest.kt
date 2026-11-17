package com.vortx.android.ui

import com.vortx.android.ui.components.artworkCandidates
import com.vortx.android.ui.components.nextArtworkCandidate
import com.vortx.android.ui.components.preferredArtworkCandidates
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

    @Test fun `wide art keeps episode precedence and never duplicates the poster request`() {
        val episode = "https://art.example/episode.jpg"
        val showBackdrop = "https://art.example/show.jpg"
        val poster = "https://art.example/poster.jpg?signature=Keep%2BMe"
        assertEquals(
            listOf(episode, showBackdrop),
            preferredArtworkCandidates(listOf(" $episode ", poster, showBackdrop, episode, null), " $poster "),
        )
        assertEquals(emptyList<String>(), preferredArtworkCandidates(listOf(poster, ""), poster))
    }
}
