package com.vortx.android.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackHistoryProjectionTest {
    @Test
    fun `history keeps an unsaved watched record but excludes a saved unwatched library record`() {
        val state = """
            {"catalog":[
              {"_id":"unsaved-watched","type":"movie","name":"Watched without save","temp":true,
               "state":{"timesWatched":1,"timeOffset":0,"duration":7200000}},
              {"_id":"saved-unwatched","type":"movie","name":"Saved only","temp":false,
               "state":{"timesWatched":0,"timeOffset":0,"duration":7200000}}
            ]}
        """.trimIndent()

        val history = EngineState.parsePlaybackHistoryStrict(state).getOrThrow()

        assertEquals(listOf("unsaved-watched"), history.map { it.id })
        assertTrue(history.single().watched)
    }
}
