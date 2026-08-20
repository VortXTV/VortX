package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.library.WatchlistStore
import com.vortx.android.person.CastMember
import com.vortx.android.person.PersonSeed
import com.vortx.android.person.TMDBPersonClient
import com.vortx.android.ui.UiState
import com.vortx.android.ui.screens.launchDetailShare
import com.vortx.android.ui.screens.resolvedDetailPlayback
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.Playback
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal enum class TvDetailFocusTarget {
    WATCH,
    SECONDARY_ACTION,
}

/** One initial request, plus one Watch retry if the loading-state request could not land. */
internal class TvDetailInitialFocus {
    private var settled = false
    private var secondaryAttempted = false
    private var watchAttempted = false

    fun next(watchEnabled: Boolean): TvDetailFocusTarget? = when {
        settled -> null
        watchEnabled && !watchAttempted -> {
            watchAttempted = true
            TvDetailFocusTarget.WATCH
        }
        !watchEnabled && !secondaryAttempted -> {
            secondaryAttempted = true
            TvDetailFocusTarget.SECONDARY_ACTION
        }
        else -> null
    }

    fun record(requestSucceeded: Boolean) {
        if (requestSucceeded) settled = true
    }
}

/// The TV title page, driven by the SAME [DetailViewModel] as the phone [com.vortx.android.ui.screens.DetailScreen]
/// (constructed once in [TvApp] via the shared factory). It renders a 10-foot two-pane layout -- a
/// cinematic backdrop with the title/meta/synopsis + a Watch CTA on the left, a focusable source list on
/// the right -- but every action routes back through the same ViewModel: [DetailViewModel.playBest] for the
/// hero Watch, [DetailViewModel.play] for a chosen source, and the [DetailViewModel.playback] state machine
/// for the resolve. When a source resolves to a [Playable] it is handed up via [onPlay], exactly as the
/// phone screen does (DetailScreen's `LaunchedEffect(playback)` -> `onPlay` + `clearPlayback`).
///
/// Because the source list comes from [DetailViewModel], the active profile's Kids content guard applies on
/// TV with no extra code -- it is enforced inside the ViewModel's source-ranking context, not in the UI.
///
/// Slice scope: this shows meta + a flat ranked source list + Play. The phone screen's season/episode
/// browser, the per-source long-press pin menu, watched-state toggles, and cast/credits are NOT reproduced
/// here yet (see the session report's gap list). For a series the ViewModel still auto-targets the
/// resume/first-unwatched episode, so Watch plays the right thing.
@Composable
fun TvDetailScreen(
    viewModel: DetailViewModel,
    title: String,
    onBack: () -> Unit,
    onPlay: (Playable, MetaDetail) -> Unit,
    modifier: Modifier = Modifier,
    onOpenTitle: (MetaItem) -> Unit = {},
) {
    val metaState by viewModel.meta.collectAsStateWithLifecycle()
    val streamsState by viewModel.streams.collectAsStateWithLifecycle()
    val playback by viewModel.playback.collectAsStateWithLifecycle()
    val watchlisted by viewModel.watchlisted.collectAsStateWithLifecycle()

    BackHandler { onBack() }

    // A resolved source -> hand the Playable to the shell (which shows the player) and reset the ViewModel's
    // playback latch, mirroring the phone DetailScreen exactly.
    LaunchedEffect(playback, metaState) {
        val resolved = resolvedDetailPlayback(playback, metaState) ?: return@LaunchedEffect
        onPlay(resolved.playable, resolved.metadata)
        viewModel.clearPlayback()
    }

    val colors = VortXTheme.colors
    Box(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        when (val meta = metaState) {
            is UiState.Loading -> TvDetailLoading(title)
            is UiState.Error -> TvError(meta.message, onRetry = onBack)
            is UiState.Success -> TvDetailContent(
                viewModel = viewModel,
                detail = meta.data,
                streamsState = streamsState,
                playback = playback,
                watchlisted = watchlisted,
                onOpenTitle = onOpenTitle,
            )
        }
    }
}

