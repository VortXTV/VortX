package com.vortx.android.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.vortx.android.downloads.BatchDownloadItem
import com.vortx.android.downloads.BatchDownloadItemState
import com.vortx.android.downloads.BatchDownloadPolicy
import com.vortx.android.downloads.BatchDownloadState
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.tv.TvDimens
import com.vortx.android.ui.tv.TvFilterChip

private const val MAX_SOURCE_CHOICES = 12

/** Selection and preparation UI only. The caller captures preferences and owns the batch lifetime. */
@Composable
fun BatchDownloadPicker(
    detail: MetaDetail,
    currentSeason: Int?,
    sources: List<StreamSource>,
    state: BatchDownloadState,
    onStart: (Set<String>, StreamSource?) -> Unit,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
    tv: Boolean = false,
) {
    val episodes = remember(detail.videos) { detail.orderedEpisodes.distinctBy { it.id } }
    val episodeIds = remember(episodes) { episodes.map { it.id }.toSet() }
    val seasons = remember(episodes) { episodes.map { it.season }.distinct() }
    val initialSeason = currentSeason?.takeIf { it in seasons }
        ?: seasons.firstOrNull { it > 0 } ?: seasons.firstOrNull()
    var browseSeason by remember(detail.id, detail.type) { mutableStateOf(initialSeason) }
    var selectedIds by remember(detail.id, detail.type) {
        val initialIds = episodes.filter { it.season == initialSeason }.map { it.id }.toSet()
        mutableStateOf(initialIds.takeIf { it.size <= BatchDownloadPolicy.MAX_EPISODES } ?: emptySet())
    }
    // Keep the actual source object chosen by the viewer; do not rebuild it from a display label or ID.
    var desiredSource by remember(detail.id, detail.type) { mutableStateOf<StreamSource?>(null) }
    val sourceChoices = remember(sources) {
        sources.asSequence().filterNot { it.isYouTubeTrailer }.distinctBy(::batchSourceKey)
            .take(MAX_SOURCE_CHOICES + 1).toList()
    }
    val selection = remember(selectedIds, episodeIds) { selectedIds.intersect(episodeIds) }
    val shownEpisodes = remember(episodes, browseSeason) {
        episodes.filter { browseSeason == null || it.season == browseSeason }
    }
    var viewResults by remember(detail.id, detail.type) { mutableStateOf(state.items.isNotEmpty()) }
    val showingResults = state.running || (viewResults && state.items.isNotEmpty())
    val closeFocus = remember { FocusRequester() }
    val listState = rememberLazyListState()
    val colors = VortXTheme.colors
    val edge = if (tv) TvDimens.edge else VortXTheme.spacing.edge
    val cap = BatchDownloadPolicy.MAX_EPISODES

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false),
    ) {
        BackHandler(onBack = onDismiss)
        LaunchedEffect(tv, showingResults) {
            listState.scrollToItem(0)
            if (tv) runCatching { closeFocus.requestFocus() }
        }
        Surface(modifier = Modifier.fillMaxSize(), color = colors.canvas, contentColor = colors.textPrimary) {
            Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = edge, vertical = VortXTheme.spacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Download episodes", style = VortXTheme.type.sectionTitle)
                        Text(detail.name, style = VortXTheme.type.label.copy(color = colors.textSecondary),
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    BatchPickerChip("Close", tv = tv, onClick = onDismiss,
                        modifier = Modifier.focusRequester(closeFocus))
                }
                LazyColumn(
                    state = listState,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = edge, vertical = VortXTheme.spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    if (showingResults) {
                        item(key = "progress") { BatchPickerProgress(state) }
                        items(state.items, key = { "result:${it.episode.id}" }) { item ->
                            BatchPickerResult(item, tv)
                        }
                    } else {
                        item(key = "source") {
                            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                                Text("Source preference", style = VortXTheme.type.cardTitle)
                                Text(
                                    "Choose a provider and quality to prefer across episodes. Your language " +
                                        "and source preferences are captured when you start.",
                                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                                )
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                                    contentPadding = PaddingValues(vertical = VortXTheme.spacing.xs)) {
                                    item(key = "best") {
                                        BatchPickerChip("Best matching source", selected = desiredSource == null,
                                            tv = tv, onClick = { desiredSource = null })
                                    }
                                    itemsIndexed(sourceChoices.take(MAX_SOURCE_CHOICES)) { index, source ->
                                        BatchPickerChip("${index + 1}. ${batchSourceLabel(source)}",
                                            selected = desiredSource?.let(::batchSourceKey) == batchSourceKey(source),
                                            tv = tv, onClick = { desiredSource = source })
                                    }
                                }
                                desiredSource?.let { source ->
                                    Text(source.title, style = VortXTheme.type.label.copy(color = colors.textTertiary),
                                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                                }
                                if (sourceChoices.size > MAX_SOURCE_CHOICES) {
                                    Text("Showing $MAX_SOURCE_CHOICES distinct source preferences from this episode.",
                                        style = VortXTheme.type.label.copy(color = colors.textTertiary))
                                }
                            }
                        }
                        item(key = "seasons") {
                            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                                Text("Episodes · ${selection.size} selected", style = VortXTheme.type.cardTitle)
                                Text("Select a season or mix episodes from different seasons. Up to $cap per batch.",
                                    style = VortXTheme.type.label.copy(color = colors.textSecondary))
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                                    contentPadding = PaddingValues(vertical = VortXTheme.spacing.xs)) {
                                    item(key = "all") {
                                        BatchPickerChip("All seasons", selected = browseSeason == null, tv = tv,
                                            onClick = { browseSeason = null })
                                    }
                                    items(seasons, key = { it }) { season ->
                                        BatchPickerChip(if (season == 0) "Specials" else "Season $season",
                                            selected = browseSeason == season, tv = tv,
                                            onClick = { browseSeason = season })
                                    }
                                }
                                val shownIds = shownEpisodes.map { it.id }.toSet()
                                val allSelected = shownIds.isNotEmpty() && selection.containsAll(shownIds)
                                val canSelectShown = (selection + shownIds).size <= cap
                                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                                    BatchPickerChip(
                                        label = if (allSelected) "Clear selection here"
                                            else if (browseSeason == null) "Select all" else "Select season",
                                        tv = tv,
                                        enabled = shownIds.isNotEmpty() && (allSelected || canSelectShown),
                                        onClick = {
                                            selectedIds = if (allSelected) selection - shownIds else selection + shownIds
                                        },
                                    )
                                    BatchPickerChip("Clear all", tv = tv, enabled = selection.isNotEmpty(),
                                        onClick = { selectedIds = emptySet() })
                                }
                                if (!canSelectShown) {
                                    Text("This selection would exceed $cap episodes. Choose individual episodes or clear some selections.",
                                        style = VortXTheme.type.label.copy(color = colors.textSecondary))
                                }
                            }
                        }
                        if (shownEpisodes.isEmpty()) {
                            item(key = "no-episodes") {
                                Text("No episodes available for this season.", style = VortXTheme.type.body)
                            }
                        }
                        items(shownEpisodes, key = { "episode:${it.id}" }) { episode ->
                            val selected = episode.id in selection
                            BatchPickerChip(
                                label = "${if (selected) "✓  " else ""}${batchEpisodeLabel(episode)}",
                                selected = selected,
                                tv = tv,
                                enabled = selected || selection.size < cap,
                                modifier = Modifier.fillMaxWidth(),
                                stateDescription = if (selected) "Selected for download" else "Not selected",
                                onClick = {
                                    selectedIds = if (selected) selection - episode.id else selection + episode.id
                                },
                            )
                        }
                    }
                }
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = edge, vertical = VortXTheme.spacing.md),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    when {
                        state.running -> {
                            Text("Cancel remaining stops preparation. Downloads already accepted will continue in Downloads.",
                                style = VortXTheme.type.label.copy(color = colors.textSecondary))
                            BatchPickerChip("Cancel remaining", tv = tv, onClick = onCancel)
                        }
                        showingResults -> BatchPickerChip("Choose episodes", tv = tv, onClick = { viewResults = false })
                        else -> {
                            val start = {
                                viewResults = true
                                onStart(selection.toSet(), desiredSource)
                            }
                            val canStart = selection.isNotEmpty() && selection.size <= cap
                            if (tv) {
                                BatchPickerChip("Queue ${selection.size} episodes", selected = true, tv = true,
                                    enabled = canStart, onClick = start)
                            } else {
                                PrimaryButton("Queue ${selection.size} episodes", enabled = canStart, onClick = start,
                                    leadingIcon = VortXIcons.download, modifier = Modifier.fillMaxWidth())
                            }
                            if (state.items.isNotEmpty()) {
                                BatchPickerChip("View last results", tv = tv, onClick = { viewResults = true })
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BatchPickerChip(
    label: String,
    tv: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    enabled: Boolean = true,
    stateDescription: String? = null,
) {
    if (tv) {
        TvFilterChip(label = label, selected = selected, onClick = onClick, modifier = modifier,
            enabled = enabled, stateDescription = stateDescription)
    } else {
        Chip(label = label, selected = selected, onClick = onClick, modifier = modifier,
            enabled = enabled, stateDescription = stateDescription)
    }
}

@Composable
private fun BatchPickerProgress(state: BatchDownloadState) {
    val finished = state.items.count {
        it.state != BatchDownloadItemState.WAITING && it.state != BatchDownloadItemState.PREPARING
    }
    val stopped = state.items.any { it.state == BatchDownloadItemState.CANCELLED }
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(when {
            state.running -> "Preparing downloads"
            stopped -> "Preparation stopped"
            else -> "Preparation finished"
        }, style = VortXTheme.type.cardTitle)
        Text("$finished of ${state.items.size} have a result · ${state.accepted} accepted · ${state.failed} failed",
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
        LinearProgressIndicator(
            progress = { if (state.items.isEmpty()) 0f else finished.toFloat() / state.items.size },
            modifier = Modifier.fillMaxWidth(),
            color = VortXTheme.colors.accent,
            trackColor = VortXTheme.colors.surface3,
        )
        Text("Accepted episodes appear in Downloads, where you can manage their transfer progress.",
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
    }
}

@Composable
private fun BatchPickerResult(item: BatchDownloadItem, tv: Boolean) {
    var focused by remember { mutableStateOf(false) }
    val colors = VortXTheme.colors
    val label = when (item.state) {
        BatchDownloadItemState.WAITING -> "Waiting for preparation"
        BatchDownloadItemState.PREPARING -> "Finding a matching source"
        BatchDownloadItemState.ACCEPTED -> "Accepted into Downloads"
        BatchDownloadItemState.ALREADY_SAVED -> "Already in Downloads"
        BatchDownloadItemState.FAILED -> "Could not prepare download"
        BatchDownloadItemState.CANCELLED -> "Cancelled · not queued"
    }
    // Read-only results remain D-pad focus stops so a long result list can be scrolled on TV.
    Surface(
        modifier = Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused }
            .focusable(enabled = tv).semantics(mergeDescendants = true) {},
        color = if (focused) colors.surface2 else colors.surface1,
        shape = VortXShapes.card,
        border = if (focused) BorderStroke(2.dp, colors.accentBright) else null,
    ) {
        Column(modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Text(batchEpisodeLabel(item.episode), style = VortXTheme.type.cardTitle,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(label, style = VortXTheme.type.label,
                color = if (item.state == BatchDownloadItemState.FAILED) colors.danger else colors.textSecondary)
            item.note?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
        }
    }
}

private fun batchEpisodeLabel(episode: Episode): String = "S${episode.season}E${episode.episode} · ${episode.title}"

private fun batchSourceLabel(source: StreamSource): String =
    listOf(source.addon.take(40), StreamRanking.qualityLabel(source), StreamRanking.releaseFlavor(source))
        .filter { it.isNotBlank() }.joinToString(" · ")

private fun batchSourceKey(source: StreamSource): List<String?> =
    listOf(source.addon, StreamRanking.qualityLabel(source), StreamRanking.releaseFlavor(source), source.bingeGroup)
