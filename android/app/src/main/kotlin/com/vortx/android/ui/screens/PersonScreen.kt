package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.model.MetaItem
import com.vortx.android.person.PersonSeed
import com.vortx.android.person.TMDBPersonClient
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.components.PosterCard
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.viewmodel.PersonUiState
import com.vortx.android.ui.viewmodel.PersonViewModel
import kotlinx.coroutines.launch

/// The Person page, ported from `app/SourcesShared/PersonView.swift`: tap a cast member on the detail
/// page and land here. The header paints the name + headshot INSTANTLY from the tapped [seed] (no spinner
/// on the thing you just tapped), then the biography, birthday, birthplace, and filmography stream in from
/// TMDB via VortX's keyless, signed catalog edge ([PersonViewModel]). Filmography tiles push straight into
/// a title detail (resolving a `tmdb:` id to its `tt` id first, exactly like the iOS `openFilmography`
/// path), so you can walk actor -> film -> co-star -> ...
///
/// This screen is shown as a DETAIL-LOCAL overlay by [DetailScreen] (a state var + conditional), not a
/// top-level route, so it needs no change to the app shell's navigation graph. [onOpenTitle] hands the
/// resolved title back up to the detail flow, which hosts the pushed detail.
@Composable
fun PersonScreen(
    viewModel: PersonViewModel,
    seed: PersonSeed,
    onBack: () -> Unit,
    onOpenTitle: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    // Guard a rapid double-tap on a filmography tile so a slow tmdb -> tt resolve can't open twice.
    var resolving by remember { mutableStateOf(false) }

    val openTitle: (MetaItem) -> Unit = { item ->
        if (!resolving) {
            resolving = true
            scope.launch {
                // Resolve tmdb: -> tt BEFORE opening, the same fail-soft resolve the hub grids use; push
                // the unresolved id if the lookup fails so the detail still opens (just sparser).
                val tt = TMDBPersonClient.imdbId(item.id, item.type)
                resolving = false
                onOpenTitle(if (tt != null) item.copy(id = tt) else item)
            }
        }
    }

    Box(modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 108.dp),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = VortXTheme.spacing.edge,
                end = VortXTheme.spacing.edge,
                top = VortXTheme.spacing.xl,
                bottom = VortXTheme.spacing.xl,
            ),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                PersonHeader(state = state, seed = seed)
            }
            state.detail?.biography?.takeIf { it.isNotBlank() }?.let { bio ->
                item(span = { GridItemSpan(maxLineSpan) }) { BiographySection(bio) }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text(
                    text = "Filmography",
                    style = VortXTheme.type.sectionTitle,
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                )
            }
            if (state.credits.isNotEmpty()) {
                items(state.credits, key = { it.id }) { item ->
                    PosterCard(
                        title = item.name,
                        subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · ").ifBlank { null },
                        onClick = { openTitle(item) },
                        art = { PosterArt(item.poster, item.name) },
                    )
                }
            } else {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    FilmographyPlaceholder(loaded = state.loadedCredits)
                }
            }
        }
        PersonBackChip(onBack = onBack, modifier = Modifier.align(Alignment.TopStart))
    }
}

/// The header: circular headshot (initials disc fallback) + department eyebrow + serif name + born line,
/// mirroring `PersonView.header`. Name + photo come from the enriched [PersonUiState.detail] once it lands,
/// else the tapped [seed], so the header is fully painted the instant the page appears.
@Composable
private fun PersonHeader(state: PersonUiState, seed: PersonSeed) {
    val detail = state.detail
    val displayName = detail?.name ?: seed.name
    val photoUrl = detail?.profileUrl ?: seed.profileUrl

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        Headshot(url = photoUrl, name = displayName)
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            detail?.knownForDepartment?.let {
                Text(text = it.uppercase(), style = VortXTheme.type.eyebrow)
            }
            Text(
                text = displayName,
                style = VortXTheme.type.screenTitle,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            bornLine(detail?.birthday, detail?.placeOfBirth)?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
    }
}

/// "Born Mar 1, 1970 · London, England", assembled from whichever parts TMDB returned (mirrors
/// `PersonView.bornLine`); null when neither is present.
private fun bornLine(birthday: String?, placeOfBirth: String?): String? {
    val parts = listOfNotNull(birthday?.let { "Born $it" }, placeOfBirth)
    return parts.takeIf { it.isNotEmpty() }?.joinToString("  ·  ")
}

/// Circular TMDB headshot with an initials-disc fallback (no photo yet, or TMDB has none), mirroring the
/// Apple headshot's circle + subtle stroke.
@Composable
private fun Headshot(url: String?, name: String) {
    Box(
        modifier = Modifier
            .size(112.dp)
            .clip(CircleShape)
            .background(VortXTheme.colors.surface2)
            .border(1.dp, VortXTheme.colors.hairline, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (url.isNullOrBlank()) {
            Text(
                text = initials(name),
                style = VortXTheme.type.sectionTitle.copy(color = VortXTheme.colors.textTertiary),
            )
        } else {
            AsyncImage(
                model = url,
                contentDescription = name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

private fun initials(name: String): String =
    name.split(" ").filter { it.isNotBlank() }.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")

/// The biography paragraph, collapsible (4 lines -> full), mirroring `PersonView.biographySection`'s
/// disclosure interaction.
@Composable
private fun BiographySection(bio: String) {
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Row(
            modifier = Modifier.clickable { expanded = !expanded },
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = "Biography", style = VortXTheme.type.sectionTitle)
            Icon(
                imageVector = VortXIcons.chevronDown,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = VortXTheme.colors.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        Text(
            text = bio,
            style = VortXTheme.type.body,
            maxLines = if (expanded) Int.MAX_VALUE else 4,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/// The grid's stand-in while credits are still streaming (a small spinner) or when the person has no
/// resolvable filmography (a quiet line), mirroring `PersonView.filmographySection`'s two non-grid states.
@Composable
private fun FilmographyPlaceholder(loaded: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(96.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (!loaded) {
            CircularProgressIndicator(color = VortXTheme.colors.accent)
        } else {
            Text(
                text = "No filmography available.",
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
            )
        }
    }
}

/// The contextual Back chip floating over the page (the same VortX-glass pill the detail page uses), so
/// the Person overlay has a consistent way back to the title it was opened from.
@Composable
private fun PersonBackChip(onBack: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(VortXTheme.spacing.md)
            .vortxGlass(
                shape = VortXShapes.chip,
                fillAlpha = VortXGlass.pillFillAlpha,
                shadow = VortXGlass.Shadow.pill,
            ),
    ) {
        IconButton(onClick = onBack) {
            Icon(VortXIcons.back, contentDescription = "Back", tint = Color.White)
        }
    }
}