@Composable
private fun TvDetailContent(
    viewModel: DetailViewModel,
    detail: MetaDetail,
    streamsState: UiState<List<com.vortx.android.model.StreamGroup>>,
    playback: Playback,
    watchlisted: Boolean,
    onOpenTitle: (MetaItem) -> Unit,
) {
    val context = LocalContext.current
    val colors = VortXTheme.colors
    val playFocus = remember { FocusRequester() }
    val secondaryFocus = remember { FocusRequester() }
    val initialFocus = remember(detail.id) { TvDetailInitialFocus() }
    val hasSources = (streamsState as? UiState.Success)?.data?.any { it.streams.isNotEmpty() } == true
    val watchEnabled = hasSources && playback !is Playback.Resolving
    val hasTrailer = detail.trailerYouTubeId != null
    val trailerModifier = if (hasTrailer) Modifier.focusRequester(secondaryFocus) else Modifier
    val saveModifier = if (hasTrailer) Modifier else Modifier.focusRequester(secondaryFocus)

    // Selected season/episode come from the SAME [DetailViewModel] the phone drives, so choosing a season or
    // episode below retargets the hero Watch/Resume + the source list, exactly as the phone screen does.
    val selectedSeason by viewModel.selectedSeason.collectAsStateWithLifecycle()
    val selectedEpisodeId by viewModel.selectedEpisodeId.collectAsStateWithLifecycle()

    // View-local Person overlay + TMDB cast enrichment, mirroring the phone [DetailScreen] (held in the view,
    // not the shared ViewModel -- the credits fetch is view-local on iOS/tvOS too). Credits come from VortX's
    // keyless, signed catalog edge, keyed off the meta's imdb id and reset per title.
    var personTarget by remember(detail.id) { mutableStateOf<PersonSeed?>(null) }
    var castMembers by remember(detail.id) { mutableStateOf<List<CastMember>>(emptyList()) }
    LaunchedEffect(detail.id, detail.type) {
        castMembers = emptyList()
        if (detail.id.startsWith("tt")) {
            castMembers = TMDBPersonClient.credits(detail.id, detail.type)
        }
    }

    val scrollState = rememberScrollState()
    val scope = rememberCoroutineScope()

    // A tapped cast tile takes over the whole detail body with the Person page, mirroring the phone overlay.
    val openPerson = personTarget
    if (openPerson != null) {
        TvPersonOverlay(
            seed = openPerson,
            onOpenTitle = { onOpenTitle(it); personTarget = null },
            onBack = { personTarget = null },
        )
        return
    }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val bandHeight = maxHeight
        Column(modifier = Modifier.fillMaxSize().verticalScroll(scrollState)) {
            // The cinematic hero band fills the first screen; episodes + cast scroll up from beneath it.
            Box(modifier = Modifier.fillMaxWidth().height(bandHeight)) {
        TvBackdrop(
            url = detail.background ?: detail.poster,
            seed = detail.id,
            modifier = Modifier.fillMaxSize(),
        )
        // Left-to-right + bottom scrims so the left-pane text and the right-pane list both stay legible over
        // the artwork.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.horizontalGradient(0f to colors.canvas, 0.85f to colors.canvas.copy(alpha = 0.35f))),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(0.4f to Color.Transparent, 1f to colors.canvas)),
        )

        Row(
            modifier = Modifier.fillMaxSize().padding(TvDimens.edge),
            verticalAlignment = Alignment.Bottom,
        ) {
            // Hero content + Watch CTA.
            Column(modifier = Modifier.weight(0.52f)) {
                Text(text = detail.type.label.uppercase(), style = VortXTheme.type.eyebrow)
                Text(
                    text = detail.name,
                    style = VortXTheme.type.hero,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.xs),
                )
                val metaLine = listOfNotNull(
                    detail.releaseInfo,
                    detail.imdbRating?.let { "★ $it" },
                    detail.runtime,
                    detail.genres.firstOrNull(),
                ).joinToString("   ·   ")
                if (metaLine.isNotBlank()) {
                    Text(
                        text = metaLine,
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                    )
                }
                detail.description?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        text = it,
                        style = VortXTheme.type.body.copy(color = colors.textSecondary),
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = VortXTheme.spacing.md).fillMaxWidth(0.95f),
                    )
                }

                Spacer(Modifier.height(TvDimens.rowGap))

                val resolving = playback is Playback.Resolving
                val isResume = ((detail.libraryItem?.timeOffsetMs) ?: 0L) > 0L
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TvPlayButton(
                        label = if (resolving) "Starting…" else if (isResume) "Resume" else "Watch",
                        enabled = hasSources && !resolving,
                        onClick = { viewModel.playBest() },
                        focusRequester = playFocus,
                    )
                    if (resolving) {
                        Spacer(Modifier.width(VortXTheme.spacing.md))
                        CircularProgressIndicator(
                            color = colors.accent,
                            modifier = Modifier.height(28.dp).width(28.dp),
                        )
                    }
                }

                // Keep the primary Watch CTA in its own fixed row. Secondary actions can outgrow the
                // standard 52% TV pane, so they live in a focus-aware LazyRow that D-pad scrolls instead
                // of clipping the trailing Save/Watchlist actions off-screen.
                Spacer(Modifier.height(VortXTheme.spacing.sm))
                LazyRow(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    // Trailer: free 1080p from the user's own IP via the client resolver (worker fallback on a
                    // miss). Shown only when the meta carries a YouTube trailer id; plays through the shared
                    // player pipeline (the same [DetailViewModel] playback latch the Watch button uses).
                    if (hasTrailer) {
                        item {
                            TvFilterChip(
                                label = "Trailer",
                                selected = false,
                                onClick = { viewModel.playTrailer() },
                                modifier = trailerModifier,
                            )
                        }
                    }
                    item {
                        TvFilterChip(
                            label = if (detail.libraryItem?.savedToLibrary == true) "Saved" else "Save",
                            selected = detail.libraryItem?.savedToLibrary == true,
                            onClick = viewModel::toggleLibrary,
                            modifier = saveModifier,
                        )
                    }
                    if (WatchlistStore.isSafeId(detail.id)) {
                        item {
                            TvFilterChip(
                                label = if (watchlisted) "In Watchlist" else "Watchlist",
                                selected = watchlisted,
                                onClick = viewModel::toggleWatchlist,
                            )
                        }
                    }
                    // DET-10: share the title's IMDb page (or its name when there is no imdb id) via the
                    // platform share sheet; fail-soft when no activity can handle the intent.
                    item {
                        TvFilterChip(
                            label = "Share",
                            selected = false,
                            onClick = { launchDetailShare(context, detail.id, detail.name) },
                        )
                    }
                }
                (playback as? Playback.Failed)?.let {
                    Text(
                        text = it.message,
                        style = VortXTheme.type.label.copy(color = colors.danger),
                        modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                    )
                }
            }

            Spacer(Modifier.width(TvDimens.edge))

            // Focusable source list.
            Column(modifier = Modifier.weight(0.48f).fillMaxHeight()) {
                Text(
                    text = "Sources",
                    style = VortXTheme.type.sectionTitle,
                    modifier = Modifier.padding(bottom = VortXTheme.spacing.sm),
                )
                TvSourceList(streamsState = streamsState, onPlaySource = viewModel::play)
            }
        }
            }

            // A series gains a focusable season picker + episode rail beneath the hero. Choosing an episode
            // selects it (loading its sources up top) and scrolls back to the hero where Watch/Resume now
            // targets it; the per-episode + per-season watched toggles route through the ViewModel's
            // profile-aware history writes.
            if (detail.type == MediaType.SERIES && detail.videos.isNotEmpty()) {
                TvSeasonEpisodeSection(
                    detail = detail,
                    selectedSeason = selectedSeason,
                    selectedEpisodeId = selectedEpisodeId,
                    onSelectSeason = viewModel::selectSeason,
                    onSelectEpisode = { episodeId ->
                        viewModel.selectEpisode(episodeId)
                        scope.launch { scrollState.animateScrollTo(0) }
                    },
                    onToggleWatched = viewModel::setVideoWatched,
                    onMarkSeasonWatched = viewModel::setSeasonWatched,
                )
            }

            TvCastCreditsSection(
                detail = detail,
                castMembers = castMembers,
                onPersonTap = { personTarget = it },
            )
        }
    }

    // While sources settle, Save is the stable enabled target. If that request could not land, Watch
    // gets one retry when it becomes enabled. A successful secondary request is never displaced.
    LaunchedEffect(detail.id, watchEnabled) {
        delay(140)
        val target = initialFocus.next(watchEnabled) ?: return@LaunchedEffect
        val requestSucceeded = runCatching {
            when (target) {
                TvDetailFocusTarget.WATCH -> playFocus.requestFocus()
                TvDetailFocusTarget.SECONDARY_ACTION -> secondaryFocus.requestFocus()
            }
        }.getOrDefault(false)
        initialFocus.record(requestSucceeded)
    }
}

