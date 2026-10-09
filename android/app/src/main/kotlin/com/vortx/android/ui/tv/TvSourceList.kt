package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import com.vortx.android.ui.components.sourceAuthoredText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferences
import com.vortx.android.player.MpvEngineFactory
import com.vortx.android.player.PlayerEngineRouter
import com.vortx.android.player.PlayerLaunchPolicy
import com.vortx.android.sources.SourcePinScope
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.detailAudioLanguageOptions

/// The 10-foot source-list DEPTH for the TV Detail page, the couch analogue of the phone
/// [com.vortx.android.ui.screens.DetailScreen] `SourcesSection` and the mirror of Apple
/// `app/SourcesTV/DetailView.swift`'s `CoreStreamList`. It renders OVER the SAME [DetailViewModel] the phone
/// drives: the ranked/assembled [DetailViewModel.streams], the remembered [DetailViewModel.sourceSort]
/// ([DetailViewModel.setSourceSort]), the effective pin ([DetailViewModel.pinUi] / [DetailViewModel.pinSource]
/// / [DetailViewModel.unpinSource]), the two-level Quality tiers via [StreamRanking.tiers] /
/// [StreamRanking.variantOptions], and the offline [DetailViewModel.download] -- never a second copy of any of
/// that. This replaces the earlier flat `flatMap` list with add-on grouping, sort, a per-add-on filter, a
/// pin-to-top long-press menu, a quality-tier picker, and Watch-Now prominence, all D-pad-focusable as ONE
/// focus section.
///
/// Everything below the header is one vertically-scrolling [LazyColumn], so the whole source column is a
/// single focus section the D-pad walks top-to-bottom; the "Show more" window (Apple's `windowedPlan`) caps
/// how many rows are built at once so a title returning thousands of sources never instantiates them all.
@Composable
fun TvSourceList(
    streamsState: UiState<List<StreamGroup>>,
    best: StreamSource?,
    resolving: Boolean,
    failure: String?,
    downloadNotice: String?,
    sort: String,
    onSortChange: (String) -> Unit,
    audioLanguageHint: String?,
    onAudioLanguageHintChange: (String?) -> Unit,
    pin: DetailViewModel.PinUi,
    entryNoun: String,
    onPlay: (StreamSource) -> Unit,
    onPlayWithEngine: (StreamSource, PlayerEngineRouter.Override) -> Unit,
    onDownload: (StreamSource) -> Unit,
    onPin: (StreamSource, SourcePinScope) -> Unit,
    onUnpin: (SourcePinScope) -> Unit,
) {
    when (val s = streamsState) {
        is UiState.Loading -> Text(
            text = "Finding sources…",
            style = VortXTheme.type.sectionTitle.copy(color = VortXTheme.colors.textSecondary),
        )
        is UiState.Error -> Text(
            text = s.message,
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger),
        )
        is UiState.Success -> TvSourceListContent(
            groups = s.data,
            best = best,
            resolving = resolving,
            failure = failure,
            downloadNotice = downloadNotice,
            sort = sort,
            onSortChange = onSortChange,
            audioLanguageHint = audioLanguageHint,
            onAudioLanguageHintChange = onAudioLanguageHintChange,
            pin = pin,
            entryNoun = entryNoun,
            onPlay = onPlay,
            onPlayWithEngine = onPlayWithEngine,
            onDownload = onDownload,
            onPin = onPin,
            onUnpin = onUnpin,
        )
    }
}

