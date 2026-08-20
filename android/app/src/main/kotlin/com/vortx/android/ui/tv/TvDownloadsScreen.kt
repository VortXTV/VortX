package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.downloads.AndroidDownloadedMediaCapabilityProbe
import com.vortx.android.downloads.DownloadGroup
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.downloads.DownloadedMediaCapabilityResolver
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.Playable
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// The 10-foot Downloads surface: the device's offline library on the couch, the D-pad analogue of the phone
/// [com.vortx.android.ui.screens.DownloadsScreen]. It drives the EXACT SAME [DownloadStore] / [DownloadManager]
/// singletons the phone screen drives (both already `init`ed in
/// [com.vortx.android.VortXApplication]), so there is no second index and no forked download engine: a title
/// this screen plays, pauses, resumes, or deletes moves the same on-disk file and the same local row the phone
/// would. It renders the same [DownloadStore.groupedDownloads] folders (a series is one folder of episodes; a
/// movie is a standalone row) with the same per-state action set (Play a finished item, Pause an in-flight one,
/// Resume a paused or failed one, Delete anything).
///
/// Device-local, not per-profile by design: a download is a physical file on ONE device plus a row in a local
/// index that is NEVER account-synced and NEVER written into a `libraryItem` document (see
/// [com.vortx.android.model.DownloadRecord]). There is no profile field to filter on, so this shows the whole
/// device list exactly as the phone screen does -- honoring the per-profile invariant by the store's own design
/// (nothing here can leak one profile's activity into another's account).
///
/// [onPlay] hands a resolved local [Playable] up to the shell's player slot, the same slot a streamed source
/// resolves into, so offline playback reuses the shared [com.vortx.android.player.PlayerScreen].
@Composable
fun TvDownloadsScreen(
    onPlay: (Playable) -> Unit,
    modifier: Modifier = Modifier,
) {
    val records by DownloadStore.records.collectAsStateWithLifecycle()
    // groupedDownloads() derives from the record list; re-derive only when it changes, not on every recomposition.
    val groups = remember(records) { DownloadStore.groupedDownloads() }
    val totalSize = remember(records) { DownloadStore.formattedTotalSize() }
    val colors = VortXTheme.colors
    var showLinkSheet by remember { mutableStateOf(false) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = TvDimens.edge, vertical = VortXTheme.spacing.md),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                Text("Downloads", style = VortXTheme.type.screenTitle)
                Spacer(Modifier.weight(1f))
                // Ad-hoc "Play a link": the couch entry to play a direct/debrid stream URL pasted from a phone.
                TvFilterChip(label = "Play a link", selected = false, onClick = { showLinkSheet = true })
                if (records.isNotEmpty()) {
                    Text(totalSize, style = VortXTheme.type.label.copy(color = colors.textTertiary))
                }
            }

            if (groups.isEmpty()) {
                TvEmpty("Titles you download for offline viewing appear here.")
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = TvDimens.edge,
                        end = TvDimens.edge,
                        bottom = TvDimens.edge,
                    ),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    item {
                        // The eviction caption, always visible: Android reclaims app storage under pressure, so a
                        // saved download is not guaranteed to persist. The phone and Apple TV screens carry the
                        // same warning.
                        Text(
                            "Android can reclaim app storage when the device runs low, so a saved download may be " +
                                "removed by the system. Re-download it any time it is gone.",
                            style = VortXTheme.type.label.copy(color = colors.textTertiary),
                            modifier = Modifier.padding(bottom = VortXTheme.spacing.xs),
                        )
                    }
                    items(groups, key = { it.id }) { group ->
                        if (group.isShow) {
                            TvDownloadShowFolder(group, onPlay)
                        } else {
                            group.records.firstOrNull()?.let { TvDownloadRow(it, title = null, onPlay = onPlay) }
                        }
                    }
                }
            }
        }

        if (showLinkSheet) {
            TvPlayLinkSheet(
                onPlay = { playable ->
                    showLinkSheet = false
                    onPlay(playable)
                },
                onDismiss = { showLinkSheet = false },
            )
        }
    }
}

