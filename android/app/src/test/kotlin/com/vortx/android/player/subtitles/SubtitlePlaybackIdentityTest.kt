package com.vortx.android.player.subtitles

import com.vortx.android.model.MediaRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitlePlaybackIdentityTest {

    @Test
    fun `resolved catalog identity preserves the episode coordinates`() {
        val catalogRef = MediaRef(isSeries = true, tmdb = 1399, season = 1, episode = 2, title = "Example")
        val resolved = SubtitlePlaybackIdentity.withResolvedImdb(catalogRef, "TT0944947")!!

        assertEquals("tt0944947", resolved.imdb)
        assertEquals(1399, resolved.tmdb)
        assertEquals(1, resolved.season)
        assertEquals(2, resolved.episode)
        assertEquals("imdb:tt0944947:1:2", SubtitlePoolContribution.contentKey(resolved))
    }

    @Test
    fun `invalid resolver output never creates a subtitle namespace`() {
        val ref = MediaRef(isSeries = false, tmdb = 1)
        assertNull(SubtitlePlaybackIdentity.withResolvedImdb(ref, "tmdb:1"))
        assertNull(SubtitlePlaybackIdentity.withResolvedImdb(ref, "not-an-id"))
    }

    @Test
    fun `pool identity remains available before a concrete duration arrives`() {
        val identity = SubtitlePlaybackIdentity.poolIdentity(
            ref = MediaRef(isSeries = false, imdb = "tt0111161"),
            durationMs = 0L,
            frameRate = null,
            releaseName = "Film.1080p.WEB-DL.x264",
        )!!

        assertEquals("imdb:tt0111161", identity.contentKey)
        assertTrue(identity.fingerprint.isNotBlank())
    }
}
