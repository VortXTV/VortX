package com.vortx.android.ui.viewmodel

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.LibraryItemInfo
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourceRequestFence
import com.vortx.android.engine.StreamRanking
import com.vortx.android.sources.SourcePrefsSnapshot
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
    fun `warm and cold binge ranking share explicit playing language without changing detail or global preferences`() {
        val preference = PlaybackBingeAudioPreference()
        val global = listOf("en")
        val detailHint = "de"
        val english = StreamSource("en", "Fixture", "Show 1080p English", url = "https://fixture.invalid/en")
        val french = english.copy(id = "fr", title = "Show 1080p French", url = "https://fixture.invalid/fr")
        val groups = listOf(StreamGroup("Fixture", listOf(english, french)))
        preference.select("fr")
        val coldPrefs = SourcePrefsSnapshot.DEFAULT.copy(audioLanguages = preference.languages(detailHint, global))
        val warmPrefs = SourcePrefsSnapshot.DEFAULT.copy(audioLanguages = preference.languages(detailHint, global))
        val settled = com.vortx.android.engine.SourceListState(groups = groups, best = english)
        assertEquals("fr", StreamRanking.best(settled.groups, prefs = coldPrefs)?.id)
        assertEquals("fr", StreamRanking.best(groups, prefs = warmPrefs)?.id)
        assertEquals(warmPrefs.audioLanguages, coldPrefs.audioLanguages)
        assertEquals("de", detailHint)
        assertEquals(listOf("en"), global)
        preference.reset()
        val resetPrefs = SourcePrefsSnapshot.DEFAULT.copy(audioLanguages = preference.languages(null, global))
        assertEquals("en", StreamRanking.best(groups, prefs = resetPrefs)?.id)
    }

    @Test
    fun `binge audio reset ends preference lifetime and every selection or reset fences ABA`() {
        val preference = PlaybackBingeAudioPreference()
        preference.select("fr")
        val first = preference.revision
        preference.select("en"); preference.select("fr")
        assertTrue(preference.revision > first)
        assertEquals(listOf("fr"), preference.languages(null, listOf("en")))
        val beforeReset = preference.revision
        preference.reset()
        assertTrue(preference.revision > beforeReset)
        assertNull(preference.language)
        assertEquals(listOf("de"), preference.languages("de", listOf("en")))
        assertEquals(listOf("en"), preference.languages(null, listOf("en")))
        preference.select("und")
        assertNull(preference.language)
        assertEquals(listOf("en"), preference.languages(null, listOf("en")))
    }

    @Test
    fun `episode rollback uses accepted season and has a first-selection fallback without accepting a provisional target`() {
        val episodes = listOf(Episode("E1", "First", 1, 1), Episode("E2", "Second", 2, 1))
        assertEquals(EpisodeSwitchRollbackTarget("E1", 1), episodeSwitchRollbackTarget("E1", "E2", 2, episodes))
        assertEquals(EpisodeSwitchRollbackTarget("E2", 2), episodeSwitchRollbackTarget(null, "E2", 2, episodes))
        assertEquals(EpisodeSwitchRollbackTarget(null, null), episodeSwitchRollbackTarget(null, null, null, episodes))
        assertEquals(EpisodeSwitchRollbackTarget("missing-accepted", null),
            episodeSwitchRollbackTarget("missing-accepted", "E2", 2, episodes))
    }

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
            manualEpisodeId = null,
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
            manualEpisodeId = null,
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
            manualEpisodeId = "s1e1",
        )

        assertEquals("s1e1", target?.id)
    }

    @Test
    fun `owner return restores original route hint after interim metadata falls back`() {
        val originalOwnerEpisodes = listOf(
            Episode("s1e1", "First", season = 1, episode = 1),
            Episode("s2e3", "Target", season = 2, episode = 3),
        )
        val interimOwnerEpisodes = listOf(Episode("s1e1", "First", season = 1, episode = 1))
        val hint = PreferredEpisode(season = 2, episode = 3)

        assertEquals(
            "s2e3",
            detailEpisodeTargetForRoute(originalOwnerEpisodes, hint, manualEpisodeId = null)?.id,
        )
        val interimTarget = detailEpisodeTargetForRoute(interimOwnerEpisodes, hint, manualEpisodeId = null)
            ?: detailEpisodeTargetOrder(interimOwnerEpisodes).first()
        assertEquals("s1e1", interimTarget.id)
        assertEquals(
            "s2e3",
            detailEpisodeTargetForRoute(originalOwnerEpisodes, hint, manualEpisodeId = null)?.id,
        )
    }

    @Test
    fun `manual choice survives owner metadata that temporarily lacks it`() {
        val originalOwnerEpisodes = listOf(
            Episode("s1e1", "First", season = 1, episode = 1),
            Episode("s2e3", "Trakt target", season = 2, episode = 3),
            Episode("s3e2", "Manual target", season = 3, episode = 2),
        )
        val interimOwnerEpisodes = listOf(Episode("s1e1", "First", season = 1, episode = 1))
        val hint = PreferredEpisode(season = 2, episode = 3)
        val manualEpisodeId = "s3e2"

        assertEquals(
            manualEpisodeId,
            detailEpisodeTargetForRoute(originalOwnerEpisodes, hint, manualEpisodeId)?.id,
        )
        val interimTarget = detailEpisodeTargetForRoute(interimOwnerEpisodes, hint, manualEpisodeId)
            ?: detailEpisodeTargetOrder(interimOwnerEpisodes).first()
        assertEquals("s1e1", interimTarget.id)
        assertEquals(
            manualEpisodeId,
            detailEpisodeTargetForRoute(originalOwnerEpisodes, hint, manualEpisodeId)?.id,
        )
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
    fun `saved special resumes but fresh or watched special chooses season one`() {
        val detail = MetaDetail("show", MediaType.SERIES, "Show", videos = listOf(
            Episode("special", "Special", season = 0, episode = 1),
            Episode("s1e2", "Second", season = 1, episode = 2),
            Episode("s1e1", "First", season = 1, episode = 1),
        ))
        assertEquals("s1e1" to false, detailPrimaryEpisode(detail)?.let { it.first.id to it.second })
        val saved = detail.copy(libraryItem = LibraryItemInfo("show", false, false, "special", 30_000L, 60_000L, 0))
        assertEquals("special" to true, detailPrimaryEpisode(saved)?.let { it.first.id to it.second })
        assertEquals("s1e1" to false, detailPrimaryEpisode(saved.copy(watchedVideoIds = setOf("special")))?.let { it.first.id to it.second })
        assertEquals("s1e1" to false, detailPrimaryEpisode(saved.copy(libraryItem = saved.libraryItem!!.copy(timeOffsetMs = 0)))?.let { it.first.id to it.second })
        assertEquals("special", detailEpisodeTargetForRoute(detail.videos, PreferredEpisode(0, 1), null)?.id)
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
    fun `filmography latest tap wins even when the first lookup completes last`() {
        val fence = DetailNavigationFence()
        val first = fence.begin()
        val latest = fence.begin()
        val opened = mutableListOf<String>()
        if (fence.accepts(latest)) opened += "latest"
        if (fence.accepts(first)) opened += "first"
        assertEquals(listOf("latest"), opened)
    }

    @Test
    fun `filmography back invalidates latest lookup before screen disposal`() {
        val fence = DetailNavigationFence()
        val pending = fence.begin()
        fence.invalidate()
        assertFalse(fence.accepts(pending))
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