/// Loading state for the detail page: the title the browse wall already knew (so the page has an identity
/// the instant it opens) over the spinner, instead of a bare spinner while `meta_details` resolves.
@Composable
private fun TvDetailLoading(title: String) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier.fillMaxSize().padding(TvDimens.edge),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = title,
            style = VortXTheme.type.hero,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(TvDimens.rowGap))
        CircularProgressIndicator(color = colors.accent)
    }
}

@Composable
private fun TvSourceList(
    streamsState: UiState<List<com.vortx.android.model.StreamGroup>>,
    onPlaySource: (StreamSource) -> Unit,
) {
    when (val s = streamsState) {
        is UiState.Loading -> TvLoading()
        is UiState.Error -> Text(
            text = s.message,
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
        )
        is UiState.Success -> {
            // Flatten the per-add-on groups into one ranked list for the slice (the phone screen keeps the
            // grouped headers + sort/pin controls; those are a later parity item). Keyed by index+id so a
            // decorated/duplicate source id can never collide in the LazyColumn.
            val sources = s.data.flatMap { it.streams }
            if (sources.isEmpty()) {
                Text(
                    text = "No playable sources found for this title.",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    contentPadding = PaddingValues(bottom = TvDimens.edge),
                ) {
                    itemsIndexed(sources, key = { i, src -> "$i-${src.id}" }) { _, source ->
                        TvSourceRow(source = source, onClick = { onPlaySource(source) })
                    }
                }
            }
        }
    }
}
