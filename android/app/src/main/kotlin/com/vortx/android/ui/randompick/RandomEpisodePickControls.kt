package com.vortx.android.ui.randompick

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.vortx.android.R

/** The same episode preview and localized guidance on phone, tablet and TV. */
@Composable
internal fun RandomEpisodePickControls(
    state: RandomEpisodePickState,
    onPick: () -> Unit,
    onOpen: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    tv: Boolean = false,
    playEnabled: Boolean = true,
) {
    val preview = state.episode?.let {
        stringResource(R.string.random_episode_pick_preview, state.seriesName.orEmpty(), it.season, it.episode, it.title)
    }
    val message = state.notice?.let {
        stringResource(when (it) {
            RandomEpisodePickNotice.EMPTY -> R.string.random_pick_empty_episodes
            RandomEpisodePickNotice.PROFILE_LOCKED -> R.string.random_pick_profile_locked
            RandomEpisodePickNotice.LOAD_ERROR -> R.string.random_pick_episode_error
            RandomEpisodePickNotice.PICK_UNAVAILABLE -> R.string.random_pick_episode_changed
        })
    }
    RandomPickControls(
        title = stringResource(R.string.random_episode_pick_title),
        preview = preview,
        message = message,
        loading = state.loading,
        onPick = onPick,
        onOpen = onOpen,
        onPlay = onPlay,
        modifier = modifier,
        tv = tv,
        playEnabled = playEnabled,
    )
}
