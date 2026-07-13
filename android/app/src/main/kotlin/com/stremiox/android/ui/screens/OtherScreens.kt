package com.stremiox.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.stremiox.android.BuildConfig
import com.stremiox.android.model.AuthState
import com.stremiox.android.model.DiscoverFilters
import com.stremiox.android.model.DiscoverResult
import com.stremiox.android.model.LibraryFilters
import com.stremiox.android.model.LibraryResult
import com.stremiox.android.model.MetaItem
import com.stremiox.android.ui.UiState
import com.stremiox.android.ui.components.Chip
import com.stremiox.android.ui.components.EmptyState
import com.stremiox.android.ui.components.ErrorState
import com.stremiox.android.ui.components.PosterArt
import com.stremiox.android.ui.components.PosterCard
import com.stremiox.android.ui.components.shimmer
import com.stremiox.android.ui.theme.VortXIcons
import com.stremiox.android.ui.theme.VortXShapes
import com.stremiox.android.ui.theme.VortXTheme
import com.stremiox.android.ui.viewmodel.DiscoverViewModel
import com.stremiox.android.ui.viewmodel.LibraryViewModel
import com.stremiox.android.ui.viewmodel.SearchViewModel

/// Discover (S04, DESIGN-SYSTEM.md §4 "Discover / Search"): type switch -> catalog chips -> genre
/// chips (when the selected catalog declares one) -> dense poster grid -> "Load more". Every chip
/// dispatches the engine's OWN `request` for that option (see [DiscoverViewModel.select]) -- the fix
/// for the S03-era bug where every chip dispatched the identical default Load and nothing ever
/// actually changed on tap.
@Composable
fun DiscoverScreen(viewModel: DiscoverViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadingMore by viewModel.loadingMore.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<DiscoverResult>)?.data?.filters

    Column(modifier = modifier.fillMaxSize()) {
        DiscoverFilterChips(filters = filters, onSelect = { viewModel.select(it) })
        when (val s = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(s.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = s.data.items,
                onItem = onItem,
                emptyHint = "No titles in this catalog yet.",
                footer = if (s.data.filters.hasNextPage) {
                    { LoadMoreFooter(loading = loadingMore, onClick = viewModel::loadMore) }
                } else {
                    null
                },
            )
        }
    }
}

/// The type/catalog/genre chip rows above Discover's grid. No-ops while [filters] is null (still
/// loading) so the grid below owns the loading/error/empty state exclusively.
///
/// GROUP 3b fix (Fold cover-screen device round: "three stacked chip rows... look wonky"): the parent
/// [DiscoverScreen] `Column` has no `verticalArrangement`, so up to three independently-emitted
/// [ChipScrollRow]s (type / catalog / genre) previously sat back-to-back with only each row's own tiny
/// `xs` vertical padding between them (2x `xs` total) -- on a wide phone that gap reads as "tight but
/// fine"; on the Fold's ~344dp-wide cover screen, where every row ALSO wraps its chips onto a horizontal
/// scroll almost immediately, the rows visually collide into a dense, hard-to-parse block. Wrapping the
/// (at most three) rows in their own [Column] with explicit `sm` spacing keeps every row scrollable
/// and unchanged in content, just legibly separated -- a minimal, cosmetic-only fix, not a redesign.
@Composable
private fun DiscoverFilterChips(filters: DiscoverFilters?, onSelect: (String) -> Unit) {
    if (filters == null) return
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        if (filters.types.isNotEmpty()) {
            ChipScrollRow {
                filters.types.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
        if (filters.catalogs.size > 1) {
            ChipScrollRow {
                filters.catalogs.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
        if (filters.genres.isNotEmpty()) {
            ChipScrollRow {
                filters.genres.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
    }
}

/// Library (S04, DESIGN-SYSTEM.md §4 "Library"): type/sort chips over the saved poster grid with the
/// remove ("x") control per poster.
@Composable
fun LibraryScreen(viewModel: LibraryViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<LibraryResult>)?.data?.filters

    Column(modifier = modifier.fillMaxSize()) {
        LibraryFilterChips(filters = filters, onSelect = { viewModel.load(it) })
        when (val s = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(s.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = s.data.items,
                onItem = onItem,
                emptyHint = "Titles you save appear here.",
                onRemove = viewModel::remove,
            )
        }
    }
}

@Composable
private fun LibraryFilterChips(filters: LibraryFilters?, onSelect: (String) -> Unit) {
    if (filters == null) return
    if (filters.types.size > 1) {
        ChipScrollRow {
            filters.types.forEach { option ->
                Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
            }
        }
    }
    if (filters.sorts.isNotEmpty()) {
        ChipScrollRow {
            filters.sorts.forEach { option ->
                Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
            }
        }
    }
}

/// Search: a query field over a poster grid of matches across every installed add-on, with recent
/// searches as chips when the query is empty (DESIGN-SYSTEM.md §4 "Discover / Search").
@Composable
fun SearchScreen(viewModel: SearchViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val query by viewModel.query.collectAsStateWithLifecycle()
    val state by viewModel.state.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors
    val openItem: (MetaItem) -> Unit = {
        viewModel.recordHistory()
        onItem(it)
    }

    Column(modifier = modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = viewModel::onQueryChange,
            leadingIcon = { Icon(VortXIcons.search, contentDescription = null) },
            placeholder = { Text("Search movies, series, channels", style = VortXTheme.type.body) },
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accent,
                unfocusedBorderColor = colors.hairline,
                cursorColor = colors.accent,
            ),
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.edge),
        )
        if (query.isBlank() && history.isNotEmpty()) {
            ChipScrollRow {
                history.forEach { term ->
                    Chip(label = term, selected = false, onClick = { viewModel.onQueryChange(term) })
                }
                Chip(label = "Clear", selected = false, onClick = viewModel::clearHistory)
            }
        }
        when (val s = state) {
            is UiState.Loading -> EmptyState("Searching your add-ons…")
            is UiState.Error -> ErrorState(s.message)
            is UiState.Success -> PosterGrid(
                items = s.data,
                onItem = openItem,
                emptyHint = if (query.isBlank()) "Type to search across your add-ons." else "No matches.",
            )
        }
    }
}

/// Settings: the same controls the iOS app exposes (DESIGN-SYSTEM.md §4 "Settings / Profiles"). Most
/// values are placeholders until preferences are wired (S09); the structure is final. The Account row
/// is real (S03): it reflects the live engine [AuthState] and opens [AccountScreen] via [onAccountClick].
/// The Add-ons row (S04) opens the add-on management screen via [onAddonsClick]. In debug builds only,
/// one extra row opens the S02 design-system gallery for visual review — the boundary is
/// [BuildConfig.DEBUG], not a build variant, so it never ships in a release build.
@Composable
fun SettingsScreen(
    authState: AuthState,
    onAccountClick: () -> Unit,
    onAddonsClick: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenGallery: (() -> Unit)? = null,
) {
    val accountValue = when (authState) {
        is AuthState.SignedIn -> authState.email ?: "Signed in"
        AuthState.SignedOut -> "Not signed in"
    }
    Column(
        modifier = modifier.fillMaxSize().padding(VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        SettingRow(VortXIcons.account, "Account", accountValue, onClick = onAccountClick)
        SettingRow(VortXIcons.addon, "Add-ons", "Manage", onClick = onAddonsClick)
        SettingRow(VortXIcons.audioOutput, "Audio output", "Auto")
        SettingRow(VortXIcons.subtitles, "Subtitle size", "Medium")
        if (BuildConfig.DEBUG && onOpenGallery != null) {
            SettingRow(VortXIcons.checkmarkCircle, "Design gallery", "Debug", onClick = onOpenGallery)
        }
    }
}

@Composable
private fun SettingRow(icon: ImageVector, title: String, value: String, onClick: (() -> Unit)? = null) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        Icon(icon, contentDescription = null, tint = colors.accent)
        Text(title, style = VortXTheme.type.cardTitle, modifier = Modifier.fillMaxWidth(0.6f))
        Text(value, style = VortXTheme.type.label.copy(color = colors.textSecondary))
    }
}