/// Fixed remote controls and add-on jump tabs above one ordered, bounded source list.
@Composable
private fun TvSourceListContent(
    groups: List<StreamGroup>,
    best: StreamSource?,
    resolving: Boolean,
    failure: String?,
    downloadNotice: String?,
    sort: String,
    onSortChange: (String) -> Unit,
    audioLanguageHint: String?,
    onAudioLanguageHintChange: (String?) -> Unit,
    pin: DetailViewModel.PinUi,
    entryNoun: String,
    onPlay: (StreamSource) -> Unit,
    onPlayWithEngine: (StreamSource, PlayerEngineRouter.Override) -> Unit,
    onDownload: (StreamSource) -> Unit,
    onPin: (StreamSource, SourcePinScope) -> Unit,
    onUnpin: (SourcePinScope) -> Unit,
) {
    val colors = VortXTheme.colors
    // Section jumps, folding and the render window belong only to this title's remote presentation.
    // Sorting, quality, audio, pinning, download and playback keep their existing shared owners.
    var jumpGroupKey by remember { mutableStateOf<String?>(null) }
    var jumpRevision by remember { mutableStateOf(0) }
    var focusRevision by remember { mutableStateOf(0L) }
    var jumpLease by remember { mutableStateOf<TvSourceJumpLease?>(null) }
    var collapsed by remember { mutableStateOf(emptySet<String>()) }
    var renderLimit by remember { mutableStateOf(TV_SOURCE_WINDOW_INITIAL) }
    var pinMenuFor by remember { mutableStateOf<String?>(null) }
    var qualityOpen by remember { mutableStateOf(false) }
    var qualityTier by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()
    val sourceTabs = tvSourceTabs(groups)
    val groupKeys = sourceTabs.map { it.key }
    val groupFocus = remember(groupKeys) { groupKeys.associateWith { FocusRequester() } }
    fun acceptFocus() { focusRevision++ }
    fun requestJump(key: String?) {
        if (key != null) collapsed = collapsed - key
        jumpGroupKey = key
        jumpRevision++
        jumpLease = TvSourceJumpLease(key, jumpRevision, focusRevision)
    }

    val total = groups.sumOf { it.streams.size }

    if (total == 0) {
        // Done, nothing playable (Apple's "No sources found" state). The add-on groups resolved but carried no
        // playable stream, so this is a calm explanation rather than a blank pane.
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Text(text = "No sources found", style = VortXTheme.type.sectionTitle)
            Text(
                text = "None of your add-ons returned a playable source for this title.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
        }
        return
    }

    // A late section jump adds at most one 40-row window to the normal global render budget.
    val items = tvSourceWindow(groups, collapsed, renderLimit, jumpGroupKey) { tvSortedStreamsInGroup(it, sort) }
    val shownRows = items.count { it is TvSourceItem.Row }
    val expandableTotal = groups.mapIndexed { index, group ->
        if (tvSourceGroupKey(group, index) in collapsed) 0 else group.streams.size
    }.sum()
    val hasMore = shownRows < expandableTotal
    val prefixCount = 1 + (if (best != null) 1 else 0) + (if (failure != null) 1 else 0) + (if (downloadNotice != null) 1 else 0)
    LaunchedEffect(jumpRevision, groupKeys, items, prefixCount) {
        val lease = jumpLease ?: return@LaunchedEffect
        if (!lease.stillOwns(jumpRevision, focusRevision, groupKeys)) return@LaunchedEffect
        val key = lease.groupKey
        if (key == null) {
            listState.scrollToItem(0)
        } else {
            val index = tvSourceSectionIndex(items, key) ?: return@LaunchedEffect
            listState.scrollToItem(prefixCount + index)
            withFrameNanos { }
            if (!lease.stillOwns(jumpRevision, focusRevision, groupKeys)) return@LaunchedEffect
            runCatching { groupFocus[key]?.requestFocus() }
        }
    }

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        TvSourceControlsRow(
            groups = groups,
            sort = sort,
            onSortChange = onSortChange,
            audioLanguageHint = audioLanguageHint,
            onAudioLanguageHintChange = onAudioLanguageHintChange,
            qualityOpen = qualityOpen,
            onQualityOpenChange = { qualityOpen = it },
            qualityTier = qualityTier,
            onQualityTierChange = { qualityTier = it },
            onPlay = onPlay,
            onFocused = ::acceptFocus,
        )
        // These tabs scroll to a section in the complete ordered list; selecting an add-on never filters
        // away its neighbors or changes the user's installed add-on order.
        if (sourceTabs.size > 1) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                item(key = "sources-all") {
                    TvFilterChip("All ($total)", jumpGroupKey == null, onClick = { requestJump(null) }, modifier = Modifier.onFocusChanged { if (it.isFocused) acceptFocus() })
                }
                itemsIndexed(sourceTabs, key = { _, tab -> tab.key }) { _, tab ->
                    val key = tab.key
                    TvFilterChip(
                        label = "${tab.addon} (${tab.count})",
                        selected = jumpGroupKey == key,
                        onClick = { requestJump(key) },
                        modifier = Modifier.onFocusChanged { if (it.isFocused) acceptFocus() },
                    )
                }
            }
        }
    LazyColumn(
        modifier = Modifier.fillMaxWidth().weight(1f),
        state = listState,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        contentPadding = PaddingValues(bottom = TvDimens.edge),
    ) {
        item(key = "sources-count") {
            Text(
                text = "Sources · $total",
                style = VortXTheme.type.sectionTitle,
                modifier = Modifier.padding(bottom = VortXTheme.spacing.xs),
            )
        }

        // Watch-Now prominence: the single global best source floated to the top as a highlighted row, the
        // couch analogue of Apple's Watch-Now action above the source column. One press plays the best-ranked
        // source straight away (the same [DetailViewModel.bestSource] the hero Watch button uses).
        best?.let { top ->
            item(key = "sources-best") {
                TvBestSourceRow(source = top, enabled = !resolving, onPlay = { onPlay(top) }, onFocused = ::acceptFocus)
            }
        }

        failure?.let {
            item(key = "sources-failure") {
                Text(text = it, style = VortXTheme.type.label.copy(color = colors.danger))
            }
        }
        // The offline-download status line (long-press a source -> Download): a transient confirmation or the
        // resolver's honest failure, in the accent tone so it reads as info, not error.
        downloadNotice?.let {
            item(key = "sources-download-notice") {
                Text(text = it, style = VortXTheme.type.label.copy(color = colors.accent))
            }
        }

        // The grouped, collapsible, windowed list. Keyed by position so a decorated/duplicate source id can
        // never collide in the LazyColumn (the same belt-and-suspenders the flat list used).
        items(items.size, key = { i -> tvSourceItemKey(i, items[i]) }) { i ->
            when (val entry = items[i]) {
                is TvSourceItem.Header -> TvSourceGroupHeader(
                    addon = entry.addon,
                    count = entry.count,
                    collapsed = entry.collapsed,
                    modifier = Modifier
                        .then(groupFocus[entry.key]?.takeIf { entry.firstProviderSection }?.let { Modifier.focusRequester(it) } ?: Modifier)
                        .onFocusChanged { if (it.isFocused) acceptFocus() },
                    onToggle = {
                        collapsed = if (entry.collapsed) collapsed - entry.key else collapsed + entry.key
                    },
                )
                is TvSourceItem.Row -> {
                    val menuKey = "${entry.groupKey}|${entry.source.id}"
                    val pinned = pin.resolved
                        ?.let { SourcePinStore.matches(entry.source, entry.addon, it) } == true
                    TvSourceDepthRow(
                        source = entry.source,
                        pinned = pinned,
                        resolving = resolving,
                        pin = pin,
                        entryNoun = entryNoun,
                        menuOpen = pinMenuFor == menuKey,
                        onOpenMenu = { pinMenuFor = menuKey },
                        onDismissMenu = { pinMenuFor = null },
                        onPlay = onPlay,
                        onPlayWithEngine = onPlayWithEngine,
                        onDownload = onDownload,
                        onPin = onPin,
                        onUnpin = onUnpin,
                        onFocused = ::acceptFocus,
                    )
                }
            }
        }

        if (hasMore) {
            item(key = "sources-show-more") {
                TvFilterChip(
                    label = "Show more · ${expandableTotal - shownRows} more",
                    selected = false,
                    onClick = { renderLimit += TV_SOURCE_WINDOW_STEP },
                    modifier = Modifier.onFocusChanged { if (it.isFocused) acceptFocus() },
                )
            }
        }
    }
    }
}

