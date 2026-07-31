package com.vortx.android.debrid

import com.vortx.android.engine.debridResolveTarget
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.viewmodel.episodeForResolve
import com.vortx.android.ui.viewmodel.DebridCacheEvidence
import com.vortx.android.ui.viewmodel.debridEpisodeForResolve
import com.vortx.android.ui.viewmodel.forOwner
import com.vortx.android.ui.viewmodel.ownerBoundResult
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DebridPlaybackProvenanceTest {

    @Test
    fun engineTargetCarriesInfoHashSelectedEpisodeAndFileIndexTogether() {
        val selected = Episode(
            id = "series:2:7",
            title = "Episode 7",
            season = 2,
            episode = 7,
        )
        val source = StreamSource(
            id = "opaque-handle#name",
            addon = "Test",
            title = "Season pack",
            isTorrent = true,
            infoHash = "authoritative-hash",
            fileIdx = 14,
        )

        val target = source.debridResolveTarget("fallback-handle", selected)

        assertEquals("authoritative-hash", target.infoHash)
        assertEquals(DebridResolver.Episode(2, 7), target.episode)
        assertEquals(14, target.fileIdx)
    }

    @Test
    fun engineTargetUsesHandleAndNoEpisodeForMovieSource() {
        val source = StreamSource(
            id = "fallback-handle#name",
            addon = "Test",
            title = "Movie",
            isTorrent = true,
            infoHash = null,
            fileIdx = 3,
        )

        val target = source.debridResolveTarget("fallback-handle", null)

        assertEquals("fallback-handle", target.infoHash)
        assertNull(target.episode)
        assertEquals(3, target.fileIdx)
    }

    @Test
    fun detailSelectionReturnsTheExactEpisodeRequestedByTheUi() {
        val first = Episode("series:2:1", "Episode 1", 2, 1)
        val second = Episode("series:2:2", "Episode 2", 2, 2)
        val detail = MetaDetail(
            id = "series",
            type = MediaType.SERIES,
            name = "Series",
            videos = listOf(first, second),
        )

        assertEquals(second, detail.episodeForResolve("series:2:2"))
        assertNull(detail.episodeForResolve("series:2:9"))
    }

    @Test
    fun playBestPreservesSeasonZeroEpisodeProvenance() {
        val special = Episode("series:0:1", "Special 1", 0, 1)

        assertEquals(DebridResolver.Episode(0, 1), special.debridEpisodeForResolve())
    }

    @Test
    fun providerResponseCannotTriggerDownstreamWorkAfterOwnerChanges() = runBlocking {
        var current = true
        var downstreamRan = false

        val error = runCatching {
            ownerFencedRequest(ownerIsCurrent = { current }) {
                current = false
                "provider-response"
            }
            downstreamRan = true
        }.exceptionOrNull()

        assertTrue(error is DebridResolver.DebridException.OwnerChanged)
        assertFalse(downstreamRan)
    }

    @Test
    fun oneUserActionCannotPublishAResultFromAnotherOwnerGeneration() = runBlocking {
        val ownerA = DebridOwnerToken(DebridOwnerScope.Account("account-a"), generation = 1)
        val ownerB = DebridOwnerToken(DebridOwnerScope.Account("account-b"), generation = 2)
        var current: DebridOwnerToken? = ownerA

        val result = ownerBoundResult(
            expectedOwner = ownerA,
            currentOwner = { current },
        ) {
            current = ownerB
            Result.success("url-from-a")
        }

        assertTrue(result.exceptionOrNull() is DebridResolver.DebridException.OwnerChanged)
    }

    @Test
    fun accountCacheEvidenceIsReadableOnlyByItsOwnerGeneration() {
        val ownerA = DebridOwnerToken(DebridOwnerScope.Account("account-a"), generation = 1)
        val ownerB = DebridOwnerToken(DebridOwnerScope.Account("account-b"), generation = 2)
        val evidence = DebridCacheEvidence(ownerA, setOf("hash-a"), setOf("nzb-a"))

        assertEquals(evidence, evidence.forOwner(ownerA))
        assertNull(evidence.forOwner(ownerB))
    }

    @Test
    fun staleOwnerReferenceIsRejectedEvenInsideFreshLinkWindow() = runBlocking {
        var state: DebridAccountOwnerState =
            DebridAccountOwnerState.Account("account-a", generation = 1)
        val binding = DebridAccountOwnerBinding().apply { bind { state } }
        val store = InMemoryStore()
        val keys = DebridKeys(store, binding)
        assertTrue(keys.setKey(DebridService.REAL_DEBRID, "key-a"))
        val oldOwner = keys.ownerToken()!!
        val ref = playbackRef(oldOwner)

        state = DebridAccountOwnerState.Account("account-a", generation = 2)

        val result = DebridCoordinator(DebridResolver(keys), keys).resumePlaybackURL(
            ref = ref,
            storedUrl = ref.url,
            linkSavedAtMillis = System.currentTimeMillis(),
        )

        assertEquals("", result.url)
        assertFalse(result.refreshed)
    }

    @Test
    fun currentOwnerReferenceKeepsFreshResumeInstant() = runBlocking {
        val binding = DebridAccountOwnerBinding().apply {
            bind { DebridAccountOwnerState.Account("account-a", generation = 1) }
        }
        val keys = DebridKeys(InMemoryStore(), binding)
        assertTrue(keys.setKey(DebridService.REAL_DEBRID, "key-a"))
        val ref = playbackRef(keys.ownerToken()!!)

        val result = DebridCoordinator(DebridResolver(keys), keys).resumePlaybackURL(
            ref = ref,
            storedUrl = ref.url,
            linkSavedAtMillis = System.currentTimeMillis(),
        )

        assertEquals(ref.url, result.url)
        assertTrue(result.refreshed)
    }

    @Test
    fun ownerChangeWhileFreshResumeIsEvaluatedRejectsTheStoredUrl() = runBlocking {
        var reads = 0
        val binding = DebridAccountOwnerBinding().apply {
            bind {
                reads++
                if (reads == 1) {
                    DebridAccountOwnerState.Account("account-a", generation = 1)
                } else {
                    DebridAccountOwnerState.Account("account-b", generation = 2)
                }
            }
        }
        val keys = DebridKeys(InMemoryStore(), binding)
        val ref = playbackRef(
            DebridOwnerToken(
                DebridOwnerScope.Account("account-a"),
                generation = 1,
            ),
        )

        val result = DebridCoordinator(DebridResolver(keys), keys).resumePlaybackURL(
            ref = ref,
            storedUrl = ref.url,
            linkSavedAtMillis = System.currentTimeMillis(),
        )

        assertEquals("", result.url)
        assertFalse(result.refreshed)
    }

    @Test
    fun staleExpectedOwnerStopsPlaybackResolveBeforeProviderWork() = runBlocking {
        val binding = DebridAccountOwnerBinding().apply {
            bind { DebridAccountOwnerState.Account("account-b", generation = 2) }
        }
        val keys = DebridKeys(InMemoryStore(), binding)
        val staleOwner = DebridOwnerToken(
            DebridOwnerScope.Account("account-a"),
            generation = 1,
        )
        val candidate = DebridCoordinator.DebridCandidate(
            infoHash = "0123456789abcdef",
        )

        val result = DebridCoordinator(DebridResolver(keys), keys).resolvePlaybackRef(
            candidate = candidate,
            expectedOwner = staleOwner,
        )

        assertNull(result)
    }

    private fun playbackRef(owner: DebridOwnerToken) =
        DebridCoordinator.DebridPlaybackRef(
            url = "https://example.invalid/video",
            service = DebridService.REAL_DEBRID,
            owner = owner,
            infoHash = "0123456789abcdef",
            torrentId = null,
            fileId = null,
            fileIdx = 4,
            episode = DebridResolver.Episode(season = 2, episode = 7),
        )

    private class InMemoryStore : DebridKeyValueStore {
        private val values = mutableMapOf<String, String>()
        private var claim: LegacyOwnerReservation = LegacyOwnerReservation.Missing

        override fun snapshot(vararg keys: String): DebridStorageSnapshot =
            DebridStorageSnapshot(
                DebridStorageAvailability.AVAILABLE,
                keys.distinct().associateWith { values[it] },
            )

        override fun write(values: Map<String, String?>): Boolean {
            values.forEach { (key, value) ->
                if (value == null) this.values.remove(key) else this.values[key] = value
            }
            return true
        }

        override fun legacyOwnerReservation(): LegacyOwnerReservation = claim

        override fun claimLegacyOwner(owner: String): Boolean {
            val existing = claim
            if (existing is LegacyOwnerReservation.Claimed) return existing.owner == owner
            claim = LegacyOwnerReservation.Claimed(owner)
            return true
        }
    }
}
