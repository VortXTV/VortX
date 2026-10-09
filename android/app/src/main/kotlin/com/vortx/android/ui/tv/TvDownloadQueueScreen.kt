package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/** D-pad controls for the same device-local queue and concurrency cap used by the phone. */
@Composable
fun TvDownloadQueueScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val records by DownloadStore.records.collectAsStateWithLifecycle()
    val queueOrder by DownloadManager.queueOrder.collectAsStateWithLifecycle()
    val maxConcurrent by DownloadManager.maxConcurrentDownloads.collectAsStateWithLifecycle()
    val downloading = remember(records) { records.filter { it.state == DownloadState.DOWNLOADING } }
    // Reordering changes queueOrder without changing records; observe both to reflect the next-start order.
    val queued = remember(records, queueOrder) { DownloadManager.orderedQueuedRecords() }
    val paused = remember(records) { records.filter { it.state == DownloadState.PAUSED } }
    val failed = remember(records) { records.filter { it.state == DownloadState.FAILED } }
    val isEmpty = downloading.isEmpty() && queued.isEmpty() && paused.isEmpty() && failed.isEmpty()
    val colors = VortXTheme.colors
    val backFocus = remember { FocusRequester() }

    BackHandler(onBack = onBack)
    LaunchedEffect(Unit) { runCatching { backFocus.requestFocus() } }

    Column(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = TvDimens.edge, vertical = VortXTheme.spacing.md),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TvFilterChip(
                label = "Back",
                selected = false,
                onClick = onBack,
                modifier = Modifier.focusRequester(backFocus),
                stateDescription = "Return to Downloads",
            )
            Text("Download queue", style = VortXTheme.type.screenTitle)
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = TvDimens.edge,
                end = TvDimens.edge,
                bottom = TvDimens.edge,
            ),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            item(key = "concurrency") {
                TvDownloadConcurrencyCard(maxConcurrent, downloading.size, queued.size)
            }
            if (isEmpty) {
                item(key = "empty") {
                    Column(
                        modifier = Modifier.padding(vertical = VortXTheme.spacing.xl),
                        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    ) {
                        Text("Nothing in the queue", style = VortXTheme.type.sectionTitle)
                        Text(
                            "Downloads you start appear here. Finished titles are in Downloads, ready to play.",
                            style = VortXTheme.type.body.copy(color = colors.textSecondary),
                        )
                    }
                }
            }
            tvDownloadQueueSection("Downloading", downloading)
            if (queued.isNotEmpty()) {
                item(key = "header:queued") { TvDownloadQueueHeader("Up next", queued.size) }
                itemsIndexed(queued, key = { _, record -> "queued:${record.id}" }) { index, record ->
                    TvDownloadQueueRow(record, queuePosition = index + 1, queueSize = queued.size)
                }
            }
            tvDownloadQueueSection("Paused", paused)
            tvDownloadQueueSection("Failed", failed)
        }
    }
}

@Composable
private fun TvDownloadConcurrencyCard(max: Int, activeCount: Int, queuedCount: Int) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(colors.surface1)
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text("Downloads at once", style = VortXTheme.type.cardTitle)
        Row(
            modifier = Modifier.focusGroup(),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            DownloadManager.CONCURRENCY_RANGE.forEach { count ->
                TvFilterChip(
                    label = "$count",
                    selected = count == max,
                    stateDescription = "Run up to $count downloads at once",
                    onClick = { DownloadManager.setMaxConcurrentDownloads(count) },
                )
            }
        }
        Text(
            "$activeCount downloading  ·  $queuedCount queued",
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
        )
        Text(
            "More at once shares your bandwidth. Lowering the limit lets current downloads finish " +
                "and holds the next ones in the queue.",
            style = VortXTheme.type.label.copy(color = colors.textTertiary),
        )
    }
}

private fun LazyListScope.tvDownloadQueueSection(title: String, records: List<DownloadRecord>) {
    if (records.isEmpty()) return
    item(key = "header:$title") { TvDownloadQueueHeader(title, records.size) }
    items(records, key = { "$title:${it.id}" }) { record -> TvDownloadQueueRow(record) }
}

@Composable
private fun TvDownloadQueueHeader(title: String, count: Int) {
    Text(
        "$title ($count)",
        style = VortXTheme.type.sectionTitle,
        modifier = Modifier.padding(top = VortXTheme.spacing.md, bottom = VortXTheme.spacing.xs),
    )
}

@Composable
private fun TvDownloadQueueRow(record: DownloadRecord, queuePosition: Int? = null, queueSize: Int = 0) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(colors.surface1)
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            record.displayTitle,
            style = VortXTheme.type.cardTitle,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            tvQueueSubtitle(record, queuePosition, queueSize),
            style = VortXTheme.type.label,
            color = if (record.state == DownloadState.FAILED) colors.danger else colors.textSecondary,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        if (record.state == DownloadState.DOWNLOADING || record.state == DownloadState.PAUSED) {
            if (record.bytesTotal > 0) {
                LinearProgressIndicator(
                    progress = { record.fractionComplete.toFloat() },
                    color = colors.accent,
                    trackColor = colors.surface3,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else if (record.state == DownloadState.DOWNLOADING) {
                LinearProgressIndicator(
                    color = colors.accent,
                    trackColor = colors.surface3,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        Row(
            modifier = Modifier.focusGroup(),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            if (record.state == DownloadState.QUEUED && queuePosition != null) {
                TvFilterChip(
                    label = "Move earlier",
                    selected = false,
                    enabled = queuePosition > 1,
                    stateDescription = if (queuePosition == 1) "First in queue" else "Move one place earlier",
                    onClick = { DownloadManager.moveQueuedEarlier(record.id) },
                )
                TvFilterChip(
                    label = "Move later",
                    selected = false,
                    enabled = queuePosition < queueSize,
                    stateDescription = if (queuePosition == queueSize) "Last in queue" else "Move one place later",
                    onClick = { DownloadManager.moveQueuedLater(record.id) },
                )
            }
            when (record.state) {
                DownloadState.DOWNLOADING, DownloadState.QUEUED -> TvFilterChip(
                    label = "Pause",
                    selected = false,
                    onClick = { DownloadManager.pause(record.id) },
                )
                DownloadState.PAUSED, DownloadState.FAILED -> TvFilterChip(
                    label = if (record.state == DownloadState.FAILED) "Retry" else "Resume",
                    selected = false,
                    onClick = { DownloadManager.resume(record.id) },
                )
                DownloadState.COMPLETED -> Unit
            }
            TvFilterChip(
                label = "Delete",
                selected = false,
                stateDescription = "Cancel download and delete its saved data",
                onClick = { DownloadManager.cancel(record.id) },
            )
        }
    }
}

private fun tvQueueSubtitle(record: DownloadRecord, queuePosition: Int?, queueSize: Int): String {
    val progress = if (record.bytesTotal > 0) {
        "${(record.fractionComplete * 100).toInt()}%"
    } else {
        DownloadStore.formatBytes(record.bytesDone)
    }
    val state = when (record.state) {
        DownloadState.DOWNLOADING -> "Downloading $progress"
        DownloadState.QUEUED -> "Queued · $queuePosition of $queueSize"
        DownloadState.PAUSED -> "Paused · $progress"
        DownloadState.FAILED -> "Failed · ${record.errorText ?: "Select Retry to try again"}"
        DownloadState.COMPLETED -> "Downloaded"
    }
    return listOfNotNull(state, record.sourceName, record.qualityText, record.retryNote)
        .filter { it.isNotBlank() }
        .joinToString("  ·  ")
}
