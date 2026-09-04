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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.home.HomeRailSurface
import com.vortx.android.iptv.LiveViewModel
import com.vortx.android.model.AuthState
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.screens.DebridLibraryScreen
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonPairingViewModel
import com.vortx.android.ui.viewmodel.AddonStoreViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

/// The five 10-foot top-level surfaces, the couch analogue of the phone [com.vortx.android.ui.VortXApp]'s
/// bottom-nav [Tab] set. Kept in the exact same order and with the same glyphs so the two form factors read
/// as one product.
enum class TvDestination(val label: String, val icon: ImageVector) {
    HOME("Home", com.vortx.android.ui.theme.VortXIcons.home),
    DISCOVER("Discover", com.vortx.android.ui.theme.VortXIcons.discover),
    LIVE("Live TV", com.vortx.android.ui.theme.VortXIcons.live),
    LIBRARY("Library", com.vortx.android.ui.theme.VortXIcons.library),
    // DOWNLOADS is an Android-TV rail entry (Apple TV keeps its offline list inside Library, but a persistent
    // rail entry guarantees the couch downloads UI is reachable regardless of where a download was started).
    // ADDONS is a top-level entry mirroring the Apple TV Add-ons tab; it is also reachable under Settings.
    DOWNLOADS("Downloads", com.vortx.android.ui.theme.VortXIcons.download),
    SEARCH("Search", com.vortx.android.ui.theme.VortXIcons.search),
    ADDONS("Add-ons", com.vortx.android.ui.theme.VortXIcons.addon),
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
    destination: TvDestination,
    onDestinationChange: (TvDestination) -> Unit,
    searchFocusRestoreSignal: Int,
    onRestoreSearchFocus: () -> Unit,
    modifier: Modifier = Modifier,
    // A finished download plays straight into the shell's player slot (no detail page). Default no-op keeps
    // the shell usable in a @Preview / test.
    onPlayLocal: (Playable) -> Unit = {},
    syncManager: VortXSyncManager? = null,
) {
    val appContext = LocalContext.current.applicationContext
    // Bumped when the active tab is re-selected on the rail. A depth-aware destination (Add-ons) pops its own
    // stack back to root; a browse surface (Home, Discover) scrolls its list back to the top -- the 10-foot
    // analogue of re-tapping a bottom-nav tab to pop to root / scroll to top (Apple `scrollToTopOnBump`).
    var reselectSignal by remember { mutableStateOf(0) }
    var showPlayLinkSheet by remember { mutableStateOf(false) }
    var showDebridLibrary by remember { mutableStateOf(false) }
    val debridKeys = remember(appContext) { DebridKeys(appContext) }
    val debridLibraryFocus = remember { FocusRequester() }
    val modalVisible = showPlayLinkSheet || showDebridLibrary

    fun dismissSearchOverlay() {
        showPlayLinkSheet = false
        showDebridLibrary = false
        if (destination == TvDestination.SEARCH) onRestoreSearchFocus()
    }

    // Every rail tab (except the always-present Home + Settings) honors the SAME cross-platform "Show <tab>"
    // preferences the phone shell reads (TabBarPrefs, keys `vortx.tabs.hide.discover|live|library|search`):
    // a hidden tab drops from the rail, and if it was the active surface the shell falls back to Home. This
    // is the couch analogue of the phone Tab bar screen, driven by the exact same keys so a change on either
    // form factor moves the same value.
    val tabBarPrefs = remember(appContext) { TabBarPrefs(appContext) }
    val hiddenTabs by tabBarPrefs.state.collectAsStateWithLifecycle()
    val destinations = remember(hiddenTabs) {
        TvDestination.entries.filter { dest ->
            when (dest) {
                TvDestination.DISCOVER -> !hiddenTabs.hideDiscover
                TvDestination.LIVE -> !hiddenTabs.hideLive
                TvDestination.LIBRARY -> !hiddenTabs.hideLibrary
                TvDestination.SEARCH -> !hiddenTabs.hideSearch
                TvDestination.HOME, TvDestination.DOWNLOADS, TvDestination.ADDONS, TvDestination.SETTINGS -> true
            }
        }
    }
    LaunchedEffect(destinations) {
        if (destination !in destinations) onDestinationChange(TvDestination.HOME)
    }

    // SD-8: Discover and Search gate on a sign-in. On TV the available signal is the engine's Stremio
    // auth state (the VortX-primary sign-in surface is a separate TV parity item); a signed-out set sees
    // the sign-in prompt on those two tabs instead of empty add-on results.
    val authState by auth.authState.collectAsStateWithLifecycle()
    val signedIn = authState is AuthState.SignedIn

    // A single D-pad Back from any non-Home surface returns to Home rather than dropping out of the app --
    // the couch convention (and what a viewer expects after a deliberate tab move). Disabled on Home so the
    // system default (leave the app) still applies there. When a detail/player overlay is up it is composed
    // ABOVE this shell with its own BackHandler, so this one is inert underneath it -- the existing
    // Home -> Detail -> Play back stack is unchanged.
    BackHandler(enabled = destination != TvDestination.HOME) { onDestinationChange(TvDestination.HOME) }

    // One factory for the shell, carrying the app Context so SearchViewModel's history store resolves --
    // the same construction the phone shell uses at VortXApp.kt. Home/Discover/Library ignore the Context.
    val factory = StremioXViewModelFactory(
        repo = repo,
        auth = auth,
        appContext = appContext,
        homeSurface = HomeRailSurface.TV,
    )

    Box(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .focusProperties { canFocus = !modalVisible },
        ) {
            TvNavRail(
            destinations = destinations,
            selected = destination,
            // Re-selecting the active tab pops that tab's own stack to root (Add-ons); switching tabs moves.
            onSelect = { dest -> if (dest == destination) reselectSignal++ else onDestinationChange(dest) },
            )
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
            // Only the selected destination's ViewModel is instantiated (lazily inside the branch); each is
            // retained in the Activity's ViewModelStore by its default class key, so switching tabs keeps a
            // surface's state (Home's live stream, a Search query) exactly as the phone shell does.
            when (destination) {
                TvDestination.HOME ->
                    TvHomeScreen(viewModel<HomeViewModel>(factory = factory), onItem, reselectSignal = reselectSignal)
                TvDestination.DISCOVER ->
                    TvDiscoverScreen(
                        viewModel<DiscoverViewModel>(factory = factory),
                        onItem,
                        signedIn = signedIn,
                        reselectSignal = reselectSignal,
                    )
                TvDestination.LIVE ->
                    TvLiveScreen(viewModel<LiveViewModel>(factory = factory), onItem)
                TvDestination.LIBRARY ->
                    TvLibraryScreen(viewModel<LibraryViewModel>(factory = factory), onItem)
                TvDestination.DOWNLOADS ->
                    TvDownloadsScreen(onPlay = onPlayLocal)
                TvDestination.SEARCH ->
                    TvSearchScreen(
                        viewModel = viewModel<SearchViewModel>(factory = factory),
                        onItem = onItem,
                        onPlayLinkClick = {
                            showPlayLinkSheet = true
                        },
                        onDebridLibraryClick = { showDebridLibrary = true },
                        signedIn = signedIn,
                        restoreQuickActionsFocusSignal = searchFocusRestoreSignal,
                    )
                TvDestination.ADDONS ->
                    TvAddonsDestination(
                        repo = repo,
                        reselectSignal = reselectSignal,
                        onExit = { onDestinationChange(TvDestination.HOME) },
                    )
                TvDestination.SETTINGS ->
                    TvSettingsScreen(repo = repo, auth = auth, syncManager = syncManager, onItem = onItem)
            }

            // Quiet "You're offline" chip pinned to the bottom of the active surface while the device has no
            // validated internet path (Apple RootTabView parity). Non-focusable and overlaid, so the D-pad
            // keeps driving the content beneath and Downloads stays reachable on the rail.
            if (rememberTvOffline()) {
                TvOfflineChip(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = TvDimens.edge),
                )
            }
            }
        }

        if (showPlayLinkSheet) {
            TvPlayLinkSheet(
                onPlay = {
                    showPlayLinkSheet = false
                    onPlayLocal(it)
                },
                onDismiss = ::dismissSearchOverlay,
            )
        }
        if (showDebridLibrary) {
            BackHandler(onBack = ::dismissSearchOverlay)
            LaunchedEffect(showDebridLibrary) {
                runCatching { debridLibraryFocus.requestFocus() }
            }
            DebridLibraryScreen(
                keys = debridKeys,
                onPlay = {
                    showDebridLibrary = false
                    onPlayLocal(it)
                },
                onBack = ::dismissSearchOverlay,
                initialFocusRequester = debridLibraryFocus,
                tvMode = true,
            )
        }
    }
}