/// The minimal 10-foot "Play a link" sheet: a focusable URL field and a Play action for an ad-hoc direct or
/// resolved-debrid HTTP(S) stream, so a viewer can paste a link (typically from their phone) and play it
/// without a detail page. A magnet needs a debrid resolver, which is not wired ad-hoc on TV yet, so a magnet
/// (or any non-HTTP input) is refused with a clear note rather than a silent dead player -- the honest minimal
/// slice until the shared "play a link" path lands. Direct HTTP(S) links build a [Playable] and hand it to the
/// shell's player slot. Back dismisses.
@Composable
private fun TvPlayLinkSheet(onPlay: (Playable) -> Unit, onDismiss: () -> Unit) {
    val colors = VortXTheme.colors
    var url by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val trimmed = url.trim()
    val isHttp = trimmed.startsWith("http://", ignoreCase = true) || trimmed.startsWith("https://", ignoreCase = true)
    BackHandler { onDismiss() }
    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = TvDimens.formMaxWidth)
                .fillMaxWidth()
                .padding(TvDimens.edge)
                .clip(VortXShapes.card)
                .background(colors.surface1)
                .padding(VortXTheme.spacing.xl),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Play a link", style = VortXTheme.type.sectionTitle)
            Text(
                "Paste a direct or debrid stream link (http/https). Magnet links are not resolved on TV yet.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
            OutlinedTextField(
                value = url,
                onValueChange = { url = it; error = null },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("https://…") },
            )
            error?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.danger)) }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                TvPlayButton(
                    label = "Play",
                    enabled = trimmed.isNotEmpty(),
                    onClick = {
                        if (isHttp) {
                            val title = trimmed.substringAfterLast('/').substringBefore('?').ifBlank { "Link" }
                            onPlay(Playable(url = trimmed, title = title))
                        } else {
                            error = "Enter a direct http(s) stream link."
                        }
                    },
                )
                TvFilterChip(label = "Cancel", selected = false, onClick = onDismiss)
            }
        }
    }
}

/// One show's downloads as an always-expanded folder (a header carrying the show name + episode count + size,
/// its episodes listed beneath, already sorted by season then episode). Always expanded like the Apple TV
/// view: a collapsed section on a remote would hide every per-episode action behind an extra focus stop.
@Composable
private fun TvDownloadShowFolder(group: DownloadGroup, onPlay: (Playable) -> Unit) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.xs, vertical = VortXTheme.spacing.xs),
        ) {
            Icon(
                VortXIcons.library,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(28.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(
                    group.title,
                    style = VortXTheme.type.cardTitle,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val episodes = if (group.count == 1) "1 episode" else "${group.count} episodes"
                Text(
                    "$episodes  ·  ${DownloadStore.recordedSize(group.records)}",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )
            }
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            modifier = Modifier.padding(start = VortXTheme.spacing.md),
        ) {
            group.records.forEach { record ->
                TvDownloadRow(record, title = tvEpisodeTitle(record), onPlay = onPlay)
            }
        }
    }
}

/// The per-episode title inside a folder ("S1E2", or "E2" with no season), falling back to the full display
/// title when a record carries no episode numbering. The folder header already shows the show name, so
/// repeating it per row would be noise -- matching the phone folder.
private fun tvEpisodeTitle(record: DownloadRecord): String {
    val season = record.season
    val episode = record.episode
    return when {
        season != null && episode != null -> "S${season}E$episode"
        episode != null -> "E$episode"
        else -> record.displayTitle
    }
}

