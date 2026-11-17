package com.vortx.android.downloads

import com.vortx.android.integrations.buildMediaRef
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.model.Playable
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.viewmodel.matchingRememberedEpisodeSource
import com.vortx.android.player.autoSkipMediaIdentity
import com.vortx.android.player.DownloadedNaturalEndAdmission
import com.vortx.android.player.PlayerState
import com.vortx.android.player.isDownloadedNaturalCompletion
import com.vortx.android.player.isLocalFilePlayback
import com.vortx.android.player.subtitleOffsetContentKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AND-DL-01 regression: a LOCAL playback session must carry its own immutable identity, built from
 * the [DownloadRecord], so that after streaming title A, playing downloaded B moves ONLY B's
 * scrobble / subtitle / skip / trickplay / resume identity -- never A's. Covers the gate matrix:
 * phone and TV produce the same binding (one shared builder), movie and episode shapes, and the
 * owner-profile vs overlay-profile split. The PlayerScreen-side host-callback gates are composition
 * logic; the identity derivations they consume are proven here.
 */
class OfflinePlaybackIdentityTest {
    private val ownerEngine = PlaybackContext.Owner(profileId = "owner-profile", usesEngineHistory = true)
    private val ownerOverlay = PlaybackContext.Owner(profileId = "kids-profile", usesEngineHistory = false)

    @Test
    fun `partial metadata leaves omitted downloads available without duplicating listed episodes`() {
        val listed = episodeRecord()
        val otherId = listed.copy(id = "different-video", videoId = "another-video")
        val nextEpisode = listed.copy(id = "next-episode", videoId = "exact-next", episode = 2)
        val video = Episode(listed.videoId, "Listed episode", 3, 1)
        val admitted = DownloadedTitleAvailability(listOf(listed, otherId, nextEpisode), allowsMetadataFallback = true)

        assertEquals(listOf(otherId, nextEpisode), admitted.unlistedEpisodes(listOf(video)))
        assertEquals(listOf(listed, otherId, nextEpisode), admitted.unlistedEpisodes(emptyList()))
        assertEquals(emptyList<DownloadRecord>(), admitted.copy(allowsMetadataFallback = false).unlistedEpisodes(listOf(video)))
        assertEquals(listOf(listed, otherId, nextEpisode), admitted.copy(allowsMetadataFallback = false).unlistedEpisodes(emptyList()))
        assertEquals(emptyList<DownloadRecord>(), DownloadedTitleAvailability().unlistedEpisodes(listOf(video)))
    }

    @Test
    fun `offline next requires exact immediate successor in same series and season`() {
        val current = episodeRecord().copy(season = 1, episode = 2)
        val currentContext = current.playbackContext(PlaybackContext.Owner("local", true))
        val next = current.copy(videoId = "exact-next", episode = 3, state = DownloadState.COMPLETED)
        val gap = next.copy(videoId = "gap", episode = 4)
        val rollover = next.copy(videoId = "rollover", season = 2, episode = 1)
        assertEquals(next, immediateDownloadedSuccessor(currentContext, listOf(gap, next)))
        assertNull(immediateDownloadedSuccessor(currentContext, listOf(next)) { false })
        assertNull(immediateDownloadedSuccessor(currentContext, listOf(gap, rollover)))
        assertNull(immediateDownloadedSuccessor(currentContext, listOf(next.copy(contentId = "other"))))
        assertNull(immediateDownloadedSuccessor(currentContext, listOf(next.copy(state = DownloadState.PAUSED))))
        assertNull(immediateDownloadedSuccessor(
            currentContext, listOf(next, next.copy(videoId = "ambiguous-alias")),
        ))
    }

    @Test
    fun `downloaded early EOF cannot open a successor despite a healthy advertised duration`() {
        val playable = episodeRecord().localPlayable("file:///fixture.mp4", PlaybackContext.Owner("local", true))
        val early = PlayerState(positionMs = 10_000L, durationMs = 2_400_000L, hasEnded = true)
        val credits = early.copy(positionMs = 2_160_000L)
        assertFalse(isDownloadedNaturalCompletion(playable, early))
        assertFalse(isDownloadedNaturalCompletion(playable, credits.copy(positionMs = 2_150_000L)))
        assertTrue(isDownloadedNaturalCompletion(playable, credits))
        assertFalse(isDownloadedNaturalCompletion(playable, credits.copy(hasEnded = false)))
        assertFalse(isDownloadedNaturalCompletion(playable, credits.copy(hasError = true)))
    }

