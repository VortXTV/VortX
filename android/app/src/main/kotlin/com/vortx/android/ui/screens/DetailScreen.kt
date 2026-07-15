package com.vortx.android.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.DefaultEpisodeThumb
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.EpisodeRow
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SourceRow
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.components.shimmer
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.Playback

/// Title detail, driven by [DetailViewModel] -- movie/series per DESIGN-SYSTEM.md §4 "Detail":
/// a fixed hero banner (backdrop + dual scrim + bottom-left title block, NOT a full-page wash, the
/// S03 landscape height clamp preserved) over a readable content column (the hero-actions cluster:
/// the one gold Watch/Resume [PrimaryButton] + Library/Sources chips -> synopsis -> credits ->
/// [series: season selector + episode list]). Movie = Watch + synopsis + credits; series adds the
/// season chips (long-press / "…" = bulk mark-watched) and the episode list (tap = choose sources for
/// that episode, checkmark = per-episode watched toggle). Quality/ranked "All sources" stay S06 scope;
/// this session only exposes the raw per-add-on list behind the "Sources" chip, unranked.
@Composable
fun DetailScreen(
    viewModel: DetailViewModel,
    title: String,
    onBack: () -> Unit,
    onPlay: (Playable) -> Unit,
    modifier: Modifier = Modifier,
) {
    val metaState by viewModel.meta.collectAsStateWithLifecycle()
    val streamsState by viewModel.streams.collectAsStateWithLifecycle()
    val playback by viewModel.playback.collectAsStateWithLifecycle()
    val selectedEpisodeId by viewModel.selectedEpisodeId.collectAsStateWithLifecycle()
    val selectedSeason by viewModel.selectedSeason.collectAsStateWithLifecycle()
    val mutationError by viewModel.mutationError.collectAsStateWithLifecycle()

    // When a source resolves, hand the Playable up to navigation and reset, so returning from the
    // player lands back on detail rather than immediately re-launching.
    LaunchedEffect(playback) {
        (playback as? Playback.Ready)?.let {
            onPlay(it.playable)
            viewModel.clearPlayback()
        }
    }

    val resolving = playback is Playback.Resolving
    var sourcesOpen by remember { mutableStateOf(false) }

    Box(modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        when (val m = metaState) {
            is UiState.Loading -> DetailSkeleton(title)
            is UiState.Error -> ErrorState(m.message, onRetry = onBack, modifier = Modifier.fillMaxSize())
            is UiState.Success -> LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
            ) {
                item { Backdrop(m.data) }
                item {
                    ActionsCluster(
                        m = m.data,
                        primaryEpisode = viewModel.primaryEpisode(),
                        watchEnabled = viewModel.bestSource() != null && !resolving,
                        resolving = resolving,
                        sourcesOpen = sourcesOpen,
                        onWatch = { viewModel.bestSource()?.let(viewModel::play) },
                        onToggleSources = { sourcesOpen = !sourcesOpen },
                        onToggleLibrary = viewModel::toggleLibrary,
                        onToggleWatched = { viewModel.setWatched(!(m.data.libraryItem?.isWatched ?: false)) },
                    )
                }
                if (sourcesOpen) {
                    item {
                        SurfaceCard(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge)) {
                            SourcesSection(
                                state = streamsState,
                                resolving = resolving,
                                failure = (playback as? Playback.Failed)?.message,
                                onPlay = viewModel::play,
                            )
                        }
                    }
                }
                m.data.description?.let { synopsis ->
                    item {
                        Text(
                            text = synopsis,
                            style = VortXTheme.type.body,
                            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
                        )
                    }
                }
                if (m.data.cast.isNotEmpty() || m.data.directors.isNotEmpty() || m.data.writers.isNotEmpty()) {
                    item { CreditsSection(m.data) }
                }
                if (m.data.type == MediaType.SERIES && m.data.videos.isNotEmpty()) {
                    item {
                        SeasonSelector(
                            detail = m.data,
                            selectedSeason = selectedSeason ?: m.data.videos.first().season,
                            onSelectSeason = viewModel::selectSeason,
                            onMarkSeasonWatched = viewModel::setSeasonWatched,
                            onMarkSeriesWatched = viewModel::setWatched,
                        )
                    }
                    val episodes = m.data.videos
                        .filter { it.season == (selectedSeason ?: m.data.videos.first().season) }
                        .sortedBy { it.episode }
                    items(episodes, key = { it.id }) { episode ->
                        val currentForSources = episode.id == selectedEpisodeId
                        EpisodeRow(
                            code = if (episode.season > 0) "S${episode.season} · E${episode.episode}" else "Episode ${episode.episode}",
                            title = episode.title,
                            overview = episode.overview,
                            airDate = episode.released?.take(10),
                            watched = episode.id in m.data.watchedVideoIds,
                            progress = episodeProgress(episode, m.data),
                            onClick = { viewModel.selectEpisode(episode.id) },
                            onLongClick = { viewModel.setVideoWatched(episode, episode.id !in m.data.watchedVideoIds) },
                            thumb = { EpisodeThumb(episode) },
                            modifier = Modifier
                                .padding(horizontal = VortXTheme.spacing.edge)
                                .then(
                                    // The episode whose sources are currently shown up in the hero
                                    // cluster gets an accent ring, so "what Watch/Resume will play"
                                    // stays legible while browsing the rest of the season.
                                    if (currentForSources) {
                                        Modifier.border(BorderStroke(1.dp, VortXTheme.colors.accent), VortXShapes.card)
                                    } else {
                                        Modifier
                                    },
                                ),
                        )
                    }
                }
                item { Spacer(Modifier.height(VortXTheme.spacing.xl)) }
            }
        }
        BackChip(onBack = onBack, modifier = Modifier.align(Alignment.TopStart))
        mutationError?.let {
            // A resolve/mutation failure is transient and non-blocking (the page underneath stays
            // usable) -- a small pill at the bottom rather than a second full-screen error layer.
            Text(
                text = it,
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(VortXTheme.spacing.md)
                    .clip(VortXShapes.chip)
                    .background(VortXTheme.colors.surface2, VortXShapes.chip)
                    .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            )
        }
    }
}

