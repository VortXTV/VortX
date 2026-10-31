package com.vortx.android.singularity

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Contract tests for the authorized transport seams. Pages and POSTs are entirely synthetic: these tests
 * exercise the real page assembler, cursor guards, authorization checks, pacer and process ledger without
 * opening a URL or requiring a live account.
 */
class SourceIndexAuthorizedClientTest {
    @Test
    fun `missing moat prevents both authorized GET and POST`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization(token = null)
        var pageCalls = 0
        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { _, _, _, _ ->
                pageCalls += 1
                pageBytes(start = 0, count = 1, nextCursor = null, hasMore = false)
            },
        )

        var postCalls = 0
        SourceIndexClient.hoardAuthorizedUsing(
            contentId = CONTENT_ID,
            descriptors = listOf(descriptor(0)),
            authorization = authorization,
            pacer = immediatePacer(),
            ledger = SourceIndexUploadLedger(),
            post = { _, _, _, _ -> postCalls += 1 },
        )

        assertTrue(fetched.isEmpty())
        assertEquals(0, pageCalls)
        assertEquals(0, postCalls)
        authorization.close()
    }

    @Test
    fun `authorized assembler traverses 257 sources as 100 100 and 57`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val moatReads = AtomicInteger()
        val authorization = requireNotNull(
            SourceIndexLifecycle.issue(
                isCurrent = { true },
                moatProvider = { "moat-${moatReads.incrementAndGet()}" },
            ),
        )
        val cursors = mutableListOf<String?>()

        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { url, moat, pageAuthorization, _ ->
                assertEquals("moat-${cursors.size + 1}", moat)
                assertTrue(pageAuthorization === authorization)
                val cursor = cursorFrom(url)
                cursors += cursor
                when (cursor) {
                    null -> pageBytes(start = 0, count = 100, nextCursor = "c1", hasMore = true)
                    "c1" -> pageBytes(start = 100, count = 100, nextCursor = "c2", hasMore = true)
                    "c2" -> pageBytes(start = 200, count = 57, nextCursor = null, hasMore = false)
                    else -> error("unexpected cursor: $cursor")
                }
            },
        )

        assertEquals(257, fetched.size)
        assertEquals(257, fetched.mapNotNull { it.id }.toSet().size)
        assertEquals(listOf(null, "c1", "c2"), cursors)
        assertEquals(3, moatReads.get())
        authorization.close()
    }

    @Test
    fun `later page error discards the assembled prefix`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        var pageCalls = 0

        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { _, _, _, _ ->
                pageCalls += 1
                if (pageCalls == 1) {
                    pageBytes(start = 0, count = 100, nextCursor = "error", hasMore = true)
                } else {
                    throw IOException("synthetic page failure")
                }
            },
        )

        assertTrue(fetched.isEmpty())
        assertEquals(2, pageCalls)
        authorization.close()
    }

    @Test
    fun `revocation after page one prevents publishing a prefix`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        var pageCalls = 0

        val outcome = runCatching {
            SourceIndexClient.fetchPooledAuthorizedUsing(
                contentId = CONTENT_ID,
                authorization = authorization,
                nowNanos = { 0L },
                page = { _, _, _, _ ->
                    pageCalls += 1
                    if (pageCalls == 1) {
                        // A native/account/consent write can revoke the capability while the response is being
                        // decoded. The owned operation is canceled, so no already collected prefix is returned.
                        SourceIndexLifecycle.invalidate()
                        pageBytes(start = 0, count = 100, nextCursor = "c1", hasMore = true)
                    } else {
                        pageBytes(start = 100, count = 1, nextCursor = null, hasMore = false)
                    }
                },
            )
        }

        assertTrue(outcome.isFailure)
        assertEquals(1, pageCalls)
        authorization.close()
    }

    @Test
    fun `v1 page followed by an unversioned legacy page is rejected`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { url, _, _, _ ->
                if (cursorFrom(url) == null) {
                    pageBytes(start = 0, count = 1, nextCursor = "legacy", hasMore = true)
                } else {
                    legacyPage(start = 1, count = 1)
                }
            },
        )

        assertTrue(fetched.isEmpty())
        authorization.close()
    }

    @Test
    fun `cursor repetition is rejected before a loop can return duplicate pages`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        var pageCalls = 0
        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { _, _, _, _ ->
                pageCalls += 1
                pageBytes(
                    start = pageCalls,
                    count = 1,
                    nextCursor = "same",
                    hasMore = true,
                )
            },
        )

        assertTrue(fetched.isEmpty())
        assertEquals(2, pageCalls)
        authorization.close()
    }

    @Test
    fun `exact 64 KiB page is accepted while an oversized page is rejected`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val exactAuthorization = authorization()
        val exact = pageBytes(
            start = 0,
            count = 1,
            nextCursor = null,
            hasMore = false,
            padToBytes = 64 * 1024,
        )
        assertEquals(64 * 1024, exact.size)
        val accepted = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = exactAuthorization,
            nowNanos = { 0L },
            page = { _, _, _, _ -> exact },
        )
        assertEquals(1, accepted.size)
        exactAuthorization.close()

        val oversizedAuthorization = authorization()
        var oversizedCalls = 0
        val rejected = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = oversizedAuthorization,
            nowNanos = { 0L },
            page = { _, _, _, _ ->
                oversizedCalls += 1
                ByteArray(64 * 1024 + 1)
            },
        )
        assertTrue(rejected.isEmpty())
        assertEquals(1, oversizedCalls)
        oversizedAuthorization.close()
    }

    @Test
    fun `assembled byte budget rejects the page after exactly 8 MiB`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        var pageCalls = 0
        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { 0L },
            page = { url, _, _, _ ->
                val index = cursorFrom(url)?.removePrefix("p")?.toInt() ?: 0
                pageCalls += 1
                pageBytes(
                    start = index,
                    count = 1,
                    nextCursor = if (index < 128) "p${index + 1}" else null,
                    hasMore = index < 128,
                    padToBytes = 64 * 1024,
                )
            },
        )

        assertTrue(fetched.isEmpty())
        assertEquals(129, pageCalls)
        authorization.close()
    }

    @Test
    fun `deadline is checked by the injected clock and never returns a late prefix`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        var clockNanos = 0L
        var pageCalls = 0
        val fetched = SourceIndexClient.fetchPooledAuthorizedUsing(
            contentId = CONTENT_ID,
            authorization = authorization,
            nowNanos = { clockNanos },
            page = { _, _, _, _ ->
                pageCalls += 1
                // Enter page one while within budget, then cross the deadline before the assembler can
                // publish the decoded prefix.
                clockNanos = 30_000_000_000L
                pageBytes(start = 0, count = 1, nextCursor = null, hasMore = false)
            },
        )

        assertTrue(fetched.isEmpty())
        assertEquals(1, pageCalls)
        authorization.close()
    }

    @Test
    fun `authorized hoard chunks at sixteen and does not evict a full process ledger`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val chunkPosted = mutableListOf<List<SourceIndexClient.Descriptor>>()

        SourceIndexClient.hoardAuthorizedUsing(
            contentId = CONTENT_ID,
            descriptors = (0 until 17).map(::descriptor),
            authorization = authorization,
            pacer = immediatePacer(),
            ledger = SourceIndexUploadLedger(),
            post = { _, chunk, moat, pageAuthorization ->
                assertEquals("moat", moat)
                assertTrue(pageAuthorization === authorization)
                chunkPosted += chunk
            },
        )

        assertEquals(listOf(16, 1), chunkPosted.map { it.size })
        assertTrue(chunkPosted.all { it.size <= 16 })

        val capacityPosted = mutableListOf<List<SourceIndexClient.Descriptor>>()
        val capacityLedger = SourceIndexUploadLedger(maxEntries = 2)
        SourceIndexClient.hoardAuthorizedUsing(
            contentId = CONTENT_ID,
            descriptors = listOf(descriptor(0), descriptor(1), descriptor(2)),
            authorization = authorization,
            pacer = immediatePacer(),
            ledger = capacityLedger,
            post = { _, chunk, _, _ -> capacityPosted += chunk },
        )
        SourceIndexClient.hoardAuthorizedUsing(
            contentId = CONTENT_ID,
            descriptors = listOf(descriptor(2)),
            authorization = authorization,
            pacer = immediatePacer(),
            ledger = capacityLedger,
            post = { _, chunk, _, _ -> capacityPosted += chunk },
        )

        assertEquals(1, capacityPosted.size)
        assertEquals(listOf(0, 1), capacityPosted.single().map { it.id.substring(36).toInt(16) })
        authorization.close()
    }

    @Test
    fun `cancelled caller waiting for pace does not reserve its descriptors`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val pacer = immediatePacer()
        val ledger = SourceIndexUploadLedger()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val posted = mutableListOf<List<SourceIndexClient.Descriptor>>()

        coroutineScope {
            val first = async {
                SourceIndexClient.hoardAuthorizedUsing(
                    contentId = CONTENT_ID,
                    descriptors = listOf(descriptor(10)),
                    authorization = authorization,
                    pacer = pacer,
                    ledger = ledger,
                    post = { _, chunk, _, _ ->
                        posted += chunk
                        firstStarted.complete(Unit)
                        withTimeout(HANDSHAKE_TIMEOUT_MS) { releaseFirst.await() }
                    },
                )
            }
            withTimeout(HANDSHAKE_TIMEOUT_MS) { firstStarted.await() }
            val queued = async(start = CoroutineStart.UNDISPATCHED) {
                SourceIndexClient.hoardAuthorizedUsing(
                    contentId = CONTENT_ID,
                    descriptors = listOf(descriptor(11)),
                    authorization = authorization,
                    pacer = pacer,
                    ledger = ledger,
                    post = { _, chunk, _, _ -> posted += chunk },
                )
            }
            yield()
            queued.cancelAndJoin()
            releaseFirst.complete(Unit)
            withTimeout(HANDSHAKE_TIMEOUT_MS) { first.await() }
        }

        // If reservation happened before pacing, the retry would be silently suppressed. A retry must still
        // reach the injected POST after cancellation while the pacer mutex was held by the first caller.
        SourceIndexClient.hoardAuthorizedUsing(
            contentId = CONTENT_ID,
            descriptors = listOf(descriptor(11)),
            authorization = authorization,
            pacer = pacer,
            ledger = ledger,
            post = { _, chunk, _, _ -> posted += chunk },
        )
        assertTrue(posted.any { it.any { descriptor -> descriptor.id == descriptor(11).id } })
        authorization.close()
    }

    @Test
    fun `overlapping callers for one descriptor produce one paced POST`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val pacer = immediatePacer()
        val ledger = SourceIndexUploadLedger()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val postCalls = AtomicInteger()

        try {
            coroutineScope {
                val first = async {
                    SourceIndexClient.hoardAuthorizedUsing(
                        contentId = CONTENT_ID,
                        descriptors = listOf(descriptor(20)),
                        authorization = authorization,
                        pacer = pacer,
                        ledger = ledger,
                        post = { _, _, _, _ ->
                            postCalls.incrementAndGet()
                            firstStarted.complete(Unit)
                            withTimeout(HANDSHAKE_TIMEOUT_MS) { releaseFirst.await() }
                        },
                    )
                }
                withTimeout(HANDSHAKE_TIMEOUT_MS) { firstStarted.await() }
                val second = async(start = CoroutineStart.UNDISPATCHED) {
                    SourceIndexClient.hoardAuthorizedUsing(
                        contentId = CONTENT_ID,
                        descriptors = listOf(descriptor(20)),
                        authorization = authorization,
                        pacer = pacer,
                        ledger = ledger,
                        post = { _, _, _, _ -> postCalls.incrementAndGet() },
                    )
                }
                // Let the second caller reach the shared pacer while the first POST is held.
                yield()
                releaseFirst.complete(Unit)
                withTimeout(HANDSHAKE_TIMEOUT_MS) { first.await() }
                withTimeout(HANDSHAKE_TIMEOUT_MS) { second.await() }
            }
        } finally {
            releaseFirst.complete(Unit)
            authorization.close()
        }

        assertEquals(1, postCalls.get())
    }

    @Test
    fun `lease close cancels a queued hoard caller before it can reserve`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val pacer = immediatePacer()
        val ledger = SourceIndexUploadLedger()
        val firstStarted = CompletableDeferred<Unit>()
        val queuedStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val postCalls = AtomicInteger()

        try {
            coroutineScope {
                val first = async {
                    runCatching {
                        SourceIndexClient.hoardAuthorizedUsing(
                            contentId = CONTENT_ID,
                            descriptors = listOf(descriptor(30)),
                            authorization = authorization,
                            pacer = pacer,
                            ledger = ledger,
                            post = { _, _, _, _ ->
                                postCalls.incrementAndGet()
                                firstStarted.complete(Unit)
                                withTimeout(HANDSHAKE_TIMEOUT_MS) { releaseFirst.await() }
                            },
                        )
                    }
                }
                withTimeout(HANDSHAKE_TIMEOUT_MS) { firstStarted.await() }
                val queued = async(start = CoroutineStart.UNDISPATCHED) {
                    queuedStarted.complete(Unit)
                    runCatching {
                        SourceIndexClient.hoardAuthorizedUsing(
                            contentId = CONTENT_ID,
                            descriptors = listOf(descriptor(31)),
                            authorization = authorization,
                            pacer = pacer,
                            ledger = ledger,
                            post = { _, _, _, _ -> postCalls.incrementAndGet() },
                        )
                    }
                }
                withTimeout(HANDSHAKE_TIMEOUT_MS) { queuedStarted.await() }
                yield()
                authorization.close()
                releaseFirst.complete(Unit)

                val firstOutcome = runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { first.await() } }
                val queuedOutcome = runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { queued.await() } }
                assertTrue(firstOutcome.isFailure || firstOutcome.getOrNull()?.isFailure == true)
                assertTrue(queuedOutcome.isFailure || queuedOutcome.getOrNull()?.isFailure == true)
            }
        } finally {
            releaseFirst.complete(Unit)
            authorization.close()
        }

        assertEquals(1, postCalls.get())
    }

    @Test
    fun `lease revocation disconnects a blocking authorized operation before it is released`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val operationEntered = CompletableDeferred<Unit>()
        val releaseOperation = CountDownLatch(1)
        val operationExited = AtomicBoolean(false)
        val connection = FakeConnection(URL(VALID_SOURCE_URL))

        val pending = async {
            SourceIndexClient.authorizedConnection(
                url = VALID_SOURCE_URL,
                authorization = authorization,
                moat = "moat",
                openConnection = { connection },
                operation = { _, requireCurrent ->
                    try {
                        operationEntered.complete(Unit)
                        if (!releaseOperation.await(HANDSHAKE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                            throw IOException("synthetic operation release timed out")
                        }
                        requireCurrent()
                        "unreachable"
                    } finally {
                        operationExited.set(true)
                    }
                },
            )
        }
        try {
            withTimeout(HANDSHAKE_TIMEOUT_MS) { operationEntered.await() }
            val callerThread = Thread.currentThread()
            authorization.close()
            assertTrue(authorization.isRetired())
            val disconnectThread = withTimeout(HANDSHAKE_TIMEOUT_MS) { connection.disconnectedSignal.await() }
            assertTrue(disconnectThread !== callerThread)
            assertFalse(operationExited.get())
            releaseOperation.countDown()
            assertTrue(withTimeout(HANDSHAKE_TIMEOUT_MS) { runCatching { pending.await() }.isFailure })
        } finally {
            releaseOperation.countDown()
            pending.cancel()
            runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { pending.join() } }
            authorization.close()
        }
    }

    @Test
    fun `caller cancellation disconnects a blocking operation and does not wait for the network`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val operationEntered = CompletableDeferred<Unit>()
        val releaseOperation = CountDownLatch(1)
        val operationExited = AtomicBoolean(false)
        val connection = FakeConnection(URL(VALID_SOURCE_URL))

        val pending = async {
            SourceIndexClient.authorizedConnection(
                url = VALID_SOURCE_URL,
                authorization = authorization,
                moat = "moat",
                openConnection = { connection },
                operation = { _, requireCurrent ->
                    try {
                        operationEntered.complete(Unit)
                        if (!releaseOperation.await(HANDSHAKE_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                            throw IOException("synthetic operation release timed out")
                        }
                        requireCurrent()
                        "unreachable"
                    } finally {
                        operationExited.set(true)
                    }
                },
            )
        }
        try {
            withTimeout(HANDSHAKE_TIMEOUT_MS) { operationEntered.await() }
            val callerThread = Thread.currentThread()
            pending.cancel()
            assertTrue(pending.isCancelled)
            val disconnectThread = withTimeout(HANDSHAKE_TIMEOUT_MS) { connection.disconnectedSignal.await() }
            assertTrue(disconnectThread !== callerThread)
            assertFalse(operationExited.get())
        } finally {
            releaseOperation.countDown()
            pending.cancel()
            runCatching { withTimeout(HANDSHAKE_TIMEOUT_MS) { pending.join() } }
            authorization.close()
        }
    }

    @Test
    fun `foreign origin and missing moat reject before opening a connection`() = runBlocking {
        SourceIndexLifecycle.invalidate()
        val authorization = authorization()
        val factoryCalls = AtomicInteger()
        val factory: (URL) -> HttpURLConnection = {
            factoryCalls.incrementAndGet()
            FakeConnection(it)
        }

        assertTrue(
            runCatching {
                SourceIndexClient.authorizedConnection(
                    url = "https://evil.example/sources?content_id=$CONTENT_ID",
                    authorization = authorization,
                    moat = "moat",
                    openConnection = factory,
                    operation = { _, _ -> Unit },
                )
            }.isFailure,
        )
        assertTrue(
            runCatching {
                SourceIndexClient.authorizedConnection(
                    url = VALID_SOURCE_URL,
                    authorization = authorization,
                    moat = "",
                    openConnection = factory,
                    operation = { _, _ -> Unit },
                )
            }.isFailure,
        )
        assertEquals(0, factoryCalls.get())
        authorization.close()
    }

    private fun authorization(token: String? = "moat"): SourceIndexAuthorization = requireNotNull(
        SourceIndexLifecycle.issue(isCurrent = { true }, moatProvider = { token }),
    )

    private fun immediatePacer() = SourceUploadPacer(
        intervalMs = 0,
        nowMs = { 0L },
        sleepMs = { },
    )

    private fun descriptor(index: Int): SourceIndexClient.Descriptor = SourceIndexClient.Descriptor(
        kind = SourceIndexClient.Kind.TORRENT.wire,
        id = index.toString(16).padStart(40, '0'),
        quality = "1080p",
        sizeBytes = 0,
        seeders = null,
    )

    private fun pageBytes(
        start: Int,
        count: Int,
        nextCursor: String?,
        hasMore: Boolean,
        padToBytes: Int? = null,
    ): ByteArray {
        val root = JSONObject()
        root.put("paginationVersion", 1)
        root.put("sources", JSONArray().apply {
            for (index in start until (start + count)) {
                put(
                    JSONObject().apply {
                        put("kind", "torrent")
                        put("id", index.toString(16).padStart(40, '0'))
                        put("quality", "1080p")
                        put("sizeBytes", 0)
                        put("corroboration", 1)
                    },
                )
            }
        })
        root.put("hasMore", hasMore)
        if (nextCursor != null) root.put("nextCursor", nextCursor)
        val body = root.toString()
        return (padToBytes?.let { body.padEnd(it, ' ') } ?: body).toByteArray(Charsets.UTF_8)
    }

    private fun legacyPage(start: Int, count: Int): ByteArray {
        val root = JSONObject()
        root.put("sources", JSONArray().apply {
            for (index in start until (start + count)) {
                put(
                    JSONObject().apply {
                        put("kind", "torrent")
                        put("id", index.toString(16).padStart(40, '0'))
                        put("quality", "1080p")
                        put("corroboration", 1)
                    },
                )
            }
        })
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    private fun cursorFrom(url: String): String? = url.substringAfter("&cursor=", "").ifBlank { null }

    private class FakeConnection(url: URL) : HttpURLConnection(url) {
        val disconnectedSignal = CompletableDeferred<Thread>()

        @Volatile
        var disconnected: Boolean = false
            private set

        override fun disconnect() {
            disconnected = true
            disconnectedSignal.complete(Thread.currentThread())
        }

        override fun usingProxy(): Boolean = false

        override fun connect() = Unit
    }

    private companion object {
        const val CONTENT_ID = "tt1234567"
        const val VALID_SOURCE_URL = "https://sources.vortx.tv/sources?content_id=tt1234567&kind=torrent&paged=1"
        const val HANDSHAKE_TIMEOUT_MS = 5_000L
        const val HANDSHAKE_TIMEOUT_SECONDS = 5L
    }
}