/// A horizontally-scrolling row of [Chip]s, the shared shape behind every filter row in this file
/// (Discover type/catalog/genre, Library type/sort, Search recents).
@Composable
private fun ChipScrollRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        content = content,
    )
}

/// The dense poster grid shared by Discover/Library/Search (DESIGN-SYSTEM.md §4: "dense poster grid
/// (auto-fill minmax)"). [onRemove] non-null adds the Library "x" remove control per poster (§4
/// "Library": "poster grid with the remove (x) control"); [footer] renders a full-width trailing row
/// (Discover's "Load more").
@Composable
private fun PosterGrid(
    items: List<MetaItem>,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    emptyHint: String,
    onRemove: ((String) -> Unit)? = null,
    footer: (@Composable () -> Unit)? = null,
) {
    if (items.isEmpty()) {
        EmptyState(emptyHint, modifier)
        return
    }
    // Defense-in-depth against the "Load more" crash (GROUP 2a): `LazyVerticalGrid`'s `key = { it.id }`
    // throws `IllegalArgumentException: Key ... was already used` on a duplicate id. The real fix dedupes
    // at the source ([com.stremiox.android.engine.EngineState.parseCatalogWithFilters], where pages get
    // flattened/appended), but this grid is shared by Discover/Library/Search, so a belt-and-suspenders
    // dedupe HERE means no future caller can reintroduce this crash class either. distinctBy is a no-op
    // allocation-wise when there are no duplicates (the common case).
    val deduped = remember(items) { items.distinctBy { it.id } }
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 112.dp),
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(VortXTheme.spacing.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        items(deduped, key = { it.id }) { item ->
            Box {
                PosterCard(
                    title = item.name,
                    subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · "),
                    onClick = { onItem(item) },
                    progress = item.progress,
                    art = { PosterArt(item.poster, item.name) },
                )
                if (onRemove != null) {
                    RemoveBadge(
                        onClick = { onRemove(item.id) },
                        modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
                    )
                }
            }
        }
        if (footer != null) {
            item(span = { GridItemSpan(maxLineSpan) }) { footer() }
        }
    }
}

/// The Library grid's per-poster remove ("x") control: a small dark circular badge so it reads clearly
/// over any poster art, tapped directly (no long-press menu yet -- S10 adds the full long-press poster
/// menu per DESIGN-SYSTEM.md §4 "Collections").
@Composable
private fun RemoveBadge(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(26.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            VortXIcons.delete,
            contentDescription = "Remove from Library",
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
    }
}

/// The "Load more" control at the bottom of a Discover grid with another page available
/// (DESIGN-SYSTEM.md §4 "Discover / Search": "'Load more' (per-catalog skip)").
@Composable
private fun LoadMoreFooter(loading: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.md),
        horizontalArrangement = Arrangement.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(color = VortXTheme.colors.accent, modifier = Modifier.size(28.dp))
        } else {
            Chip(label = "Load more", selected = false, onClick = onClick)
        }
    }
}

/// The shimmer loading state for a poster grid (DESIGN-SYSTEM.md §3 "skeleton shimmer for loading").
@Composable
private fun ShimmerGrid() {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 112.dp),
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(VortXTheme.spacing.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        items(List(9) { it }) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(2f / 3f)
                    .clip(VortXShapes.card)
                    .shimmer(),
            )
        }
    }
}
