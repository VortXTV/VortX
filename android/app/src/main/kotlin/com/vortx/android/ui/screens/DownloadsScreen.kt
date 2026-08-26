package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
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
import com.vortx.android.model.PlaybackContext
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassStrip
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// Settings > Downloads: the device's offline downloads with per-item state (Downloading %, Queued, Paused,
/// Downloaded, Failed + error), a play-from-local action, a delete action, and the total storage used. Kotlin/Compose
/// port of the Apple `TVDownloadsView` / iOS `DownloadsView`, rendering the same folders from the same
/// [DownloadStore.groupedDownloads] derivation: each series is ONE folder holding its episodes sorted by season then
/// episode, and a movie is a standalone row.
///
/// It drives the [DownloadManager] / [DownloadStore] singletons directly, the way [MediaServersScreen] and
/// [IntegrationsScreen] drive theirs, so it needs no ViewModel.
///
/// Device-local only: a download is a physical file on ONE device plus a row in the local index. This screen never
/// syncs the list and never touches `libraryItem` documents.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DownloadsScreen(
    onBack: () -> Unit,
    onPlay: (Playable) -> Unit,
    modifier: Modifier = Modifier,
    // Opens the download QUEUE manager (reorder / pause / concurrency cap / storage), the Android port of
    // Apple's `DownloadQueueView`. Additive default keeps every existing call site unchanged.
    onManageQueue: () -> Unit = {},
) {
    val records by DownloadStore.records.collectAsStateWithLifecycle()
    // groupedDownloads() derives from the record list, so re-derive whenever it changes and not on every recomposition.
    val groups = remember(records) { DownloadStore.groupedDownloads() }
    val totalSize = remember(records) { DownloadStore.formattedTotalSize() }
    val colors = VortXTheme.colors

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Downloads", style = VortXTheme.type.screenTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
                actions = {
                    if (records.isNotEmpty()) {
                        Text(
                            totalSize,
                            style = VortXTheme.type.label,
                            color = colors.textTertiary,
                            modifier = Modifier.padding(end = VortXTheme.spacing.xs),
                        )
                    }
                    // Manage queue: reorder pending downloads, pause / retry, and cap how many run at once
                    // (the DownloadQueueScreen). Always available so the concurrency + storage controls stay
                    // reachable even with an empty list.
                    IconButton(onClick = onManageQueue) {
                        Icon(VortXIcons.chevronUpDown, contentDescription = "Manage download queue")
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
        if (groups.isEmpty()) {
            // Keep the auto-delete policy reachable even with an empty list: enabling it can EMPTY the list,
            // so hiding the toggle when empty would trap a viewer who wanted to turn it back off.
            Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                AutoDeleteWatchedToggle(
                    Modifier.padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
                )
                EmptyDownloads(Modifier.fillMaxSize())
            }
            return@Scaffold
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = VortXTheme.spacing.sm),
        ) {
            item { AutoDeleteWatchedToggle() }
            item {
                // The eviction caption, always visible: Android reclaims app storage under pressure, so a saved
                // download is not guaranteed to persist. Apple shows the same warning on tvOS for the same reason.
                Text(
                    "Android can reclaim app storage when the device runs low, so a saved download may be removed " +
                        "by the system. Re-download it any time it is gone.",
                    style = VortXTheme.type.label,
                    color = colors.textTertiary,
                    modifier = Modifier.padding(bottom = VortXTheme.spacing.xs),
                )
            }
            items(groups, key = { it.id }) { group ->
                if (group.isShow) {
                    ShowFolder(group, onPlay)
                } else {
                    group.records.firstOrNull()?.let { DownloadRow(it, title = null, onPlay = onPlay) }
                }
            }
        }
    }
}

/// Auto-delete watched downloads (SET-11, Apple `vortx.downloads.autoDeleteWatched`). A synced policy row.
/// The reclaim sweep is a separate port (see [DownloadManager.AUTO_DELETE_WATCHED_KEY]); this persists the
/// choice on Apple's exact key so it round-trips across devices and gates the sweep once that lands.
@Composable
private fun AutoDeleteWatchedToggle(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(DownloadManager.isAutoDeleteWatchedEnabled(context)) }
    Column(modifier = modifier) {
        SettingsSection(
            title = "Storage",
            footer = "When on, a title is removed from downloads once you have finished watching it, to free space.",
        ) {
            ToggleRow(
                label = "Auto-delete watched downloads",
                detail = null,
                checked = enabled,
                onCheckedChange = {
                    enabled = it
                    DownloadManager.setAutoDeleteWatchedEnabled(context, it)
                },
            )
        }
    }
}

@Composable
private fun EmptyDownloads(modifier: Modifier) {
    val colors = VortXTheme.colors
    Column(
        modifier = modifier.padding(VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            VortXIcons.download,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(44.dp),
        )
        Text("No downloads yet", style = VortXTheme.type.cardTitle, color = colors.textSecondary)
        Text(
            "Titles you save for offline viewing appear here.",
            style = VortXTheme.type.label,
            color = colors.textTertiary,
        )
    }
}

/// One show's downloads as a folder: a header (title + episode count + size) with its episodes listed underneath,
/// already sorted by season then episode. Always expanded, matching the Apple TV view: a collapsed section would hide
/// the per-episode actions behind an extra tap, and on a TV remote behind an extra focus stop.
@Composable
private fun ShowFolder(group: DownloadGroup, onPlay: (Playable) -> Unit) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.xs),
        ) {
            Icon(
                VortXIcons.library,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(26.dp),
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
                    style = VortXTheme.type.label,
                    color = colors.textTertiary,
                )
            }
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            modifier = Modifier.padding(start = VortXTheme.spacing.md),
        ) {
            group.records.forEach { record ->
                DownloadRow(record, title = episodeTitle(record), onPlay = onPlay)
            }
        }
    }
}