/// The contextual Back chip (DESIGN-SYSTEM.md §4 Detail "contextual Back chip top-left"), floating
/// over the backdrop rather than a Material top app bar -- Detail has no app-bar chrome, matching the
/// blueprint's fixed hero + content column, not a Scaffold shell.
@Composable
private fun BackChip(onBack: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(VortXTheme.spacing.md)
            .clip(VortXShapes.chip)
            .background(Color.Black.copy(alpha = 0.35f), VortXShapes.chip),
    ) {
        IconButton(onClick = onBack) {
            Icon(VortXIcons.back, contentDescription = "Back", tint = Color.White)
        }
    }
}

/// Skeleton shimmer loading state (DESIGN-SYSTEM.md §3 "skeleton shimmer for loading, never a bare
/// spinner as the whole state"): a backdrop-shaped block + a few text-line blocks. [title] (the poster
/// card's name, passed down from whichever rail the user tapped) renders immediately instead of a
/// shimmering line, so the transition into Detail reads as instant even before `meta_details` answers.
@Composable
private fun DetailSkeleton(title: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(top = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            Box(modifier = Modifier.fillMaxWidth().height(heroHeight(maxWidth)).shimmer())
        }
        Column(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text(text = title, style = VortXTheme.type.screenTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Box(modifier = Modifier.fillMaxWidth(0.4f).heightIn(min = 16.dp, max = 16.dp).clip(VortXShapes.chip).shimmer())
            Box(modifier = Modifier.width(140.dp).heightIn(min = 48.dp, max = 48.dp).clip(VortXShapes.control).shimmer())
        }
    }
}

