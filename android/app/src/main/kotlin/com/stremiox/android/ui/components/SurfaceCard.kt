package com.stremiox.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import com.stremiox.android.ui.theme.VortXShapes
import com.stremiox.android.ui.theme.VortXTheme
import com.stremiox.android.ui.theme.vortxShadow

/// `surface1` fill, card radius, `rest` shadow (DESIGN-SYSTEM.md §3 "Surface card") — the one row/panel
/// container for the app. NEVER nest a [SurfaceCard] inside another (§7 anti-pattern "nested cards");
/// a row that needs internal grouping uses padding/dividers, not another card.
@Composable
fun SurfaceCard(
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .vortxShadow(VortXTheme.elevation.rest, VortXShapes.card)
            .clip(VortXShapes.card)
            .background(VortXTheme.colors.surface1, VortXShapes.card),
        content = content,
    )
}