    @Test
    fun `retired terminal offer stays invalid even after replay ends again`() {
        var ended = true
        val original = DownloadedNaturalEndAdmission { ended }
        assertTrue(original.isCurrent())
        ended = false
        assertFalse(original.isCurrent())
        original.retire()
        ended = true
        assertFalse(original.isCurrent())
        assertTrue(DownloadedNaturalEndAdmission { ended }.isCurrent())
    }

    @Test
    fun `manual downloaded playback resumes only a real unfinished local offset`() {
        assertEquals(120_000L, playableDownloadResumeMs(120_000L, 2_400_000L))
        assertEquals(0L, playableDownloadResumeMs(2_160_000L, 2_400_000L))
        assertEquals(0L, playableDownloadResumeMs(120_000L, 0L))
        assertEquals(0L, playableDownloadResumeMs(-1L, 2_400_000L))
    }

    @Test
    fun continueWatchingMovieMatchesOnlyExactCompletedCopy() {
        val movie = movieRecord()
        val item = MetaItem(movie.contentId, MediaType.MOVIE, movie.name)
        val target = requireNotNull(continueWatchingDownloadTarget(item))
        assertTrue(target.matches(movie))
        assertFalse(target.matches(movie.copy(contentId = "other")))
        assertFalse(target.matches(movie.copy(videoId = "other")))
        assertFalse(target.matches(movie.copy(episode = 1)))
        assertFalse(target.matches(movie.copy(state = DownloadState.PAUSED)))
        assertNull(continueWatchingDownloadTarget(item.copy(watched = true)))
        assertNull(continueWatchingDownloadTarget(item.copy(continueWatchingUnavailableMessage = "unavailable")))
    }

    @Test
    fun continueWatchingSeriesRequiresExactUnfinishedEpisodeAndCoordinates() {
        val episode = episodeRecord()
        val hint = PreferredEpisode(3, 1, episode.videoId)
        val item = MetaItem(episode.contentId, MediaType.SERIES, episode.name, preferredEpisode = hint, watched = true)
        val target = requireNotNull(continueWatchingDownloadTarget(item))
        assertTrue(target.matches(episode))
        assertFalse(target.matches(episode.copy(contentId = "other")))
        assertFalse(target.matches(episode.copy(videoId = "other:3:1")))
        assertFalse(target.matches(episode.copy(season = 4)))
        assertFalse(target.matches(episode.copy(episode = 2)))
        assertNull(continueWatchingDownloadTarget(item.copy(preferredEpisode = null)))
        assertNull(continueWatchingDownloadTarget(item.copy(preferredEpisode = hint.copy(videoIdentity = null))))
        assertNull(continueWatchingDownloadTarget(item.copy(preferredEpisode = hint.copy(upNext = true))))
        assertNull(continueWatchingDownloadTarget(item.copy(preferredEpisode = hint.copy(episode = 0))))
    }

    @Test
    fun continueWatchingRememberedEpisodeSourceRejectsInstanceAndPhysicalFileAmbiguity() {
        val saved = StreamSource("source", "Configured", "Episode", isTorrent = true, infoHash = "hash", fileIdx = 3)
        val current = saved.copy(nativePlaybackToken = "fresh-lease")
        val group = StreamGroup(saved.addon, listOf(current), base = "https://example.test/config-a")
        assertTrue(matchingRememberedEpisodeSource(listOf(group), saved) === current)
        assertNull(matchingRememberedEpisodeSource(listOf(group.copy(base = "")), saved))
        assertNull(matchingRememberedEpisodeSource(listOf(group, group.copy(addon = "Alias", streams = emptyList())), saved))
        assertNull(matchingRememberedEpisodeSource(listOf(group, group.copy(base = "https://example.test/config-b",
            streams = listOf(current.copy(id = "another-source")))), saved))
        assertNull(matchingRememberedEpisodeSource(listOf(group.copy(streams = listOf(current, current))), saved))
        assertNull(matchingRememberedEpisodeSource(listOf(group.copy(streams = listOf(current.copy(fileIdx = 4)))), saved))
    }

