package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassStrip

/// Settings > Downloads > Manage queue: the download QUEUE manager. ONE screen to see, reorder, pause /
/// resume / retry, and cap the concurrency of offline downloads, plus the storage location + used space.
/// Kotlin/Compose port of the Apple iOS/macOS `DownloadQueueView`.
///
/// It is a pure control surface over the existing [DownloadManager] + [DownloadStore] singletons (no
/// transfer logic of its own): every action routes back through the manager, which owns the WorkManager
/// machinery and the reorderable drain order. Rows are grouped by lifecycle - Downloading, Up next
/// (queued), Paused, Failed - so the pipeline reads top to bottom. Completed downloads are deliberately
/// absent: they are finished library items, surfaced for playback by [DownloadsScreen], not part of the
/// pending queue.
///
/// The queued group is the only one that carries the up / down reorder controls (the running, paused, and
/// failed states have no queue position to move), and its rows use the manager's canonical
/// [DownloadManager.orderedQueuedRecords] order so what the user sees is exactly what starts next.
///
/// Self-contained like [DownloadsScreen]: it drives the singletons directly, so it needs no ViewModel.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DownloadQueueScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val records by DownloadStore.records.collectAsStateWithLifecycle()
    val maxConcurrent by DownloadManager.maxConcurrentDownloads.collectAsStateWithLifecycle()
    // The reorder order is its own StateFlow: recompute the queued list whenever EITHER the records or the
    // explicit order changes, and not on every recomposition. orderedQueuedRecords() reads both internally.
    val queueOrder by DownloadManager.queueOrder.collectAsStateWithLifecycle()

    val downloading = remember(records) { records.filter { it.state == DownloadState.DOWNLOADING } }
    val queued = remember(records, queueOrder) { DownloadManager.orderedQueuedRecords() }
    val paused = remember(records) { records.filter { it.state == DownloadState.PAUSED } }
    val failed = remember(records) { records.filter { it.state == DownloadState.FAILED } }
    val isEmpty = downloading.isEmpty() && queued.isEmpty() && paused.isEmpty() && failed.isEmpty()

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Download queue", style = VortXTheme.type.screenTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = Color.Transparent,
                ),
                modifier = Modifier.vortxGlassStrip(),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            contentPadding = PaddingValues(vertical = VortXTheme.spacing.sm),
        ) {
            item {
                ConcurrencyCard(
                    max = maxConcurrent,
                    activeCount = downloading.size,
                    queuedCount = queued.size,
                )
            }
            item { StorageCard() }

            if (isEmpty) {
                item { EmptyQueue(Modifier.fillMaxWidth()) }
                return@LazyColumn
            }

            queueSection("Downloading", VortXIcons.download, downloading, keyPrefix = "dl") { record ->
                QueueRow(record)
            }
            if (queued.isNotEmpty()) {
                item { SectionHeader("Up next", VortXIcons.chevronUpDown, queued.size) }
                itemsIndexed(queued, key = { _, record -> "q:${record.id}" }) { index, record ->
                    QueueRow(record, isFirst = index == 0, isLast = index == queued.lastIndex)
                }
            }
            queueSection("Paused", VortXIcons.arrowDownCircle, paused, keyPrefix = "pause") { record ->
                QueueRow(record)
            }
            queueSection("Failed", VortXIcons.close, failed, keyPrefix = "fail") { record ->
                QueueRow(record)
            }
        }
    }
}

/// A titled group of queue rows, rendered only when it has content. The queued ("Up next") group is
/// special-cased inline in the caller because its rows need their index for the reorder-arrow edges.
private fun androidx.compose.foundation.lazy.LazyListScope.queueSection(
    title: String,
    icon: ImageVector,
    records: List<DownloadRecord>,
    keyPrefix: String,
    row: @Composable (DownloadRecord) -> Unit,
) {
    if (records.isEmpty()) return
    item(key = "header:$keyPrefix") { SectionHeader(title, icon, records.size) }
    items(records, key = { "$keyPrefix:${it.id}" }) { row(it) }
}