/// The per-episode title inside a folder: "S1E2" (or "E2" with no season), falling back to the full display title for
/// a record with no episode numbering. The folder header already carries the show name, so repeating it per episode
/// would be noise.
private fun episodeTitle(record: DownloadRecord): String {
    val season = record.season
    val episode = record.episode
    return when {
        season != null && episode != null -> "S${season}E$episode"
        episode != null -> "E$episode"
        else -> record.displayTitle
    }
}

/// One download row: a state glyph, the title + subtitle (quality / progress / error), a progress bar while active,
/// then the per-state action bar. Play for a completed row, Pause for an in-flight one, Resume for a paused or failed
/// one; Delete is always available.
@Composable
private fun DownloadRow(record: DownloadRecord, title: String?, onPlay: (Playable) -> Unit) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.sm),
        ) {
            Icon(
                stateIcon(record.state),
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
                    subtitle(record),
                    style = VortXTheme.type.label,
                    color = colors.textTertiary,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                if (record.state == DownloadState.DOWNLOADING || record.state == DownloadState.PAUSED) {
                    // An unknown total (bytesTotal == 0: every torrent loopback transfer, and any debrid link that
                    // streams without a Content-Length) renders INDETERMINATE. A determinate bar pinned at 0% would
                    // claim we know the size and are stuck, which is a different and false story.
                    if (record.bytesTotal > 0) {
                        LinearProgressIndicator(
                            progress = { record.fractionComplete.toFloat() },
                            color = colors.accent,
                            trackColor = colors.surface3,
                            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                        )
                    } else if (record.state == DownloadState.DOWNLOADING) {
                        LinearProgressIndicator(
                            color = colors.accent,
                            trackColor = colors.surface3,
                            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                        )
                    }
                }
            }
            DownloadRowActions(record, onPlay)
        }
    }
}

@Composable
private fun DownloadRowActions(record: DownloadRecord, onPlay: (Playable) -> Unit) {
    val scope = rememberCoroutineScope()
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        when (record.state) {
            DownloadState.COMPLETED -> Chip(
                label = "Play",
                selected = false,
                leadingIcon = VortXIcons.playFill,
                onClick = { scope.launch { playLocal(record, onPlay) } },
            )
            DownloadState.DOWNLOADING -> Chip(
                label = "Pause",
                selected = false,
                onClick = { DownloadManager.pause(record.id) },
            )
            DownloadState.PAUSED, DownloadState.FAILED -> Chip(
                label = "Resume",
                selected = false,
                onClick = { DownloadManager.resume(record.id) },
            )
            DownloadState.QUEUED -> Unit
        }
        Chip(
            label = "Delete",
            selected = false,
            leadingIcon = VortXIcons.delete,
            // The danger accent marks this as the destructive action, matching the Apple row's `.destructive` role.
            accent = VortXTheme.colors.danger,
            accentText = VortXTheme.colors.danger,
            onClick = { DownloadManager.cancel(record.id) },
        )
    }
}

/// Play a completed download from its LOCAL file.
///
/// IDENTITY BINDING (closes the AND-DL-01 fidelity gap): the playable is built with the ACTIVE
/// profile captured NOW, so its immutable [PlaybackContext] and derived mediaRef bind progress /
/// scrobble / auto-next consumers to THIS title before playback starts, exactly like Apple's
/// `record.playbackMeta` rebuild. The record preserves known DV and Atmos routing flags; a legacy
/// record is probed off the UI thread before routing. Fail-soft if the file was purged out from
/// under us (the eviction caption above is not hypothetical): drop the stale row instead of
/// presenting a dead player.
private suspend fun playLocal(record: DownloadRecord, onPlay: (Playable) -> Unit) {
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
            localURL = DownloadStore.fileFor(resolution.record).toURI().toString(),
            owner = activePlaybackOwner(),
        ),
    )
}

/// Who is watching RIGHT NOW (a download index is device-local, so the owner binds at play time).
/// Mirrors the repository's history split: engine/account history for the owner and own-account
/// profiles, a private overlay history otherwise. Defaults match ProfileStore's own no-store
/// fallbacks (owner id + engine history) so an uninitialized store still names a stable owner.
internal fun activePlaybackOwner(): PlaybackContext.Owner {
    val profiles = ProfileStore.sharedOrNull()
    return PlaybackContext.Owner(
        profileId = profiles?.activeProfileId ?: UserProfile.OWNER_ID,
        usesEngineHistory = profiles?.activeUsesEngineHistory ?: true,
    )
}

private fun stateIcon(state: DownloadState) = when (state) {
    DownloadState.COMPLETED -> VortXIcons.playCircle
    DownloadState.FAILED -> VortXIcons.close
    DownloadState.PAUSED -> VortXIcons.arrowDownCircle
    else -> VortXIcons.download
}

private fun subtitle(record: DownloadRecord): String {
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
                // No declared size: report the bytes we actually have rather than a fake percentage.
                "Downloading ${DownloadStore.formatBytes(record.bytesDone)}"
            },
        )
        DownloadState.PAUSED -> listOf(record.errorText ?: "Paused")
        DownloadState.FAILED -> listOf(record.errorText ?: "Failed")
        DownloadState.QUEUED -> listOf("Queued")
    }
    // The batch auto-retry note, when present, is appended rather than replacing the state line: the user should see
    // BOTH that the episode was retried and what it is doing now.
    return (parts + listOfNotNull(record.retryNote)).joinToString("  ·  ")
}
