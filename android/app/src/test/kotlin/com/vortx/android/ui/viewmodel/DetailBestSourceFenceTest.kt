package com.vortx.android.ui.viewmodel

import com.vortx.android.engine.SourceListState
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourceRequestFence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DetailBestSourceFenceTest {
    @Test
    fun `episode B cannot reuse assembled best from episode A`() {
        val fence = SourceRequestFence("profile-a")
        val episodeA = fence.begin("profile-a", "show:1:1")
        val staleA = SourceListState(
            best = stream("episode-a"),
            requestGeneration = episodeA.generation,
            streamId = episodeA.targetId,
        )

        fence.begin("profile-a", "show:1:2")

        assertNull(currentAssembledBest(staleA, fence.currentToken()))
        assertEquals(
            "episode-b",
            bestSourceForCurrentRequest(
                state = staleA,
                request = fence.currentToken(),
                currentGroups = listOf(StreamGroup("Provider", listOf(stream("episode-b")))),
                rankCurrent = { it.single().streams.single() },
            )?.id,
        )
    }

    @Test
    fun `matching generation and target may use assembled best`() {
        val fence = SourceRequestFence("profile-a")
        val current = fence.begin("profile-a", "show:1:2")
        val episodeB = SourceListState(
            best = stream("episode-b"),
            requestGeneration = current.generation,
            streamId = current.targetId,
        )

        assertEquals("episode-b", currentAssembledBest(episodeB, current)?.id)
    }

    private fun stream(id: String) = StreamSource(
        id = id,
        addon = "Provider",
        title = id,
        url = "https://cdn.example/$id",
    )
}
