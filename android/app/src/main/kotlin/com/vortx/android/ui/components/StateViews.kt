package com.vortx.android.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.style.TextAlign
import com.vortx.android.ui.theme.VortXTheme

/// A calm shimmering placeholder fill — the loading-state building block (DESIGN-SYSTEM.md §3
/// "skeleton shimmer for loading, never a bare spinner as the whole state"). Sweeps a soft highlight
/// across the surface tone; reduced-motion collapses to a static mid-tone fill instead of animating.
fun Modifier.shimmer(): Modifier = composed {
    val colors = VortXTheme.colors
    val reduced = VortXTheme.reducedMotion
    if (reduced) {
        background(colors.surface2)
    } else {
        val transition = rememberInfiniteTransition(label = "shimmer")
        val translate by transition.animateFloat(
            initialValue = -1000f,
            targetValue = 1000f,
            animationSpec = infiniteRepeatable(tween(1400), RepeatMode.Restart),
            label = "shimmerTranslate",
        )
        background(
            Brush.linearGradient(
                colors = listOf(colors.surface2, colors.surface3, colors.surface2),
                start = Offset(translate, 0f),
                end = Offset(translate + 400f, 400f),
            ),
        )
    }
}

/// A composed surface-card guidance line + one [Chip] action (DESIGN-SYSTEM.md §3 "Empty/loading/
/// error: composed surface-card with a line of guidance + one chip action; no `window.alert`") — the
/// single shared shape for both the empty and error states below.
@Composable
private fun GuidanceCard(message: String, actionLabel: String?, onAction: (() -> Unit)?, modifier: Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        SurfaceCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(VortXTheme.spacing.lg),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = message,
                    style = VortXTheme.type.body,
                    textAlign = TextAlign.Center,
                )
                if (actionLabel != null && onAction != null) {
                    Chip(label = actionLabel, selected = false, onClick = onAction)
                }
            }
        }
    }
}

/// A user-facing, never-silent error card with one chip action ("Retry"). Real add-on/engine failures
/// land here unchanged.
@Composable
fun ErrorState(message: String, onRetry: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    GuidanceCard(message = message, actionLabel = if (onRetry != null) "Retry" else null, onAction = onRetry, modifier = modifier)
}

/// A calm empty (but successful) state, e.g. an empty Library or a search with no query yet.
/// [actionLabel]/[onAction] add the one allowed chip (e.g. "Browse Discover" from an empty Library).
@Composable
fun EmptyState(hint: String, modifier: Modifier = Modifier, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    GuidanceCard(message = hint, actionLabel = actionLabel, onAction = onAction, modifier = modifier)
}
