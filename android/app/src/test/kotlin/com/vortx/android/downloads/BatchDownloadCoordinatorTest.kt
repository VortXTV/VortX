package com.vortx.android.downloads

import com.vortx.android.data.*
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.*
import com.vortx.android.sources.SourcePrefsSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class BatchDownloadCoordinatorTest {
    private val owner = ContinueWatchingOwner("p", "a", "u", true, 1)
    private val episodes = (1..3).map { Episode("show:1:$it", "Episode $it", 1, it) }
    private val detail = MetaDetail("show", MediaType.SERIES, "Show", videos = episodes)
    private val source = StreamSource("source", "Provider", "1080p English", quality = "1080p", url = "https://example.test/video.mp4")
    private fun snapshot(desired: StreamSource? = source) = BatchDownloadSnapshot(detail, episodes, owner, null,
        SourcePrefsSnapshot.DEFAULT.copy(audioLanguages = listOf("en")), desired, null, null, false)

    private inner class Fixture {
        var activeOwner = owner
        var closed = false
        var leaseCloses = 0
        val fetched = mutableListOf<String>()
        val accepted = mutableListOf<String>()
        var capacity = true
        var resolver: suspend () -> Playable = {
            Playable("https://example.test/video.mp4", "Episode", playbackLease = AutoCloseable { leaseCloses++ })
        }
        val session = object : DownloadSourceSession {
            override val owner = this@BatchDownloadCoordinatorTest.owner
            override suspend fun streams(type: MediaType, id: String, episode: Episode?, rememberedQuality: String?,
                wantedAddon: String?): Result<List<StreamGroup>> {
                fetched += episode!!.id
                assertEquals("Provider", wantedAddon)
                assertEquals("1080p", rememberedQuality)
                return Result.success(listOf(StreamGroup("Provider", listOf(source))))
            }
            override fun pin(source: StreamSource, episode: Episode?) = object : DownloadSourceResolver {
                override val owner = this@BatchDownloadCoordinatorTest.owner
                override suspend fun resolve() = Result.success(resolver())
                override fun isCurrent() = activeOwner == owner
                override fun admit(action: () -> Unit): Boolean = isCurrent().also { if (it) action() }
            }
            override fun close() { closed = true }
        }
        val repo = object : CatalogRepository by PreviewCatalogRepository(0) {
            override fun continueWatchingOwner() = activeOwner
            override fun captureDownloadSession(expectedOwner: ContinueWatchingOwner) = session.takeIf { expectedOwner == activeOwner }
        }
        val queue = object : BatchDownloadQueue {
            override fun contains(videoId: String) = videoId in accepted
            override fun preparationHasCapacity() = capacity
            override fun accept(resolver: DownloadSourceResolver, playable: Playable, source: StreamSource,
                snapshot: BatchDownloadSnapshot, episode: Episode): DownloadRecord? {
                if (!resolver.admit { accepted += episode.id }) { playable.playbackLease?.close(); return null }
                // The fake retains the accepted lease; cancellation of the preparer must not close it.
                return DownloadRecord(contentId = detail.id, videoId = episode.id, type = "series", name = detail.name,
                    remoteURL = playable.url, localFilename = "test.mp4", state = DownloadState.QUEUED)
            }
        }
    }

    @Test fun `arbitrary selection is validated and ordered without duplicate targets`() {
        assertEquals(listOf(episodes[0], episodes[2]), BatchDownloadPolicy.select(detail, setOf(episodes[2].id, episodes[0].id)))
        assertThrows(IllegalArgumentException::class.java) { BatchDownloadPolicy.select(detail, setOf("other:1:1")) }
    }

    @Test fun `source continuity rejects another provider quality release or foreign language`() {
        val wanted = source.copy(bingeGroup = "release")
        val candidates = listOf(wanted, wanted.copy(id = "wrong-provider", addon = "Other"),
            wanted.copy(id = "wrong-quality", title = "720p English", quality = "720p"),
            wanted.copy(id = "wrong-release", bingeGroup = "different"),
            wanted.copy(id = "wrong-language", title = "1080p French"))
        assertEquals(listOf(wanted), BatchDownloadPolicy.candidates(snapshot(wanted), listOf(StreamGroup("Provider", candidates))))
    }

    @Test fun `explicit release flavor without binge group never silently changes to web`() {
        val bluray = source.copy(title = "1080p BluRay English")
        val web = source.copy(id = "web", title = "1080p WEB-DL English")
        assertTrue(BatchDownloadPolicy.candidates(snapshot(bluray), listOf(StreamGroup("Provider", listOf(web)))).isEmpty())
    }

    @Test fun `same source ID metadata changes cannot reuse stale release classification`() {
        val initial = source.copy(id = "metadata-reused-id")
        val web = source.copy(id = "metadata-web", title = "1080p WEB-DL English")
        assertEquals("", StreamRanking.releaseFlavor(initial))
        val changed = listOf(
            initial.copy(title = "1080p BluRay English"),
            initial.copy(description = "BluRay"),
            initial.copy(quality = "1080p BluRay"),
            initial.copy(filename = "episode.bluray.mkv"),
        )
        changed.forEach { wanted ->
            assertEquals(initial.id, wanted.id)
            assertEquals("BluRay", StreamRanking.releaseFlavor(wanted))
            assertTrue(BatchDownloadPolicy.candidates(snapshot(wanted), listOf(StreamGroup("Provider", listOf(web)))).isEmpty())
            assertEquals("", StreamRanking.releaseFlavor(initial))
        }
    }

    @Test fun `accepted items are independent and duplicate targets are skipped`() = runTest {
        val fixture = Fixture()
        fixture.accepted += episodes[0].id
        val coordinator = BatchDownloadCoordinator(fixture.repo, this, fixture.queue)
        assertTrue(coordinator.start(snapshot()) { true })
        runCurrent()
        assertEquals(episodes.map { it.id }, fixture.accepted)
        assertEquals(listOf(episodes[1].id, episodes[2].id), fixture.fetched)
        assertEquals(2, coordinator.state.value.accepted)
        assertEquals(0, fixture.leaseCloses)
        assertTrue(fixture.closed)
    }

    @Test fun `cancel at queue capacity leaves accepted producers untouched and stops pending fetches`() = runTest {
        val fixture = Fixture()
        fixture.accepted += episodes[0].id
        fixture.capacity = false
        val coordinator = BatchDownloadCoordinator(fixture.repo, this, fixture.queue)
        coordinator.start(snapshot()) { true }
        runCurrent()
        coordinator.cancel()
        runCurrent()
        assertTrue(fixture.fetched.isEmpty())
        assertEquals(listOf(episodes[0].id), fixture.accepted)
        assertEquals(0, fixture.leaseCloses)
        assertEquals(2, coordinator.state.value.items.count { it.state == BatchDownloadItemState.CANCELLED })
        assertTrue(fixture.closed)
    }

    @Test fun `owner switch during resolve rejects late lease and all remaining episodes`() = runTest {
        val fixture = Fixture()
        fixture.resolver = {
            fixture.activeOwner = owner.copy(profileId = "other", revision = 2)
            Playable("https://example.test/video.mp4", "Episode", playbackLease = AutoCloseable { fixture.leaseCloses++ })
        }
        val coordinator = BatchDownloadCoordinator(fixture.repo, this, fixture.queue)
        coordinator.start(snapshot()) { true }
        runCurrent()
        assertTrue(fixture.accepted.isEmpty())
        assertEquals(1, fixture.fetched.size)
        assertEquals(1, fixture.leaseCloses)
        assertFalse(coordinator.state.value.running)
    }

    @Test fun `noncooperative late resolve after cancellation closes lease exactly once`() = runTest {
        val fixture = Fixture()
        val gate = CompletableDeferred<Unit>()
        fixture.resolver = { withContext(NonCancellable) {
            gate.await()
            Playable("https://example.test/video.mp4", "Episode", playbackLease = AutoCloseable { fixture.leaseCloses++ })
        } }
        val coordinator = BatchDownloadCoordinator(fixture.repo, this, fixture.queue)
        coordinator.start(snapshot()) { true }
        runCurrent()
        coordinator.cancel()
        gate.complete(Unit)
        runCurrent()
        assertTrue(fixture.accepted.isEmpty())
        assertEquals(1, fixture.leaseCloses)
        assertTrue(fixture.closed)
    }

    @Test fun `lease retirement and duplicate terminal callbacks close only owned producer once`() {
        val registry = DownloadSourceLeases()
        var closes = 0
        registry.adopt("a", AutoCloseable { closes++ }, null)
        assertTrue(registry.isCurrent("a"))
        registry.retire("a")
        registry.retire("a")
        registry.remove("a")
        assertEquals(1, closes)
        assertFalse(registry.isCurrent("a"))
    }

    @Test fun `direct and HLS sources without producer leases retain native owner authority`() {
        val fixture = Fixture()
        val resolver = fixture.session.pin(source, episodes[0])!!
        val registry = DownloadSourceLeases()
        registry.adopt("direct", null, resolver)
        registry.adopt("hls", null, resolver)
        assertTrue(registry.isCurrent("direct"))
        registry.retire("hls")
        assertTrue(registry.isCurrent("hls"))
        fixture.activeOwner = owner.copy(profileId = "other", revision = 2)
        assertFalse(registry.isCurrent("direct"))
        assertFalse(registry.isCurrent("hls"))
    }
}
