package com.vortx.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.vortxGlass

/// The one row/panel container for the app: now the VortX glass card (warm translucent fill, lit top edge,
/// soft shadow) at card radius, replacing the old flat `surface1` fill. NEVER nest a [SurfaceCard] inside
/// another (§7 anti-pattern "nested cards"); a row that needs internal grouping uses padding/dividers, not
/// another card.
@Composable
fun SurfaceCard(
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .vortxGlass(
                shape = VortXShapes.card,
                fillAlpha = VortXGlass.cardFillAlpha,
                shadow = VortXGlass.Shadow.card,
            ),
        content = content,
    )
}
