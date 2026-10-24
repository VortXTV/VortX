package com.vortx.android.ui.randompick

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.vortx.android.R

/** Thin shared caller: touch and TV get identical filtering, preview and explicit-action semantics. */
@Composable
internal fun RandomLibraryPickHeader(
    state: RandomLibraryPickState,
    onPick: (RandomLibraryFilter) -> Unit,
    onOpen: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    tv: Boolean = false,
) {
    val filters = RandomLibraryFilter.entries
    val labels = listOf(
        stringResource(R.string.random_library_filter_all),
        stringResource(R.string.random_library_filter_movies),
        stringResource(R.string.random_library_filter_shows),
    )
    val message = when (state.message) {
        null -> null
        RandomLibraryPickNotice.EMPTY -> stringResource(R.string.random_pick_empty_library)
        RandomLibraryPickNotice.PROFILE_LOCKED -> stringResource(R.string.random_pick_profile_locked)
        RandomLibraryPickNotice.LOAD_ERROR -> stringResource(R.string.random_pick_library_error)
        RandomLibraryPickNotice.PICK_UNAVAILABLE -> stringResource(R.string.random_pick_library_changed)
    }
    RandomPickControls(
        title = stringResource(R.string.random_library_pick_title),
        preview = state.preview?.name,
        message = message,
        loading = state.loading,
        onPick = { onPick(state.filter) },
        onOpen = onOpen,
        onPlay = onPlay,
        modifier = modifier,
        tv = tv,
        filters = filters.mapIndexed { index, filter -> labels[index] to (filter == state.filter) },
        onFilter = { index -> filters.getOrNull(index)?.let(onPick) },
    )
}
