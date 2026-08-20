package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.metadata.ArtworkPreferences
import com.vortx.android.ui.components.DefaultPosterArt
import com.vortx.android.ui.components.PosterCard
import com.vortx.android.ui.prefs.PosterStylePreferences
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/**
 * Poster Style settings screen (item 5): Width + Corner-radius presets + Landscape 16:9 + Hide-labels, with
 * a LIVE preview. Persists on Apple's exact `stremiox.catalog.*` keys via [PosterStylePreferences], so the
 * choices ride the shared cross-platform settings carriage. The preview renders real [PosterCard]s, which
 * read the same live preference StateFlow the catalog rails do, so every control updates the sample cards
 * (and the whole app) the instant it changes.
 */
@Composable
fun PosterStyleScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val style by PosterStylePreferences.state.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors

    // Artwork & ratings toggles (items 1/2/4), on Apple's exact `stremiox.xrdb/erdb/fanart.*` keys. These
    // read straight from the flat settings (PosterArtwork reads them fresh per call), so local state seeds
    // from the store and writes back through it; the catalog re-reads on the next paint.
    var xrdbOn by remember { mutableStateOf(ArtworkPreferences.bool(ArtworkPreferences.XRDB_ENABLED_KEY, true)) }
    var erdbOn by remember { mutableStateOf(ArtworkPreferences.bool(ArtworkPreferences.ERDB_ENABLED_KEY, false)) }
    var fanartOn by remember { mutableStateOf(ArtworkPreferences.bool(ArtworkPreferences.FANART_ENABLED_KEY, false)) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(
                horizontal = VortXTheme.spacing.edge,
                vertical = VortXTheme.spacing.md,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            androidx.compose.foundation.layout.Box(
                modifier = Modifier.clickable(onClick = onBack),
            ) {
                Icon(VortXIcons.back, contentDescription = "Back", tint = colors.textPrimary)
            }
            Text("Poster Style", style = VortXTheme.type.screenTitle)
        }

        // Live preview: real cards that read the same live prefs the rails do.
        Column(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text(
                "PREVIEW",
                style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                PREVIEW_SAMPLES.forEach { sample ->
                    PosterCard(
                        title = sample.first,
                        subtitle = sample.second,
                        onClick = {},
                        modifier = Modifier.width(style.width.compactWidth),
                        art = { DefaultPosterArt(sample.first) },
                    )
                }
            }
        }

        Column(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            SettingsSection(title = "Card width", footer = "Wider cards show fewer, larger posters per row.") {
                PickerRow(
                    label = "Width",
                    options = PosterStylePreferences.WidthPreset.entries.map { it.wire to it.label },
                    selectedId = style.width.wire,
                    onSelect = { PosterStylePreferences.setWidth(PosterStylePreferences.WidthPreset.fromWire(it)) },
                )
            }

            SettingsSection(title = "Corner radius", footer = null) {
                PickerRow(
                    label = "Corners",
                    options = PosterStylePreferences.RadiusPreset.entries.map { it.wire to it.label },
                    selectedId = style.radius.wire,
                    onSelect = { PosterStylePreferences.setRadius(PosterStylePreferences.RadiusPreset.fromWire(it)) },
                )
            }

            SettingsSection(title = "Layout", footer = "Landscape shows cinematic 16:9 cards instead of portrait posters.") {
                ToggleRow(
                    label = "Landscape cards",
                    detail = "Cinematic 16:9 catalog cards.",
                    checked = style.landscape,
                    onCheckedChange = { PosterStylePreferences.setLandscape(it) },
                )
                ToggleRow(
                    label = "Hide labels",
                    detail = "Drop the title under each poster.",
                    checked = style.hideLabels,
                    onCheckedChange = { PosterStylePreferences.setHideLabels(it) },
                )
            }

            SettingsSection(
                title = "Ratings & artwork",
                footer = "VortX bakes the rating onto posters with its own keyless service. ERDB adds baked " +
                    "posters, backdrops and logos. fanart.tv uses community clearlogos for the hero.",
            ) {
                ToggleRow(
                    label = "Show ratings on posters",
                    detail = "Bake the rating onto each poster (no key needed).",
                    checked = xrdbOn,
                    onCheckedChange = {
                        xrdbOn = it
                        ArtworkPreferences.setBool(ArtworkPreferences.XRDB_ENABLED_KEY, it)
                    },
                )
                ToggleRow(
                    label = "Use ERDB (baked posters + logos)",
                    detail = "Overrides the poster service; replaces posters, backdrops and logos.",
                    checked = erdbOn,
                    onCheckedChange = {
                        erdbOn = it
                        ArtworkPreferences.setBool(ArtworkPreferences.ERDB_ENABLED_KEY, it)
                    },
                )
                ToggleRow(
                    label = "Use fanart.tv logos",
                    detail = "Community clearlogos for the hero (uses your fanart.tv key).",
                    checked = fanartOn,
                    onCheckedChange = {
                        fanartOn = it
                        ArtworkPreferences.setBool(ArtworkPreferences.FANART_ENABLED_KEY, it)
                    },
                )
            }
        }
    }
}

/// A small set of sample cards for the live preview, so the presets read against a representative row.
private val PREVIEW_SAMPLES = listOf(
    "Aurora Drift" to "2024 · Movie",
    "The Long Quiet" to "2023 · Series",
    "Neon Harbor" to "2022 · Movie",
)
