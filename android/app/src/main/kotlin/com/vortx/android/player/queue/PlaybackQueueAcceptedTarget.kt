package com.vortx.android.player.queue

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail

/** The accepted catalog/episode must still be the entry the viewer queued, never a nested title. */
internal object PlaybackQueueAcceptedTarget {
    fun matches(entry: PlaybackQueueEntry, metadata: MetaDetail, selectedEpisodeId: String?, isTrailer: Boolean): Boolean {
        val item = entry.item
        if (isTrailer || metadata.id != item.id || metadata.type != item.type ||
            (item.type != MediaType.MOVIE && item.type != MediaType.SERIES)) return false
        val hint = item.preferredEpisode ?: return true
        if (item.type != MediaType.SERIES || selectedEpisodeId.isNullOrBlank()) return false
        val selected = metadata.videos.singleOrNull { it.id == selectedEpisodeId } ?: return false
        return selected.season == hint.season && selected.episode == hint.episode &&
            (hint.videoIdentity == null || selected.id == hint.videoIdentity)
    }
}
