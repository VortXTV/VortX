package com.vortx.android.ui.tv

import com.vortx.android.model.Episode
import com.vortx.android.model.MetaDetail
import com.vortx.android.ui.components.artworkCandidates

/** No episode runtime is carried by Episode: title runtime must remain explicitly typical. */
internal fun tvEpisodeFacts(
    episodeId: String,
    selectedEpisodeId: String?,
    titleRuntime: String?,
    acceptedSelectedQualityLabels: List<String>,
): String? = listOfNotNull(
    titleRuntime?.trim()?.takeIf(String::isNotEmpty)?.let { "Typical · $it" },
    acceptedSelectedQualityLabels.takeIf { episodeId == selectedEpisodeId }
        ?.map(String::trim)?.filter { it.isNotEmpty() && !it.equals("Others", ignoreCase = true) }
        ?.distinct()?.joinToString(" / ")?.takeIf(String::isNotEmpty),
).joinToString(" · ").takeIf(String::isNotEmpty)

internal fun tvEpisodeArtwork(episode: Episode, detail: MetaDetail): List<String> =
    artworkCandidates(listOf(episode.thumbnail, detail.background, detail.poster))
