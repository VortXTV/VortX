package com.vortx.android.engine

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun newerStreamLoadGenerationSupersedesOlderRequest() {
        val fence = StreamLoadDispatchGate()
        val old = fence.begin()
        assertTrue(fence.isCurrent(old))

        val fresh = fence.begin()
        assertFalse(fence.isCurrent(old))
        assertTrue(fence.isCurrent(fresh))
    }

    @Test
    fun forceRefreshUnloadAndLoadStayAtomicAgainstNewerGeneration() {
        val gate = StreamLoadDispatchGate()
        val first = gate.begin()
        val unloadDispatched = CountDownLatch(1)
        val releaseLoad = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())
        val executor = Executors.newFixedThreadPool(2)

        try {
            val refresh = executor.submit {
                gate.dispatchCurrent(first, listOf("Unload", "Load")) { action ->
                    events += action
                    if (action == "Unload") {
                        unloadDispatched.countDown()
                        assertTrue(releaseLoad.await(2, TimeUnit.SECONDS))
                    }
                }
            }
            assertTrue(unloadDispatched.await(2, TimeUnit.SECONDS))

            val newer = executor.submit<Long> {
                val generation = gate.begin()
                events += "new:$generation"
                generation
            }
            assertFalse("newer generation entered between Unload and Load", newer.isDone)

            releaseLoad.countDown()
            refresh.get(2, TimeUnit.SECONDS)
            val latest = newer.get(2, TimeUnit.SECONDS)

            assertEquals(listOf("Unload", "Load", "new:$latest"), events)
            assertTrue(gate.isCurrent(latest))
        } finally {
            releaseLoad.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun appliedAddonOrderIsPreservedWhenTheSourceRankingUsesAddonOrder() {
        val groups = listOf(
            group("Third", "https://third.example/manifest.json"),
            group("First", "https://first.example/manifest.json"),
            group("Second", "https://second.example/manifest.json"),
        )

        val ordered = orderStreamGroupsByAppliedAddonOrder(
            groups,
            listOf("https://first.example/manifest.json", "https://second.example/manifest.json"),
        )

        assertEquals(listOf("First", "Second", "Third"), ordered.map { it.addon })
    }

    private fun group(addon: String, base: String) = StreamGroup(
        addon = addon,
        base = base,
        streams = listOf(
            StreamSource(
                id = addon,
                addon = addon,
                title = "1080p WEB",
                url = "https://cdn.example/$addon",
            ),
        ),
    )
}
