package com.stremiox.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.Playable
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
import com.stremiox.android.ui.UiState
import com.stremiox.android.ui.components.Badge
import com.stremiox.android.ui.components.ErrorState
import com.stremiox.android.ui.viewmodel.DetailViewModel
import com.stremiox.android.ui.viewmodel.Playback

/// Title detail, driven by [DetailViewModel]: a cinematic backdrop + the metadata row (rating · year
/// · runtime · genres), then the sources list grouped per add-on — the same information hierarchy the
/// tvOS DetailView leads with. The Watch button and the per-source rows resolve a source through the
/// repository and launch the player via [onPlay]; the resolve round-trip (streaming-server hand-off /
/// debrid unlock) is reflected as a Resolving state so the UI shows progress, not a freeze.
@OptIn(ExperimentalMaterial3Api::class)
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

    // When a source resolves, hand the Playable up to navigation and reset, so returning from the
    // player lands back on detail rather than immediately re-launching.
    LaunchedEffect(playback) {
        (playback as? Playback.Ready)?.let {
            onPlay(it.playable)
            viewModel.clearPlayback()
        }
    }

    val resolving = playback is Playback.Resolving

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        when (val m = metaState) {
            is UiState.Loading -> Box(modifier.fillMaxSize().padding(padding)) {
                Text(
                    "Loading…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
            is UiState.Error -> ErrorState(m.message, modifier = modifier.padding(padding))
            is UiState.Success -> LazyColumn(
                modifier = modifier.fillMaxSize().padding(padding),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { Backdrop(m.data) }
                item {
                    MetaBlock(
                        m = m.data,
                        watchEnabled = viewModel.bestSource() != null && !resolving,
                        onWatch = { viewModel.bestSource()?.let(viewModel::play) },
                    )
                }
                item {
                    SourcesSection(
                        state = streamsState,
                        resolving = resolving,
                        failure = (playback as? Playback.Failed)?.message,
                        onPlay = viewModel::play,
                    )
                }
            }
        }
    }
}

/// Cinematic 16:9 backdrop. With no engine artwork yet it is a brand gradient with the type kicker,
/// the load-time placeholder the real `background` image will sit on top of.
@Composable
private fun Backdrop(m: MetaDetail) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .background(
                Brush.verticalGradient(
                    listOf(
                        MaterialTheme.colorScheme.surfaceVariant,
                        MaterialTheme.colorScheme.background,
                    )
                )
            ),
    ) {
        Text(
            text = m.type.label.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.align(Alignment.BottomStart).padding(20.dp),
        )
    }
}

/// Title, the metadata row (rating · year · runtime · genres), the Watch button, and the synopsis —
/// the lower title band of the tvOS hero. Watch plays the best source; it is disabled until sources
/// have resolved (and while a resolve is in flight).
@Composable
private fun MetaBlock(m: MetaDetail, watchEnabled: Boolean, onWatch: () -> Unit) {
    Column(
        modifier = Modifier.padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = m.name,
            style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onBackground,
        )
        MetaRow(m)
        Button(onClick = onWatch, enabled = watchEnabled, modifier = Modifier.padding(top = 8.dp)) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null)
            Text("  Watch", style = MaterialTheme.typography.labelLarge)
        }
        m.description?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/// rating · year · runtime · genres, the same one-line metadata strip as tvOS `metaRow`.
@Composable
private fun MetaRow(m: MetaDetail) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        m.imdbRating?.let { rating ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.Star,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
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
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/// The sources section: the per-add-on, multi-quality source list the engine fans out. Mirrors the
/// tvOS `CoreStreamList` hierarchy — a header with the source count, then one labeled block per
/// add-on, each row carrying the add-on name, a quality/torrent badge, and the add-on's own title.
/// Tapping a row resolves it through the engine and launches the player; [resolving] dims the rows
/// while a resolve is in flight, and [failure] surfaces a resolve error inline.
@Composable
private fun SourcesSection(
    state: UiState<List<StreamGroup>>,
    resolving: Boolean,
    failure: String?,
    onPlay: (StreamSource) -> Unit,
) {
    Column(
        modifier = Modifier.padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        when (state) {
            is UiState.Loading -> Text(
                "Finding sources…",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            is UiState.Error -> Text(
                state.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            is UiState.Success -> {
                val total = state.data.sumOf { it.streams.size }
                Text(
                    text = "Sources · $total",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                )
                Text(
                    text = if (resolving) "Starting source…" else "Tap a source to play.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                failure?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                state.data.forEach { group ->
                    group.streams.forEach { source ->
                        SourceRow(source = source, enabled = !resolving, onPlay = { onPlay(source) })
                    }
                }
            }
        }
    }
}

/// One source row: a leading state icon (download for torrents, play otherwise), the add-on +
/// quality/torrent badges, and the add-on's human-written title/description. Tapping resolves the
/// source and launches the player; disabled while another resolve is in flight.
@Composable
private fun SourceRow(source: StreamSource, enabled: Boolean, onPlay: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .clickable(enabled = enabled, onClick = onPlay)
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            imageVector = if (source.isTorrent) Icons.Filled.Download else Icons.Filled.PlayCircle,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Badge(source.addon)
                source.quality?.let { Badge(it) }
                if (source.isTorrent) Badge("Torrent")
            }
            Text(
                text = source.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
            )
            source.description?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