    private fun movieRecord() = DownloadRecord(
        id = "dl-movie",
        contentId = "tt0111161",
        videoId = "tt0111161",
        type = "movie",
        name = "The Shawshank Redemption",
        poster = "https://example.test/movie-poster.jpg",
        sourceName = "Torrentio 4K",
        qualityText = "2160p",
        remoteURL = "https://example.test/movie.mkv",
        localFilename = "dl-movie.mkv",
        state = DownloadState.COMPLETED,
    )

    private fun episodeRecord() = DownloadRecord(
        id = "dl-episode",
        contentId = "tt0108778",
        videoId = "tt0108778:3:1",
        type = "series",
        name = "Friends",
        poster = "https://example.test/show-poster.jpg",
        season = 3,
        episode = 1,
        sourceName = "Torrentio HD",
        qualityText = "1080p",
        isTorrent = true,
        debridOwnerIdentity = "account:account-a",
        debridOwnerGeneration = 7,
        remoteURL = "https://example.test/s03e01.mkv",
        localFilename = "dl-episode.mkv",
        state = DownloadState.COMPLETED,
    )

    /** The STREAMED twin of an episode play, built exactly the way DetailViewModel builds one. */
    private fun streamedEpisodePlayable(
        contentId: String,
        season: Int,
        episode: Int,
        // The streaming path passes the catalog detail name; the download record stores the SAME
        // name, so exact parity must pass it here too ([MediaRef] carries the title field).
        title: String,
    ): Playable {
        val ref = requireNotNull(
            buildMediaRef(
                type = MediaType.SERIES,
                metaId = contentId,
                episode = Episode(id = "$contentId:$season:$episode", title = "", season = season, episode = episode),
                title = title,
                year = null,
            ),
        )
        return Playable(url = "https://addon.test/stream.m3u8", title = "stream", mediaRef = ref)
    }

    @Test
    fun `downloaded movie binds full immutable context before playback`() {
        val playable = movieRecord().localPlayable("file:///downloads/dl-movie.mkv", owner = ownerEngine)

        val context = requireNotNull(playable.playbackContext)
        assertEquals("owner-profile", context.owner.profileId)
        assertTrue(context.owner.usesEngineHistory)
        assertEquals("tt0111161", context.contentId)
        assertEquals("tt0111161", context.videoId)
        assertEquals("movie", context.type)
        assertNull(context.season)
        assertNull(context.episode)
        assertEquals("The Shawshank Redemption", context.title)
        assertEquals("https://example.test/movie-poster.jpg", context.poster)
        assertEquals("movie|tt0111161|tt0111161", context.identityKey)
        assertEquals("owner-profile:engine:tt0111161", context.resumeIdentity)

        val provenance = context.provenance
        assertEquals("Torrentio 4K", provenance.sourceName)
        assertEquals("2160p", provenance.qualityText)
        assertFalse(provenance.torrentFetched)
        assertNull(provenance.debridOwnerIdentity)
        assertNull(provenance.debridOwnerGeneration)
    }

    @Test
    fun `downloaded episode binds series shape and provenance`() {
        val playable = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerOverlay)

        val context = requireNotNull(playable.playbackContext)
        assertTrue(context.isSeriesEpisode)
        assertEquals("tt0108778", context.contentId)
        assertEquals("tt0108778:3:1", context.videoId)
        assertEquals(3, context.season)
        assertEquals(1, context.episode)
        assertEquals("kids-profile:overlay:tt0108778:3:1", context.resumeIdentity)
        assertFalse(context.owner.usesEngineHistory)