/// The max-concurrent-downloads control (Apple's `concurrencyCard`): a stepper over the manager's cap, a
/// live activity line, and a plain-language note on what raising / lowering does. The stepper writes
/// through [DownloadManager.setMaxConcurrentDownloads], which clamps + persists and fills freed slots on a
/// raise. Persisted on Apple's exact `vortx.downloads.maxConcurrent` key (device-local, not synced).
@Composable
private fun ConcurrencyCard(max: Int, activeCount: Int, queuedCount: Int) {
    val range = DownloadManager.CONCURRENCY_RANGE
    SettingsSection(
        title = "Downloads at once",
        footer = "More at once shares your bandwidth across them. Lowering this never interrupts a " +
            "download already in progress, it just holds the next ones in the queue.",
    ) {
        StepperRow(
            label = "Run up to $max at once",
            canDecrease = max > range.first,
            canIncrease = max < range.last,
            onDecrease = { DownloadManager.setMaxConcurrentDownloads(max - 1) },
            onIncrease = { DownloadManager.setMaxConcurrentDownloads(max + 1) },
        )
        Text(
            activitySummary(activeCount, queuedCount),
            style = VortXTheme.type.label,
            color = VortXTheme.colors.textTertiary,
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        )
    }
}

/// "N downloading  ·  M waiting  ·  X on disk" (Apple's `activitySummary`). The "waiting" clause is
/// dropped when the queue is empty so the line never reads "0 waiting".
private fun activitySummary(active: Int, queued: Int): String {
    val parts = mutableListOf<String>()
    parts += if (active == 1) "1 downloading" else "$active downloading"
    if (queued > 0) parts += "$queued waiting"
    parts += "${DownloadStore.formattedTotalSize()} on disk"
    return parts.joinToString("  ·  ")
}

/// Storage location + used-space display. Android downloads live in the app's PRIVATE internal storage
/// (no permission, not user-relocatable, removed on uninstall), so the location is a fixed "on this
/// device" rather than a chooser; the actual directory path is shown for transparency. Apple's Downloads
/// screens show only the used size because iOS has no equivalent user-visible path.
@Composable
private fun StorageCard() {
    val location = remember { runCatching { DownloadStore.downloadsDirectory().absolutePath }.getOrNull() }
    val used = DownloadStore.formattedTotalSize()
    SettingsSection(
        title = "Storage",
        footer = "Downloads are kept in VortX's private storage on this device. Android can reclaim this " +
            "space when the device runs low, and everything here is removed if you uninstall VortX.",
    ) {
        InfoRow(label = "Location", value = "On this device")
        InfoRow(label = "Used", value = used)
        if (location != null) {
            Text(
                location,
                style = VortXTheme.type.label,
                color = VortXTheme.colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            )
        }
    }
}

/// A read-only label / value line for the storage card (a labelled fact, not a control).
@Composable
private fun InfoRow(label: String, value: String) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = VortXTheme.type.body, color = colors.textSecondary)
        Text(value, style = VortXTheme.type.label, color = colors.textPrimary)
    }
}

@Composable
private fun SectionHeader(title: String, icon: ImageVector, count: Int) {
    val colors = VortXTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(start = VortXTheme.spacing.xs, top = VortXTheme.spacing.xs),
    ) {
        Icon(icon, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
        Text(title.uppercase(), style = VortXTheme.type.eyebrow, color = colors.textSecondary)
        Text("$count", style = VortXTheme.type.eyebrow, color = colors.textTertiary)
    }
}

/// One queue row: a state glyph, the title + subtitle (progress / waiting / error), a progress bar while
/// active, then the per-state action bar. [isFirst] / [isLast] are supplied only for queued rows (they
/// gate the reorder arrows); every other state passes the defaults and shows no arrows.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QueueRow(record: DownloadRecord, isFirst: Boolean = true, isLast: Boolean = true) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    stateIcon(record.state),
                    contentDescription = null,
                    tint = if (record.state == DownloadState.FAILED) colors.danger else colors.accent,
                    modifier = Modifier.size(28.dp),
                )
                Column(Modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        record.displayTitle,
                        style = VortXTheme.type.cardTitle,
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        subtitle(record),
                        style = VortXTheme.type.label,
                        color = colors.textTertiary,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (record.state == DownloadState.DOWNLOADING || record.state == DownloadState.PAUSED) {
                // An unknown total (bytesTotal == 0: every torrent loopback transfer, and any debrid link
                // that streams without a Content-Length) renders INDETERMINATE. A determinate bar pinned at
                // 0% would claim we know the size and are stuck, which is a different and false story.
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
            QueueRowActions(record, isFirst, isLast)
        }
    }
}

