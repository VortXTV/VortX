package com.vortx.android.player.queue

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackQueueAcceptedTargetTest {
    private fun entry(type: MediaType = MediaType.MOVIE, hint: PreferredEpisode? = null) = PlaybackQueueEntry(
        "00000000-0000-0000-0000-000000000001",
        MetaItem("catalog-target", type, "Queued title", preferredEpisode = hint),
    )
    private fun metadata(type: MediaType = MediaType.MOVIE, videos: List<Episode> = emptyList()) =
        MetaDetail("catalog-target", type, "Loaded title", videos = videos)

    @Test fun `movie acknowledgement requires the exact queued catalog ID and media type`() {
        val queued = entry()
        val loaded = metadata()
        assertTrue(PlaybackQueueAcceptedTarget.matches(queued, loaded, null, false))
        assertFalse(PlaybackQueueAcceptedTarget.matches(queued, loaded.copy(id = "nested-other-title"), null, false))
        assertFalse(PlaybackQueueAcceptedTarget.matches(queued, loaded.copy(type = MediaType.SERIES), null, false))
    }

    @Test fun `trailer and live targets cannot acknowledge a queued movie or episode`() {
        assertFalse(PlaybackQueueAcceptedTarget.matches(entry(), metadata(), null, true))
        val episode = Episode("episode-1", "Episode", 1, 1)
        assertFalse(PlaybackQueueAcceptedTarget.matches(entry(MediaType.SERIES),
            metadata(MediaType.SERIES, listOf(episode)), episode.id, true))
        for (liveType in listOf(MediaType.CHANNEL, MediaType.TV)) {
            assertFalse(PlaybackQueueAcceptedTarget.matches(entry(liveType), metadata(liveType), null, false))
        }
    }

    @Test fun `a generic queued series accepts its normal currently selected episode`() {
        val selected = Episode("provider-episode-7", "Episode seven", 2, 7)
        val queued = entry(MediaType.SERIES)
        assertTrue(PlaybackQueueAcceptedTarget.matches(queued,
            metadata(MediaType.SERIES, listOf(Episode("episode-6", "Previous", 2, 6), selected)), selected.id, false))
    }

    @Test fun `exact hinted episode accepts matching coordinates and optional opaque ID without changing source`() {
        val selected = Episode("opaque-provider-special", "Special", 0, 2)
        val hinted = entry(MediaType.SERIES, PreferredEpisode(0, 2, selected.id))
        val before = hinted.copy(item = hinted.item.copy())
        val loaded = metadata(MediaType.SERIES, listOf(selected))
        assertTrue(PlaybackQueueAcceptedTarget.matches(hinted, loaded, selected.id, false))
        assertTrue(PlaybackQueueAcceptedTarget.matches(
            entry(MediaType.SERIES, PreferredEpisode(0, 2)), loaded, selected.id, false))
        assertFalse(PlaybackQueueAcceptedTarget.matches(hinted, loaded.copy(id = "other-series"), selected.id, false))
        assertEquals(before, hinted)
    }

    @Test fun `wrong season episode or required opaque video identity cannot acknowledge the entry`() {
        val selected = Episode("opaque-episode", "Selected", 2, 7)
        val queued = entry(MediaType.SERIES, PreferredEpisode(2, 7, selected.id))
        for (wrongCoordinates in listOf(selected.copy(season = 1), selected.copy(episode = 8))) {
            assertFalse(PlaybackQueueAcceptedTarget.matches(queued,
                metadata(MediaType.SERIES, listOf(wrongCoordinates)), selected.id, false))
        }
        val differentOpaqueId = selected.copy(id = "other-provider-episode")
        assertFalse(PlaybackQueueAcceptedTarget.matches(queued,
            metadata(MediaType.SERIES, listOf(differentOpaqueId)), differentOpaqueId.id, false))
    }

    @Test fun `hinted episode requires one unique actually loaded row for the selected identity`() {
        val selected = Episode("opaque-episode", "Selected", 2, 7)
        val queued = entry(MediaType.SERIES, PreferredEpisode(2, 7, selected.id))
        val loaded = metadata(MediaType.SERIES, listOf(selected))
        for (missingId in listOf(null, "", " ", "not-loaded")) {
            assertFalse(PlaybackQueueAcceptedTarget.matches(queued, loaded, missingId, false))
        }
        assertFalse(PlaybackQueueAcceptedTarget.matches(queued, metadata(MediaType.SERIES), selected.id, false))
        assertFalse(PlaybackQueueAcceptedTarget.matches(queued,
            metadata(MediaType.SERIES, listOf(selected, selected.copy(title = "Duplicate row"))), selected.id, false))
    }
}
