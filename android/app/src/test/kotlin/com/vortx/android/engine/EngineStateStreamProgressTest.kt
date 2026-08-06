package com.vortx.android.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineStateStreamProgressTest {

    @Test
    fun countsReadyAndFailedRequestsAsSettledAcrossBothStreamArrays() {
        val progress = EngineState.parseStreamLoadProgress(
            """
            {
              "metaStreams": [
                {"content":{"type":"Ready","content":[]}},
                {"content":{"type":"Loading"}}
              ],
              "streams": [
                {"content":{"type":"Err","error":"offline"}},
                {"content":{"type":"Ready","content":[{"url":"https://example.invalid/video"}]}},
                {"request":{"base":"https://malformed.invalid"}}
              ]
            }
            """.trimIndent(),
        )

        assertEquals(5, progress.total)
        assertEquals(3, progress.loaded)
    }

    @Test
    fun malformedOrAbsentStateHasNoFalseSettlement() {
        assertEquals(EngineState.StreamLoadProgress(0, 0), EngineState.parseStreamLoadProgress("not-json"))
        assertEquals(EngineState.StreamLoadProgress(0, 0), EngineState.parseStreamLoadProgress("{}"))
    }

    @Test
    fun episodeScopedProgressAndGroupsExcludePreviouslyLoadedEpisode() {
        val json =
            """
            {
              "streams": [
                {
                  "request":{"base":"https://old.invalid","path":{"id":"show:1:1"}},
                  "content":{"type":"Ready","content":[{"url":"https://old.invalid/video"}]}
                },
                {
                  "request":{"base":"https://new.invalid","path":{"id":"show:1:2"}},
                  "content":{"type":"Loading"}
                }
              ]
            }
            """.trimIndent()

        assertTrue(EngineState.parseStreamGroups(json, "show:1:2").isEmpty())
        assertEquals(
            EngineState.StreamLoadProgress(loaded = 0, total = 1),
            EngineState.parseStreamLoadProgress(json, "show:1:2"),
        )
    }
}
