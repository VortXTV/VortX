package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.downloads.DownloadedTitleAvailability
import com.vortx.android.downloads.downloadedTitleAvailability
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.downloads.downloadedEpisode
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.ui.theme.VortXTheme

@Composable
internal fun rememberCompletedTitleDownloads(
    contentIds: Set<String>,
    type: MediaType,
    metadataLoaded: Boolean,
): DownloadedTitleAvailability {
    val context = LocalContext.current
    val token = PlaybackOwnerEpoch.capture()
    val index by DownloadStore.records.collectAsStateWithLifecycle()
    val candidates = remember(index, contentIds, type) {
        index.filter { it.state == DownloadState.COMPLETED && it.contentId in contentIds && it.type == type.id }
    }
    return key(contentIds, type, candidates, token, metadataLoaded) {
        val available by produceState(DownloadedTitleAvailability()) {
            if (token != null) value = downloadedTitleAvailability(context, candidates, token)
        }
        available
    }
}

internal fun heroDownload(records: List<DownloadRecord>, type: MediaType, episode: Episode?) =
    when (type) {
        MediaType.MOVIE -> records.firstOrNull {
            it.videoId == it.contentId && it.season == null && it.episode == null
        }
        MediaType.SERIES -> episode?.let { downloadedEpisode(records, it) }
        else -> null
    }

@Composable
internal fun DownloadedDetailFallback(
    title: String,
    records: List<DownloadRecord>,
    action: @Composable (DownloadRecord) -> Unit,
    retry: @Composable () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item { Text(title, style = VortXTheme.type.sectionTitle) }
        items(records, key = { it.id }) { record -> action(record) }
        item { retry() }
    }
}
