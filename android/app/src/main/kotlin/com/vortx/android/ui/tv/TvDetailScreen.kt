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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.vortx.android.player.MpvEngineFactory
import com.vortx.android.player.PlayerEngineRouter
import com.vortx.android.player.PlayerLaunchChoice
import com.vortx.android.player.PlayerLaunchPolicy
import com.vortx.android.catalog.CollectionClient
import com.vortx.android.catalog.DiscoverRegion
import com.vortx.android.catalog.FinancialsClient
import com.vortx.android.catalog.SimilarClient
import com.vortx.android.catalog.WatchProvider
import com.vortx.android.catalog.WatchProvidersClient
import com.vortx.android.library.WatchlistStore
import com.vortx.android.person.CastMember
import com.vortx.android.person.PersonSeed
import com.vortx.android.person.TMDBPersonClient
import com.vortx.android.ratings.MdbListRatings
import com.vortx.android.ratings.VortXRatingsClient
import com.vortx.android.ui.UiState
import com.vortx.android.ui.prefs.HomeDiscoverPreferences
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
    onPlay: (Playable, MetaDetail, PlayerEngineRouter.Override) -> Unit,
    modifier: Modifier = Modifier,
    onOpenTitle: (MetaItem) -> Unit = {},
) {
    val metaState by viewModel.meta.collectAsStateWithLifecycle()
    val streamsState by viewModel.streams.collectAsStateWithLifecycle()
    val playback by viewModel.playback.collectAsStateWithLifecycle()
    val watchlisted by viewModel.watchlisted.collectAsStateWithLifecycle()
    val launchPlayerChoices = remember { PlayerLaunchPolicy.choices(MpvEngineFactory.isBundled) }
    var launchEnginePreference by remember {
        mutableStateOf(PlayerLaunchPolicy.defaultPreference(MpvEngineFactory.isBundled))
    }
    var pendingLaunchEnginePreference by remember { mutableStateOf(launchEnginePreference) }
    val beginPlayback: (() -> Unit) -> Unit = { action ->
        pendingLaunchEnginePreference = launchEnginePreference
        action()
    }

    BackHandler { onBack() }

    // A resolved source -> hand the Playable to the shell (which shows the player) and reset the ViewModel's
    // playback latch, mirroring the phone DetailScreen exactly.
    LaunchedEffect(playback, metaState) {
        val resolved = resolvedDetailPlayback(playback, metaState) ?: return@LaunchedEffect
        onPlay(resolved.playable, resolved.metadata, pendingLaunchEnginePreference)
        viewModel.clearPlayback()
    }

    val colors = VortXTheme.colors
    Box(modifier = modifier.fillMaxSize().background(colors.canvas)) {
        when (val meta = metaState) {
            is UiState.Loading -> TvDetailLoading(title)
            // Retry must retain this detail route. Sending the remote Back here used to discard the title
            // instead of retrying its failed metadata request.
            is UiState.Error -> TvError(meta.message, onRetry = viewModel::retryMeta)
            is UiState.Success -> TvDetailContent(
                viewModel = viewModel,
                detail = meta.data,
                streamsState = streamsState,
                playback = playback,
                watchlisted = watchlisted,
                launchPlayerChoices = launchPlayerChoices,
                launchEnginePreference = launchEnginePreference,
                onSelectLaunchEngine = { launchEnginePreference = it },
                beginPlayback = beginPlayback,
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
    launchPlayerChoices: List<PlayerLaunchChoice>,
    launchEnginePreference: PlayerEngineRouter.Override,
    onSelectLaunchEngine: (PlayerEngineRouter.Override) -> Unit,
    beginPlayback: (() -> Unit) -> Unit,
    onOpenTitle: (MetaItem) -> Unit,
) {
    val context = LocalContext.current
    val colors = VortXTheme.colors
    val playFocus = remember { FocusRequester() }
    val secondaryFocus = remember { FocusRequester() }
    val sourcesFocus = remember { FocusRequester() }
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

    // Source-list depth state, from the SAME [DetailViewModel] the phone drives: the remembered sort, the
    // effective pin, and the transient offline-download notice. The couch source list re-ranks / re-badges off
    // these exactly as the phone SourcesSection does; there is no second copy of any of it.
    val pinUi by viewModel.pinUi.collectAsStateWithLifecycle()
    val sourceSort by viewModel.sourceSort.collectAsStateWithLifecycle()
    val sourceAudioLanguageHint by viewModel.sourceAudioLanguageHint.collectAsStateWithLifecycle()
    val downloadNotice by viewModel.downloadNotice.collectAsStateWithLifecycle()

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

    // View-local detail-breadth enrichment off the SAME keyless, edge-signed phone clients the phone
    // [com.vortx.android.ui.screens.DetailScreen] fetches (held in the view, not the shared ViewModel, exactly
    // as the cast credits are): the VortX cross-provider ratings token strip ([VortXRatingsClient]), the
    // Where-to-Watch providers ([WatchProvidersClient]), and the More-Like-This rail ([SimilarClient]).
    // Fail-soft -- a non-`tt` id / live type / down edge leaves each null/empty and its rail is simply omitted.
    var vortxRatings by remember(detail.id) { mutableStateOf<MdbListRatings?>(null) }
    var similarItems by remember(detail.id) { mutableStateOf<List<MetaItem>>(emptyList()) }
    var watchProviders by remember(detail.id) { mutableStateOf<List<WatchProvider>>(emptyList()) }
    LaunchedEffect(detail.id, detail.type) {
        vortxRatings = null
        similarItems = emptyList()
        watchProviders = emptyList()
        if (detail.id.startsWith("tt")) {
            vortxRatings = VortXRatingsClient.ratings(detail.id, detail.type.id)
            similarItems = SimilarClient.similar(detail.id, detail.type)
            watchProviders =
                WatchProvidersClient.availability(detail.id, detail.type, DiscoverRegion.effective(context))
                    ?.providers.orEmpty()
        }
    }

    // DET financials + franchise/collection rails (MOVIES ONLY), off the SAME keyless phone clients the phone
    // [com.vortx.android.ui.screens.DetailScreen] uses. Financials is gated on the cross-device "Show budget &
    // box office" setting (`vortx.detail.showFinancials`); the collection rail always resolves. Fail-soft: a
    // non-`tt` id / series / down edge leaves each null and its line/rail is simply omitted. Mirrors Apple
    // `DetailView.swift`'s `loadFinancials` + `loadCollection`.
    val discoverPrefs = remember(context) { HomeDiscoverPreferences(context) }
    val showFinancials = discoverPrefs.showFinancials
    var financials by remember(detail.id) { mutableStateOf<FinancialsClient.Financials?>(null) }
    var movieCollection by remember(detail.id) { mutableStateOf<CollectionClient.MovieCollection?>(null) }
    LaunchedEffect(detail.id, detail.type, showFinancials) {
        financials = null
        movieCollection = null
        if (detail.id.startsWith("tt") && detail.type == MediaType.MOVIE) {
            if (showFinancials) financials = FinancialsClient.financials(detail.id, isSeries = false)
            movieCollection = CollectionClient.collection(detail.id, isSeries = false)
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
                        onClick = { beginPlayback { viewModel.playBest() } },
                        focusRequester = playFocus,
                    )
                    Spacer(Modifier.width(VortXTheme.spacing.sm))
                    // Sources is an explicit peer of Watch, not a distant right-pane discovery task.
                    // It parks the remote on the source pane's stable Re-find control, from which the
                    // ranked Watch Now row and filters are one deterministic D-pad step away.
                    TvFilterChip(
                        label = "Sources",
                        selected = false,
                        onClick = { runCatching { sourcesFocus.requestFocus() } },
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
                                onClick = { beginPlayback { viewModel.playTrailer() } },
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
                    item {
                        TvDetailPlayerChoiceChip(
                            choices = launchPlayerChoices,
                            selected = launchEnginePreference,
                            onSelect = onSelectLaunchEngine,
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

            // Focusable source-list DEPTH: add-on grouping, sort, per-add-on filter, a quality-tier picker,
            // pin-to-top, and Watch-Now prominence, all off the SAME [DetailViewModel] the phone drives.
            Column(modifier = Modifier.weight(0.48f).fillMaxHeight()) {
                // Header + the "Re-find" escape hatch (D-pad focusable): re-query the add-ons fresh so an
                // expired/dead source, or an exhausted ladder, is replaced. All logic lives in
                // [DetailViewModel.refreshSources]; this only calls it. Disabled visual is unnecessary here
                // because a re-find while resolving simply re-begins the fence the resolve rides.
                Row(
                    modifier = Modifier.fillMaxWidth().padding(bottom = VortXTheme.spacing.sm),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Sources",
                        style = VortXTheme.type.sectionTitle,
                    )
                    TvFilterChip(
                        label = "Re-find",
                        selected = false,
                        onClick = viewModel::refreshSources,
                        modifier = Modifier.focusRequester(sourcesFocus),
                    )
                }
                TvSourceList(
                    streamsState = streamsState,
                    best = viewModel.bestSource(),
                    resolving = playback is Playback.Resolving,
                    failure = (playback as? Playback.Failed)?.message,
                    downloadNotice = downloadNotice,
                    sort = sourceSort,
                    onSortChange = viewModel::setSourceSort,
                    audioLanguageHint = sourceAudioLanguageHint,
                    onAudioLanguageHintChange = viewModel::setSourceAudioLanguageHint,
                    pin = pinUi,
                    entryNoun = viewModel.pinEntryNoun,
                    onPlay = { source -> beginPlayback { viewModel.play(source) } },
                    onDownload = viewModel::download,
                    onPin = viewModel::pinSource,
                    onUnpin = viewModel::unpinSource,
                )
            }
        }
            }

            // VortX cross-provider critic scores (Rotten Tomatoes / Metacritic / TMDB) as a token strip just
            // beneath the hero band -- additive to the IMDb score already in the hero meta line, shown only
            // when the ratings service returned at least one.
            vortxRatings?.takeIf { it.hasAny }?.let { r ->
                TvRatingsStrip(
                    ratings = r,
                    modifier = Modifier.padding(horizontal = TvDimens.edge, vertical = VortXTheme.spacing.sm),
                )
            }

            // DET financials (MOVIES ONLY, gated on "Show budget & box office"): budget + box office + profit
            // as one compact fact line under the ratings, additive to the hero meta line. Mirrors the phone
            // `DetailFactLine`.
            financials?.let { FinancialsClient.financialsText(it) }?.let { text ->
                TvFinancialsLine(
                    text = text,
                    modifier = Modifier.padding(horizontal = TvDimens.edge, vertical = VortXTheme.spacing.xs),
                )
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

            // Where to Watch: legal region providers (TMDB, keyless edge). Gated off live content (no
            // providers) and an empty result, so it never leaves a blank band.
            if (watchProviders.isNotEmpty() && !tvIsLiveType(detail.type)) {
                TvWhereToWatchRail(
                    providers = watchProviders,
                    modifier = Modifier.padding(top = TvDimens.rowGap),
                )
            }

            // DET franchise/collection rail (MOVIES ONLY): the TMDB collection this movie belongs to, in
            // release order, rendered JUST ABOVE More Like This (Apple parity). Hidden for a single-part
            // collection. Each tile resolves its tmdb: id to a tt id before opening, the same fail-soft resolve
            // the More Like This rail uses.
            movieCollection?.takeIf { it.parts.size > 1 }?.let { collection ->
                TvCollectionRail(
                    collection = collection,
                    onOpen = { item ->
                        scope.launch {
                            val tt = TMDBPersonClient.imdbId(item.id, item.type)
                            onOpenTitle(if (tt != null) item.copy(id = tt) else item)
                        }
                    },
                    modifier = Modifier.padding(top = TvDimens.rowGap),
                )
            }

            // More Like This: TMDB recommendations as focusable poster tiles that open the title (resolving
            // the tile's tmdb: id to a tt id first, the same fail-soft resolve the phone SimilarRail uses).
            // Gated off live content and an empty result.
            if (similarItems.isNotEmpty() && !tvIsLiveType(detail.type)) {
                TvSimilarRail(
                    type = detail.type,
                    titles = similarItems,
                    onOpen = { item ->
                        scope.launch {
                            val tt = TMDBPersonClient.imdbId(item.id, item.type)
                            onOpenTitle(if (tt != null) item.copy(id = tt) else item)
                        }
                    },
                    modifier = Modifier.padding(top = TvDimens.rowGap, bottom = TvDimens.edge),
                )
            }
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

/** D-pad player picker. It is an additive secondary chip, so the established Trailer/Save focus target stays. */
@Composable
private fun TvDetailPlayerChoiceChip(
    choices: List<PlayerLaunchChoice>,
    selected: PlayerEngineRouter.Override,
    onSelect: (PlayerEngineRouter.Override) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val current = choices.firstOrNull { it.preference == selected } ?: choices.first()
    Box {
        TvFilterChip(
            label = "Player · ${current.label}",
            selected = selected != PlayerEngineRouter.Override.AUTO,
            stateDescription = "Selected player: ${current.label}. Applies to this launch only.",
            onClick = { menuOpen = true },
        )
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            choices.forEach { choice ->
                DropdownMenuItem(
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = if (choice.preference == selected) {
                                    "${choice.label} · Selected"
                                } else {
                                    choice.label
                                },
                                style = VortXTheme.type.label,
                            )
                            Text(
                                text = choice.detail,
                                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
                            )
                        }
                    },
                    onClick = {
                        onSelect(choice.preference)
                        menuOpen = false
                    },
                )
            }
        }
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
