package com.vortx.android.player

import com.vortx.android.model.SubtitleRequestMetadata
import org.junit.Assert.assertEquals
import org.junit.Test

class SubtitleRequestMetadataTest {
    @Test fun exactFileHintsUseTheStremioExtraPathWithoutQueryInjection() {
        val hints = SubtitleRequestMetadata("Episode 9 & #1/%?.mkv", "0123456789abcdef", 6_750_000_000L)
        assertEquals("subtitles/series/tt123:1:9/videoHash=0123456789abcdef&videoSize=6750000000&filename=Episode%209%20%26%20%231%2F%25%3F.mkv.json",
            hints.resourcePath("series", "tt123:1:9"))
    }

    @Test fun absentAndInvalidMetadataKeepLegacyRequests() {
        assertEquals("subtitles/movie/tt123.json", SubtitleRequestMetadata().resourcePath("movie", "tt123"))
        assertEquals("subtitles/movie/tt123.json", SubtitleRequestMetadata(videoSize = -1).resourcePath("movie", "tt123"))
    }

    @Test fun unicodeAndReservedIdsCannotChangeTheResourceRoute() {
        assertEquals("subtitles/movie/id%2Fwith%3Fquery%23fragment/filename=%C3%A9%20%E6%97%A5.mkv.json",
            SubtitleRequestMetadata(filename = "é 日.mkv").resourcePath("movie", "id/with?query#fragment"))
    }
}
