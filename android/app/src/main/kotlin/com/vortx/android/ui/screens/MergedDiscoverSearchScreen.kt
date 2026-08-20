package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.SignedOutState
import com.vortx.android.ui.search.searchEmptyMessage
import com.vortx.android.ui.search.textResourceId
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel

/// The combined Discover + Search surface (SD-2, `HomeDiscoverPreferences.mergeDiscoverSearch`), the
/// Android port of Apple's merged mode (iOSRootView.swift:2629-2666): one search field pinned above the
/// browse, so the tab bar can drop the standalone Search tab. Below the field, the query length is the
/// switch -- fewer than two characters shows the normal [DiscoverScreen] browse (type/catalog/genre chips
/// + catalog grid); two or more characters REPLACE the browse with the same grouped Movies/Series/Other
/// result grid the Search tab renders, with the long-press catalog menu and watched badges. Submitting
/// runs the search immediately (the field's own IME action skips the debounce). Fully reversible: turning
/// the pref off restores the Search tab and returns Discover to a plain browse.
@Composable
fun MergedDiscoverSearchScreen(
    discoverViewModel: DiscoverViewModel,
    searchViewModel: SearchViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
    hideLive: Boolean = false,
    reselectSignal: Int = 0,
) {
    val searchState by searchViewModel.screenState.collectAsStateWithLifecycle()
    val query = searchState.query
    // The engine's own two-character gate (Apple `hasSearchQuery`): below it, browse; at it, grouped
    // results. So a one-character query keeps the Discover browse on screen, never a misleading "No matches".
    val hasQuery = query.trim().length >= 2

    if (!signedIn) {
        SignedOutState(modifier = modifier.fillMaxSize())
        return
    }

    val openItem: (MetaItem) -> Unit = {
        searchViewModel.recordHistory()
        onItem(it)
    }

    Column(modifier = modifier.fillMaxSize()) {
        SearchField(
            query = query,
            onQueryChange = searchViewModel::onQueryChange,
            onSubmit = searchViewModel::submitQuery,
            onClear = { searchViewModel.onQueryChange("") },
        )
        if (hasQuery) {
            when (val s = searchState.content) {
                is UiState.Loading -> EmptyState("Searching your add-ons…", Modifier.weight(1f))
                is UiState.Error -> ErrorState(s.message, modifier = Modifier.weight(1f))
                is UiState.Success -> PosterGrid(
                    items = s.data,
                    onItem = openItem,
                    modifier = Modifier.weight(1f),
                    emptyHint = when (val message = searchEmptyMessage(query, s)) {
                        null -> ""
                        else -> stringResource(message.textResourceId)
                    },
                    sectioned = true,
                    showMenu = true,
                )
            }
        } else {
            // The plain Discover browse fills the space beneath the field.
            DiscoverScreen(
                viewModel = discoverViewModel,
                onItem = onItem,
                modifier = Modifier.weight(1f),
                signedIn = true,
                hideLive = hideLive,
                reselectSignal = reselectSignal,
            )
        }
    }
}
