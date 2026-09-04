package com.vortx.android.debrid

import com.vortx.android.engine.debridResolveTarget
import com.vortx.android.engine.usenetPlaybackFailure
import com.vortx.android.engine.usenetResolveTarget
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.viewmodel.DebridCacheEvidence
import com.vortx.android.ui.viewmodel.debridCandidateFor
import com.vortx.android.ui.viewmodel.debridEpisodeForResolve
import com.vortx.android.ui.viewmodel.episodeForResolve
import com.vortx.android.ui.viewmodel.forOwner
import com.vortx.android.ui.viewmodel.nativeDebridResumeRef
import com.vortx.android.ui.viewmodel.ownerBoundResult
import com.vortx.android.ui.viewmodel.torrentServicesFromCacheHits
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

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
    fun usenetTargetCarriesNzbHashRegexEpisodeAndFileIndexTogether() {
        val selected = Episode(
            id = "series:3:4",
            title = "Episode 4",
            season = 3,
            episode = 4,
        )
        val source = StreamSource(
            id = "opaque-source",
            addon = "Test",
            title = "Season pack",
            infoHash = "torrent-field-must-not-supply-usenet-identity",
            usenetKnownHash = "Authoritative-NZB-MD5",
            fileIdx = 9,
            nzbUrl = "https://example.invalid/fetch/pack",
            fileMustInclude = "(?i)S03E04.*\\.mkv$",
        )

        val target = source.usenetResolveTarget(selected)

        assertEquals("https://example.invalid/fetch/pack", target.nzbUrl)
        assertEquals("Authoritative-NZB-MD5", target.knownHash)
        assertEquals("(?i)S03E04.*\\.mkv$", target.fileMustInclude)
        assertEquals(DebridResolver.Episode(3, 4), target.episode)
        assertEquals(9, target.fileIdx)
    }

    @Test
    fun usenetResolveErrorsDescribeTheUsenetFailure() {
        assertEquals(
            "Usenet playback needs a TorBox debrid key or configured native NNTP provider.",
            usenetPlaybackFailure(DebridResolver.DebridException.NoKey).message,
        )
        assertEquals(
            "No playable video matched this Usenet source.",
            usenetPlaybackFailure(DebridResolver.DebridException.NoMatchingFile).message,
        )
        assertEquals(
            "This Usenet source is still preparing in TorBox.",
            usenetPlaybackFailure(DebridResolver.DebridException.NotReady).message,
        )
    }

    @Test
    fun normalUsenetPlaybackUsesCoordinatorNativeFallbackInsteadOfTorBoxOnlyResolver() {
        val repository = source("src/main/kotlin/com/vortx/android/engine/EngineStremioRepository.kt")
        val usenetBranch = repository.substringAfter("if (source.isUsenet) {")
            .substringBefore("} else if (!source.isTorrent")

        assertTrue(usenetBranch.contains("debridCoordinator.resolvePlaybackRef("))
        assertTrue(usenetBranch.contains("DebridCoordinator.DebridCandidate("))
        assertFalse(usenetBranch.contains("debridResolver.resolveUsenet("))
        assertTrue(usenetBranch.contains("?: throw usenetPlaybackFailure(DebridResolver.DebridException.NoKey)"))
        assertTrue(repository.contains("appContext = appContext"))
        assertTrue(repository.contains("usenetProviderStore = UsenetProviderStore(appContext)"))
        assertFalse(repository.contains("DebridResolver(DebridKeys(appContext))"))
    }

    @Test
    fun coordinatorKeepsTorBoxPrecedenceThenNativeFallbackAndDoesNotSwallowCancellation() {
        val coordinator = source("src/main/kotlin/com/vortx/android/debrid/DebridCoordinator.kt")
        val usenetBranch = coordinator.substringAfter("// USENET first:")
            .substringBefore("// Raw torrent only:")

        val torBox = usenetBranch.indexOf("keys.isConfigured(DebridService.TOR_BOX, owner)")
        val native = usenetBranch.indexOf("usenetProviderStore?.load()")
        assertTrue("TorBox must be attempted before the native provider", torBox >= 0 && torBox < native)
        assertTrue(usenetBranch.contains("catch (cancel: CancellationException) {\n                        throw cancel"))
        assertTrue(usenetBranch.contains("if (!keys.isCurrent(owner)) return@withTimeoutOrNull null"))
        assertTrue(usenetBranch.contains("isNativeFile = true"))
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
        val evidence = DebridCacheEvidence(
            owner = ownerA,
            credentialRevision = 7L,
            torrentServices = mapOf("hash-a" to DebridService.PREMIUMIZE),
            usenetUrls = setOf("nzb-a"),
        )

        assertEquals(evidence, evidence.forOwner(ownerA, credentialRevision = 7L))
        assertNull(evidence.forOwner(ownerA, credentialRevision = 8L))
        assertNull(evidence.forOwner(ownerB, credentialRevision = 7L))
    }

    @Test
    fun lowerRankedFailoverWinnerRetainsExactSourceOnSecondPlayResume() {
        val owner = DebridOwnerToken(DebridOwnerScope.Account("account-a"), generation = 1)
        val labeledBest = StreamSource(
            id = "best",
            addon = "Best add-on",
            title = "Labeled best 4K HDR",
            quality = "2160p HDR",
            isTorrent = true,
            infoHash = "best-hash",
        )
        val failoverWinner = StreamSource(
            id = "winner",
            addon = "Failover add-on",
            title = "Actual winner 1080p Dolby Vision Atmos",
            quality = "1080p Dolby Vision Atmos",
            isTorrent = true,
            infoHash = "winner-hash",
        )
        val playbackRef = DebridCoordinator.DebridPlaybackRef(
            url = "https://example.invalid/first",
            service = DebridService.PREMIUMIZE,
            owner = owner,
            infoHash = failoverWinner.infoHash!!,
            torrentId = 3,
            fileId = 8,
            fileIdx = 1,
        )
        val stored = nativeDebridResumeRef(
            targetId = "movie",
            winner = DebridCoordinator.PlayableWinner(
                ref = playbackRef,
                candidate = DebridCoordinator.DebridCandidate(
                    infoHash = failoverWinner.infoHash,
                    source = failoverWinner,
                ),
            ),
            fallbackSource = labeledBest,
            savedAtMs = 1L,
        )

        val firstPlay = stored.playable(
            resolvedUrl = stored.url,
            resumeMs = 0L,
            mediaRef = null,
            expectedDurationMs = 7_200_000L,
        )
        val secondPlay = stored.copy(url = "https://example.invalid/resumed").playable(
            resolvedUrl = "https://example.invalid/resumed",
            resumeMs = 42_000L,
            mediaRef = null,
            expectedDurationMs = 7_200_000L,
        )

        assertFalse(labeledBest == failoverWinner)
        assertEquals(failoverWinner, stored.source)
        assertEquals(failoverWinner.title, firstPlay.title)
        assertEquals(failoverWinner.title, secondPlay.title)
        assertTrue(firstPlay.isDolbyVision)
        assertTrue(firstPlay.isAtmos)
        assertEquals(firstPlay.isDolbyVision, secondPlay.isDolbyVision)
        assertEquals(firstPlay.isAtmos, secondPlay.isAtmos)
        assertFalse(secondPlay.viaStreamingServer)
        assertEquals(42_000L, secondPlay.startPositionMs)
    }

    @Test
    fun cacheConfirmedTorrentUsesTheProviderThatProvedTheHit() {
        val hash = "abcdef0123456789"
        val owner = DebridOwnerToken(DebridOwnerScope.Account("account-a"), generation = 1)
        val cacheHits = mapOf(
            hash to DebridCoordinator.CacheHit(
                service = DebridService.PREMIUMIZE,
                files = listOf(
                    DebridResolver.DebridFile(
                        id = 1,
                        name = "Movie.mkv",
                        shortName = "Movie.mkv",
                        size = 1_000L,
                    ),
                ),
            ),
        )
        val evidence = DebridCacheEvidence(
            owner = owner,
            credentialRevision = 3L,
            torrentServices = torrentServicesFromCacheHits(cacheHits),
            usenetUrls = emptySet(),
        )
        val candidate = debridCandidateFor(
            source = StreamSource(
                id = "torrent",
                addon = "Test",
                title = "Movie",
                isTorrent = true,
                infoHash = hash.uppercase(),
            ),
            torrentServices = evidence.torrentServices,
        )!!

        assertEquals(DebridService.PREMIUMIZE, candidate.confirmedCachedService)
        assertEquals(
            DebridService.PREMIUMIZE,
            torrentResolveService(
                confirmedCachedService = candidate.confirmedCachedService,
                configuredServices = listOf(
                    DebridService.REAL_DEBRID,
                    DebridService.PREMIUMIZE,
                ),
            ),
        )
        assertNull(
            torrentResolveService(
                confirmedCachedService = DebridService.PREMIUMIZE,
                configuredServices = listOf(DebridService.REAL_DEBRID),
            ),
        )
    }

    @Test
    fun usenetCandidateRemainsTorBoxOnlyAndDoesNotInheritTorrentProviderEvidence() {
        val nzbUrl = "https://example.invalid/release.nzb"
        val candidate = debridCandidateFor(
            source = StreamSource(
                id = "usenet",
                addon = "Test",
                title = "Usenet release",
                infoHash = "torrent-field-must-not-supply-usenet-identity",
                usenetKnownHash = "authoritative-nzb-md5",
                fileIdx = 6,
                nzbUrl = nzbUrl,
                fileMustInclude = "(?i)movie.*\\.mkv$",
            ),
            torrentServices = mapOf("unrelated" to DebridService.PREMIUMIZE),
        )!!

        assertEquals(nzbUrl, candidate.nzbUrl)
        assertEquals("authoritative-nzb-md5", candidate.usenetKnownHash)
        assertEquals("(?i)movie.*\\.mkv$", candidate.fileMustInclude)
        assertEquals(6, candidate.fileIdx)
        assertNull(candidate.confirmedCachedService)
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

    private fun source(relativePath: String): String {
        val candidates = listOf(
            File(relativePath),
            File("app/$relativePath"),
            File("android/app/$relativePath"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
