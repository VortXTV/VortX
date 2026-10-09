package com.vortx.android.ui.components

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.vortxGlass

fun cinemaEpisodeStatus(watched: Boolean, progress: Float?): String = when {
    watched -> "Watched"
    progress != null && progress.isFinite() && progress > 0.01f -> "Resume · ${(progress.coerceIn(0f, 1f) * 100).toInt()}%"
    else -> "Unwatched"
}

/** Touch detail card: the real episode artwork and summary receive the full rail-card width. */
@Composable
@OptIn(ExperimentalFoundationApi::class)
fun CinemaEpisodeCard(
    code: String,
    title: String,
    overview: String?,
    airDate: String?,
    watched: Boolean,
    progress: Float?,
    runtime: String?,
    quality: String?,
    onClick: () -> Unit,
    onToggleWatched: () -> Unit,
    focusRequester: FocusRequester,
    modifier: Modifier = Modifier,
    thumb: @Composable () -> Unit,
) {
    val status = cinemaEpisodeStatus(watched, progress)
    Column(
        modifier = modifier.vortxGlass(VortXShapes.card, VortXGlass.cardFillAlpha, shadow = VortXGlass.Shadow.flat)
            .semantics { contentDescription = "$code, $title"; stateDescription = status }
            .focusRequester(focusRequester)
            .combinedClickable(onClick = onClick, onLongClick = onToggleWatched)
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(VortXShapes.card)) {
            Box(Modifier.fillMaxSize().alpha(if (watched) 0.55f else 1f)) { thumb() }
            if (watched) {
                Icon(VortXIcons.checkmarkCircle, "Watched", tint = VortXTheme.colors.accent,
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(24.dp))
            }
            progress?.takeIf { it.isFinite() && it > 0f }?.let { fraction ->
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(VortXTheme.colors.surface3)) {
                    Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxSize().background(VortXTheme.colors.accent))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(code, style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accent), modifier = Modifier.weight(1f))
            Text(status, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
        }
        Text(title, style = VortXTheme.type.cardTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
        listOfNotNull(airDate?.takeIf(String::isNotBlank), runtime?.takeIf(String::isNotBlank)?.let { "Typical · $it" }, quality?.takeIf(String::isNotBlank))
            .takeIf { it.isNotEmpty() }?.let {
                Text(it.joinToString(" · "), style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        overview?.takeIf(String::isNotBlank)?.let {
            Text(it, style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary), maxLines = 4, overflow = TextOverflow.Ellipsis)
        }
        Chip(label = if (watched) "Mark unwatched" else "Mark watched", selected = watched, onClick = onToggleWatched)
    }
}
