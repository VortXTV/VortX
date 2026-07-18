package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

/// The five 10-foot top-level surfaces, the couch analogue of the phone [com.vortx.android.ui.StremioXApp]'s
/// bottom-nav [Tab] set. Kept in the exact same order and with the same glyphs so the two form factors read
/// as one product.
enum class TvDestination(val label: String, val icon: ImageVector) {
    HOME("Home", com.vortx.android.ui.theme.VortXIcons.home),
    DISCOVER("Discover", com.vortx.android.ui.theme.VortXIcons.discover),
    LIBRARY("Library", com.vortx.android.ui.theme.VortXIcons.library),
    SEARCH("Search", com.vortx.android.ui.theme.VortXIcons.search),
    SETTINGS("Settings", com.vortx.android.ui.theme.VortXIcons.settings),
}

/// The Android TV navigation shell: a left focus rail beside the current destination. This is the 10-foot
/// analogue of the phone shell's bottom [androidx.compose.material3.NavigationBar] -- a side rail, because a
/// D-pad steps naturally up/down a vertical list and into the wall to its right, where a bottom bar would
/// force an awkward long down-travel past every row on every set. It sits UNDER the detail + player overlays
/// (which [TvApp] keeps above it), so the existing Home -> Detail -> Play flow is untouched: this only adds
/// the four sibling surfaces and the way to reach them.
///
/// Every destination is driven by the SAME ViewModel the phone screen uses, built through the SAME
/// [StremioXViewModelFactory] with the shared engine [repo] -- there is no forked business logic and no
/// second data path. Because those ViewModels read the active profile (and its Kids source guard) exactly
/// as the phone does, every TV surface honors the active profile by construction. Selecting a title on any
/// surface calls [onItem], which [TvApp] turns into the shared [TvDetailScreen].
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvShell(
    repo: CatalogRepository,
    auth: AuthRepository,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val appContext = LocalContext.current.applicationContext
    var destination by remember { mutableStateOf(TvDestination.HOME) }

    // A single D-pad Back from any non-Home surface returns to Home rather than dropping out of the app --
    // the couch convention (and what a viewer expects after a deliberate tab move). Disabled on Home so the
    // system default (leave the app) still applies there. When a detail/player overlay is up it is composed
    // ABOVE this shell with its own BackHandler, so this one is inert underneath it -- the existing
    // Home -> Detail -> Play back stack is unchanged.
    BackHandler(enabled = destination != TvDestination.HOME) { destination = TvDestination.HOME }

    // One factory for the shell, carrying the app Context so SearchViewModel's history store resolves --
    // the same construction the phone shell uses at StremioXApp.kt. Home/Discover/Library ignore the Context.
    val factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)

    Row(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvNavRail(selected = destination, onSelect = { destination = it })
        Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
            // Only the selected destination's ViewModel is instantiated (lazily inside the branch); each is
            // retained in the Activity's ViewModelStore by its default class key, so switching tabs keeps a
            // surface's state (Home's live stream, a Search query) exactly as the phone shell does.
            when (destination) {
                TvDestination.HOME ->
                    TvHomeScreen(viewModel<HomeViewModel>(factory = factory), onItem)
                TvDestination.DISCOVER ->
                    TvDiscoverScreen(viewModel<DiscoverViewModel>(factory = factory), onItem)
                TvDestination.LIBRARY ->
                    TvLibraryScreen(viewModel<LibraryViewModel>(factory = factory), onItem)
                TvDestination.SEARCH ->
                    TvSearchScreen(viewModel<SearchViewModel>(factory = factory), onItem)
                TvDestination.SETTINGS ->
                    TvSettingsScreen()
            }
        }
    }
}

/// The left focus rail. Five focusable [Surface] items; the current destination reads accent-tinted, the
/// focused one lights the accent ring and pulls its label bright -- the two signals a viewer needs to tell
/// "where am I" from "where will the D-pad go" apart at 10 feet. Selection is on center-click (not on focus)
/// so passing focus THROUGH the rail toward the content never yanks the whole surface out from under the
/// viewer.
@Composable
private fun TvNavRail(selected: TvDestination, onSelect: (TvDestination) -> Unit) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .width(TvDimens.railWidth)
            .background(colors.surface1)
            .padding(vertical = TvDimens.edge, horizontal = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        TvDestination.entries.forEach { dest ->
            TvNavItem(
                destination = dest,
                selected = dest == selected,
                onClick = { onSelect(dest) },
            )
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvNavItem(destination: TvDestination, selected: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    var focused by remember { mutableStateOf(false) }
    // Colors are set explicitly off (focused, selected) rather than leaned on the tv content-color local,
    // matching the rest of ui/tv/: focus wins (onAccent over the accent fill), then selection (bright), then
    // the resting secondary tone.
    val content = when {
        focused -> colors.onAccent
        selected -> colors.textPrimary
        else -> colors.textSecondary
    }
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) colors.surface3 else Color.Transparent,
            contentColor = content,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(destination.icon, contentDescription = null, tint = content)
            Spacer(Modifier.width(14.dp))
            Text(
                text = destination.label,
                style = VortXTheme.type.body.copy(color = content),
                maxLines = 1,
            )
        }
    }
}
