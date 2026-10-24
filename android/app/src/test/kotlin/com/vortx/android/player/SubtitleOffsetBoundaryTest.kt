package com.vortx.android.player

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual memory JSON functions, also runnable by the no-Android focused extraction lane. */
class SubtitleOffsetBoundaryTest {
    @Test fun originalOutOfBoundsValuesAreNotRoundedIntoValidity() {
        for (seconds in listOf(120.04, -120.04, Double.NaN, Double.POSITIVE_INFINITY)) {
            val text = mutateSubtitleOffsetJson(null, "imdb:tt12345", seconds, 3.0)
            assertNull(savedSubtitleOffset(text, "imdb:tt12345"))
            assertFalse(JSONObject(text).has("imdb:tt12345"))
        }
        for (seconds in listOf(120.0, -120.0)) {
            assertEquals(seconds, savedSubtitleOffset(mutateSubtitleOffsetJson(null, "imdb:tt12345", seconds,
                3.0), "imdb:tt12345")!!, 0.0)
        }
    }

    @Test fun zeroResetKeepsExistingDurableForgetContract() {
        val saved = mutateSubtitleOffsetJson(null, "imdb:tt12345", 1.26, 3.0)
        assertEquals(1.3, savedSubtitleOffset(saved, "imdb:tt12345")!!, 0.0)
        val reset = mutateSubtitleOffsetJson(saved, "imdb:tt12345", 0.0, 4.0)
        assertFalse(JSONObject(reset).has("imdb:tt12345"))
        assertNull(savedSubtitleOffset(reset, "imdb:tt12345"))
    }

    @Test fun rejectsCorruptMemoryWithoutDroppingAnotherValidTitle() {
        assertNull(savedSubtitleOffset("not-json", "imdb:tt12345"))
        val first = mutateSubtitleOffsetJson(null, "imdb:tt12345", -0.7, 3.0)
        val second = mutateSubtitleOffsetJson(first, "imdb:tt54321", 0.4, 4.0)
        val removed = mutateSubtitleOffsetJson(second, "imdb:tt12345", 0.0, 5.0)
        assertEquals(0.4, savedSubtitleOffset(removed, "imdb:tt54321")!!, 0.0)
        assertNull(savedSubtitleOffset(removed, "imdb:tt12345"))
    }
}
