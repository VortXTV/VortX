package com.stremiox.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.data.PreviewCatalogRepository
import com.stremiox.android.model.MetaItem
import com.stremiox.android.model.Playable
import com.stremiox.android.player.PlayerScreen
import com.stremiox.android.ui.screens.DetailScreen
import com.stremiox.android.ui.screens.DiscoverScreen
import com.stremiox.android.ui.screens.HomeScreen
import com.stremiox.android.ui.screens.LibraryScreen
import com.stremiox.android.ui.screens.SearchScreen
import com.stremiox.android.ui.screens.SettingsScreen
import com.stremiox.android.ui.theme.StremioXTheme
import com.stremiox.android.ui.viewmodel.DetailViewModel
import com.stremiox.android.ui.viewmodel.DiscoverViewModel
import com.stremiox.android.ui.viewmodel.HomeViewModel
import com.stremiox.android.ui.viewmodel.LibraryViewModel
import com.stremiox.android.ui.viewmodel.SearchViewModel
import com.stremiox.android.ui.viewmodel.StremioXViewModelFactory

private enum class Tab(val label: String, val icon: ImageVector) {
    HOME("Home", Icons.Filled.Home),
    DISCOVER("Discover", Icons.Filled.Explore),
    LIBRARY("Library", Icons.Filled.VideoLibrary),
    SEARCH("Search", Icons.Filled.Search),
    SETTINGS("Settings", Icons.Filled.Settings),
}

/// The whole app: a five-tab shell matching the iOS and Apple TV structure, with a detail overlay.
/// [repo] defaults to the offline preview source; the real stremio-core engine is injected here once
/// the JNI binding lands, with no change to any screen — every screen consumes a ViewModel, and every
/// ViewModel depends only on [CatalogRepository].
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StremioXApp(repo: CatalogRepository = PreviewCatalogRepository()) {
    StremioXTheme {
        var tab by remember { mutableStateOf(Tab.HOME) }
        var detail by remember { mutableStateOf<MetaItem?>(null) }
        var playing by remember { mutableStateOf<Playable?>(null) }
        val onItem: (MetaItem) -> Unit = { detail = it }

        // Player is the topmost layer: when a source resolves to a Playable, it covers everything and
        // back returns to the detail page underneath.
        val playable = playing
        if (playable != null) {
            PlayerScreen(playable = playable, onBack = { playing = null })
            return@StremioXTheme
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
            return@StremioXTheme
        }

        val factory = StremioXViewModelFactory(repo)
        Scaffold(
            topBar = { TopAppBar(title = { Wordmark(tab.label) }) },
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
                Tab.SETTINGS -> SettingsScreen(content)
            }
        }
    }
}

/// The editorial signature on Home: warm-white "Stremio" with an ember "X", the same wordmark the
/// tvOS app leads with. On other tabs the plain tab label reads as the screen title.
@Composable
private fun Wordmark(label: String) {
    if (label != "Home") {
        Text(label)
        return
    }
    Text(
        buildAnnotatedString {
            append("Stremio")
            withStyle(SpanStyle(color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)) {
                append("X")
            }
        }
    )
}
