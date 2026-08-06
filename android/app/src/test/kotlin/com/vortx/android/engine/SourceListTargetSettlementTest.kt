package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceIndexServeSource
import com.vortx.android.torbox.TorBoxSearch
import com.vortx.android.torbox.TorBoxSearchSource
import java.util.concurrent.Executors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.system.measureTimeMillis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceListTargetSettlementTest {

    @Test
    fun emptyContributorSettlementDoesNotBurnTheOuterDeadline() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val torbox = TorBoxSearchSource(
            scope = scope,
            fetchStreams = { _, _, _, _ ->
                TorBoxSearch.Result(emptyList(), rateLimited = false, transportError = false)
            },
        )
        val singularity = SourceIndexServeSource(
            scope = scope,
            fetchStreams = { _, _ -> emptyList() },
            testMarker = Unit,
        )
        val model = SourceListModel(scope, coalesceMs = 0L)
        val generation = 8L
        val target = "tt1234567:1:3"
        var settled: SourceListState? = null

        try {
            model.bind(torbox, singularity)
            model.setContext(
                SourceListModel.Context(
                    streamId = target,
                    requestGeneration = generation,
                    contentId = target,
                ),
            )
            model.setRawGroups(listOf(StreamGroup("Raw", listOf(direct("raw", "Raw")))))
            torbox.refresh("tt1234567", 1, 3, generation)
            singularity.refresh(target, isSignedIn = true, requestGeneration = generation)

            val elapsedMs = measureTimeMillis {
                settled = model.awaitSettledTarget(generation, target, deadlineMs = 2_000L)
            }
            assertNotNull(settled)
            assertTrue("settlement burned the deadline: ${elapsedMs}ms", elapsedMs < 1_500L)
        } finally {
            model.close()
            torbox.close()
            singularity.close()
        }
    }

    @Test
    fun singularityRejectsLateCanceledTargetPublication() = runBlocking {
        val dispatcher = Executors.newFixedThreadPool(2).asCoroutineDispatcher()
        val firstStarted = CompletableDeferred<Unit>()
        val secondStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val releaseSecond = CompletableDeferred<Unit>()
        val first = torrent("a".repeat(40), SourceIndexClient.GROUP_ADDON)
        val second = torrent("b".repeat(40), SourceIndexClient.GROUP_ADDON)
        val source = SourceIndexServeSource(
            scope = CoroutineScope(SupervisorJob() + dispatcher),
            fetchStreams = { contentId, _ ->
                if (contentId.endsWith(":1:1")) {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                    listOf(first)
                } else {
                    secondStarted.complete(Unit)
                    releaseSecond.await()
                    listOf(second)
                }
            },
            testMarker = Unit,
        )

        try {
            source.refresh("tt1234567:1:1", isSignedIn = true, requestGeneration = 1L)
            withTimeout(2_000L) { firstStarted.await() }
            source.refresh("tt1234567:1:2", isSignedIn = true, requestGeneration = 2L)
            withTimeout(2_000L) { secondStarted.await() }
            releaseFirst.complete(Unit)
            releaseSecond.complete(Unit)

            withTimeout(2_000L) {
                while (source.settlement.value != SourceContributorSettlement(2L, settled = true)) {
                    kotlinx.coroutines.yield()
                }
            }
            assertEquals("b".repeat(40), source.streams.value.single().infoHash)
        } finally {
            releaseFirst.complete(Unit)
            releaseSecond.complete(Unit)
            source.close()
            dispatcher.close()
        }
    }

    @Test
    fun targetSettlementRanksRawTorboxSingularityAndMediaServerTogether() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val torboxStream = torrent("b".repeat(40), "TorBox Search")
        val singularityStream = torrent("c".repeat(40), SourceIndexClient.GROUP_ADDON)
        val torbox = TorBoxSearchSource(
            scope = scope,
            fetchStreams = { _, _, _, _ ->
                TorBoxSearch.Result(listOf(torboxStream), rateLimited = false, transportError = false)
            },
        )
        val singularity = SourceIndexServeSource(
            scope = scope,
            fetchStreams = { _, _ -> listOf(singularityStream) },
            testMarker = Unit,
        )
        val model = SourceListModel(scope, coalesceMs = 0L)
        val generation = 7L
        val target = "tt1234567:1:2"
        val raw = listOf(StreamGroup("Raw Add-on", listOf(direct("raw", "Raw Add-on"))))
        val media = listOf(StreamGroup("Media Server", listOf(direct("media", "Media Server"))))

        model.bind(torbox, singularity)
        model.setContext(
            SourceListModel.Context(
                metaId = "tt1234567",
                streamId = target,
                requestGeneration = generation,
                contentId = target,
            ),
        )
        model.setRawGroups(raw)
        model.setMediaServerGroups(media)
        torbox.refresh("tt1234567", 1, 2, generation)
        singularity.refresh(target, isSignedIn = true, requestGeneration = generation)

        val settled = model.awaitSettledTarget(generation, target, deadlineMs = 2_000L)
        assertNotNull(settled)
        assertEquals(generation, settled!!.requestGeneration)
        assertEquals(target, settled.streamId)
        val addons = settled.groups.map { it.addon }.toSet()
        assertTrue("Raw Add-on" in addons)
        assertTrue(TorBoxSearch.GROUP_ADDON in addons)
        assertTrue(SourceIndexClient.GROUP_ADDON in addons)
        assertTrue("Media Server" in addons)

        model.close()
        torbox.close()
        singularity.close()
    }

    private fun direct(id: String, addon: String) = StreamSource(
        id = id,
        addon = addon,
        title = "1080p WEB-DL",
        url = "https://example.invalid/$id",
    )

    private fun torrent(hash: String, addon: String) = StreamSource(
        id = hash,
        addon = addon,
        title = "1080p WEB-DL",
        infoHash = hash,
    )
}
