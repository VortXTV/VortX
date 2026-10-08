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
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.LibraryViewModel

/**
 * A focused Library history route. The engine's Library payload is the authoritative local collection;
 * [MetaItem.watched] is also the predicate behind the existing Library "Watched" smart filter. Keeping
 * this as a separate route gives the Library entry a real destination without replacing Continue Watching,
 * which remains a playback-progress rail on Home.
 */
@Composable
fun PreviouslyWatchedScreen(
    viewModel: LibraryViewModel,
    onBack: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val watched = (state as? UiState.Success<LibraryResult>)?.data?.items.orEmpty().filter { it.watched }

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
                    "History from your Library",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        when (val loaded = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(loaded.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = watched,
                onItem = onItem,
                emptyHint = "Titles you finish from your Library appear here.",
            )
        }
    }
}
