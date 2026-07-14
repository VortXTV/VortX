package com.vortx.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxShadow

/// The ONE gold CTA (DESIGN-SYSTEM.md §3 "Primary button"): accent fill, on-accent text, control
/// radius, an optional leading icon, `15dp/32dp` padding. A screen has exactly one of these live at a
/// time (§1 principle 2 "One primary action") — everything else is a [Chip]. Press = scale(.97);
/// disabled/[loading] drop to a muted surface2 fill with no shadow, per spec.
@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    leadingIcon: ImageVector? = null,
) {
    val colors = VortXTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val active = enabled && !loading
    val reduced = VortXTheme.reducedMotion
    val scale by animateFloatAsState(
        targetValue = if (pressed && active) VortXMotion.PRESS_SCALE else 1f,
        animationSpec = VortXMotion.stateAware(reduced),
        label = "primaryButtonScale",
    )
    val fill = if (active) colors.accent else colors.surface2
    val ink = if (active) colors.onAccent else colors.textTertiary

    Row(
        modifier = modifier
            .scale(scale)
            .clip(VortXShapes.control)
            .then(if (active) Modifier.vortxShadow(VortXTheme.elevation.glow(colors.accent, alpha = 0.30f), VortXShapes.control) else Modifier)
            .background(fill, VortXShapes.control)
            .clickable(
                enabled = enabled && !loading,
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = 32.dp, vertical = 15.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        if (loading) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), color = ink, strokeWidth = 2.dp)
        } else if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = ink, modifier = Modifier.size(20.dp))
        }
        Text(text = text, style = VortXTheme.type.label.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold, color = ink))
    }
}
