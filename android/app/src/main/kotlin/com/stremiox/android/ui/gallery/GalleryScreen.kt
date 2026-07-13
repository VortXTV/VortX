package com.stremiox.android.ui.gallery

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.stremiox.android.ui.components.Chip
import com.stremiox.android.ui.components.EmptyState
import com.stremiox.android.ui.components.EpisodeRow
import com.stremiox.android.ui.components.ErrorState
import com.stremiox.android.ui.components.PosterCard
import com.stremiox.android.ui.components.PrimaryButton
import com.stremiox.android.ui.components.SourceRow
import com.stremiox.android.ui.components.SurfaceCard
import com.stremiox.android.ui.components.Wordmark
import com.stremiox.android.ui.components.shimmer
import com.stremiox.android.ui.theme.VortXAccents
import com.stremiox.android.ui.theme.VortXIcons
import com.stremiox.android.ui.theme.VortXShapes
import com.stremiox.android.ui.theme.VortXTheme

/// Debug-only design-system gallery (ANDROID-PLAN.md S02 scope): every [com.stremiox.android.ui.components]
/// component in every state, plus token swatches and the type scale, for visual review against
/// `docs/screenshots/*.png`. Reachable from Settings → "Design gallery" (debug builds only, gated by
/// `BuildConfig.DEBUG` at the call site in OtherScreens.kt) rather than a separate launcher activity —
/// simplest wiring, no extra manifest entry, and it composes inside the existing nav stack so `onBack`
/// is a normal back-stack pop. The accent switcher here wraps its OWN [VortXTheme] instance (local
/// state, not persisted) so every accent + OLED + Material You can be eyeballed without touching the
/// app-wide theme choice, which is S09's (profiles/settings persistence) scope, not this session's.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GalleryScreen(onBack: () -> Unit) {
    var accentId by remember { mutableStateOf(VortXAccents.default.id) }
    var oled by remember { mutableStateOf(false) }
    var materialYou by remember { mutableStateOf(false) }

    VortXTheme(accentId = accentId, oled = oled, materialYou = materialYou) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Design gallery") },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(VortXIcons.back, contentDescription = "Back")
                        }
                    },
                )
            },
        ) { padding ->
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(bottom = VortXTheme.spacing.xxl),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
            ) {
                item { AccentSwitcher(accentId, { accentId = it }, oled, { oled = it }, materialYou, { materialYou = it }) }
                item { Section("Wordmark") { Wordmark() } }
                item { Section("Type scale") { TypeScaleSpecimen() } }
                item { Section("Token swatches") { SwatchGrid() } }
                item { Section("Primary button") { PrimaryButtonStates() } }
                item { Section("Chips") { ChipStates() } }
                item { Section("Surface card") { SurfaceCardSample() } }
                item { Section("Poster card") { PosterCardStates() } }
                item { Section("Source row") { SourceRowStates() } }
                item { Section("Episode row") { EpisodeRowStates() } }
                item { Section("Loading (skeleton)") { LoadingSample() } }
                item { Section("Empty state") { EmptyState("Titles you save appear here.", actionLabel = "Browse Discover") {} } }
                item { Section("Error state") { ErrorState("Couldn't reach your add-ons.", onRetry = {}) } }
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(text = title, style = VortXTheme.type.sectionTitle)
        content()
    }
}

@Composable
private fun AccentSwitcher(
    accentId: String,
    onAccent: (String) -> Unit,
    oled: Boolean,
    onOled: (Boolean) -> Unit,
    materialYou: Boolean,
    onMaterialYou: (Boolean) -> Unit,
) {
    Column(modifier = Modifier.padding(horizontal = VortXTheme.spacing.edge), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(text = "Theme", style = VortXTheme.type.sectionTitle)
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            VortXAccents.curated.forEach { accent ->
                Chip(
                    label = accent.label,
                    selected = !materialYou && accentId == accent.id,
                    onClick = { onMaterialYou(false); onAccent(accent.id) },
                    accent = accent.base,
                    accentText = accent.bright,
                )
            }
            Chip(label = "Material You", selected = materialYou, onClick = { onMaterialYou(true) })
            Chip(label = "OLED", selected = oled, onClick = { onOled(!oled) })
        }
    }
}

