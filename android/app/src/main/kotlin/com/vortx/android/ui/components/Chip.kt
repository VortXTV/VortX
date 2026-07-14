package com.vortx.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// The single secondary control for the whole app (DESIGN-SYSTEM.md §3 "Chip"): Quality, Sources,
/// Trailer, Save, Share, season, filters, type switch, nav links all render through this ONE
/// component, so "selected" never means two different things on two different screens.
/// - idle: surface2 fill, secondary text.
/// - [selected]: accentSoft fill + accentBright text + inset 1px accent ring.
/// [accent]/[accentText] let a destructive chip (e.g. "Remove") override the ring/text color while
/// keeping the same shape and fill logic — still never a second visual language.
///
/// [onLongClick] (S05 addition, opt-in/additive: null preserves every existing call site unchanged) is
/// the discoverable-by-long-press bulk menu on a season chip (mark season/series watched/unwatched),
/// mirroring the tvOS season chip's `.contextMenu`.
@Composable
fun Chip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    leadingIcon: ImageVector? = null,
    accent: Color = VortXTheme.colors.accent,
    accentText: Color = VortXTheme.colors.accentBright,
    onLongClick: (() -> Unit)? = null,
) {
    val colors = VortXTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val reduced = VortXTheme.reducedMotion
    val scale by animateFloatAsState(
        targetValue = if (pressed && enabled) VortXMotion.PRESS_SCALE else 1f,
        animationSpec = VortXMotion.stateAware(reduced),
        label = "chipScale",
    )
    val fill = when {
        selected -> accent.copy(alpha = 0.18f)
        else -> colors.surface2
    }
    val textColor = when {
        selected -> accentText
        !enabled -> colors.textTertiary
        else -> colors.textSecondary
    }

    Row(
        modifier = modifier
            .scale(scale)
            .clip(VortXShapes.chip)
            .background(fill, VortXShapes.chip)
            .then(
                if (selected) Modifier.border(BorderStroke(1.dp, accent), VortXShapes.chip) else Modifier,
            )
            .then(
                if (onLongClick != null) {
                    Modifier.combinedClickable(
                        enabled = enabled,
                        interactionSource = interactionSource,
                        indication = null,
                        role = Role.Button,
                        onLongClick = onLongClick,
                        onClick = onClick,
                    )
                } else {
                    Modifier.clickable(
                        enabled = enabled,
                        interactionSource = interactionSource,
                        indication = null,
                        role = Role.Button,
                        onClick = onClick,
                    )
                },
            )
            .semantics { this.selected = selected }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = textColor, modifier = Modifier.size(16.dp))
        }
        Text(text = label, style = VortXTheme.type.label.copy(color = textColor))
    }
}