/// One download row: a state glyph, the title + a state subtitle (quality / progress / error), a progress bar
/// while active, and the per-state D-pad action pills. The info panel is a non-focusable card (like the phone
/// `SurfaceCard`); focus lands only on the action pills, so the D-pad steps action -> action -> next row.
@Composable
private fun TvDownloadRow(record: DownloadRecord, title: String?, onPlay: (Playable) -> Unit) {
    val colors = VortXTheme.colors
    val scope = rememberCoroutineScope()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(colors.surface1)
            .padding(VortXTheme.spacing.md),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    tvDownloadStateIcon(record.state),
                    contentDescription = null,
                    tint = if (record.state == DownloadState.FAILED) colors.danger else colors.accent,
                    modifier = Modifier.size(28.dp),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        title ?: record.displayTitle,
                        style = VortXTheme.type.cardTitle,
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        tvDownloadSubtitle(record),
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (record.state == DownloadState.DOWNLOADING || record.state == DownloadState.PAUSED) {
                // An unknown total (bytesTotal == 0: a torrent loopback transfer, or any debrid link streamed
                // without a Content-Length) renders INDETERMINATE. A determinate bar pinned at 0% would claim we
                // know the size and are stuck -- a different, false story. Matches the phone row exactly.
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
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                when (record.state) {
                    DownloadState.COMPLETED -> TvFilterChip(
                        label = "Play",
                        selected = false,
                        onClick = { scope.launch { tvPlayLocal(record, onPlay) } },
                    )
                    DownloadState.DOWNLOADING -> TvFilterChip(
                        label = "Pause",
                        selected = false,
                        onClick = { DownloadManager.pause(record.id) },
                    )
                    // resume() covers both PAUSED and FAILED (it re-queues a failed transfer), matching the phone.
                    DownloadState.PAUSED, DownloadState.FAILED -> TvFilterChip(
                        label = "Resume",
                        selected = false,
                        onClick = { DownloadManager.resume(record.id) },
                    )
                    DownloadState.QUEUED -> Unit
                }
                // cancel() IS the delete action: it stops any transfer, removes the row, and frees the queue slot.
                TvFilterChip(
                    label = "Delete",
                    selected = false,
                    onClick = { DownloadManager.cancel(record.id) },
                )
            }
        }
    }
}

/// Play a completed download from its LOCAL file, off the UI thread.
///
/// FIDELITY GAP (stated, not hidden), identical to the phone screen: Android has no `PlaybackMeta` port yet, so
/// this hands the shell a local [Playable] and the engine attributes progress to whatever item its session
/// currently points at. Per-title progress attribution for a play started here is not yet guaranteed; the record
/// keeps every id needed to close it later. Fail-soft if the file was purged out from under us (the eviction
/// caption is not hypothetical): drop the stale row rather than present a dead player.
private suspend fun tvPlayLocal(record: DownloadRecord, onPlay: (Playable) -> Unit) {
    if (record.state != DownloadState.COMPLETED) return
    val resolution = withContext(Dispatchers.IO) {
        val file = DownloadStore.fileFor(record)
        if (!file.isFile) return@withContext null
        DownloadedMediaCapabilityResolver.resolve(
            record = record,
            file = file,
            probe = AndroidDownloadedMediaCapabilityProbe,
            persistResolved = { resolved ->
                DownloadStore.update(record.id) { current ->
                    current.copy(
                        isDolbyVision = resolved.isDolbyVision,
                        isAtmos = resolved.isAtmos,
                    )
                }
            },
        )
    }
    if (resolution == null) {
        if (record.state == DownloadState.COMPLETED) DownloadManager.cancel(record.id)
        return
    }
    onPlay(
        resolution.record.localPlayable(
            DownloadStore.fileFor(resolution.record).toURI().toString(),
        ),
    )
}

private fun tvDownloadStateIcon(state: DownloadState) = when (state) {
    DownloadState.COMPLETED -> VortXIcons.playCircle
    DownloadState.FAILED -> VortXIcons.close
    DownloadState.PAUSED -> VortXIcons.arrowDownCircle
    else -> VortXIcons.download
}

private fun tvDownloadSubtitle(record: DownloadRecord): String {
    val parts = when (record.state) {
        DownloadState.COMPLETED -> listOfNotNull(
            record.sourceName,
            record.qualityText,
            DownloadStore.formatBytes(maxOf(record.bytesDone, record.bytesTotal)),
        )
        DownloadState.DOWNLOADING -> listOf(
            if (record.bytesTotal > 0) {
                "Downloading ${(record.fractionComplete * 100).toInt()}%"
            } else {
                "Downloading ${DownloadStore.formatBytes(record.bytesDone)}"
            },
        )
        DownloadState.PAUSED -> listOf(record.errorText ?: "Paused")
        DownloadState.FAILED -> listOf(record.errorText ?: "Failed")
        DownloadState.QUEUED -> listOf("Queued")
    }
    return (parts + listOfNotNull(record.retryNote)).joinToString("  ·  ")
}
