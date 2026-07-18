package com.vortx.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.library.LibraryAutoAdd
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.PlayerScreen
import com.vortx.android.ui.components.Wordmark
import com.vortx.android.ui.gallery.GalleryScreen
import com.vortx.android.ui.screens.AccountScreen
import com.vortx.android.ui.screens.AddonsScreen
import com.vortx.android.ui.screens.DetailScreen
import com.vortx.android.ui.screens.DiscoverScreen
import com.vortx.android.ui.screens.DownloadsScreen
import com.vortx.android.ui.screens.HomeScreen
import com.vortx.android.ui.screens.IntegrationsScreen
import com.vortx.android.ui.screens.LibraryScreen
import com.vortx.android.ui.screens.LibraryTransferScreen
import com.vortx.android.ui.screens.MediaServersScreen
import com.vortx.android.ui.screens.PlaybackSettingsScreen
import com.vortx.android.ui.screens.SearchScreen
import com.vortx.android.ui.screens.SettingsScreen
import com.vortx.android.ui.screens.SourcesSettingsScreen
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassStrip
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory
import kotlinx.coroutines.launch

/// Auto-add fires at ~60s of playback, matching Apple's `d >= 60` at PlayerScreen.swift:972 and
/// TVPlayerView.swift:810. Expressed in ms because Android reports position in ms.
private const val AUTO_ADD_AFTER_MS = 60_000L

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
        // The catalog meta of the title currently in [playing], captured at the moment play starts. This is
        // the Android analogue of Apple's `curMeta` (`PlaybackMeta`): [Playable] itself carries only the
        // resolved stream (url/flags/mediaRef), never the library identity, so the auto-add seam below would
        // otherwise have nothing to add. Bound explicitly at each play entrypoint rather than read off the
        // `detail` slot, so an entrypoint with no catalog title (a local download) can never inherit a stale
        // detail and auto-add the WRONG title. Null = an ad-hoc play, which auto-add skips (fail-soft, and
        // exactly what Apple's `let m = curMeta` does).
        var playingMeta by remember { mutableStateOf<MetaItem?>(null) }
        var showGallery by remember { mutableStateOf(false) }
        var showAccount by remember { mutableStateOf(false) }
        var showAddons by remember { mutableStateOf(false) }
        var showIntegrations by remember { mutableStateOf(false) }
        var showMediaServers by remember { mutableStateOf(false) }
        var showDownloads by remember { mutableStateOf(false) }
        var showPlayback by remember { mutableStateOf(false) }
        var showSources by remember { mutableStateOf(false) }
        var showLibraryTransfer by remember { mutableStateOf(false) }
        val onItem: (MetaItem) -> Unit = { detail = it }
        val appContext = LocalContext.current.applicationContext
        // A scope tied to the whole shell (not the player overlay), so the end-of-playback engine write
        // (final progress tick + Player unload) still runs after the player leaves composition.
        val appScope = rememberCoroutineScope()
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
            // Freshest reported position/duration (ms) for the save-on-exit write: [0] = position,
            // [1] = duration. Reset when the played source changes.
            val lastProgress = remember(playable) { longArrayOf(0L, 0L) }
            // Auto-add-to-Library (D8). One instance per player session; its own SharedPreferences ledger
            // makes the add idempotent ACROSS playbacks (so a later manual removal sticks), while the latch
            // below keeps it to one attempt WITHIN a playback. Reset per source, mirroring Apple's
            // `autoAddedThisPlayback` being a per-playback @State.
            val autoAdd = remember(appContext) { LibraryAutoAdd(appContext) }
            val autoAddedThisPlayback = remember(playable) { booleanArrayOf(false) }
            // Hardware/gesture back pops the player overlay instead of exiting the app (there was no
            // BackHandler anywhere in the shell before; this is the minimum one, scoped to the player).
            BackHandler { playing = null }
            // Engine playback session: load the Player so progress attributes to the right library item,
            // then end it (final tick + unload + watched-near-end) when the player closes. A TRAILER is not
            // the feature (it must not write a resume position, mark watched, or attribute progress to any
            // library item), so it opens NO engine playback session -- exactly as Apple plays trailers through
            // dedicated player instances that never touch the library.
            DisposableEffect(playable) {
                if (!playable.isTrailer) appScope.launch { repo.beginPlaybackSession() }
                onDispose {
                    if (!playable.isTrailer) appScope.launch { repo.endPlaybackSession(lastProgress[0], lastProgress[1]) }
                }
            }
            PlayerScreen(
                playable = playable,
                onBack = { playing = null },
                onError = { playing = null },
                onProgress = { pos, dur ->
                    lastProgress[0] = pos
                    lastProgress[1] = dur
                    // A trailer reports no progress and never auto-adds to the library (it is not the feature).
                    if (playable.isTrailer) return@PlayerScreen
                    appScope.launch { repo.reportProgress(pos, dur) }
                    // ~60s in -> the viewer is really watching this: auto-add it to the Library (D8), once
                    // per playback. This is the Android seam for Apple's block at PlayerScreen.swift:972-978
                    // and TVPlayerView.swift:810-816, which hangs the same call off the same progress tick:
                    // same 60s threshold, same set-the-latch-BEFORE-the-call ordering (so a failed add is
                    // retried on the next PLAYBACK rather than re-fired every tick of this one), and the same
                    // "no meta -> skip" rule. A resume that starts past 60s, a source hop, or an episode
                    // switch never double-fires for the same title: the latch covers the playback, and
                    // [LibraryAutoAdd]'s ledger covers everything after it.
                    //
                    // Live gating: Apple guards with `!effectivelyLive`. Android has no live/VOD flag on
                    // [Playable] yet, so the equivalent is enforced structurally -- a live stream has no
                    // duration, and [PlayerScreen] only reports progress once `durationMs > 0` -- and
                    // explicitly, by admitting only the two library-meaningful types here. CHANNEL/TV have no
                    // library meaning, exactly as on Apple. [LibraryAutoAdd] then re-checks the id shape.
                    val meta = playingMeta
                    if (!autoAddedThisPlayback[0] && meta != null && pos >= AUTO_ADD_AFTER_MS &&
                        (meta.type == MediaType.MOVIE || meta.type == MediaType.SERIES)
                    ) {
                        autoAddedThisPlayback[0] = true
                        // Runs on the shell scope, not the player's: an auto-add fired at the 60s tick must
                        // still complete if the viewer closes the player mid-write, like the final progress
                        // tick above it.
                        appScope.launch {
                            autoAdd.addIfNeeded(
                                repo = repo,
                                id = meta.id,
                                type = meta.type,
                                name = meta.name,
                                poster = meta.poster,
                                // Read at fire time, not at composition, so turning the Settings toggle off
                                // takes effect on the very next tick. This is the same constant the Settings
                                // toggle writes, so the two sides cannot drift.
                                enabled = AutoAddLibrarySetting.isEnabled(appContext),
                            )
                        }
                    }
                },
            )
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

        if (showIntegrations) {
            // Settings > Integrations: connect Trakt / SIMKL. Self-contained (drives the auth singletons
            // directly), so it needs no repository or ViewModel, matching its own doc comment.
            IntegrationsScreen(onBack = { showIntegrations = false })
            return@VortXTheme
        }

        if (showMediaServers) {
            // Settings > Media servers: connect Plex / Jellyfin / Emby. Self-contained like Integrations
            // (drives the MediaServerRepository singleton directly), so it needs no repository or ViewModel.
            MediaServersScreen(onBack = { showMediaServers = false })
            return@VortXTheme
        }

        if (showDownloads) {
            // Settings > Downloads: the device's offline downloads. Self-contained like Integrations and Media
            // servers (it drives the DownloadManager / DownloadStore singletons directly), so it needs no
            // repository or ViewModel. Play-from-local hands a Playable up to the same `playing` slot a streamed
            // source uses, so a downloaded title opens the ordinary player rather than a parallel one.
            DownloadsScreen(
                onBack = { showDownloads = false },
                // A local download carries no catalog meta here, so the played title has no library
                // identity: clear the binding rather than let the previous play's meta ride along. Auto-add
                // then skips this play (Apple's `let m = curMeta` skip).
                onPlay = { playing = it; playingMeta = null },
            )
            return@VortXTheme
        }

        if (showPlayback) {
            // Settings > Playback: device-scoped player preferences. Self-contained like the two above
            // (reads and writes the shared `vortx_settings` SharedPreferences the engines already read at
            // load time), so it needs no repository or ViewModel.
            PlaybackSettingsScreen(onBack = { showPlayback = false })
            return@VortXTheme
        }

        if (showSources) {
            // Settings > Sources: source ranking + filters. Self-contained for the same reason as Playback:
            // it drives `SourcePreferencesStore`, which is the same `vortx_settings` file, and the ranker
            // rebuilds its snapshot from that store on every source list. Nothing here needs the engine
            // repository, so a change is picked up on the next load with no plumbing through this shell.
            SourcesSettingsScreen(onBack = { showSources = false })
            return@VortXTheme
        }

        if (showLibraryTransfer) {
            // Settings > Library: export / import the active profile's saved titles. UNLIKE the two screens
            // above it this one is NOT self-contained: export reads the account library and import writes to
            // it, both through the engine's own dispatch, so it takes [repo] the same way the Account and
            // Detail screens do. It holds no ViewModel because it owns no state that survives the screen: a
            // transfer is one shot, driven by the file picker.
            LibraryTransferScreen(repo = repo, onBack = { showLibraryTransfer = false })
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
                    appContext = appContext,
                ),
            )
            DetailScreen(
                viewModel = detailVm,
                title = current.name,
                onBack = { detail = null },
                // Bind the played title's catalog meta for the 60s auto-add. [current] is the SHOW/movie
                // item, never an episode, which is the identity the library is keyed by -- the same
                // distinction Apple draws between `PlaybackMeta.libraryId` and its `videoId`.
                onPlay = { playing = it; playingMeta = current },
            )
            return@VortXTheme
        }

        val factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)
        val authState by accountVm.authState.collectAsStateWithLifecycle()
        Scaffold(
            topBar = {
                // The top bar reads as VortX glass: the stock opaque Material3 container is made transparent
                // and the flush glass strip renders behind it. Title / items / behavior are unchanged.
                TopAppBar(
                    title = {
                        if (tab == Tab.HOME) Wordmark() else Text(tab.label, style = VortXTheme.type.screenTitle)
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                    modifier = Modifier.vortxGlassStrip(),
                )
            },
            bottomBar = {
                // The bottom nav bar reads as VortX glass too: transparent M3 container plus zero tonal
                // overlay, with the flush glass strip behind. Every tab item stays exactly as it was.
                NavigationBar(
                    containerColor = Color.Transparent,
                    tonalElevation = 0.dp,
                    modifier = Modifier.vortxGlassStrip(),
                ) {
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
                    onIntegrationsClick = { showIntegrations = true },
                    onMediaServersClick = { showMediaServers = true },
                    onDownloadsClick = { showDownloads = true },
                    onPlaybackClick = { showPlayback = true },
                    onSourcesClick = { showSources = true },
                    onLibraryClick = { showLibraryTransfer = true },
                    modifier = content,
                    onOpenGallery = { showGallery = true },
                )
            }
        }
    }
}
