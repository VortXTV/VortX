package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.home.HomeRail
import com.vortx.android.home.HomeCatalogLayout
import com.vortx.android.home.HomeRailPreferences
import com.vortx.android.home.HomeRailSurface
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvCustomizeHomeScreen(
    preferences: HomeRailPreferences,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val layout by preferences.state.collectAsStateWithLifecycle()
    val rails = remember(layout) { preferences.ordered(HomeRailSurface.TV) }

    LazyColumn(
        modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text("Customize Home", style = VortXTheme.type.screenTitle)
                Text(
                    "Move or hide Home rows. Continue Watching always stays first.",
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
                Text("Catalog layout", style = VortXTheme.type.cardTitle)
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    TvHomeEditorAction(
                        label = "Rails",
                        enabled = true,
                        selected = layout.catalogLayout == HomeCatalogLayout.RAILS,
                        onClick = { preferences.setCatalogLayout(HomeCatalogLayout.RAILS) },
                    )
                    TvHomeEditorAction(
                        label = "Poster wall",
                        enabled = true,
                        selected = layout.catalogLayout == HomeCatalogLayout.WALL,
                        onClick = { preferences.setCatalogLayout(HomeCatalogLayout.WALL) },
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    TvHomeEditorAction("Done", enabled = true, onClick = onBack)
                    TvHomeEditorAction("Reset to default", enabled = true, onClick = preferences::reset)
                }
            }
        }
        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Continue Watching", style = VortXTheme.type.cardTitle, modifier = Modifier.weight(1f))
                Text(
                    "Always first",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        itemsIndexed(rails, key = { _, rail -> rail.key }) { index, rail ->
            val shown = rail !in layout.hidden
            Row(
                modifier = Modifier.fillMaxWidth().focusGroup().padding(vertical = VortXTheme.spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                Text("${index + 1}", style = VortXTheme.type.label, modifier = Modifier.width(36.dp))
                Text(
                    rail.title,
                    style = VortXTheme.type.cardTitle.copy(
                        color = if (shown) VortXTheme.colors.textPrimary else VortXTheme.colors.textTertiary,
                    ),
                    modifier = Modifier.weight(1f),
                )
                TvHomeEditorAction(
                    label = if (shown) "Shown" else "Hidden",
                    enabled = true,
                    onClick = { preferences.setHidden(rail, hidden = shown) },
                )
                TvHomeEditorAction(
                    label = "Up",
                    enabled = index > 0,
                    onClick = { preferences.move(rail, -1, HomeRailSurface.TV) },
                )
                TvHomeEditorAction(
                    label = "Down",
                    enabled = index < rails.lastIndex,
                    onClick = { preferences.move(rail, 1, HomeRailSurface.TV) },
                )
            }
        }
        item { Spacer(Modifier.width(1.dp)) }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvHomeEditorAction(
    label: String,
    enabled: Boolean,
    selected: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) colors.accent else colors.surface1,
            contentColor = if (selected) colors.onAccent else colors.textPrimary,
            focusedContainerColor = if (selected) colors.accentBright else colors.surface3,
            focusedContentColor = if (selected) colors.onAccent else colors.textPrimary,
            disabledContainerColor = colors.surface1,
            disabledContentColor = colors.textTertiary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Text(label, style = VortXTheme.type.label, modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp))
    }
}