/// Cinematic hero banner (DESIGN-SYSTEM.md §4 Detail "hero banner"): a real backdrop image (falls back
/// to the brand-tinted gradient with no artwork yet) behind a dual scrim -- a vertical fade to canvas
/// (readability against the content column below) plus a leading horizontal fade (readability behind
/// the bottom-left title block) -- with the title/logo + single-line meta row anchored bottom-left.
@Composable
private fun Backdrop(m: MetaDetail) {
    val colors = VortXTheme.colors
    // BoxWithConstraints + an explicitly computed height, NOT `.heightIn(max = 260.dp).aspectRatio(...)`
    // -- that combination is the actual bug behind the tablet "synopsis painted over the hero"
    // report (Tab S11 Ultra, both a movie and a series). `fillMaxWidth()` forces this Box's width
    // constraints to be FIXED (min == max == the available width). Compose's `aspectRatio` solver can
    // only honor a fixed width by deriving height = width / ratio; when that derived height exceeds
    // the `heightIn` cap on any width above ~462dp (i.e. virtually every tablet, in EITHER
    // orientation, not just a short landscape viewport) none of its four solve attempts (max-width,
    // max-height, min-width, min-height) satisfy both the fixed width AND the capped height
    // simultaneously, so it silently falls back to `IntSize(constraints.minWidth, constraints.minHeight)`
    // -- a width-only, ZERO-HEIGHT box. The LazyColumn item collapses to 0dp, so `ActionsCluster` and
    // the synopsis start rendering at the very top of the screen while the hero's own (unclipped, per
    // Compose's no-implicit-clip default) title/backdrop content still draws at its natural size --
    // the visual overlap. Computing the height ourselves from the ACTUAL measured width sidesteps the
    // solver entirely: it is always well-defined, always <= the 260dp cap, and the content column
    // below can never start before the hero's real bottom edge, at any width or orientation.
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(heroHeight(maxWidth)),
        ) {
            val backdropUrl = m.background ?: m.poster
            if (backdropUrl.isNullOrBlank()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Brush.verticalGradient(listOf(colors.surface2, colors.canvas))),
                )
            } else {
                AsyncImage(
                    model = backdropUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            // Dual scrim: a vertical fade to the canvas color (blends the banner into the content
            // column) layered with a leading (bottom-left) radial-ish darkening so the title block
            // stays readable over bright artwork -- never a full-page wash (§7 anti-pattern), the
            // scrim only lives inside this fixed-height banner.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.55f to colors.canvas.copy(alpha = 0.35f),
                            1f to colors.canvas,
                        ),
                    ),
            )
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.horizontalGradient(
                            0f to Color.Black.copy(alpha = 0.55f),
                            0.6f to Color.Transparent,
                        ),
                    ),
            )
            Column(
                modifier = Modifier.align(Alignment.BottomStart).padding(VortXTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(text = m.name, style = VortXTheme.type.hero, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                MetaRow(m)
            }
        }
    }
}

/// The hero banner's height for a given measured [width]: the true 16:9-of-width height, clamped to
/// the S03 260dp cap -- computed directly instead of via `.heightIn(max = …).aspectRatio(…)`, whose
/// constraint solver cannot satisfy a FIXED width (`fillMaxWidth()`) together with a capped height
/// once the aspect-correct height would exceed that cap (see [Backdrop]'s doc comment for the full
/// root-cause trace). A plain arithmetic min() has no such failure mode at any width.
private fun heroHeight(width: Dp): Dp = minOf(width * 9f / 16f, 260.dp)

/// rating · year · runtime · genres, the same one-line metadata strip as tvOS `metaRow`.
@Composable
private fun MetaRow(m: MetaDetail) {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        m.imdbRating?.let { rating ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    VortXIcons.starFill,
                    contentDescription = null,
                    tint = VortXTheme.colors.accentBright,
                    modifier = Modifier.size(14.dp),
                )
                MetaText(rating)
            }
        }
        m.releaseInfo?.let { MetaText(it) }
        m.runtime?.let { MetaText(it) }
        if (m.genres.isNotEmpty()) {
            MetaText(m.genres.take(3).joinToString(" · "))
        }
    }
}

@Composable
private fun MetaText(text: String) {
    Text(text = text, style = VortXTheme.type.label.copy(color = Color.White.copy(alpha = 0.82f)))
}

