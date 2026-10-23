package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.Dp
import com.vortx.android.model.MediaType
import com.vortx.android.person.PersonLifeLine
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.CinemaLandscapeArt
import com.vortx.android.ui.prefs.PosterStylePreferences
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
import androidx.compose.runtime.DisposableEffect
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
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.components.PosterCard
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.viewmodel.PersonUiState
import com.vortx.android.ui.viewmodel.PersonViewModel
import com.vortx.android.ui.viewmodel.DetailNavigationFence
import com.vortx.android.ui.viewmodel.resolveRelatedDetailTitle
import kotlinx.coroutines.Job
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
    /** IMDb / TMDB link chips; off on TV, which has no browser. */
    showWebLinks: Boolean = true,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    // The latest selection wins even if a blocking TMDB request outlives cancellation.
    val lookupFence = remember(viewModel, seed.id) { DetailNavigationFence() }
    var lookupJob by remember(viewModel, seed.id) { mutableStateOf<Job?>(null) }
    DisposableEffect(lookupFence) {
        onDispose {
            lookupFence.invalidate()
            lookupJob?.cancel()
        }
    }
    val back: () -> Unit = {
        lookupFence.invalidate()
        lookupJob?.cancel()
        onBack()
    }
    BackHandler(onBack = back)

    val openTitle: (MetaItem) -> Unit = { item ->
        val generation = lookupFence.begin()
        lookupJob?.cancel()
        lookupJob = scope.launch {
            val resolved = resolveRelatedDetailTitle(item)
            if (lookupFence.accepts(generation)) {
                lookupFence.invalidate()
                onOpenTitle(resolved)
            }
        }
    }

    val posterStyle by PosterStylePreferences.state.collectAsStateWithLifecycle()
    val landscape = posterStyle.landscape
    var filter by remember(seed.id) { mutableStateOf(FilmographyFilter.ALL) }
    val visible = state.credits.filter(filter::admits)
    val offersFilter = state.credits.any { it.type == MediaType.MOVIE } && state.credits.any { it.type == MediaType.SERIES }

    BoxWithConstraints(modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        val wide = maxWidth >= 600.dp
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = if (landscape) 220.dp else 116.dp),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = VortXTheme.spacing.edge,
                end = VortXTheme.spacing.edge,
                top = VortXTheme.spacing.xl + 40.dp,
                bottom = VortXTheme.spacing.xl,
            ),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                PersonHeader(state = state, seed = seed, wide = wide, showWebLinks = showWebLinks)
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                FilmographyHeader(
                    count = visible.size.takeIf { state.credits.isNotEmpty() },
                    filter = filter.takeIf { offersFilter },
                    onFilter = { filter = it },
                )
            }
            if (visible.isNotEmpty()) {
                items(visible, key = { it.id }) { item ->
                    PosterCard(
                        title = item.name,
                        subtitle = item.year,
                        onClick = { openTitle(item) },
                        landscape = landscape,
                        art = {
                            if (landscape) CinemaLandscapeArt(item)
                            else PosterArt(item.poster, item.name, id = item.id, type = item.type.id)
                        },
                    )
                }
            } else {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    FilmographyPlaceholder(loaded = state.loadedCredits)
                }
            }
        }
        PersonBackChip(onBack = back, modifier = Modifier.align(Alignment.TopStart))
    }
}

/// All / Movies / Shows over the filmography, the same three-way filter Apple shows.
private enum class FilmographyFilter(val label: String) {
    ALL("All"), MOVIES("Movies"), SHOWS("Shows");

    fun admits(item: MetaItem): Boolean = when (this) {
        ALL -> true
        MOVIES -> item.type == MediaType.MOVIE
        SHOWS -> item.type == MediaType.SERIES
    }
}

/// "Filmography 59" with the All / Movies / Shows chips on the right (only when the person has both).
@Composable
private fun FilmographyHeader(count: Int?, filter: FilmographyFilter?, onFilter: (FilmographyFilter) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.md),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = "Filmography", style = VortXTheme.type.sectionTitle)
        count?.let {
            Text(text = "$it", style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
        }
        Spacer(Modifier.weight(1f))
        filter?.let { current ->
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                FilmographyFilter.entries.forEach { option ->
                    Chip(label = option.label, selected = option == current, onClick = { onFilter(option) })
                }
            }
        }
    }
}

/// The header: a 2:3 portrait (the same shape as the posters below), the department eyebrow, the serif name,
/// the born line with age, IMDb / TMDB links (not on TV, which has no browser), and the biography. Name and
/// photo come from the enriched [PersonUiState.detail] once it lands, else the tapped [seed].
@Composable
private fun PersonHeader(state: PersonUiState, seed: PersonSeed, wide: Boolean, showWebLinks: Boolean) {
    val detail = state.detail
    val displayName = detail?.name ?: seed.name
    val photoUrl = detail?.profileUrl ?: seed.profileUrl
    val identity: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            detail?.knownForDepartment?.let {
                Text(text = it.uppercase(), style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accent))
            }
            Text(
                text = displayName,
                style = if (wide) VortXTheme.type.hero else VortXTheme.type.screenTitle,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            PersonLifeLine.describe(detail)?.let {
                Text(text = it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
            }
            if (showWebLinks) PersonLinks(personId = seed.id, imdbId = detail?.imdbId)
        }
    }
    val bio = detail?.biography?.takeIf { it.isNotBlank() }
    if (wide) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
            verticalAlignment = Alignment.Top,
        ) {
            Portrait(url = photoUrl, name = displayName, width = 200.dp)
            Column(
                modifier = Modifier.widthIn(max = 760.dp),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                identity()
                bio?.let { BiographySection(it) }
            }
        }
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md), verticalAlignment = Alignment.Top) {
                Portrait(url = photoUrl, name = displayName, width = 112.dp)
                identity()
            }
            bio?.let { BiographySection(it) }
        }
    }
}

/// IMDb and TMDB pages for the person, as small chips that open the browser.
@Composable
private fun PersonLinks(personId: Int, imdbId: String?) {
    val uriHandler = LocalUriHandler.current
    Row(
        modifier = Modifier.padding(top = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        imdbId?.takeIf { it.startsWith("nm") }?.let { id ->
            Chip(label = "IMDb", selected = false, onClick = { runCatching { uriHandler.openUri("https://www.imdb.com/name/$id/") } })
        }
        if (personId > 0) {
            Chip(label = "TMDB", selected = false, onClick = { runCatching { uriHandler.openUri("https://www.themoviedb.org/person/$personId") } })
        }
    }
}

/// A 2:3 rounded portrait with an initials fallback, the same shape as the filmography posters.
@Composable
private fun Portrait(url: String?, name: String, width: Dp) {
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier = Modifier
            .width(width)
            .aspectRatio(2f / 3f)
            .clip(shape)
            .background(VortXTheme.colors.surface2)
            .border(1.dp, VortXTheme.colors.hairline, shape),
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

/// The biography, five lines with More / Less, matching Apple.
@Composable
private fun BiographySection(bio: String) {
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = bio,
            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            maxLines = if (expanded) Int.MAX_VALUE else 5,
            overflow = TextOverflow.Ellipsis,
        )
        if (bio.length > 320) {
            Text(
                text = if (expanded) "Less" else "More",
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.accent),
                modifier = Modifier.clickable { expanded = !expanded }.padding(vertical = 4.dp),
            )
        }
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
