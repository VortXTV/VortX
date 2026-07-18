package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme as TvMaterialTheme
import androidx.tv.material3.darkColorScheme as tvDarkColorScheme
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.player.PlayerScreen
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory
import kotlinx.coroutines.launch

/// The Android TV shell: a three-state D-pad flow (Home browse -> Detail -> Player) that is the 10-foot
/// analogue of the phone [com.vortx.android.ui.StremioXApp], reusing the exact same seams underneath.
///
/// This is the FIRST TV slice. It deliberately covers Home + Detail + Play only; the phone shell's Discover
/// / Library / Search / Settings tabs, the source long-press / pin menu, the episode+season browser, and
/// the in-player overlay are NOT reproduced here yet (see the honest gap list in the session report). What
/// IS here is real: the rows come from the same engine repository, the detail + play come from the same
/// [DetailViewModel], and playback runs on the same [PlayerScreen].
///
/// [repo]/[auth] default to the offline preview so a Compose @Preview / test can drive the TV shell without
/// the engine, exactly like [com.vortx.android.ui.StremioXApp].
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvApp(
    repo: CatalogRepository = PreviewCatalogRepository(),
    auth: AuthRepository = PreviewAuthRepository(),
) {
    VortXTheme {
        // The title currently open in Detail; null = the Home browse wall.
        var detail by remember { mutableStateOf<MetaItem?>(null) }
        // The resolved source currently playing; null = not in the player. The DETAIL page resolves a
        // chosen source into this [Playable] (through [DetailViewModel]); the shell then covers everything
        // with the player, exactly as the phone shell keys [PlayerScreen] off its own `playing` slot.
        var playing by remember { mutableStateOf<Playable?>(null) }

        val appContext = LocalContext.current.applicationContext
        // A scope tied to the whole shell (not the player layer), so the end-of-playback engine write (final
        // progress tick + Player unload) still completes after the player leaves composition -- the same
        // reason the phone shell uses an app-scoped coroutine for this.
        val appScope = rememberCoroutineScope()

        // Player is the topmost layer. When a source resolves to a [Playable] it covers Home/Detail and back
        // returns to the detail page underneath. The begin/report/end-playback-session calls mirror
        // StremioXApp exactly, so Continue Watching + resume track on TV the same way they do on the phone.
        val playable = playing
        if (playable != null) {
            // Freshest reported position/duration (ms) for the save-on-exit write: [0] = position,
            // [1] = duration. Reset when the played source changes.
            val lastProgress = remember(playable) { longArrayOf(0L, 0L) }
            // D-pad Back pops the player back to the detail page rather than exiting the app.
            BackHandler { playing = null }
            DisposableEffect(playable) {
                appScope.launch { repo.beginPlaybackSession() }
                onDispose {
                    appScope.launch { repo.endPlaybackSession(lastProgress[0], lastProgress[1]) }
                }
            }
            PlayerScreen(
                playable = playable,
                onBack = { playing = null },
                onError = { playing = null },
                onProgress = { pos, dur ->
                    lastProgress[0] = pos
                    lastProgress[1] = dur
                    appScope.launch { repo.reportProgress(pos, dur) }
                },
            )
            return@VortXTheme
        }

        // Home + Detail live under androidx.tv's own MaterialTheme so the focus-first tv-material `Surface`
        // tiles resolve their CompositionLocals (its ClickableSurfaceDefaults read the tv color scheme for
        // any default not passed explicitly). VortXTheme still supplies every VortX design token the content
        // reads (colors/type/spacing); the two themes coexist -- one owns tv-component defaults, the other
        // owns the brand tokens.
        TvMaterialTheme(colorScheme = tvDarkColorScheme()) {
            val current = detail
            if (current != null) {
                // One DetailViewModel per open title, keyed by id and fed type+id through the factory's
                // DetailArgs -- the SAME construction the phone shell uses. Reusing it is what makes the TV
                // detail page respect the active profile's Kids source guard for free (the guard lives in
                // DetailViewModel.buildContext).
                val detailVm: DetailViewModel = viewModel(
                    key = "tv-detail-${current.id}",
                    factory = StremioXViewModelFactory(
                        repo = repo,
                        detailArgs = StremioXViewModelFactory.DetailArgs(current.type, current.id),
                        appContext = appContext,
                    ),
                )
                TvDetailScreen(
                    viewModel = detailVm,
                    title = current.name,
                    onBack = { detail = null },
                    onPlay = { playing = it },
                )
            } else {
                val homeVm: HomeViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
                TvHomeScreen(viewModel = homeVm, onItem = { detail = it })
            }
        }
    }
}