/// The hero-actions cluster (DESIGN-SYSTEM.md §4 Detail): the ONE gold Watch/Resume [PrimaryButton] +
/// a Sources chip (toggles the raw per-add-on list below, unranked pending S06) + a Library chip
/// reflecting the engine's saved state. For a series the button label/target follows
/// [primaryEpisode] (Resume S1 E3 vs Play S1 E1); the movie-level watched toggle rides the same
/// checkmark affordance the episode rows use, exposed here as a small icon on the Library chip's row.
@Composable
private fun ActionsCluster(
    m: MetaDetail,
    primaryEpisode: Pair<Episode, Boolean>?,
    watchEnabled: Boolean,
    resolving: Boolean,
    sourcesOpen: Boolean,
    onWatch: () -> Unit,
    onToggleSources: () -> Unit,
    onToggleLibrary: () -> Unit,
    onToggleWatched: () -> Unit,
) {
    val watchLabel = when {
        resolving -> "Starting…"
        primaryEpisode != null -> {
            val (video, isResume) = primaryEpisode
            val prefix = if (isResume) "Resume" else "Play"
            val code = if (video.season > 0) "S${video.season} E${video.episode}" else "Episode ${video.episode}"
            "$prefix $code"
        }
        else -> "Watch"
    }
    val inLibrary = m.libraryItem?.savedToLibrary == true
    val isWatched = m.libraryItem?.isWatched == true

    Column(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        PrimaryButton(
            text = watchLabel,
            onClick = onWatch,
            enabled = watchEnabled,
            loading = resolving,
            leadingIcon = if (!resolving) VortXIcons.playFill else null,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Chip(
                label = if (inLibrary) "Saved" else "Save",
                selected = inLibrary,
                leadingIcon = if (inLibrary) VortXIcons.bookmarkFill else VortXIcons.bookmark,
                onClick = onToggleLibrary,
            )
            Chip(
                label = "Sources",
                selected = sourcesOpen,
                leadingIcon = VortXIcons.listBullet,
                onClick = onToggleSources,
            )
            // Movie-level watched toggle (a series marks watched per-episode/season via the
            // SeasonSelector's chips instead, since there's no single "the" episode here).
            if (m.videos.isEmpty()) {
                Chip(
                    label = if (isWatched) "Watched" else "Mark Watched",
                    selected = isWatched,
                    leadingIcon = VortXIcons.checkmarkCircle,
                    onClick = onToggleWatched,
                )
            }
        }
    }
}

/// Cast/Director/Writer credits (DESIGN-SYSTEM.md §4 Detail "credits"), read straight from the
/// engine's own categorized `links` (see [com.vortx.android.engine.EngineState.parseCredits]) --
/// no extra network call. Full cast headshots (the Apple TMDB-credits enrichment) are deferred; see
/// this session's report.
@Composable
private fun CreditsSection(m: MetaDetail) {
    Column(
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(text = "Credits", style = VortXTheme.type.sectionTitle)
        m.cast.takeIf { it.isNotEmpty() }?.let { CreditLine("Cast", it) }
        m.directors.takeIf { it.isNotEmpty() }?.let { CreditLine("Director", it) }
        m.writers.takeIf { it.isNotEmpty() }?.let { CreditLine("Writer", it) }
    }
}

@Composable
private fun CreditLine(role: String, names: List<String>) {
    Text(
        text = "$role: ${names.take(6).joinToString(", ")}",
        style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
    )
}

/// Season chips (DESIGN-SYSTEM.md §4 "season selector"): always rendered even for a single season, the
/// only home of the bulk mark-watched menu (long-press a chip, or the trailing "…" chip), mirroring
/// tvOS `CoreSeasonedEpisodes`'s season row.
@Composable
private fun SeasonSelector(
    detail: MetaDetail,
    selectedSeason: Int,
    onSelectSeason: (Int) -> Unit,
    onMarkSeasonWatched: (Int, Boolean) -> Unit,
    onMarkSeriesWatched: (Boolean) -> Unit,
) {
    val seasons = detail.videos.map { it.season }.distinct().sorted()
    var menuSeason by remember { mutableStateOf<Int?>(null) }
    val episodeCount = detail.videos.count { it.season == selectedSeason }

    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Column(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge)) {
            Text(text = "Episodes".uppercase(), style = VortXTheme.type.eyebrow)
            Text(
                text = "$episodeCount episode${if (episodeCount == 1) "" else "s"}",
                style = VortXTheme.type.sectionTitle,
            )
        }
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge),
        ) {
            items(seasons, key = { it }) { season ->
                Box {
                    Chip(
                        label = seasonLabel(season),
                        selected = season == selectedSeason,
                        onClick = { onSelectSeason(season) },
                        onLongClick = { menuSeason = season },
                    )
                    SeasonMenu(
                        expanded = menuSeason == season,
                        onDismiss = { menuSeason = null },
                        seasonLabel = seasonLabel(season),
                        onMarkSeasonWatched = { onMarkSeasonWatched(season, it) },
                        onMarkSeriesWatched = onMarkSeriesWatched,
                    )
                }
            }
            item {
                Box {
                    Chip(
                        label = "",
                        selected = false,
                        leadingIcon = VortXIcons.moreHoriz,
                        onClick = { menuSeason = MENU_ALL_SEASONS },
                    )
                    SeasonMenu(
                        expanded = menuSeason == MENU_ALL_SEASONS,
                        onDismiss = { menuSeason = null },
                        seasonLabel = seasonLabel(selectedSeason),
                        onMarkSeasonWatched = { onMarkSeasonWatched(selectedSeason, it) },
                        onMarkSeriesWatched = onMarkSeriesWatched,
                    )
                }
            }
        }
    }
}

