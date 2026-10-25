package com.vortx.android.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeTorrentFallbackPolicyTest {
    @Test fun hashOnlyEpisodeHasNoRawFallback() {
        assertNull(nativeTorrentFallbackFileIndex(fileIdx = null, isEpisode = true))
    }

    @Test fun hashOnlyMovieKeepsExistingFileZeroFallback() {
        assertEquals(0, nativeTorrentFallbackFileIndex(fileIdx = null, isEpisode = false))
    }

    @Test fun explicitEpisodeAndMovieSelectorsArePreserved() {
        for (isEpisode in listOf(false, true)) {
            for (index in listOf(0, 1, 27)) {
                assertEquals(index, nativeTorrentFallbackFileIndex(fileIdx = index, isEpisode = isEpisode))
            }
        }
    }

    @Test fun negativeSelectorsNeverGainAFallback() {
        for (isEpisode in listOf(false, true)) {
            assertNull(nativeTorrentFallbackFileIndex(fileIdx = -1, isEpisode = isEpisode))
        }
    }
}
