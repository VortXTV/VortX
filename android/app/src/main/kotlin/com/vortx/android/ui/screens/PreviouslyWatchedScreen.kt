package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.LibraryLandingViewModel

/**
 * A focused playback-history route. Its source is owner-bound repository history, not the saved Library:
 * users can finish an unsaved title and can save a title they have never played.
 */
@Composable
fun PreviouslyWatchedScreen(
    viewModel: LibraryLandingViewModel,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val history = (state as? UiState.Success)?.data?.playbackHistory.orEmpty()

    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            IconButton(onClick = onBack) {
                Icon(VortXIcons.back, contentDescription = "Back to Library")
            }
            Column {
                Text("Previously Watched", style = VortXTheme.type.screenTitle)
                Text(
                    "Your complete playback history",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        when (val loaded = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(loaded.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = history,
                onItem = onItem,
                emptyHint = "Titles you watch appear here, even when they are not saved.",
            )
        }
    }
}
