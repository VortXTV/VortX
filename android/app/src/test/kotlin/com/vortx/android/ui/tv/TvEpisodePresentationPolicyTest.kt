package com.vortx.android.ui.tv

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.ui.components.nextArtworkCandidate
import org.junit.Assert.*
import org.junit.Test

class TvEpisodePresentationPolicyTest {
    private val episode = Episode("tt-show:2:3", "A real episode", 2, 3, thumbnail = "thumbnail")
    private val detail = MetaDetail("tt-show", MediaType.SERIES, "Show", background = "background", poster = "poster")

    @Test fun `runtime is explicitly typical rather than invented episode duration`() {
        assertEquals("Typical · 45 min", tvEpisodeFacts(episode.id, null, " 45 min ", emptyList()))
    }
    @Test fun `selected episode displays only real accepted qualities`() {
        assertEquals("Typical · 45 min · 4K / 1080p", tvEpisodeFacts(episode.id, episode.id, "45 min", listOf("4K", "Others", "1080p", "4K")))
    }
    @Test fun `neighbor episode cannot inherit selected episode quality`() {
        assertEquals("Typical · 45 min", tvEpisodeFacts("tt-show:2:4", episode.id, "45 min", listOf("4K")))
    }
    @Test fun `missing runtime and unknown quality remain absent`() {
        assertNull(tvEpisodeFacts(episode.id, episode.id, " ", listOf("", "others", " Others ")))
        assertNull(tvEpisodeFacts(episode.id, null, null, listOf("1080p")))
    }
    @Test fun `stale or loading selected request has no quality fact`() {
        assertNull(tvEpisodeFacts(episode.id, episode.id, null, emptyList()))
    }
    @Test fun `art tries actual episode then background then poster in that order`() {
        val candidates = tvEpisodeArtwork(episode, detail)
        assertEquals(listOf("thumbnail", "background", "poster"), candidates)
        assertEquals("background", candidates[nextArtworkCandidate(0, 0, candidates.size)])
        assertEquals("poster", candidates[nextArtworkCandidate(1, 1, candidates.size)])
    }
    @Test fun `blank and duplicate metadata artwork does not add fake placeholders`() {
        assertEquals(listOf("poster"), tvEpisodeArtwork(episode.copy(thumbnail = " "), detail.copy(background = "poster")))
        assertTrue(tvEpisodeArtwork(episode.copy(thumbnail = null), detail.copy(background = null, poster = null)).isEmpty())
    }
}
