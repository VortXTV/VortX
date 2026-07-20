package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import coil3.compose.AsyncImage
import com.vortx.android.VortXApplication
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.person.CastMember
import com.vortx.android.person.PersonSeed
import com.vortx.android.person.TMDBPersonClient
import com.vortx.android.ratings.MdbListRatings
import com.vortx.android.ratings.VortXRatingsClient
import com.vortx.android.sources.SourcePinScope
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.DefaultEpisodeThumb
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.EpisodeRow
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SourceRow
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.components.shimmer
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.theme.vortxGlassToast
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.PersonViewModel
import com.vortx.android.ui.viewmodel.Playback
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

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
    val downloadNotice by viewModel.downloadNotice.collectAsStateWithLifecycle()
    val pinUi by viewModel.pinUi.collectAsStateWithLifecycle()
    val sourceSort by viewModel.sourceSort.collectAsStateWithLifecycle()

    // The download status line is a transient confirmation, not a persistent state: show it for a beat then
    // clear it (the live queue/progress lives on the Downloads screen). Keyed on the notice text so each new
    // message restarts the timer; a null notice cancels cleanly.
    LaunchedEffect(downloadNotice) {
        if (downloadNotice != null) {
            kotlinx.coroutines.delay(4_000)
            viewModel.clearDownloadNotice()
        }
    }

    // Detail-local navigation for the cast/person feature, kept OUT of StremioXApp's own nav graph and
    // out of DetailViewModel (the media-servers wave owns those): a tapped cast tile opens the Person
    // page ([personTarget]); a Person-page filmography tile opens that title's own detail ([titleTarget]).
    // Both are plain overlay state on this screen, so no top-level route is added and neither wave collides.
    var personTarget by remember { mutableStateOf<PersonSeed?>(null) }
    var titleTarget by remember { mutableStateOf<MetaItem?>(null) }

    // Nested title detail (opened from a Person page's filmography grid): a full DetailScreen for the
    // tapped title, built off the Application's shared repository so it reuses the exact detail flow
    // without threading a new callback through the app shell. System back closes it back to the Person page.
    titleTarget?.let { target ->
        val app = LocalContext.current.applicationContext as VortXApplication
        val nestedVm: DetailViewModel = viewModel(
            key = "detail-nested-${target.id}",
            factory = StremioXViewModelFactory(
                repo = app.catalogRepository,
                detailArgs = StremioXViewModelFactory.DetailArgs(target.type, target.id),
                appContext = app,
            ),
        )
        BackHandler { titleTarget = null }
        DetailScreen(
            viewModel = nestedVm,
            title = target.name,
            onBack = { titleTarget = null },
            onPlay = onPlay,
            modifier = modifier,
        )
        return
    }

    // Person page overlay (opened from a tappable cast tile below): shown in place of the detail body,
    // seeded for instant header paint. System back closes it back to this title.
    personTarget?.let { seed ->
        val personVm: PersonViewModel = viewModel(
            key = "person-${seed.id}",
            factory = PersonViewModel.Factory(seed.id),
        )
        BackHandler { personTarget = null }
        PersonScreen(
            viewModel = personVm,
            seed = seed,
            onBack = { personTarget = null },
            onOpenTitle = { titleTarget = it },
            modifier = modifier,
        )
        return
    }

    // View-local TMDB cast enrichment, mirroring the Apple detail views' `loadCredits` @State: fetch the
    // full cast (person ids + character + headshots) through VortX's keyless signed edge, keyed off the
    // meta's imdb id. Fail-soft -- an empty result (no tt id, or the edge is down) leaves the plain-name
    // cast fallback below. Held here (not in DetailViewModel) so the media-servers wave's ViewModel is
    // untouched, exactly as the credits fetch is view-local on iOS/tvOS.
    var castMembers by remember { mutableStateOf<List<CastMember>>(emptyList()) }
    val loadedMeta = metaState as? UiState.Success
    val castImdbId = loadedMeta?.data?.id
    val castType = loadedMeta?.data?.type
    LaunchedEffect(castImdbId, castType) {
        castMembers = emptyList()
        if (castImdbId != null && castImdbId.startsWith("tt") && castType != null) {
            castMembers = TMDBPersonClient.credits(castImdbId, castType)
        }
    }

    // View-local VortX ratings enrichment, mirroring the Apple detail views loading `VortXRatingsClient`:
    // the keyless, edge-signed ratings.vortx.tv service returns cross-provider critic scores (Rotten
    // Tomatoes / Metacritic / TMDB) the engine meta does not carry, keyed off the meta's imdb id. Fail-soft
    // -- a non-`tt` id, a title with no scores, or a down edge leaves this null and the ratings strip is
    // omitted. Held here (not in DetailViewModel) so the media-servers wave's ViewModel is untouched,
    // exactly as the cast credits fetch is view-local.
    var vortxRatings by remember { mutableStateOf<MdbListRatings?>(null) }
    LaunchedEffect(castImdbId, castType) {
        vortxRatings = null
        if (castImdbId != null && castImdbId.startsWith("tt") && castType != null) {
            vortxRatings = VortXRatingsClient.ratings(castImdbId, castType.id)
        }
    }

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
                        onWatch = { viewModel.playBest() },
                        onToggleSources = { sourcesOpen = !sourcesOpen },
                        onToggleLibrary = viewModel::toggleLibrary,
                        onToggleWatched = { viewModel.setWatched(!(m.data.libraryItem?.isWatched ?: false)) },
                        hasTrailer = m.data.trailerYouTubeId != null,
                        onTrailer = { viewModel.playTrailer() },
                    )
                }
                // VortX cross-provider critic scores under the hero actions (only when the ratings service
                // returned at least one), the additive detail ratings strip -- IMDb already shows in the
                // hero MetaRow, so this surfaces Rotten Tomatoes / Metacritic / TMDB.
                vortxRatings?.let { r ->
                    item {
                        RatingsRow(
                            ratings = r,
                            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
                        )
                    }
                }
                if (sourcesOpen) {
                    item {
                        SurfaceCard(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge)) {
                            SourcesSection(
                                state = streamsState,
                                resolving = resolving,
                                failure = (playback as? Playback.Failed)?.message,
                                downloadNotice = downloadNotice,
                                sort = sourceSort,
                                onSortChange = viewModel::setSourceSort,
                                pin = pinUi,
                                entryNoun = viewModel.pinEntryNoun,
                                onPin = viewModel::pinSource,
                                onUnpin = viewModel::unpinSource,
                                onPlay = viewModel::play,
                                onDownload = viewModel::download,
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
                if (m.data.cast.isNotEmpty() || castMembers.isNotEmpty() ||
                    m.data.directors.isNotEmpty() || m.data.writers.isNotEmpty()
                ) {
                    item {
                        CreditsSection(
                            m = m.data,
                            castMembers = castMembers,
                            onPersonTap = { personTarget = it },
                        )
                    }
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
                            onClick = {
                                // With Smart auto-pick on, the tap plays the best source straight away;
                                // opening the sources section under it is the escape hatch (backing out
                                // of the player reveals the full list, Apple's exact wording).
                                if (viewModel.autoPickEnabled) sourcesOpen = true
                                viewModel.selectEpisode(episode.id)
                            },
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
                    // Transient, non-blocking notice: the VortX glass toast (was a flat surface2 pill).
                    .vortxGlassToast(VortXShapes.chip)
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
            // The contextual Back chip floats over the backdrop as VortX glass (was a flat black scrim pill).
            // The chip is chrome, distinct from the backdrop art below it, which stays clean.
            .vortxGlass(
                shape = VortXShapes.chip,
                fillAlpha = VortXGlass.pillFillAlpha,
                shadow = VortXGlass.Shadow.pill,
            ),
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

/// The VortX cross-provider ratings strip: Rotten Tomatoes / Metacritic / TMDB critic scores from the
/// keyless [VortXRatingsClient], rendered as compact score badges. Shown only when at least one provider
/// returned a value (the caller already dropped a null / empty result). Mirrors the extra ratings the Apple
/// detail row renders from `MDBListRatings`; IMDb stays in the hero [MetaRow], so this shows the three
/// critic providers the engine meta does not carry.
@Composable
private fun RatingsRow(ratings: MdbListRatings, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ratings.rottenTomatoes?.let { RatingBadge("Rotten Tomatoes", "$it%") }
        ratings.metacritic?.let { RatingBadge("Metacritic", it.toString()) }
        ratings.tmdb?.let { RatingBadge("TMDB", "$it%") }
    }
}

/// One provider score badge: the emphasized value over its muted provider label.
@Composable
private fun RatingBadge(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = value,
            style = VortXTheme.type.label.copy(
                color = VortXTheme.colors.textPrimary,
                fontWeight = FontWeight.SemiBold,
            ),
        )
        Text(
            text = label,
            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.textTertiary),
        )
    }
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
    hasTrailer: Boolean,
    onTrailer: () -> Unit,
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
            // Trailer: free 1080p from the user's own IP via the client resolver (worker fallback on a miss).
            // Shown only when the meta carries a YouTube trailer id. Plays through the shared player pipeline.
            if (hasTrailer) {
                Chip(
                    label = "Trailer",
                    selected = false,
                    leadingIcon = VortXIcons.playRectangle,
                    onClick = onTrailer,
                )
            }
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

/// Cast & Crew (DESIGN-SYSTEM.md §4 Detail "credits"), ported from the Apple detail views' cast rail:
/// when TMDB credits resolved ([castMembers] non-empty), the cast shows as a horizontal rail of
/// headshot tiles that tap through to the Person page (real person id only); otherwise it falls back to
/// the engine's plain categorized-`links` cast names (no extra call, no headshots), exactly like the
/// Apple `railCastMembers` fallback. Director / Writer stay plain credit lines either way.
@Composable
private fun CreditsSection(
    m: MetaDetail,
    castMembers: List<CastMember>,
    onPersonTap: (PersonSeed) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = "Cast & Crew",
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
        )
        // TMDB rail (tappable headshots) when it resolved, else the meta's plain-name cast list.
        if (castMembers.isNotEmpty()) {
            CastRail(members = castMembers, onPersonTap = onPersonTap)
        } else {
            m.cast.takeIf { it.isNotEmpty() }?.let { CreditLine("Cast", it) }
        }
        m.directors.takeIf { it.isNotEmpty() }?.let { CreditLine("Director", it) }
        m.writers.takeIf { it.isNotEmpty() }?.let { CreditLine("Writer", it) }
    }
}

