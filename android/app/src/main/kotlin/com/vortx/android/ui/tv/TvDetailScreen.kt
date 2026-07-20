package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.ui.UiState
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.Playback
import kotlinx.coroutines.delay

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
    onPlay: (Playable) -> Unit,
    modifier: Modifier = Modifier,
) {
    val metaState by viewModel.meta.collectAsStateWithLifecycle()
    val streamsState by viewModel.streams.collectAsStateWithLifecycle()
    val playback by viewModel.playback.collectAsStateWithLifecycle()

    BackHandler { onBack() }

    // A resolved source -> hand the Playable to the shell (which shows the player) and reset the ViewModel's
    // playback latch, mirroring the phone DetailScreen exactly.
    LaunchedEffect(playback) {
        (playback as? Playback.Ready)?.let {
            onPlay(it.playable)
            viewModel.clearPlayback()
        }
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
                onPlay = onPlay,
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
    onPlay: (Playable) -> Unit,
) {
    val colors = VortXTheme.colors
    val playFocus = remember { FocusRequester() }

    Box(modifier = Modifier.fillMaxSize()) {
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

                val hasSources = (streamsState as? UiState.Success)?.data?.any { it.streams.isNotEmpty() } == true
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
                    // Trailer: free 1080p from the user's own IP via the client resolver (worker fallback on a
                    // miss). Shown only when the meta carries a YouTube trailer id; plays through the shared
                    // player pipeline (the same [DetailViewModel] playback latch the Watch button uses).
                    if (detail.trailerYouTubeId != null) {
                        Spacer(Modifier.width(VortXTheme.spacing.md))
                        TvFilterChip(
                            label = "Trailer",
                            selected = false,
                            onClick = { viewModel.playTrailer() },
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

    // Seed focus on the Watch button once meta is up, so a fresh detail page lands on the primary action.
    LaunchedEffect(Unit) {
        delay(140)
        runCatching { playFocus.requestFocus() }
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
