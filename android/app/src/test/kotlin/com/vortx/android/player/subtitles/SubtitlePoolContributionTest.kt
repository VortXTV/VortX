package com.vortx.android.player.subtitles

import com.vortx.android.model.MediaRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the pure decision surface of [SubtitlePoolContribution] (content key, fingerprint, format
 * inference, upload gate). The network + moat + [android.content.Context] paths are fail-soft integration glue
 * exercised on device.
 */
class SubtitlePoolContributionTest {

    @Test
    fun contentKeyForMovieAndEpisodeMatchesApple() {
        assertEquals(
            "imdb:tt0111161",
            SubtitlePoolContribution.contentKey(MediaRef(isSeries = false, imdb = "tt0111161")),
        )
        assertEquals(
            "imdb:tt0903747:1:1",
            SubtitlePoolContribution.contentKey(
                MediaRef(isSeries = true, imdb = "tt0903747", season = 1, episode = 1),
            ),
        )
    }

    @Test
    fun contentKeyNullWithoutImdbIdentity() {
        // tmdb-only ref (no imdb) has no pool content key.
        assertNull(SubtitlePoolContribution.contentKey(MediaRef(isSeries = false, tmdb = 456)))
        // An imdb field that is actually a tmdb: id must not mint a bogus tt key.
        assertNull(SubtitlePoolContribution.contentKey(MediaRef(isSeries = false, imdb = "tmdb:456")))
        // A series episode missing the episode number no-ops rather than mis-keying.
        assertNull(
            SubtitlePoolContribution.contentKey(
                MediaRef(isSeries = true, imdb = "tt0903747", season = 1, episode = null),
            ),
        )
        assertNull(SubtitlePoolContribution.contentKey(null))
    }

    @Test
    fun fingerprintIsStableAndRipSpecific() {
        val a = SubtitlePoolContribution.fingerprint(releaseName = "Show.S01E01.1080p.WEB-DL.x264-GRP")
        val b = SubtitlePoolContribution.fingerprint(releaseName = "Show.S01E01.1080p.WEB-DL.x264-GRP")
        assertEquals(a, b)
        val bluray = SubtitlePoolContribution.fingerprint(releaseName = "Show.S01E01.2160p.BluRay.REMUX.HEVC")
        assertTrue(a != bluray)
    }

    @Test
    fun subtitleFormatInferenceMatchesApple() {
        assertEquals("srt", SubtitlePoolContribution.subtitleFormatFromUrl("https://x/y.srt"))
        assertEquals("vtt", SubtitlePoolContribution.subtitleFormatFromUrl("https://x/y.vtt"))
        assertEquals("ass", SubtitlePoolContribution.subtitleFormatFromUrl("https://x/y.ass"))
        // Unknown / missing extension defaults to srt (the worker's treatment of unknowns).
        assertEquals("srt", SubtitlePoolContribution.subtitleFormatFromUrl("https://x/y.xyz"))
        assertEquals("srt", SubtitlePoolContribution.subtitleFormatFromUrl("https://x/y"))
    }

    @Test
    fun embeddedUploadGateIsLocalFileOnly() {
        assertTrue(SubtitlePoolContribution.canUploadEmbedded("/data/user/0/x/movie.mkv"))
        assertFalse(SubtitlePoolContribution.canUploadEmbedded("https://cdn/movie.mkv"))
        assertFalse(SubtitlePoolContribution.canUploadEmbedded("http://127.0.0.1:11470/stream"))
    }
}