/// The horizontal full-cast rail: one [CastTile] per member, scrolling edge-to-edge (its own leading/
/// trailing inset rather than a padded parent) so tiles slide under the screen edge like the hub rails.
@Composable
private fun CastRail(members: List<CastMember>, onPersonTap: (PersonSeed) -> Unit) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge),
    ) {
        // No item key: TMDB cast ids are effectively unique here, but keying by a possibly-repeated id
        // risks the duplicate-key crash the grid screens guard against, and this list is static per title.
        items(members) { member ->
            CastTile(
                member = member,
                // Only a real TMDB person id opens the Person page; a name-only entry stays a plain tile.
                onTap = if (member.isTappable) {
                    { onPersonTap(PersonSeed(member.id, member.name, member.profileUrl)) }
                } else {
                    null
                },
            )
        }
    }
}

/// One cast entry: a circular headshot (initials-disc fallback), the actor name, and the character
/// beneath -- mirroring the Apple `castMemberTile`. Clickable only when [onTap] is non-null.
@Composable
private fun CastTile(member: CastMember, onTap: (() -> Unit)?) {
    Column(
        modifier = Modifier
            .width(84.dp)
            .then(if (onTap != null) Modifier.clickable(onClick = onTap) else Modifier),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(VortXTheme.colors.surface2),
            contentAlignment = Alignment.Center,
        ) {
            if (member.profileUrl.isNullOrBlank()) {
                Text(
                    text = castInitials(member.name),
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                )
            } else {
                AsyncImage(
                    model = member.profileUrl,
                    contentDescription = member.name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Text(
            text = member.name,
            style = VortXTheme.type.label,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        member.character?.let {
            Text(
                text = it,
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun castInitials(name: String): String =
    name.split(" ").filter { it.isNotBlank() }.take(2)
        .mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")

@Composable
private fun CreditLine(role: String, names: List<String>) {
    Text(
        text = "$role: ${names.take(6).joinToString(", ")}",
        style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
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

/// How the streams inside each add-on group are ordered, mirroring Apple `iOSSourceList.SourceSort`
/// exactly: Best leaves the engine ranking intact; Size and Seeders sort descending WITHIN each group
/// (so the add-on grouping survives), with unknown values sinking to the bottom (sizeForSort 0,
/// seedersForSort -1). Ids are the lowercase persistence keys `defaultSourceSort` stores.
private val sourceSortOptions: List<Pair<String, String>> = listOf(
    "best" to "Best",
    "size" to "Size",
    "seeders" to "Seeders",
)

/// The sources section: the assembled, ranked stream list. A header with the source count and the
/// Best/Size/Seeders sort chips (remembered via `defaultSourceSort`), then one [SourceRow] per stream.
/// [resolving] dims the rows while a resolve is in flight, and [failure] surfaces a resolve error inline.
/// Long-pressing a row opens the pin menu (pin for this show/movie, pin everywhere, unpin), Apple's
/// `.contextMenu { pinMenu(...) }`; the row whose stream the effective [pin] floats to the top wears a
/// "Pinned" badge, computed with the SAME [SourcePinStore.matches] the ranker bonus uses.
@Composable
private fun SourcesSection(
    state: UiState<List<StreamGroup>>,
    resolving: Boolean,
    failure: String?,
    downloadNotice: String?,
    sort: String,
    onSortChange: (String) -> Unit,
    pin: DetailViewModel.PinUi,
    entryNoun: String,
    onPin: (StreamSource, SourcePinScope) -> Unit,
    onUnpin: (SourcePinScope) -> Unit,
    onPlay: (StreamSource) -> Unit,
    onDownload: (StreamSource) -> Unit,
) {
    // The row whose long-press opened the pin menu (null = closed). Keyed by the stream id so the menu
    // anchors to its own row and a recompose from a pin write closes it cleanly.
    var pinMenuFor by remember { mutableStateOf<String?>(null) }
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
                if (total > 0) {
                    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                        sourceSortOptions.forEach { (key, label) ->
                            Chip(
                                label = label,
                                selected = key == sort,
                                onClick = { onSortChange(key) },
                            )
                        }
                    }
                }
                failure?.let {
                    Text(text = it, style = VortXTheme.type.body.copy(color = VortXTheme.colors.danger))
                }
                // The offline-download status line (long-press a source -> Download): a transient confirmation
                // or the resolver's honest failure, in the accent tone so it reads as info, not error.
                downloadNotice?.let {
                    Text(text = it, style = VortXTheme.type.body.copy(color = VortXTheme.colors.accent))
                }
                if (total == 0) {
                    Text("No sources yet -- your add-ons may still be answering.", style = VortXTheme.type.body)
                }
                // Groups + streams are already ranked best-first by the assembly; here we derive the quality
                // label, flavour tags, and size from the source's own tags via the same StreamRanking parse
                // that scored them, so the picker shows a real "4K · HDR · Remux · 18 GB" line the viewer
                // can choose from. The sort chips reorder WITHIN each group only (Apple `sortedStreams`).
                state.data.forEach { group ->
                    val streams = when (sort) {
                        "size" -> group.streams.sortedByDescending { StreamRanking.sizeForSort(it) }
                        "seeders" -> group.streams.sortedByDescending { StreamRanking.seedersForSort(it) }
                        else -> group.streams
                    }
                    streams.forEach { source ->
                        val pinned = pin.resolved?.let { SourcePinStore.matches(source, group.addon, it) } == true
                        Box {
                            SourceRow(
                                addon = source.addon,
                                title = source.title,
                                quality = StreamRanking.qualityLabel(source),
                                isTorrent = source.isTorrent,
                                flavorTags = StreamRanking.flavorTags(source),
                                size = StreamRanking.sizeText(source),
                                enabled = !resolving,
                                pinned = pinned,
                                onClick = { onPlay(source) },
                                onLongClick = { pinMenuFor = source.id },
                            )
                            DropdownMenu(
                                expanded = pinMenuFor == source.id,
                                onDismissRequest = { pinMenuFor = null },
                            ) {
                                // The download create-path entry point (DownloadManager.CREATE_PATH_WIRED): save
                                // this source for offline viewing. First item because it is the reason the menu
                                // most often gets opened now.
                                DropdownMenuItem(
                                    text = { Text("Download for offline") },
                                    onClick = { pinMenuFor = null; onDownload(source) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Pin for this $entryNoun") },
                                    onClick = { pinMenuFor = null; onPin(source, SourcePinScope.ENTRY) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Pin everywhere") },
                                    onClick = { pinMenuFor = null; onPin(source, SourcePinScope.GLOBAL) },
                                )
                                if (pin.hasEntry) {
                                    DropdownMenuItem(
                                        text = { Text("Unpin this $entryNoun") },
                                        onClick = { pinMenuFor = null; onUnpin(SourcePinScope.ENTRY) },
                                    )
                                }
                                if (pin.hasGlobal) {
                                    DropdownMenuItem(
                                        text = { Text("Unpin everywhere") },
                                        onClick = { pinMenuFor = null; onUnpin(SourcePinScope.GLOBAL) },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