/// The prominent Watch-Now row: the best-ranked source, accent-ringed with a "BEST" pill and its
/// [StreamRanking.watchLabel], so the couch viewer sees exactly what one press will play. Its own focusable tv
/// [Surface]; a cached best also lights the "Instant" tag.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvBestSourceRow(source: StreamSource, enabled: Boolean, onPlay: () -> Unit, onFocused: () -> Unit) {
    val colors = VortXTheme.colors
    val cached = StreamRanking.isCachedSource(source)
    Surface(
        onClick = onPlay,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().onFocusChanged { if (it.isFocused) onFocused() },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.accent.copy(alpha = 0.22f),
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        border = ClickableSurfaceDefaults.border(
            border = Border(
                border = BorderStroke(TvDimens.focusBorder, colors.accent),
                shape = VortXShapes.control,
            ),
            focusedBorder = Border(
                border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Icon(imageVector = VortXIcons.playFill, contentDescription = null)
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Watch Now",
                    style = VortXTheme.type.eyebrow,
                    maxLines = 1,
                )
                Text(
                    text = StreamRanking.watchLabel(source),
                    style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            TvSourceBadge(text = "BEST", tint = colors.accentBright, onTint = colors.onAccent)
            if (cached) TvSourceBadge(text = "Instant", tint = colors.accentBright, onTint = colors.onAccent)
        }
    }
}

