package com.vortx.android.home

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionsHubLifecycleTest {
    @Test
    fun `provider loading is distinct from valid empty`() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val model = model(
            FakeCollectionsPreferences(),
            source(
                providers = { _, _ ->
                    started.complete(Unit)
                    release.await()
                    emptyList()
                },
            ),
        )

        try {
            val load = async { model.load() }
            withTimeout(5_000) { started.await() }
            assertTrue(model.snapshot.value.streamingLoading)
            assertFalse(model.snapshot.value.streamingLoadFailed)

            release.complete(Unit)
            withTimeout(5_000) { load.await() }
            assertFalse(model.snapshot.value.streamingLoading)
            assertFalse(model.snapshot.value.streamingLoadFailed)
            assertTrue(model.snapshot.value.streaming.isEmpty())
        } finally {
            release.complete(Unit)
            model.close()
        }
    }

    @Test
    fun `typed cold provider failures stay distinct from honest empty`() = runBlocking {
        val failures = listOf<() -> Throwable>(
            { CollectionsHubTransportFailure.Auth(401) },
            { CollectionsHubTransportFailure.Http(503) },
            { CollectionsHubTransportFailure.MalformedJson(IllegalArgumentException("malformed")) },
            { java.io.IOException("offline") },
        )

        failures.forEach { failure ->
            val model = model(
                FakeCollectionsPreferences(),
                source(providers = { _, _ -> throw failure() }),
            )
            try {
                model.load()
                assertTrue(model.snapshot.value.streamingLoadFailed)
                assertFalse(model.snapshot.value.streamingLoading)
                assertTrue(model.snapshot.value.streaming.isEmpty())
                assertTrue(model.snapshot.value.discover.isNotEmpty())
                assertTrue(model.snapshot.value.genres.isNotEmpty())
            } finally {
                model.close()
            }
        }

        val honestEmpty = model(FakeCollectionsPreferences(), source())
        try {
            honestEmpty.load()
            assertFalse(honestEmpty.snapshot.value.streamingLoadFailed)
            assertFalse(honestEmpty.snapshot.value.streamingLoading)
            assertTrue(honestEmpty.snapshot.value.streaming.isEmpty())
        } finally {
            honestEmpty.close()
        }
    }

    @Test
    fun `stale providers survive failure and successful retry clears warning`() = runBlocking {
        val calls = AtomicInteger()
        val preferences = FakeCollectionsPreferences().apply {
            saveProviderCache(
                "GB.auto",
                """[{"id":8,"title":"Cached provider"}]""",
                savedAtMillis = -1L,
            )
        }
        val model = model(
            preferences,
            source(
                providers = { _, _ ->
                    if (calls.incrementAndGet() == 1) throw java.io.IOException("offline")
                    listOf(providerTile(8, "Recovered provider"))
                },
            ),
        )

        try {
            model.load()
            assertTrue(model.snapshot.value.streamingLoadFailed)
            assertFalse(model.snapshot.value.streamingLoading)
            assertEquals(listOf("service:8"), model.snapshot.value.streaming.map(CollectionsHubTile::id))

            model.load()
            assertFalse(model.snapshot.value.streamingLoadFailed)
            assertFalse(model.snapshot.value.streamingLoading)
            assertEquals(listOf("service:8"), model.snapshot.value.streaming.map(CollectionsHubTile::id))
        } finally {
            model.close()
        }
    }

    @Test
    fun `successful empty providers replace stale cache before a later failure`() = runBlocking {
        val calls = AtomicInteger()
        val preferences = FakeCollectionsPreferences().apply {
            saveProviderCache(
                "GB.auto",
                """[{"id":8,"title":"Stale provider"}]""",
                savedAtMillis = -1L,
            )
        }
        val model = model(
            preferences,
            source(
                providers = { _, _ ->
                    if (calls.incrementAndGet() == 1) emptyList() else throw java.io.IOException("offline")
                },
            ),
        )

        try {
            model.load()
            assertFalse(model.snapshot.value.streamingLoadFailed)
            assertTrue(model.snapshot.value.streaming.isEmpty())

            model.load()

            assertEquals(2, calls.get())
            assertTrue(model.snapshot.value.streamingLoadFailed)
            assertTrue(model.snapshot.value.streaming.isEmpty())
        } finally {
            model.close()
        }
    }

    @Test
    fun `disable during load setup cannot republish enabled base snapshot`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val regionStarted = CountDownLatch(1)
        val releaseRegion = CountDownLatch(1)
        val regionCalls = AtomicInteger()
        val model = model(
            preferences = preferences,
            source = source(),
            deviceRegion = {
                if (regionCalls.incrementAndGet() > 1) {
                    regionStarted.countDown()
                    check(releaseRegion.await(5, TimeUnit.SECONDS))
                }
                "GB"
            },
        )

        try {
            val load = async(Dispatchers.Default) { model.load() }
            assertTrue(regionStarted.await(5, TimeUnit.SECONDS))
            preferences.enabled = false
            preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
            releaseRegion.countDown()
            withTimeout(5_000) { load.await() }

            assertFalse(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
        } finally {
            releaseRegion.countDown()
            model.close()
        }
    }

    @Test
    fun `queued open after disable cannot publish browse content`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val calls = mutableListOf<CollectionsHubTarget>()
        val firstTarget = CollectionsHubTarget.Discover(DiscoverList.TRENDING)
        val queuedTarget = CollectionsHubTarget.Discover(DiscoverList.LATEST)
        val model = model(
            preferences,
            source(
                loadPage = { target, _, _, _, _ ->
                    calls += target
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                    CollectionsHubPage(listOf(item("tt1234567")), hasMore = false)
                },
            ),
        )

        try {
            val first = async { model.open(firstTarget) }
            withTimeout(5_000) { firstStarted.await() }
            val queued = async { model.open(queuedTarget) }

            preferences.enabled = false
            preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
            releaseFirst.complete(Unit)
            withTimeout(5_000) {
                first.await()
                queued.await()
            }

            assertEquals(listOf(firstTarget), calls)
            assertFalse(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
        } finally {
            releaseFirst.complete(Unit)
            model.close()
        }
    }

    @Test
    fun `disabled direct open is inert and reenable restores ordinary load and browse`() = runBlocking {
        val preferences = FakeCollectionsPreferences().apply { enabled = false }
        val providerCalls = AtomicInteger()
        val pageCalls = AtomicInteger()
        val target = CollectionsHubTarget.Discover(DiscoverList.POPULAR)
        val model = model(
            preferences,
            source(
                providers = { _, _ ->
                    providerCalls.incrementAndGet()
                    listOf(providerTile(8, "Provider"))
                },
                loadPage = { _, _, _, _, _ ->
                    pageCalls.incrementAndGet()
                    CollectionsHubPage(listOf(item("tt7654321")), hasMore = false)
                },
            ),
        )

        try {
            model.open(target)
            assertEquals(0, pageCalls.get())
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)

            preferences.enabled = true
            preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
            model.load()
            model.open(target)

            assertEquals(1, providerCalls.get())
            assertEquals(1, pageCalls.get())
            assertTrue(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.CONTENT, model.browse.value.phase)
        } finally {
            model.close()
        }
    }

    @Test
    fun `settings generation suppresses a hostile late provider result`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val stale = providerTile(8, "Stale")
        val model = model(
            preferences,
            source(
                providers = { _, _ ->
                    started.complete(Unit)
                    withContext(NonCancellable) { release.await() }
                    listOf(stale)
                },
            ),
        )

        try {
            val load = async { model.load() }
            withTimeout(5_000) { started.await() }
            preferences.notify(COLLECTIONS_SELECTED_PROVIDERS_KEY)
            release.complete(Unit)
            withTimeout(5_000) { load.await() }

            assertTrue(model.snapshot.value.streaming.isEmpty())
            assertTrue(model.snapshot.value.enabled)
        } finally {
            release.complete(Unit)
            model.close()
        }
    }

    @Test
    fun `close unregisters settings and suppresses a non cooperative browse completion`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val model = model(
            preferences,
            source(
                loadPage = { _, _, _, _, _ ->
                    started.complete(Unit)
                    withContext(NonCancellable) { release.await() }
                    CollectionsHubPage(listOf(item("tt1234567")), hasMore = false)
                },
            ),
        )

        val open = async { model.open(CollectionsHubTarget.Discover(DiscoverList.TRENDING)) }
        withTimeout(5_000) { started.await() }
        model.close()
        release.complete(Unit)
        withTimeout(5_000) { open.await() }

        assertTrue(preferences.closed)
        assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
        assertFalse(model.snapshot.value.enabled)

        preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
        assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
        assertFalse(model.snapshot.value.enabled)
    }

    @Test
    fun `browse cancellation propagates and is never converted to an error`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val started = CompletableDeferred<Unit>()
        val model = model(
            preferences,
            source(
                loadPage = { _, _, _, _, _ ->
                    started.complete(Unit)
                    awaitCancellation()
                },
            ),
        )

        try {
            val open = async { model.open(CollectionsHubTarget.Discover(DiscoverList.POPULAR)) }
            withTimeout(5_000) { started.await() }
            open.cancelAndJoin()

            assertTrue(open.isCancelled)
            assertEquals(CollectionsHubBrowsePhase.LOADING, model.browse.value.phase)
            assertNull(model.browse.value.error)
        } finally {
            model.close()
        }
    }

    @Test
    fun `closing a browse session suppresses a hostile late pagination result`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val pageTwoStarted = CompletableDeferred<Unit>()
        val releasePageTwo = CompletableDeferred<Unit>()
        val model = model(
            preferences,
            source(
                loadPage = { _, _, _, page, _ ->
                    if (page == 1) {
                        CollectionsHubPage(listOf(item("tt1111111")), hasMore = true)
                    } else {
                        pageTwoStarted.complete(Unit)
                        withContext(NonCancellable) { releasePageTwo.await() }
                        CollectionsHubPage(listOf(item("tt2222222")), hasMore = false)
                    }
                },
            ),
        )

        try {
            model.open(CollectionsHubTarget.Discover(DiscoverList.LATEST))
            val pagination = async { model.loadMore() }
            withTimeout(5_000) { pageTwoStarted.await() }
            model.closeBrowse()
            releasePageTwo.complete(Unit)
            withTimeout(5_000) { pagination.await() }

            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
            assertTrue(model.browse.value.items.isEmpty())
        } finally {
            releasePageTwo.complete(Unit)
            model.close()
        }
    }

    @Test
    fun `disable before pagination publication stays idle and cleanly reenables`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val pageCalls = AtomicInteger()
        val publicationCalls = AtomicInteger()
        val target = CollectionsHubTarget.Discover(DiscoverList.POPULAR)
        val model = model(
            preferences = preferences,
            source = source(
                loadPage = { _, _, _, page, _ ->
                    pageCalls.incrementAndGet()
                    CollectionsHubPage(listOf(item("tt000000$page")), hasMore = page == 1)
                },
            ),
            beforePaginationPublication = {
                if (publicationCalls.incrementAndGet() == 1) {
                    preferences.enabled = false
                    preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
                }
            },
        )

        try {
            model.open(target)
            model.loadMore()

            assertEquals(1, pageCalls.get())
            assertFalse(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)

            preferences.enabled = true
            preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
            model.open(target)
            model.loadMore()

            assertTrue(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.CONTENT, model.browse.value.phase)
            assertEquals(listOf("tt0000001", "tt0000002"), model.browse.value.items.map(MetaItem::id))
            assertFalse(model.browse.value.loading)
            assertFalse(model.browse.value.hasMore)
        } finally {
            model.close()
        }
    }

    @Test
    fun `close browse before pagination publication cannot resurrect stale browse`() = runBlocking {
        val pageCalls = AtomicInteger()
        lateinit var model: CollectionsHubModel
        model = model(
            preferences = FakeCollectionsPreferences(),
            source = source(
                loadPage = { _, _, _, page, _ ->
                    pageCalls.incrementAndGet()
                    CollectionsHubPage(listOf(item("tt000000$page")), hasMore = page == 1)
                },
            ),
            beforePaginationPublication = { model.closeBrowse() },
        )

        try {
            model.open(CollectionsHubTarget.Discover(DiscoverList.LATEST))
            model.loadMore()

            assertEquals(1, pageCalls.get())
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
            assertTrue(model.browse.value.items.isEmpty())
        } finally {
            model.close()
        }
    }

    @Test
    fun `error empty and content are distinct and retry reuses the active category`() = runBlocking {
        val calls = AtomicInteger()
        val model = model(
            FakeCollectionsPreferences(),
            source(
                loadPage = { _, category, _, _, _ ->
                    when (calls.incrementAndGet()) {
                        1 -> throw IllegalStateException("offline")
                        2 -> CollectionsHubPage(emptyList(), hasMore = false)
                        else -> CollectionsHubPage(listOf(item("tt7654321", category.id)), hasMore = false)
                    }
                },
            ),
        )

        try {
            model.open(CollectionsHubTarget.Discover(DiscoverList.UPCOMING))
            assertEquals(CollectionsHubBrowsePhase.ERROR, model.browse.value.phase)

            model.retry()
            assertEquals(CollectionsHubBrowsePhase.EMPTY, model.browse.value.phase)

            model.retry()
            assertEquals(CollectionsHubBrowsePhase.CONTENT, model.browse.value.phase)
            assertEquals("movies", model.browse.value.selectedCategory?.id)
        } finally {
            model.close()
        }
    }

    @Test
    fun `successful final load more retry clears the stale error`() = runBlocking {
        val pageTwoCalls = AtomicInteger()
        val model = model(
            FakeCollectionsPreferences(),
            source(
                loadPage = { _, _, _, page, _ ->
                    when {
                        page == 1 -> CollectionsHubPage(listOf(item("tt1111111")), hasMore = true)
                        pageTwoCalls.incrementAndGet() == 1 -> throw IllegalStateException("hostile page two failure")
                        else -> CollectionsHubPage(listOf(item("tt2222222")), hasMore = false)
                    }
                },
            ),
        )

        try {
            model.open(CollectionsHubTarget.Discover(DiscoverList.TRENDING))
            model.loadMore()
            assertEquals(CollectionsHubError.LOAD_MORE, model.browse.value.error)

            model.loadMore()

            assertNull(model.browse.value.error)
            assertEquals(2, model.browse.value.page)
            assertFalse(model.browse.value.hasMore)
            assertEquals(listOf("tt1111111", "tt2222222"), model.browse.value.items.map(MetaItem::id))
        } finally {
            model.close()
        }
    }

    @Test
    fun `filtered empty first page advances to a playable second page`() = runBlocking {
        val requestedPages = mutableListOf<Int>()
        val model = model(
            FakeCollectionsPreferences(),
            source(
                loadPage = { _, _, _, page, _ ->
                    requestedPages += page
                    when (page) {
                        1 -> CollectionsHubPage(emptyList(), hasMore = true)
                        2 -> CollectionsHubPage(listOf(item("tt2222222")), hasMore = false)
                        else -> error("unexpected page $page")
                    }
                },
            ),
        )

        try {
            model.open(CollectionsHubTarget.Discover(DiscoverList.POPULAR))

            assertEquals(listOf(1, 2), requestedPages)
            assertEquals(CollectionsHubBrowsePhase.CONTENT, model.browse.value.phase)
            assertEquals(2, model.browse.value.page)
            assertEquals(listOf("tt2222222"), model.browse.value.items.map(MetaItem::id))
        } finally {
            model.close()
        }
    }

    @Test
    fun `perpetually filtered pages stop at the initial scan bound`() = runBlocking {
        val calls = AtomicInteger()
        val model = model(
            FakeCollectionsPreferences(),
            source(
                loadPage = { _, _, _, _, _ ->
                    calls.incrementAndGet()
                    CollectionsHubPage(emptyList(), hasMore = true)
                },
            ),
        )

        try {
            withTimeout(5_000) {
                model.open(CollectionsHubTarget.Discover(DiscoverList.LATEST))
            }

            assertTrue(calls.get() in 2..10)
            assertEquals(CollectionsHubBrowsePhase.ERROR, model.browse.value.phase)
        } finally {
            model.close()
        }
    }

    @Test
    fun `disabling collections fences hostile provider and browse completions`() = runBlocking {
        val preferences = FakeCollectionsPreferences()
        val providersStarted = CompletableDeferred<Unit>()
        val browseStarted = CompletableDeferred<Unit>()
        val releaseProviders = CompletableDeferred<Unit>()
        val releaseBrowse = CompletableDeferred<Unit>()
        val model = model(
            preferences,
            source(
                providers = { _, _ ->
                    providersStarted.complete(Unit)
                    withContext(NonCancellable) { releaseProviders.await() }
                    listOf(providerTile(8, "Stale provider"))
                },
                loadPage = { _, _, _, _, _ ->
                    browseStarted.complete(Unit)
                    withContext(NonCancellable) { releaseBrowse.await() }
                    CollectionsHubPage(listOf(item("tt9999999")), hasMore = false)
                },
            ),
        )

        try {
            val load = async { model.load() }
            val open = async { model.open(CollectionsHubTarget.Discover(DiscoverList.UPCOMING)) }
            withTimeout(5_000) {
                providersStarted.await()
                browseStarted.await()
            }

            preferences.enabled = false
            preferences.notify(SHOW_COLLECTIONS_HUB_KEY)
            assertFalse(model.snapshot.value.enabled)
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)

            releaseProviders.complete(Unit)
            releaseBrowse.complete(Unit)
            withTimeout(5_000) {
                load.await()
                open.await()
            }

            assertFalse(model.snapshot.value.enabled)
            assertTrue(model.snapshot.value.streaming.isEmpty())
            assertEquals(CollectionsHubBrowsePhase.IDLE, model.browse.value.phase)
            assertTrue(model.browse.value.items.isEmpty())
        } finally {
            releaseProviders.complete(Unit)
            releaseBrowse.complete(Unit)
            model.close()
        }
    }

    private fun model(
        preferences: FakeCollectionsPreferences,
        source: CollectionsHubSource,
        deviceRegion: () -> String = { "GB" },
        beforePaginationPublication: () -> Unit = {},
    ) = CollectionsHubModel(
        preferences = preferences,
        source = source,
        nowMillis = { 1_000L },
        deviceRegion = deviceRegion,
        tmdbCatalogSupported = { true },
        beforePaginationPublication = beforePaginationPublication,
    )

    private fun source(
        providers: suspend (String, List<Int>) -> List<CollectionsHubTile> = { _, _ -> emptyList() },
        loadPage: suspend (
            CollectionsHubTarget,
            CollectionsHubCategory,
            String,
            Int,
            Boolean,
        ) -> CollectionsHubPage = { _, _, _, _, _ -> CollectionsHubPage(emptyList(), false) },
    ) = object : CollectionsHubSource {
        override suspend fun providers(region: String, selectedProviderIds: List<Int>) =
            providers(region, selectedProviderIds)

        override suspend fun page(
            target: CollectionsHubTarget,
            category: CollectionsHubCategory,
            region: String,
            page: Int,
            tmdbCatalogSupported: Boolean,
        ) = loadPage(target, category, region, page, tmdbCatalogSupported)
    }

    private fun item(id: String, name: String = id) = MetaItem(id, MediaType.MOVIE, name)

    private fun providerTile(id: Int, title: String) = CollectionsHubTile(
        id = "service:$id",
        title = CollectionsHubLabel.Literal(title),
        target = CollectionsHubTarget.Service(id, title),
    )
}

private class FakeCollectionsPreferences : CollectionsHubPreferences {
    var enabled = true
    var cadence = COLLECTIONS_REFRESH_CADENCE_DEFAULT
    var selected = COLLECTIONS_SELECTED_PROVIDERS_DEFAULT
    var closed = false
        private set
    private var listener: ((String) -> Unit)? = null
    private val caches = mutableMapOf<String, CollectionsHubProviderCache>()

    override fun enabled(): Boolean = enabled
    override fun refreshCadence(): String = cadence
    override fun selectedProviders(): String = selected
    override fun providerCache(scope: String): CollectionsHubProviderCache =
        caches[scope] ?: CollectionsHubProviderCache(null, 0L)

    override fun saveProviderCache(scope: String, encoded: String, savedAtMillis: Long) {
        caches[scope] = CollectionsHubProviderCache(encoded, savedAtMillis)
    }

    override fun observe(listener: (String) -> Unit) {
        check(this.listener == null)
        this.listener = listener
    }

    override fun close() {
        closed = true
        listener = null
    }

    fun notify(key: String) {
        listener?.invoke(key)
    }
}
