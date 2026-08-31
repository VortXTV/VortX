package com.vortx.android.engine

import com.vortx.android.data.StreamLoadUpdate
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
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
    fun supersededGenerationRethrowsCancellationInsteadOfReturningFailureResult() = runBlocking {
        val gate = StreamLoadDispatchGate()
        val stale = gate.begin()
        gate.begin()
        var cancelled = false

        try {
            runCatchingStreamLoad {
                gate.dispatchCurrent(stale, listOf("Load")) { }
            }
        } catch (_: CancellationException) {
            cancelled = true
        }

        assertTrue("supersession must cancel the caller", cancelled)
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

    @Test
    fun fastLowPriorityThenSlowHighPriorityPublishesOrderedTerminalSnapshot() = runBlocking {
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
        val state = AtomicReference(streamState(high = "Loading", low = "Loading"))
        val dispatched = CountDownLatch(1)
        val partialRead = CountDownLatch(1)
        val updates = async(Dispatchers.Default) {
            streamLoadStateUpdates(
                changes = changes,
                dispatch = { dispatched.countDown() },
                readState = state::get,
                snapshot = { json ->
                    streamUpdate(json).also { update ->
                        if (update.groups.map(StreamGroup::addon) == listOf("low.invalid")) {
                            partialRead.countDown()
                        }
                    }
                },
                isCurrent = { true },
                timeoutMs = 2_000L,
            ).toList()
        }

        assertTrue(dispatched.await(2, TimeUnit.SECONDS))
        state.set(streamState(high = "Loading", low = "Ready"))
        changes.tryEmit(Unit)
        assertTrue(partialRead.await(2, TimeUnit.SECONDS))
        state.set(streamState(high = "Ready", low = "Ready"))
        changes.tryEmit(Unit)

        val snapshots = updates.await()
        assertTrue(snapshots.any { it.groups.map(StreamGroup::addon) == listOf("low.invalid") && !it.terminal })
        assertEquals(listOf("high.invalid", "low.invalid"), snapshots.last().groups.map(StreamGroup::addon))
        assertTrue(snapshots.last().terminal)
    }

    @Test
    fun allEmptyAnswersPublishAnImmediateTerminalSnapshot() = runBlocking {
        val state = AtomicReference(streamState(high = "Ready", low = "Err", empty = true))
        val update = streamLoadStateUpdates(
            changes = MutableSharedFlow(),
            dispatch = { },
            readState = state::get,
            snapshot = ::streamUpdate,
            isCurrent = { true },
            timeoutMs = 2_000L,
        ).toList().single()

        assertTrue(update.groups.isEmpty())
        assertEquals(2, update.loaded)
        assertEquals(2, update.total)
        assertTrue(update.terminal)
    }

    @Test
    fun stalePreviousGenerationCannotPublishAfterSupersession() = runBlocking {
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 2)
        val current = AtomicBoolean(true)
        val dispatched = CountDownLatch(1)
        val old = async(Dispatchers.Default) {
            runCatching {
                streamLoadStateUpdates(
                    changes = changes,
                    dispatch = { dispatched.countDown() },
                    readState = { streamState(high = "Loading", low = "Loading") },
                    snapshot = ::streamUpdate,
                    isCurrent = current::get,
                    timeoutMs = 2_000L,
                ).toList()
            }.exceptionOrNull()
        }

        assertTrue(dispatched.await(2, TimeUnit.SECONDS))
        current.set(false)
        changes.tryEmit(Unit)
        assertTrue(old.await() is CancellationException)
    }

    @Test
    fun repeatedRefindCollectorsReturnOnlyTheirOwnTerminalState() = runBlocking {
        suspend fun load(id: String): List<StreamLoadUpdate> {
            val json = streamState(high = "Ready", low = "Err", sourceId = id)
            return streamLoadStateUpdates(
                changes = MutableSharedFlow(),
                dispatch = { },
                readState = { json },
                snapshot = ::streamUpdate,
                isCurrent = { true },
                timeoutMs = 2_000L,
            ).toList()
        }

        assertTrue(load("first").single().groups.single().streams.single().id.contains("/first#first"))
        assertTrue(load("second").single().groups.single().streams.single().id.contains("/second#second"))
    }

    private fun streamUpdate(json: String): StreamLoadUpdate {
        val progress = EngineState.parseStreamLoadProgress(json)
        return StreamLoadUpdate(
            groups = EngineState.parseStreamGroups(json),
            loaded = progress.loaded,
            total = progress.total,
            terminal = progress.total > 0 && progress.loaded == progress.total,
        )
    }

    private fun streamState(
        high: String,
        low: String,
        empty: Boolean = false,
        sourceId: String = "source",
    ): String {
        fun entry(base: String, type: String, id: String): String {
            val content = when (type) {
                "Ready" -> if (empty) "[]" else """[{"url":"https://cdn.invalid/$id","name":"$id"}]"""
                else -> "null"
            }
            return if (type == "Ready") {
                """{"request":{"base":"https://$base.invalid"},"content":{"type":"Ready","content":$content}}"""
            } else {
                """{"request":{"base":"https://$base.invalid"},"content":{"type":"$type"}}"""
            }
        }
        return """{"streams":[${entry("high", high, sourceId)},${entry("low", low, "low")}] }"""
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