/// The left focus rail. Five focusable [Surface] items; the current destination reads accent-tinted, the
/// focused one lights the accent ring and pulls its label bright -- the two signals a viewer needs to tell
/// "where am I" from "where will the D-pad go" apart at 10 feet. Selection is on center-click (not on focus)
/// so passing focus THROUGH the rail toward the content never yanks the whole surface out from under the
/// viewer.
@Composable
private fun TvNavRail(
    destinations: List<TvDestination>,
    selected: TvDestination,
    onSelect: (TvDestination) -> Unit,
) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .width(TvDimens.railWidth)
            .background(colors.surface1)
            .padding(vertical = TvDimens.edge, horizontal = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        destinations.forEach { dest ->
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

/// The top-level Add-ons tab: a self-contained three-state stack (installed list -> add-on store / install-by-QR)
/// that reuses the SAME [TvAddonsScreen] / [TvAddonStoreScreen] / [TvAddonPairingScreen] the Settings-nested
/// Add-ons route uses, built on the SAME [StremioXViewModelFactory], so there is one add-ons flow with two entry
/// points (the rail and Settings), not a fork. Depth-aware Back: a sub-screen's own [BackHandler] pops it to the
/// installed root; at the root there is no local handler, so the shell's "Back returns to Home" applies -- and
/// [onExit] gives the visible Back button the same destination. [reselectSignal] (bumped when the Add-ons tab is
/// re-selected on the rail) pops the stack to root, the couch analogue of re-tapping a bottom-nav tab.
@Composable
private fun TvAddonsDestination(
    repo: CatalogRepository,
    reselectSignal: Int,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var route by remember { mutableStateOf(TvAddonsRoute.ROOT) }
    LaunchedEffect(reselectSignal) { route = TvAddonsRoute.ROOT }
    when (route) {
        TvAddonsRoute.STORE -> {
            BackHandler { route = TvAddonsRoute.ROOT }
            val storeVm: AddonStoreViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            TvAddonStoreScreen(viewModel = storeVm, onBack = { route = TvAddonsRoute.ROOT }, modifier = modifier)
        }
        TvAddonsRoute.PAIRING -> {
            BackHandler { route = TvAddonsRoute.ROOT }
            val pairingVm: AddonPairingViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            TvAddonPairingScreen(viewModel = pairingVm, onBack = { route = TvAddonsRoute.ROOT }, modifier = modifier)
        }
        TvAddonsRoute.ROOT -> {
            val addonsVm: AddonsViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            TvAddonsScreen(
                viewModel = addonsVm,
                onBack = onExit,
                onDiscover = { route = TvAddonsRoute.STORE },
                onInstallByQr = { route = TvAddonsRoute.PAIRING },
                modifier = modifier,
            )
        }
    }
}

private enum class TvAddonsRoute { ROOT, STORE, PAIRING }
