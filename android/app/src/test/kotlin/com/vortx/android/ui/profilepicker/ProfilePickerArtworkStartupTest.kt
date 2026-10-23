package com.vortx.android.ui.profilepicker

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual production controller/codec, synthetic public catalog and image IO only. No account or network. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfilePickerArtworkStartupTest {
    private val movie = ProfilePickerArtworkCandidate("tt12345", "Public family fixture",
        listOf("https://images.metahub.space/background/big/tt12345/img"))
    private val poster = "https://images.metahub.space/poster/medium/tt12345/img"

    @Test fun cachedFirstMoviePublishesBeforeLiveCatalogCanComplete() = runTest {
        val live = CompletableDeferred<List<ProfilePickerArtworkCandidate>>()
        var catalogCalls = 0
        var imageHTTPCalls = 0
        lateinit var controller: ProfilePickerArtworkController
        controller = ProfilePickerArtworkController(
            fetchCandidates = {
                catalogCalls++
                assertEquals(movie, controller.movie.value) // Publication precedes this live await.
                live.await()
            },
            loadArtwork = { imageHTTPCalls++; error("Warm first movie cannot depend on image HTTP") },
            readCachedCandidates = { listOf(movie) },
            loadCachedArtwork = { assertEquals(movie.artworkURLs.single(), it); true },
        )
        val running = launch { controller.run(reducedMotion = true) }
        runCurrent()
        assertEquals(movie, controller.movie.value)
        assertEquals(1, catalogCalls); assertEquals(0, imageHTTPCalls)
        assertTrue(running.isActive)
        live.complete(emptyList()); running.join()
        assertEquals(movie, controller.movie.value) // Failed refresh cannot blank ready public art.
    }

    @Test fun firstImageAndPersistedSnapshotUseTheWinningFallbackOnly() = runTest {
        val candidate = movie.copy(artworkURLs = listOf("failed-background", "winning-poster"))
        val loads = mutableListOf<String>()
        val snapshots = mutableListOf<List<ProfilePickerArtworkCandidate>>()
        val controller = ProfilePickerArtworkController(
            fetchCandidates = { listOf(candidate) },
            loadArtwork = { loads += it; it == "winning-poster" },
            writeCachedCandidates = { snapshots += it.toList() },
        )
        controller.run(reducedMotion = true)
        assertEquals(listOf("failed-background", "winning-poster"), loads)
        assertEquals(listOf("winning-poster"), controller.movie.value?.artworkURLs)
        assertEquals(listOf("winning-poster"), snapshots.last().first().artworkURLs)
        controller.run(reducedMotion = true)
        assertEquals(2, loads.size) // Ready presentation does not retry the failed prefix.
    }

    @Test fun purgedDiskImageDoesNotPoisonLaterNormalLoadOfTheSameMovie() = runTest {
        var catalogCalls = 0
        var liveLoads = 0
        val controller = ProfilePickerArtworkController(
            fetchCandidates = { catalogCalls++; listOf(movie) },
            loadArtwork = { liveLoads++; true },
            readCachedCandidates = { listOf(movie) },
            loadCachedArtwork = { false },
        )
        controller.run(reducedMotion = true)
        assertEquals(1, catalogCalls); assertEquals(1, liveLoads)
        assertEquals(movie, controller.movie.value)
        assertTrue(controller.unavailableCandidateIDs().isEmpty())
    }

    @Test fun cancellationDuringCachedDecodeDoesNotPublishOrPermanentlySkipWarmSeed() = runTest {
        var cacheLoads = 0
        var catalogCalls = 0
        val decodeGate = CompletableDeferred<Unit>()
        val controller = ProfilePickerArtworkController(
            fetchCandidates = { catalogCalls++; emptyList() },
            loadArtwork = { error("No normal image load expected") },
            readCachedCandidates = { listOf(movie) },
            loadCachedArtwork = {
                cacheLoads++
                if (cacheLoads == 1) decodeGate.await()
                true
            },
        )
        val hidden = launch { controller.run(reducedMotion = true) }
        runCurrent(); assertEquals(1, cacheLoads); assertNull(controller.movie.value)
        hidden.cancelAndJoin()
        assertEquals(0, catalogCalls); assertTrue(controller.unavailableCandidateIDs().isEmpty())
        controller.run(reducedMotion = true)
        assertEquals(movie, controller.movie.value)
        assertEquals(2, cacheLoads); assertEquals(1, catalogCalls)
    }

    @Test fun cancelledLiveRefreshRetainsThePublishedCachedMovie() = runTest {
        val live = CompletableDeferred<List<ProfilePickerArtworkCandidate>>()
        val controller = ProfilePickerArtworkController(
            fetchCandidates = { live.await() },
            loadArtwork = { error("No image HTTP needed") },
            readCachedCandidates = { listOf(movie) },
            loadCachedArtwork = { true },
        )
        val running = launch { controller.run(reducedMotion = false) }
        runCurrent(); assertEquals(movie, controller.movie.value)
        running.cancelAndJoin()
        assertEquals(movie, controller.movie.value)
        assertTrue(controller.unavailableCandidateIDs().isEmpty())
    }

    @Test fun cacheCodecBoundsAndValidatesPublicPresentationOnly() {
        val now = 1_800_000_000_000L
        val accepted = movie.copy(artworkURLs = listOf(poster))
        val encoded = requireNotNull(ProfilePickerPublicArtworkCacheCodec.encode(listOf(accepted), now))
        assertEquals(listOf(accepted), ProfilePickerPublicArtworkCacheCodec.decode(encoded, now))
        assertEquals(emptyList<ProfilePickerArtworkCandidate>(),
            ProfilePickerPublicArtworkCacheCodec.decode(encoded, now + 8L * 24 * 60 * 60 * 1000))
        assertTrue(ProfilePickerPublicArtworkCacheCodec.decode(encoded, now - 1).isEmpty())
        assertTrue(ProfilePickerPublicArtworkCacheCodec.decode(" ".repeat(ProfilePickerPublicArtworkCacheCodec.MAX_BYTES + 1), now).isEmpty())
        assertTrue(ProfilePickerPublicArtworkCacheCodec.decode(
            JSONObject(encoded).put("profile", "fixture-private-not-allowed").toString(), now).isEmpty())
        for (url in listOf("https://127.0.0.1/art", "https://art.tailnet.invalid/art",
            "file:///fixture/art", "https://images.metahub.space/art?token=fixture",
            "https://user:fixture@images.metahub.space/art")) {
            assertNull(ProfilePickerPublicArtworkCacheCodec.encode(
                listOf(accepted.copy(artworkURLs = listOf(url))), now))
            assertTrue(ProfilePickerPublicArtworkCacheCodec.decode(
                JSONObject(encoded).apply { getJSONArray("movies").getJSONObject(0)
                    .put("urls", org.json.JSONArray(listOf(url))) }.toString(), now).isEmpty())
        }
    }
}