/// Per-state controls, wrapped in a [FlowRow] so a queued row's four chips (Up, Down, Pause, Delete) never
/// overflow a narrow phone. Queued rows get the reorder arrows (disabled at the ends); the terminal states
/// get the matching primary action; every row gets Delete last. Delete routes through the manager's
/// [DownloadManager.cancel], which stops any live task, clears its bookkeeping, prunes the queue order, and
/// removes the on-disk file - never a raw store delete that would strand a running transfer.
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QueueRowActions(record: DownloadRecord, isFirst: Boolean, isLast: Boolean) {
    val colors = VortXTheme.colors
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        modifier = Modifier.fillMaxWidth(),
    ) {
        when (record.state) {
            DownloadState.DOWNLOADING -> Chip(
                label = "Pause",
                selected = false,
                onClick = { DownloadManager.pause(record.id) },
            )
            DownloadState.QUEUED -> {
                Chip(
                    label = "Up",
                    selected = false,
                    enabled = !isFirst,
                    leadingIcon = VortXIcons.chevronUp,
                    stateDescription = "Move earlier in queue",
                    onClick = { DownloadManager.moveQueuedEarlier(record.id) },
                )
                Chip(
                    label = "Down",
                    selected = false,
                    enabled = !isLast,
                    leadingIcon = VortXIcons.chevronDown,
                    stateDescription = "Move later in queue",
                    onClick = { DownloadManager.moveQueuedLater(record.id) },
                )
                Chip(
                    label = "Pause",
                    selected = false,
                    onClick = { DownloadManager.pause(record.id) },
                )
            }
            DownloadState.PAUSED -> Chip(
                label = "Resume",
                selected = false,
                onClick = { DownloadManager.resume(record.id) },
            )
            DownloadState.FAILED -> Chip(
                label = "Retry",
                selected = false,
                onClick = { DownloadManager.resume(record.id) },
            )
            DownloadState.COMPLETED -> Unit
        }
        Chip(
            label = "Delete",
            selected = false,
            leadingIcon = VortXIcons.delete,
            // The danger accent marks this as the destructive action, matching the Apple row's `trash`.
            accent = colors.danger,
            accentText = colors.danger,
            onClick = { DownloadManager.cancel(record.id) },
        )
    }
}

@Composable
private fun EmptyQueue(modifier: Modifier) {
    val colors = VortXTheme.colors
    Column(
        modifier = modifier.padding(VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            VortXIcons.arrowDownCircle,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(44.dp),
        )
        Text("Nothing downloading", style = VortXTheme.type.cardTitle, color = colors.textSecondary)
        Text(
            "Downloads you start appear here, where you can reorder, pause, and set how many run at once.",
            style = VortXTheme.type.label,
            color = colors.textTertiary,
        )
    }
}

private fun stateIcon(state: DownloadState): ImageVector = when (state) {
    DownloadState.COMPLETED -> VortXIcons.playCircle
    DownloadState.FAILED -> VortXIcons.close
    DownloadState.PAUSED -> VortXIcons.arrowDownCircle
    else -> VortXIcons.download
}

/// The per-state subtitle. The batch auto-retry note, when present, is appended rather than replacing the
/// state line: the user should see BOTH that the episode was retried and what it is doing now.
private fun subtitle(record: DownloadRecord): String {
    val parts = when (record.state) {
        DownloadState.DOWNLOADING -> listOf(
            if (record.bytesTotal > 0) {
                "Downloading ${(record.fractionComplete * 100).toInt()}%"
            } else {
                // No declared size: report the bytes we actually have rather than a fake percentage.
                "Downloading ${DownloadStore.formatBytes(record.bytesDone)}"
            },
            record.sourceName,
        )
        DownloadState.QUEUED -> listOf("Waiting", record.qualityText)
        DownloadState.PAUSED -> listOf(
            if (record.bytesTotal > 0) "Paused at ${(record.fractionComplete * 100).toInt()}%" else "Paused",
        )
        DownloadState.FAILED -> listOf(record.errorText ?: "Failed")
        DownloadState.COMPLETED -> listOf(record.qualityText ?: "Downloaded")
    }
    return (parts + record.retryNote).filterNotNull().joinToString("  ·  ")
}