@Composable
private fun TypeScaleSpecimen() {
    val t = VortXTheme.type
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text("Hero title", style = t.hero)
        Text("Screen title", style = t.screenTitle)
        Text("Section title", style = t.sectionTitle)
        Text("Card title", style = t.cardTitle)
        Text("Body copy reads at a comfortable 16sp with 1.5x line height.", style = t.body)
        Text("Label", style = t.label)
        Text("EYEBROW KICKER", style = t.eyebrow)
    }
}

@Composable
private fun SwatchGrid() {
    val c = VortXTheme.colors
    val swatches = listOf(
        "canvas" to c.canvas, "surface1" to c.surface1, "surface2" to c.surface2, "surface3" to c.surface3,
        "hairline" to c.hairline, "accent" to c.accent, "accentBright" to c.accentBright,
        "accentSoft" to c.accentSoft, "onAccent" to c.onAccent, "danger" to c.danger,
    )
    LazyRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        items(swatches) { (name, color) ->
            Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
                Box(
                    modifier = Modifier.size(56.dp).clip(VortXShapes.chip).background(color)
                        .then(Modifier),
                )
                Text(name, style = VortXTheme.type.label.copy(fontSize = androidx.compose.ui.unit.TextUnit(10f, androidx.compose.ui.unit.TextUnitType.Sp)))
            }
        }
    }
}

@Composable
private fun PrimaryButtonStates() {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        PrimaryButton("Watch", onClick = {}, leadingIcon = VortXIcons.playFill)
        PrimaryButton("Loading", onClick = {}, loading = true)
        PrimaryButton("Disabled", onClick = {}, enabled = false)
    }
}

@Composable
private fun ChipStates() {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Chip("Idle", selected = false, onClick = {})
        Chip("Selected", selected = true, onClick = {})
        Chip("Disabled", selected = false, onClick = {}, enabled = false)
    }
}

@Composable
private fun SurfaceCardSample() {
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            "A surface card: surface1 fill, card radius, rest shadow. Never nested.",
            style = VortXTheme.type.body,
            modifier = Modifier.padding(VortXTheme.spacing.md),
        )
    }
}

@Composable
private fun PosterCardStates() {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        PosterCard("Rest", onClick = {}, modifier = Modifier.width(110.dp))
        PosterCard("Watched", onClick = {}, watched = true, modifier = Modifier.width(110.dp))
        PosterCard("In progress", onClick = {}, progress = 0.4f, modifier = Modifier.width(110.dp))
        PosterCard("Disabled", onClick = {}, enabled = false, modifier = Modifier.width(110.dp))
    }
}

@Composable
private fun SourceRowStates() {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        SourceRow(
            addon = "Torrentio", title = "Movie.Title.2024.2160p.UHD.BluRay.x265-GROUP",
            quality = "4K", isTorrent = true, flavorTags = listOf("HDR10", "Atmos"), size = "18.2 GB",
            onClick = {},
        )
        SourceRow(
            addon = "Real-Debrid", title = "Movie.Title.2024.1080p.WEB-DL.x264-GROUP",
            quality = "1080p", flavorTags = listOf("DDP5.1"), size = "3.1 GB",
            onClick = {},
        )
        SourceRow(addon = "Resolving", title = "Disabled while a resolve is in flight", onClick = {}, enabled = false)
    }
}

@Composable
private fun EpisodeRowStates() {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        EpisodeRow(code = "S1 · E1", title = "Pilot", overview = "The first episode overview text wraps to two lines before it clips.", airDate = "2024-01-01", onClick = {})
        EpisodeRow(code = "S1 · E2", title = "Watched episode", watched = true, onClick = {})
        EpisodeRow(code = "S1 · E3", title = "In progress", progress = 0.6f, onClick = {})
    }
}

@Composable
private fun LoadingSample() {
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        repeat(3) {
            Box(
                modifier = Modifier
                    .width(110.dp)
                    .aspectRatio(2f / 3f)
                    .clip(VortXShapes.card)
                    .shimmer(),
            )
        }
    }
}
