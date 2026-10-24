package com.vortx.android.ui.randompick

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import java.time.Instant

/** Explicit Random Play authority survives source loading, but not any owner/target change. */
internal data class RandomEpisodePlaybackLease<O : Any>(
    val owner: O,
    val detailId: String,
    val detailType: MediaType,
    val episode: Episode,
    val request: Any,
) {
    fun accepts(
        currentOwner: O?,
        currentRequest: Any?,
        selectedEpisodeId: String?,
        currentDetail: MetaDetail?,
        now: Instant,
    ): Boolean {
        if (owner != currentOwner || request !== currentRequest || selectedEpisodeId != episode.id) return false
        if (currentDetail == null || currentDetail.id != detailId || currentDetail.type != detailType) return false
        return RandomPickPolicy.episodeCandidates(currentDetail, now).any {
            it.id == episode.id && it.season == episode.season && it.episode == episode.episode
        }
    }
}
