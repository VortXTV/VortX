package com.vortx.android.ui.viewmodel

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourceRequestFence
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DetailEpisodeTargetPolicyTest {
    @Test
    fun `route hint chooses its exact actual episode regardless of metadata order or title`() {
        val episodes = listOf(
            Episode("s3e1", "Season premiere", season = 3, episode = 1),
            Episode("s2e3", "Renamed by add-on", season = 2, episode = 3),
            Episode("s2e2", "Earlier", season = 2, episode = 2),
        )

        val target = detailEpisodeTargetForRoute(
            videos = episodes,
            preferredEpisode = PreferredEpisode(season = 2, episode = 3),
            selectedEpisodeId = null,
        )

        assertEquals("s2e3", target?.id)
    }

    @Test
    fun `new-season route hint uses coordinates and optional exact video identity`() {
        val episodes = listOf(
            Episode("old-id", "Episode", season = 4, episode = 1),
            Episode("new-id", "Episode", season = 5, episode = 1),
        )

        val target = detailEpisodeTargetForRoute(
            videos = episodes,
            preferredEpisode = PreferredEpisode(season = 5, episode = 1, videoIdentity = "new-id"),
            selectedEpisodeId = null,
        )

        assertEquals("new-id", target?.id)
    }

    @Test
    fun `stale invalid or wrong-identity route hints leave primary fallback available`() {
        val episodes = listOf(
            Episode("s1e1", "First", season = 1, episode = 1),
            Episode("s1e2", "Second", season = 1, episode = 2),
        )

        val staleTarget = detailEpisodeTargetForRoute(episodes, PreferredEpisode(1, 9), null)
        assertNull(staleTarget)
        assertEquals("s1e1", (staleTarget ?: detailEpisodeTargetOrder(episodes).first()).id)
        assertNull(detailEpisodeTargetForRoute(episodes, PreferredEpisode(-1, 1), null))
        assertNull(detailEpisodeTargetForRoute(episodes, PreferredEpisode(1, 2, "stale-id"), null))
    }

    @Test
    fun `manual episode selection takes precedence over a route hint`() {
        val episodes = listOf(
            Episode("s1e1", "First", season = 1, episode = 1),
            Episode("s1e2", "Second", season = 1, episode = 2),
        )

        val target = detailEpisodeTargetForRoute(
            videos = episodes,
            preferredEpisode = PreferredEpisode(1, 2),
            selectedEpisodeId = "s1e1",
        )

        assertEquals("s1e1", target?.id)
    }

    @Test
    fun `specials never outrank the first actual episode`() {
        val ordered = detailEpisodeTargetOrder(
            listOf(
                Episode("special", "Special", season = 0, episode = 1),
                Episode("s1e2", "Second", season = 1, episode = 2),
                Episode("s1e1", "First", season = 1, episode = 1),
            ),
        )

        assertEquals(listOf("s1e1", "s1e2"), ordered.map { it.id })
    }

    @Test
    fun `special-only titles retain their complete inventory`() {
        val ordered = detailEpisodeTargetOrder(
            listOf(
                Episode("special-2", "Second", season = 0, episode = 2),
                Episode("special-1", "First", season = 0, episode = 1),
            ),
        )

        assertEquals(listOf("special-1", "special-2"), ordered.map { it.id })
    }

    @Test
    fun `selection revision equality rejects a late old-language assembly`() {
        val old = DetailSourceSelectionRevision(requestGeneration = 4L, audioLanguage = "en")
        val newer = DetailSourceSelectionRevision(requestGeneration = 5L, audioLanguage = "fr")

        assertFalse(acceptsDetailSourceSelection(old, newer))
        assertTrue(acceptsDetailSourceSelection(newer, newer))
    }

    @Test
    fun `audio options follow source and addon order and omit unavailable settings`() {
        val groups = listOf(
            StreamGroup(
                addon = "French Addon",
                streams = listOf(StreamSource("fr", "French Addon", "WEB 1080p French", url = "https://fr")),
            ),
            StreamGroup(
                addon = "Japanese Addon",
                streams = listOf(StreamSource("ja", "Japanese Addon", "WEB 1080p Japanese", url = "https://ja")),
            ),
        )

        assertEquals(listOf("fr", "ja"), detailAudioLanguageOptions(groups).map { it.first })
        assertFalse(detailAudioLanguageOptions(groups).any { it.first == "en" })
    }

    @Test
    fun `subtitle-only language markers do not become audio choices`() {
        val groups = listOf(
            StreamGroup(
                addon = "Subs",
                streams = listOf(StreamSource("ko-subs", "Subs", "WEB 1080p korsub", url = "https://subs")),
            ),
        )

        assertTrue(detailAudioLanguageOptions(groups).isEmpty())
    }

    @Test
    fun `unsupported related types are not converted to movie lookups`() {
        assertFalse(canResolveRelatedDetail(MediaType.CHANNEL))
        assertFalse(canResolveRelatedDetail(MediaType.TV))
        assertTrue(canResolveRelatedDetail(MediaType.SERIES))
    }

    @Test
    fun `relation fence invalidation blocks an in-flight result after detail leaves`() {
        val fence = DetailNavigationFence()
        val stale = fence.begin()

        fence.invalidate()

        assertFalse(fence.accepts(stale))
        val current = fence.begin()
        assertTrue(fence.accepts(current))
    }

    @Test
    fun `warm source is retained only for the exact current owner and profile`() {
        val sourceFence = SourceRequestFence("profile-a")
        val request = sourceFence.begin("profile-a", "episode-2")
        val owner = ContinueWatchingOwner("profile-a", "primary", "account-a", true, 11L)
        val lease = WarmNextSourceLease(
            episodeId = "episode-2",
            source = StreamSource("source", "Addon", "WEB 1080p", url = "https://source"),
            profileId = "profile-a",
            owner = owner,
            sourceRequest = request,
            prewarmGeneration = 3L,
        )

        assertTrue(acceptsWarmNextSourceLease(lease, "episode-2", "profile-a", owner, request, 3L))
        assertFalse(
            acceptsWarmNextSourceLease(
                lease,
                "episode-2",
                "profile-a",
                owner.copy(revision = 12L),
                request,
                3L,
            ),
        )
        assertFalse(
            acceptsWarmNextSourceLease(
                lease,
                "episode-2",
                "profile-b",
                owner.copy(profileId = "profile-b", revision = 13L),
                request,
                3L,
            ),
        )
    }

    @Test
    fun `warm source publication rejects a replaced target or disposed generation`() {
        val sourceFence = SourceRequestFence("profile-a")
        val request = sourceFence.begin("profile-a", "episode-2")
        val owner = ContinueWatchingOwner("profile-a", "primary", "account-a", true, 11L)
        val lease = WarmNextSourceLease(
            episodeId = "episode-2",
            source = StreamSource("source", "Addon", "WEB 1080p", url = "https://source"),
            profileId = "profile-a",
            owner = owner,
            sourceRequest = request,
            prewarmGeneration = 3L,
        )

        val replacementRequest = sourceFence.begin("profile-a", "episode-3")
        assertFalse(acceptsWarmNextSourceLease(lease, "episode-3", "profile-a", owner, replacementRequest, 4L))
        assertFalse(acceptsWarmNextSourceLease(lease, "episode-2", "profile-a", owner, request, 4L))
    }

    @Test
    fun `delayed noncooperative completion after profile reset cannot publish`() = runTest {
        val sourceFence = SourceRequestFence("profile-a")
        val request = sourceFence.begin("profile-a", "episode-2")
        val ownerA = ContinueWatchingOwner("profile-a", "primary", "account-a", true, 11L)
        val ownerB = ContinueWatchingOwner("profile-b", "primary", "account-b", true, 12L)
        val delayedSource = CompletableDeferred<StreamSource>()
        val captured = WarmNextSourceLease(
            episodeId = "episode-2",
            source = StreamSource("placeholder", "Addon", "placeholder"),
            profileId = "profile-a",
            owner = ownerA,
            sourceRequest = request,
            prewarmGeneration = 3L,
        )
        var published: StreamSource? = null

        val oldRequest = launch {
            val source = delayedSource.await()
            val candidate = captured.copy(source = source)
            if (acceptsWarmNextSourceLease(candidate, "episode-2", "profile-b", ownerB, sourceFence.currentToken(), 4L)) {
                published = source
            }
        }
        runCurrent()

        // The old repository completion is deliberately delivered after the owner reset; no cancellation
        // cooperation is required for the lease to reject it.
        sourceFence.invalidate("profile-b")
        delayedSource.complete(StreamSource("late", "Addon", "late", url = "https://late"))
        runCurrent()

        assertTrue(oldRequest.isCompleted)
        assertNull(published)
    }
}