/// Sentinel for the trailing "…" chip's own menu instance (distinct from any real season number).
private const val MENU_ALL_SEASONS = Int.MIN_VALUE

private fun seasonLabel(season: Int): String = if (season == 0) "Specials" else "Season $season"

/// The bulk mark-watched menu shared by a season chip's long-press and the trailing "…" chip
/// (DESIGN-SYSTEM.md §4 Detail "per-season and whole-series watched controls in a long-press menu on
/// season chips AND a visible … menu"). Four actions: this season watched/unwatched, whole series
/// watched/unwatched.
@Composable
private fun SeasonMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    seasonLabel: String,
    onMarkSeasonWatched: (Boolean) -> Unit,
    onMarkSeriesWatched: (Boolean) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Mark $seasonLabel watched") }, onClick = { onMarkSeasonWatched(true); onDismiss() })
        DropdownMenuItem(text = { Text("Mark $seasonLabel unwatched") }, onClick = { onMarkSeasonWatched(false); onDismiss() })
        DropdownMenuItem(text = { Text("Mark whole series watched") }, onClick = { onMarkSeriesWatched(true); onDismiss() })
        DropdownMenuItem(text = { Text("Mark whole series unwatched") }, onClick = { onMarkSeriesWatched(false); onDismiss() })
    }
}

/// [EpisodeRow]'s `thumb` slot for a real episode: a Coil [AsyncImage] of the video's thumbnail,
/// falling back to the default placeholder -- the same slot-fill pattern as [com.vortx.android.ui.components.PosterArt].
@Composable
private fun EpisodeThumb(episode: Episode) {
    if (episode.thumbnail.isNullOrBlank()) {
        DefaultEpisodeThumb()
    } else {
        AsyncImage(
            model = episode.thumbnail,
            contentDescription = episode.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

/// 0f..1f in-progress fraction for one episode, from the library item's saved position when it matches
/// this video (the same match rule as tvOS `episodeProgress`); null (no stripe) otherwise, including
/// for an already-watched episode (its dim + check communicate state, not a stripe).
private fun episodeProgress(episode: Episode, detail: MetaDetail): Float? {
    val lib = detail.libraryItem ?: return null
    if (episode.id in detail.watchedVideoIds) return null
    if (lib.videoId != episode.id) return null
    return lib.progress
}

/// The sources section: the raw per-add-on stream list the engine fans out (unranked -- S06 owns
/// tiering/quality collapse). Mirrors the tvOS `CoreStreamList` hierarchy at the "everything" level:
/// a header with the source count, then one [SourceRow] per stream. [resolving] dims the rows while a
/// resolve is in flight, and [failure] surfaces a resolve error inline.
@Composable
private fun SourcesSection(
    state: UiState<List<StreamGroup>>,
    resolving: Boolean,
    failure: String?,
    onPlay: (StreamSource) -> Unit,
) {
    Column(
        modifier = Modifier.padding(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        when (state) {
            is UiState.Loading -> Text("Finding sources…", style = VortXTheme.type.sectionTitle)
            is UiState.Error -> Text(state.message, style = VortXTheme.type.body)
            is UiState.Success -> {
                val total = state.data.sumOf { it.streams.size }
                Text(text = "Sources · $total", style = VortXTheme.type.sectionTitle)
                failure?.let {
                    Text(text = it, style = VortXTheme.type.body.copy(color = VortXTheme.colors.danger))
                }
                if (total == 0) {
                    Text("No sources yet -- your add-ons may still be answering.", style = VortXTheme.type.body)
                }
                // Groups + streams are already ranked best-first by CatalogRepository.streams(); here we
                // derive the quality label, flavour tags, and size from the source's own tags via the same
                // StreamRanking parse that scored them, so the picker shows a real "4K · HDR · Remux · 18 GB"
                // line the viewer can choose from.
                state.data.forEach { group ->
                    group.streams.forEach { source ->
                        SourceRow(
                            addon = source.addon,
                            title = source.title,
                            quality = StreamRanking.qualityLabel(source),
                            isTorrent = source.isTorrent,
                            flavorTags = StreamRanking.flavorTags(source),
                            size = StreamRanking.sizeText(source),
                            enabled = !resolving,
                            onClick = { onPlay(source) },
                        )
                    }
                }
            }
        }
    }
}
