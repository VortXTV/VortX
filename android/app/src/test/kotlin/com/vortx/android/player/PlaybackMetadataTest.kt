package com.vortx.android.player

import org.junit.Assert.*
import org.junit.Test

/** Pure current model assertions, UNRUN; not renderer, Media3/mpv or device proof. */
class PlaybackMetadataTest {
    @Test fun encodedWidthLabelsCinemaAndMissingDimensionsRemainUnknown() {
        assertEquals("4K", PlaybackMetadata(width = 3840, height = 1600).pills().single().text)
        assertTrue(PlaybackMetadata(height = 2160).pills().isEmpty())
    }
    @Test fun actualTransferOnlyNeverDisplayOrFilenameGuess() {
        assertEquals(PlaybackDynamicRange.PQ, PlaybackMetadata.mpvRange("pq"))
        assertEquals(PlaybackDynamicRange.HLG, PlaybackMetadata.mpvRange("hlg"))
        assertEquals(PlaybackDynamicRange.UNKNOWN, PlaybackMetadata.mpvRange("Dolby Vision filename"))
        assertTrue(PlaybackMetadata().pills().isEmpty())
        assertEquals("HDR", PlaybackMetadata(dynamicRange = PlaybackDynamicRange.PQ).pills().single().text)
    }
    @Test fun selectedAudioCarriesLanguageCodecAndExactChannelCountNotAtmos() {
        val text = PlaybackMetadata(audioSelected = true, audioLanguage = "en", audioCodec = "audio/eac3",
            audioChannels = 6).pills().single().text
        val language = java.util.Locale.forLanguageTag("en").getDisplayLanguage(java.util.Locale.getDefault())
        assertEquals("$language · EAC3 · 6ch", text)
        assertFalse(text.contains("Atmos")); assertFalse(text.contains("5.1"))
        assertTrue(PlaybackMetadata(audioLanguage = "fr", audioCodec = "aac", audioChannels = 8).pills().isEmpty())
    }
    @Test fun unknownAudioHasNeutralFallbackAndJocIsNotAnOutputClaim() {
        assertEquals("Audio", PlaybackMetadata(audioSelected = true, audioLanguage = "und",
            audioCodec = "Atmos filename", audioChannels = -1).pills().single().text)
        assertEquals("EAC3", PlaybackMetadata.codecLabel("audio/eac3-joc"))
    }
    @Test fun freshPhysicalLoadClearsEveryPriorMetadataField() {
        val prior = PlayerState(metadata = PlaybackMetadata(width = 3840, height = 2160,
            dynamicRange = PlaybackDynamicRange.DOLBY_VISION, audioSelected = true,
            audioLanguage = "ja", audioCodec = "aac", audioChannels = 2))
        assertEquals(3, prior.metadata.pills().size)
        assertTrue(freshPlayerStateForLoad().metadata.pills().isEmpty())
    }
}
