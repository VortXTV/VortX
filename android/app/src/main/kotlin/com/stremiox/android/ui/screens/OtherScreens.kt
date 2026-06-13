package com.stremiox.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaItem
import com.stremiox.android.ui.UiState
import com.stremiox.android.ui.components.EmptyState
import com.stremiox.android.ui.components.ErrorState
import com.stremiox.android.ui.components.LoadingRail
import com.stremiox.android.ui.components.PosterCard
import com.stremiox.android.ui.components.PosterRail
import com.stremiox.android.ui.viewmodel.DiscoverViewModel
import com.stremiox.android.ui.viewmodel.LibraryViewModel
import com.stremiox.android.ui.viewmodel.SearchViewModel

/// Discover: a type filter (Movie/Series/...) over add-on catalog rails for that type.
@Composable
fun DiscoverScreen(viewModel: DiscoverViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val type by viewModel.type.collectAsStateWithLifecycle()
    val state by viewModel.state.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MediaType.entries.forEach { t ->
                FilterChip(
                    selected = t == type,
                    onClick = { viewModel.selectType(t) },
                    label = { Text(t.label) },
                )
            }
        }
        when (val s = state) {
            is UiState.Loading -> LazyColumn(
                contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) { items(List(2) { it }) { LoadingRail() } }
            is UiState.Error -> ErrorState(s.message)
            is UiState.Success -> LazyColumn(
                contentPadding = PaddingValues(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                items(s.data, key = { it.id }) { catalog: Catalog ->
                    PosterRail(catalog = catalog, onItem = onItem)
                }
            }
        }
    }
}

/// Library: the user's saved titles in a poster grid.
@Composable
fun LibraryScreen(viewModel: LibraryViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    when (val s = state) {
        is UiState.Loading -> EmptyState("Loading your library…", modifier)
        is UiState.Error -> ErrorState(s.message, modifier = modifier)
        is UiState.Success -> PosterGrid(
            items = s.data,
            onItem = onItem,
            modifier = modifier,
            emptyHint = "Titles you save appear here.",
        )
    }
}

/// Search: a query field over a poster grid of matches across every installed add-on.
@Composable
fun SearchScreen(viewModel: SearchViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val query by viewModel.query.collectAsStateWithLifecycle()
    val state by viewModel.state.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = viewModel::onQueryChange,
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            placeholder = { Text("Search movies, series, channels") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(16.dp),
        )
        when (val s = state) {
            is UiState.Loading -> EmptyState("Searching your add-ons…")
            is UiState.Error -> ErrorState(s.message)
            is UiState.Success -> PosterGrid(
                items = s.data,
                onItem = onItem,
                emptyHint = if (query.isBlank()) "Type to search across your add-ons." else "No matches.",
            )
        }
    }
}

/// Settings: the same controls the iOS app exposes. Values are placeholders until the engine and
/// preferences are wired; the structure is final.
@Composable
fun SettingsScreen(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        SettingRow(Icons.Filled.Person, "Account", "Not signed in")
        SettingRow(Icons.Filled.GraphicEq, "Audio output", "Auto")
        SettingRow(Icons.Filled.Subtitles, "Subtitle size", "Medium")
    }
}

@Composable
private fun SettingRow(icon: ImageVector, title: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onBackground, modifier = Modifier.fillMaxWidth(0.6f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun PosterGrid(items: List<MetaItem>, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier, emptyHint: String) {
    if (items.isEmpty()) {
        EmptyState(emptyHint, modifier)
        return
    }
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 112.dp),
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        items(items, key = { it.id }) { item -> PosterCard(item = item, onClick = { onItem(item) }) }
    }
}
