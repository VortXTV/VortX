package com.vortx.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.player.PlayerScreen
import com.vortx.android.ui.components.Wordmark
import com.vortx.android.ui.gallery.GalleryScreen
import com.vortx.android.ui.screens.AccountScreen
import com.vortx.android.ui.screens.AddonsScreen
import com.vortx.android.ui.screens.DetailScreen
import com.vortx.android.ui.screens.DiscoverScreen
import com.vortx.android.ui.screens.HomeScreen
import com.vortx.android.ui.screens.LibraryScreen
import com.vortx.android.ui.screens.SearchScreen
import com.vortx.android.ui.screens.SettingsScreen
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

private enum class Tab(val label: String, val icon: ImageVector) {
    HOME("Home", VortXIcons.home),
    DISCOVER("Discover", VortXIcons.discover),
    LIBRARY("Library", VortXIcons.library),
    SEARCH("Search", VortXIcons.search),
    SETTINGS("Settings", VortXIcons.settings),
}

/// The whole app: a five-tab shell matching the iOS and Apple TV structure, with a detail overlay.
/// [repo] defaults to the offline preview source; the real stremio-core engine is injected here (from
/// `VortXApplication`), with no change to any screen — every screen consumes a ViewModel, and every
/// ViewModel depends only on [CatalogRepository] (or, for the account screen, [AuthRepository]).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StremioXApp(
    repo: CatalogRepository = PreviewCatalogRepository(),
    auth: AuthRepository = PreviewAuthRepository(),
) {
    VortXTheme {
        var tab by remember { mutableStateOf(Tab.HOME) }
        var detail by remember { mutableStateOf<MetaItem?>(null) }
        var playing by remember { mutableStateOf<Playable?>(null) }
        var showGallery by remember { mutableStateOf(false) }
        var showAccount by remember { mutableStateOf(false) }
        var showAddons by remember { mutableStateOf(false) }
        val onItem: (MetaItem) -> Unit = { detail = it }
        val appContext = LocalContext.current.applicationContext
        // One AccountViewModel for the whole shell (not per-screen-visit like the catalog ViewModels):
        // Settings' Account row summary and the AccountScreen overlay both read the SAME live
        // authState, so a sign-in on one immediately reflects on the other with no extra plumbing.
        val accountVm: AccountViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo, auth = auth))

        // The debug-only design-system gallery (S02) is the topmost overlay when open, above even the
        // detail/player layers below — it is a review tool, not part of the product navigation graph.
        if (showGallery) {
            GalleryScreen(onBack = { showGallery = false })
            return@VortXTheme
        }

        // Player is the topmost layer: when a source resolves to a Playable, it covers everything and
        // back returns to the detail page underneath.
        val playable = playing
        if (playable != null) {
            PlayerScreen(playable = playable, onBack = { playing = null })
            return@VortXTheme
        }

        if (showAccount) {
            AccountScreen(viewModel = accountVm, onBack = { showAccount = false })
            return@VortXTheme
        }

        if (showAddons) {
            val addonsVm: AddonsViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            AddonsScreen(viewModel = addonsVm, onBack = { showAddons = false })
            return@VortXTheme
        }

        val current = detail
        if (current != null) {
            // A ViewModel keyed to this title's id, fed type+id through the factory's DetailArgs.
            val detailVm: DetailViewModel = viewModel(
                key = "detail-${current.id}",
                factory = StremioXViewModelFactory(
                    repo = repo,
                    detailArgs = StremioXViewModelFactory.DetailArgs(current.type, current.id),
                ),
            )
            DetailScreen(
                viewModel = detailVm,
                title = current.name,
                onBack = { detail = null },
                onPlay = { playing = it },
            )
            return@VortXTheme
        }

        val factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)
        val authState by accountVm.authState.collectAsStateWithLifecycle()
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        if (tab == Tab.HOME) Wordmark() else Text(tab.label, style = VortXTheme.type.screenTitle)
                    },
                )
            },
            bottomBar = {
                NavigationBar {
                    Tab.entries.forEach { t ->
                        NavigationBarItem(
                            selected = t == tab,
                            onClick = { tab = t },
                            icon = { Icon(t.icon, contentDescription = t.label) },
                            label = { Text(t.label) },
                        )
                    }
                }
            },
        ) { padding ->
            val content = Modifier.padding(padding)
            when (tab) {
                Tab.HOME -> HomeScreen(viewModel<HomeViewModel>(factory = factory), onItem, content)
                Tab.DISCOVER -> DiscoverScreen(viewModel<DiscoverViewModel>(factory = factory), onItem, content)
                Tab.LIBRARY -> LibraryScreen(viewModel<LibraryViewModel>(factory = factory), onItem, content)
                Tab.SEARCH -> SearchScreen(viewModel<SearchViewModel>(factory = factory), onItem, content)
                Tab.SETTINGS -> SettingsScreen(
                    authState = authState,
                    onAccountClick = { showAccount = true },
                    onAddonsClick = { showAddons = true },
                    modifier = content,
                    onOpenGallery = { showGallery = true },
                )
            }
        }
    }
}