        val provenance = context.provenance
        assertEquals("Torrentio HD", provenance.sourceName)
        assertEquals("1080p", provenance.qualityText)
        assertTrue(provenance.torrentFetched)
        assertEquals("account:account-a", provenance.debridOwnerIdentity)
        assertEquals(7L, provenance.debridOwnerGeneration)
    }

    @Test
    fun `downloaded episode scrobble identity is byte-equivalent to its streamed twin`() {
        val downloaded = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)
        val streamed = streamedEpisodePlayable(contentId = "tt0108778", season = 3, episode = 1, title = "Friends")

        assertEquals(streamed.mediaRef, downloaded.mediaRef)
        val ref = requireNotNull(downloaded.mediaRef)
        assertTrue(ref.isSeries)
        assertEquals("tt0108778", ref.imdb)
        assertEquals(3, ref.season)
        assertEquals(1, ref.episode)
    }

    @Test
    fun `unresolvable catalog id fails scrobble closed instead of guessing`() {
        val record = episodeRecord().copy(contentId = "kitsu12345", videoId = "kitsu12345:1:2")
        val playable = record.localPlayable("file:///downloads/kitsu.mkv", owner = ownerEngine)

        // The context still binds everything the record knows; only the provider ref stays absent,
        // exactly like a streamed kitsu-only play (the player simply does not scrobble).
        assertNotNull(playable.playbackContext)
        assertNull(playable.mediaRef)
    }

    @Test
    fun `stream A then downloaded B changes only B identity keys`() {
        val streamA = streamedEpisodePlayable(contentId = "tt1399", season = 2, episode = 1, title = "Game of Thrones")
        val downloadB = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)

        // Every identity consumer derives from B's own binding, never from ambient session state.
        assertEquals("imdb:tt0108778:s3:e1", autoSkipMediaIdentity(downloadB))
        assertEquals("imdb:tt0108778:3:1", subtitleOffsetContentKey(downloadB.mediaRef))
        // ...and each key names B, not the previously streamed title.
        assertTrue(autoSkipMediaIdentity(streamA) != autoSkipMediaIdentity(downloadB))
        assertTrue(subtitleOffsetContentKey(streamA.mediaRef) != subtitleOffsetContentKey(downloadB.mediaRef))
    }

    @Test
    fun `phone and TV screens produce identical bindings for the same owner`() {
        // Both screens call the SAME builder with their captured owner; prove the outputs match
        // value-for-value so phone and TV behave identically across the matrix.
        val fromPhone = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)
        val fromTv = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)

        assertEquals(fromPhone.playbackContext, fromTv.playbackContext)
        assertEquals(fromPhone.mediaRef, fromTv.mediaRef)
    }

    @Test
    fun `overlay profile keeps a separate resume line without touching title identity`() {
        val asOwner = episodeRecord().playbackContext(ownerEngine)
        val asOverlay = episodeRecord().playbackContext(ownerOverlay)

        // Resume identity splits per owner route...
        assertTrue(asOwner.resumeIdentity != asOverlay.resumeIdentity)
        // ...but WHICH title is playing does not depend on who watches.
        assertEquals(asOwner.identityKey, asOverlay.identityKey)
        assertEquals(asOwner.toMediaRef(), asOverlay.toMediaRef())
    }

    @Test
    fun `local file classification distinguishes downloads from every network source`() {
        val local = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)
        val streamed = streamedEpisodePlayable(contentId = "tt0108778", season = 3, episode = 1, title = "Friends")
        val loopback = Playable(url = "http://127.0.0.1:11470/hash/0", title = "torrent")

        assertTrue(isLocalFilePlayback(local))
        assertFalse(isLocalFilePlayback(streamed))
        assertFalse(isLocalFilePlayback(loopback))
    }

    @Test
    fun `routing flags survive alongside the new identity binding`() {
        val record = movieRecord().copy(isDolbyVision = true, isAtmos = true)
        val playable = record.localPlayable("file:///downloads/dl-movie.mkv", owner = ownerEngine)

        assertTrue(playable.isDolbyVision)
        assertTrue(playable.isAtmos)
        assertFalse(playable.isTorrent)
        assertFalse(playable.viaStreamingServer)
        assertEquals("file:///downloads/dl-movie.mkv", playable.url)
        // The display title stays episode-aware while the identity title carries the item name.
        val episodePlayable = episodeRecord().localPlayable("file:///downloads/dl-episode.mkv", owner = ownerEngine)
        assertEquals("Friends  \u00b7  S3E1", episodePlayable.title)
        assertEquals("Friends", requireNotNull(episodePlayable.playbackContext).title)
    }
}