/// The Best/Size/Seeders sort chips plus the two-level Quality picker (resolution tier -> flavour variant),
/// mirroring the phone SourcesSection controls row. The Quality picker reuses [StreamRanking.tiers] and
/// [StreamRanking.variantOptions] (never a second quality classifier) and plays the chosen variant through
/// [onPlay]. Hidden until at least one tier resolves.
@Composable
private fun TvSourceControlsRow(
    groups: List<StreamGroup>,
    sort: String,
    onSortChange: (String) -> Unit,
    audioLanguageHint: String?,
    onAudioLanguageHintChange: (String?) -> Unit,
    qualityOpen: Boolean,
    onQualityOpenChange: (Boolean) -> Unit,
    qualityTier: String?,
    onQualityTierChange: (String?) -> Unit,
    onPlay: (StreamSource) -> Unit,
    onFocused: () -> Unit,
) {
    var audioOpen by remember { mutableStateOf(false) }
    // The picker is a session filter over the sources currently assembled for this title.  Keep the
    // settings list as a label fallback only: iterating it here used to advertise every configured
    // language (including languages no add-on returned) and left the TV menu out of sync with the phone.
    val audioLanguageOptions = detailAudioLanguageOptions(groups)
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        modifier = Modifier.onFocusChanged { if (it.hasFocus) onFocused() },
    ) {
        items(TV_SOURCE_SORT_OPTIONS, key = { it.first }) { (key, label) ->
            TvFilterChip(label = label, selected = key == sort, onClick = { onSortChange(key) })
        }
        val tiers = StreamRanking.tiers(groups)
        if (tiers.isNotEmpty()) {
            item(key = "quality-picker") {
                Box {
                    TvFilterChip(
                        label = "Quality",
                        selected = qualityOpen,
                        onClick = { onQualityOpenChange(true); onQualityTierChange(null) },
                    )
                    // Level 1: the resolution tiers (4K / 1080p / 720p / Others).
                    DropdownMenu(
                        expanded = qualityOpen && qualityTier == null,
                        onDismissRequest = { onQualityOpenChange(false) },
                    ) {
                        tiers.forEach { tier ->
                            DropdownMenuItem(
                                text = { Text(tier) },
                                onClick = { onQualityTierChange(tier) },
                            )
                        }
                    }
                    // Level 2: the flavour variants inside the chosen tier (Dolby Vision · Remux, HDR · Atmos …).
                    val activeTier = qualityTier
                    DropdownMenu(
                        expanded = qualityOpen && activeTier != null,
                        onDismissRequest = { onQualityOpenChange(false); onQualityTierChange(null) },
                    ) {
                        DropdownMenuItem(text = { Text("‹ Back") }, onClick = { onQualityTierChange(null) })
                        if (activeTier != null) {
                            StreamRanking.variantOptions(groups, activeTier).forEach { (label, source) ->
                                DropdownMenuItem(
                                    text = { Text(label) },
                                    onClick = {
                                        onQualityOpenChange(false)
                                        onQualityTierChange(null)
                                        onPlay(source)
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
        item(key = "audio-picker") {
            Box {
                TvFilterChip(
                    label = audioLanguageHint?.let { code ->
                        audioLanguageOptions.firstOrNull { it.first == code }?.second
                            ?: TrackPreferences.commonLanguages.firstOrNull { it.first == code }?.second
                            ?: code
                    } ?: "Audio",
                    selected = audioOpen || audioLanguageHint != null,
                    onClick = { audioOpen = true },
                )
                DropdownMenu(
                    expanded = audioOpen,
                    onDismissRequest = { audioOpen = false },
                ) {
                    DropdownMenuItem(
                        text = { Text(if (audioLanguageHint == null) "✓ Auto" else "Auto") },
                        onClick = {
                            audioOpen = false
                            onAudioLanguageHintChange(null)
                        },
                    )
                    audioLanguageOptions.forEach { (code, name) ->
                        DropdownMenuItem(
                            text = { Text(if (audioLanguageHint == code) "✓ $name" else name) },
                            onClick = {
                                audioOpen = false
                                onAudioLanguageHintChange(code)
                            },
                        )
                    }
                }
            }
        }
    }
}

/// A tappable per-add-on header (name + source count + fold chevron) that folds its rows away, the collapsible
/// section head of the grouped list (Apple's `sectionHeader`, the phone `SourceGroupHeader`). Focusable so the
/// D-pad can collapse a noisy add-on from the couch.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvSourceGroupHeader(addon: String, count: Int, collapsed: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onToggle,
        modifier = modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.chip),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface2,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.01f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.chip,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = addon.uppercase(), style = VortXTheme.type.eyebrow.copy(color = colors.accent))
            Text(text = "$count", style = VortXTheme.type.label.copy(color = colors.textTertiary))
            Box(modifier = Modifier.weight(1f))
            Icon(
                imageVector = if (collapsed) VortXIcons.chevronDown else VortXIcons.chevronUp,
                contentDescription = if (collapsed) "Expand $addon sources" else "Collapse $addon sources",
                tint = colors.textSecondary,
            )
        }
    }
}

/// One focusable source row with its ranker-derived badges (quality, Cached "Instant", torrent seeders,
/// Pinned, flavour tags) and a long-press pin/download menu, the couch analogue of the phone
/// `StreamRowWithPinMenu`. Every badge/tag comes from the SAME [StreamRanking] helpers the phone rows and the
/// ranker itself use; long-press opens the pin/unpin/download menu ([onPin]/[onUnpin]/[onDownload]), pinning
/// through the SAME [DetailViewModel] seam so a pin floats this source to the top on the next re-rank.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvSourceDepthRow(
    source: StreamSource,
    pinned: Boolean,
    resolving: Boolean,
    pin: DetailViewModel.PinUi,
    entryNoun: String,
    menuOpen: Boolean,
    onOpenMenu: () -> Unit,
    onDismissMenu: () -> Unit,
    onPlay: (StreamSource) -> Unit,
    onPlayWithEngine: (StreamSource, PlayerEngineRouter.Override) -> Unit,
    onDownload: (StreamSource) -> Unit,
    onPin: (StreamSource, SourcePinScope) -> Unit,
    onUnpin: (SourcePinScope) -> Unit,
    onFocused: () -> Unit,
) {
    val colors = VortXTheme.colors
    val cached = StreamRanking.isCachedSource(source)
    val seeders = StreamRanking.seedersForSort(source).takeIf { source.isTorrent && it >= 0 }
    val quality = StreamRanking.qualityLabel(source)
    val size = StreamRanking.sizeText(source)
    // Drop the plain "Cached" flavour tag when the prominent Instant badge shows, so a cached row reads as one
    // badge, not two (the same de-dup the phone row does).
    val flavorTags = StreamRanking.flavorTags(source).filter { !(it == "Cached" && cached) }
    Box {
        Surface(
            onClick = { onPlay(source) },
            onLongClick = onOpenMenu,
            enabled = !resolving,
            modifier = Modifier.fillMaxWidth().onFocusChanged { if (it.isFocused) onFocused() },
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = colors.surface1,
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface3,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(2.dp, colors.accentBright),
                    shape = VortXShapes.control,
                ),
            ),
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
                Text(
                    text = sourceAuthoredText(source.title, source.description),
                    style = VortXTheme.type.body,
                )
                val metaLine = listOfNotNull(
                    quality.takeIf { it.isNotBlank() },
                    source.addon,
                    size,
                    seeders?.let { "$it seeders" },
                ).joinToString("  ·  ")
                if (metaLine.isNotBlank()) {
                    Text(
                        text = metaLine,
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                // Ranker-derived badges: the prominent Cached "Instant" mark, a Pinned mark, then a few flavour
                // tags (Dolby Vision, HDR, Atmos, Remux, …), all display-only over the existing helpers. A plain
                // row (capped) so the couch pane never has to scroll a badge strip inside a focused row.
                if (cached || pinned || flavorTags.isNotEmpty()) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                        modifier = Modifier.padding(top = 6.dp),
                    ) {
                        if (cached) {
                            TvSourceBadge(text = "Instant", tint = colors.accentBright, onTint = colors.onAccent)
                        }
                        if (pinned) {
                            TvSourceBadge(text = "Pinned", tint = colors.accent, onTint = colors.onAccent)
                        }
                        flavorTags.take(3).forEach { tag ->
                            TvSourceBadge(text = tag, tint = colors.surface3, onTint = colors.textSecondary)
                        }
                    }
                }
            }
        }
        // The long-press menu starts with explicit, one-launch player choices for THIS source, then retains
        // the existing offline-download and pin actions.
        DropdownMenu(expanded = menuOpen, onDismissRequest = onDismissMenu) {
            PlayerLaunchPolicy.sourceChoices(source, MpvEngineFactory.isBundled).forEach { choice ->
                DropdownMenuItem(
                    text = { Text("Play with ${choice.label}") },
                    onClick = { onDismissMenu(); onPlayWithEngine(source, choice.preference) },
                )
            }
            DropdownMenuItem(
                text = { Text("Download for offline") },
                onClick = { onDismissMenu(); onDownload(source) },
            )
            DropdownMenuItem(
                text = { Text("Pin for this $entryNoun") },
                onClick = { onDismissMenu(); onPin(source, SourcePinScope.ENTRY) },
            )
            DropdownMenuItem(
                text = { Text("Pin everywhere") },
                onClick = { onDismissMenu(); onPin(source, SourcePinScope.GLOBAL) },
            )
            if (pin.hasEntry) {
                DropdownMenuItem(
                    text = { Text("Unpin this $entryNoun") },
                    onClick = { onDismissMenu(); onUnpin(SourcePinScope.ENTRY) },
                )
            }
            if (pin.hasGlobal) {
                DropdownMenuItem(
                    text = { Text("Unpin everywhere") },
                    onClick = { onDismissMenu(); onUnpin(SourcePinScope.GLOBAL) },
                )
            }
        }
    }
}

