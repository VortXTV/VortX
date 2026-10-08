package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeCatalogBrowseViewModel

/** Full-grid counterpart of a Home rail. Pagination stays on the row's established repository action. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun HomeCatalogBrowseScreen(
    viewModel: HomeCatalogBrowseViewModel,
    title: String,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(title, style = VortXTheme.type.screenTitle) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(VortXIcons.back, contentDescription = "Back")
                }
            },
        )
        when (val current = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(current.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = current.data.items,
                onItem = onItem,
                emptyHint = "This catalog has no titles right now.",
                showMenu = true,
                footer = if (current.data.hasNextPage) {
                    {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.md),
                            horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Chip(label = "Load more", selected = false, onClick = viewModel::loadNextPage)
                        }
                    }
                } else {
                    null
                },
            )
        }
    }
}
