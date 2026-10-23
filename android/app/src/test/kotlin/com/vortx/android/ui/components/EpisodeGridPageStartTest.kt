package com.vortx.android.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class EpisodeGridPageStartTest {
    @Test fun `the page holding the current episode opens first`() {
        assertEquals(0, episodeGridPageStart(targetIndex = 0, pageSize = 12))
        assertEquals(0, episodeGridPageStart(targetIndex = 11, pageSize = 12))
        assertEquals(12, episodeGridPageStart(targetIndex = 12, pageSize = 12))
        assertEquals(240, episodeGridPageStart(targetIndex = 251, pageSize = 12))
    }

    @Test fun `no current episode opens the first page`() {
        assertEquals(0, episodeGridPageStart(targetIndex = null, pageSize = 12))
        assertEquals(0, episodeGridPageStart(targetIndex = -1, pageSize = 12))
        assertEquals(0, episodeGridPageStart(targetIndex = 5, pageSize = 0))
    }
}