/// A small pill badge for a source row's ranker signal (BEST / Instant / Pinned / a flavour tag). Display-only.
@Composable
private fun TvSourceBadge(text: String, tint: Color, onTint: Color) {
    Text(
        text = text,
        style = VortXTheme.type.eyebrow.copy(color = onTint, fontWeight = FontWeight.SemiBold),
        maxLines = 1,
        modifier = Modifier
            .clip(VortXShapes.pill)
            .background(tint)
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

/// How the streams inside each add-on group are ordered, mirroring the phone `sortedStreamsInGroup` and Apple
/// `iOSSourceList.SourceSort` exactly: Best leaves the engine ranking intact; Size and Seeders sort descending
/// WITHIN each group (so the add-on grouping survives), with unknown values sinking (sizeForSort 0 /
/// seedersForSort -1) via the SAME [StreamRanking] helpers the phone list uses.
private fun tvSortedStreamsInGroup(streams: List<StreamSource>, sort: String): List<StreamSource> =
    when (sort) {
        "size" -> streams.sortedByDescending { StreamRanking.sizeForSort(it) }
        "seeders" -> streams.sortedByDescending { StreamRanking.seedersForSort(it) }
        else -> streams
    }

/// A stable LazyColumn key for a rendered [TvSourceItem]: position-prefixed so a decorated / duplicate source
/// id can never collide, header vs row disambiguated by kind.
/// The sort ids/labels, the SAME lowercase persistence keys the phone `defaultSourceSort` stores, so the TV
/// list opens the way the user last left it and a change written here is read back on the phone.
private val TV_SOURCE_SORT_OPTIONS: List<Pair<String, String>> = listOf(
    "best" to "Best",
    "size" to "Size",
    "seeders" to "Seeders",
)

/// The render window for the grouped source list: how many rows are built up front and the step "Show more"
/// grows it by, the couch analogue of the phone SOURCE_WINDOW_* / Apple's `sourceWindowStep`. Bounded so a
/// title returning thousands of sources never instantiates them all at once.
private const val TV_SOURCE_WINDOW_INITIAL = 40
private const val TV_SOURCE_WINDOW_STEP = 40
