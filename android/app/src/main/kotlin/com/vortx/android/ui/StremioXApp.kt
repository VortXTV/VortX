package com.vortx.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.StreamRanking
import com.vortx.android.library.LibraryAutoAdd
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.BadSourceAutoRetrySetting
import com.vortx.android.player.DefaultEmber
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
import com.vortx.android.ui.screens.ProfilesScreen
import com.vortx.android.ui.screens.SearchScreen
import com.vortx.android.ui.screens.SettingsScreen
import com.vortx.android.ui.screens.SourcesSettingsScreen
import com.vortx.android.ui.screens.VortXAccountScreen
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent
import com.vortx.android.ui.theme.vortxGlassStrip
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.Playback
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import kotlinx.coroutines.delay
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
    // The app-process VortX account + sync engine (VortXApplication.syncManager). Null in @Previews and
    // when the manager could not be stood up (keystore failure): the VortX Account settings row is then
    // hidden and everything else is unchanged -- sync is off the critical path by design.
    syncManager: VortXSyncManager? = null,
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
        var showVortxAccount by remember { mutableStateOf(false) }
        var showAddons by remember { mutableStateOf(false) }
        var showIntegrations by remember { mutableStateOf(false) }
        var showMediaServers by remember { mutableStateOf(false) }
        var showDownloads by remember { mutableStateOf(false) }
        var showPlayback by remember { mutableStateOf(false) }
        var showSources by remember { mutableStateOf(false) }
        var showLibraryTransfer by remember { mutableStateOf(false) }
        var showProfiles by remember { mutableStateOf(false) }
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
            // Hardware/gesture Back dismisses the overlay instead of exiting the app. Every overlay layer
            // in this shell installs its own BackHandler the same way: with none, the system back (which
            // the manifest opts into via enableOnBackInvokedCallback) falls through to the Activity and
            // finishes it, so Back on any overlay quit the whole app (the device-audit finding).
            BackHandler { showGallery = false }
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

            // UP NEXT AUTO-ADVANCE + BAD-SOURCE RETRY. For ANY detail-launched play (never a trailer,
            // never a local download -- those reach the player with `detail == null`), grab the SAME
            // keyed DetailViewModel the detail layer below uses (identical key + factory args, so this
            // is the instance that already holds the played target's selection and its ranked source
            // list). Two consumers hang off it:
            //   - Up Next: when a SERIES episode ENDS, PlayerScreen's onEnded asks it for the next
            //     episode: present -> the Up Next countdown overlay below; absent -> exit-to-detail.
            //     (nextEpisode() is null for a movie, so Up Next stays series-only by construction.)
            //   - The bad-source retry ladder: when the live source is judged BAD (dead link, stall,
            //     or the runtime-mismatch junk-file verdict), retryNextSource() plays the next ranked
            //     source for the SAME target, and after 3 failed sources the manual pick overlay
            //     surfaces -- movies and series both.
            // The condition is stable for the life of this block ([detail] cannot change while the
            // player overlay is up).
            val showForNext = detail
            val advanceVm: DetailViewModel? =
                if (showForNext != null && !playable.isTrailer) {
                    viewModel(
                        key = "detail-${showForNext.id}",
                        factory = StremioXViewModelFactory(
                            repo = repo,
                            detailArgs = StremioXViewModelFactory.DetailArgs(showForNext.type, showForNext.id),
                            appContext = appContext,
                        ),
                    )
                } else {
                    null
                }
            // The next episode being offered, set by onEnded. Keyed per playable so advancing into the
            // next episode (a NEW playable) clears the offer automatically.
            var upNext by remember(playable) { mutableStateOf<Episode?>(null) }
            // Bad-source ladder surfaces, keyed per playable DELIBERATELY: a successful retry swaps
            // [playing] to the new source's playable, which resets both to false and closes the
            // overlay on its own. The ladder's cross-retry memory (failed sources + the 3-attempt
            // cap per episode) lives in [DetailViewModel], which survives the swaps.
            var retryingSource by remember(playable) { mutableStateOf(false) }
            var manualSourcePick by remember(playable) { mutableStateOf(false) }
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
            Box {
                PlayerScreen(
                    playable = playable,
                    onBack = { playing = null },
                    onError = { playing = null },
                    // Natural end of the stream: offer the next episode when the open series has one,
                    // otherwise keep the old exit back to the detail page.
                    onEnded = {
                        val next = advanceVm?.nextEpisode()
                        if (next != null) upNext = next else playing = null
                    },
                    // Bad source (dead link, stall, or a runtime-mismatch junk file): run the auto-retry
                    // ladder instead of bouncing to the detail page -- the next ranked source resolves
                    // through [advanceVm]'s ordinary playback flow and the collector below swaps
                    // [playing] in place. When the ladder is exhausted (3 distinct sources failed for
                    // this target) or there is nothing left to try, surface MANUAL selection: never
                    // silently give up, never advance. Null (the pre-ladder error overlay) when no
                    // detail ViewModel exists (a local download / ad-hoc play) or the kill switch
                    // [BadSourceAutoRetrySetting] is off.
                    onSourceFailed = if (advanceVm != null && BadSourceAutoRetrySetting.isEnabled(appContext)) {
                        {
                            if (advanceVm.retryNextSource()) retryingSource = true else manualSourcePick = true
                        }
                    } else {
                        null
                    },
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
                // The Up Next countdown overlay + its resolution collector. The collector lives HERE, not in
                // DetailScreen (which is not composed while the player covers it): playNextEpisode() posts
                // Ready/Failed through the ViewModel's ordinary playback flow, and this is the only observer
                // while the player is up. Ready swaps `playing` to the next episode's Playable (the
                // DisposableEffect(playable) above then closes the old engine session and opens the new one);
                // Failed falls back to the detail page, where the full source list is available.
                val nextEp = upNext
                if (nextEp != null && advanceVm != null) {
                    val nextPlayback by advanceVm.playback.collectAsStateWithLifecycle()
                    LaunchedEffect(nextPlayback) {
                        when (val pb = nextPlayback) {
                            is Playback.Ready -> {
                                advanceVm.clearPlayback()
                                playingMeta = showForNext
                                playing = pb.playable
                            }
                            is Playback.Failed -> {
                                advanceVm.clearPlayback()
                                playing = null
                            }
                            else -> Unit
                        }
                    }
                    UpNextOverlay(
                        episode = nextEp,
                        resolving = nextPlayback is Playback.Resolving,
                        onPlayNow = { advanceVm.playNextEpisode() },
                        onCancel = { playing = null },
                    )
                }
                // The bad-source ladder's surfaces + their resolution collector. Like the Up Next
                // collector above, this is the only [Playback] observer while its overlay is up (the
                // two are mutually exclusive: Up Next requires a GENUINE ended verdict, the ladder a
                // BAD one, and PlayerScreen keeps those disjoint). Ready swaps [playing] to the
                // retried/picked source's playable, which resets the per-playable overlay state and
                // closes everything; a resolve FAILURE while auto-retrying counts as the next rung of
                // the ladder (the failed pick was recorded by retryNextSource's ledger via
                // lastPlayedSource), falling through to manual pick when the ladder is done; a
                // failure of the viewer's own manual pick stays on the picker for another choice.
                if ((retryingSource || manualSourcePick) && advanceVm != null) {
                    val retryPlayback by advanceVm.playback.collectAsStateWithLifecycle()
                    LaunchedEffect(retryPlayback) {
                        when (val pb = retryPlayback) {
                            is Playback.Ready -> {
                                advanceVm.clearPlayback()
                                // A pick made on the MANUAL fallback is the viewer's own, warned
                                // choice: mark it userForcedSource so the player lets it play
                                // instead of condemning it again (the never-poison gates stay on).
                                playing = if (manualSourcePick) {
                                    pb.playable.copy(userForcedSource = true)
                                } else {
                                    pb.playable
                                }
                            }
                            is Playback.Failed -> {
                                advanceVm.clearPlayback()
                                if (!manualSourcePick && !advanceVm.retryNextSource()) {
                                    retryingSource = false
                                    manualSourcePick = true
                                }
                            }
                            else -> Unit
                        }
                    }
                    if (manualSourcePick) {
                        ManualSourcePickOverlay(
                            sources = advanceVm.manualSourceOptions(),
                            resolving = retryPlayback is Playback.Resolving,
                            onPick = { advanceVm.play(it) },
                            onClose = { playing = null },
                        )
                    } else {
                        RetryingSourceOverlay()
                    }
                }
            }
            return@VortXTheme
        }

        if (showVortxAccount && syncManager != null) {
            // Settings > VortX Account: the E2E VortX account (sign in / create / recover) + cross-device
            // sync controls, driving the app-process VortXSyncManager. Separate from the Stremio account
            // overlay below: the VortX account is the primary login; Stremio stays the optional import.
            BackHandler { showVortxAccount = false }
            val vortxAccountVm: VortXAccountViewModel =
                viewModel(factory = StremioXViewModelFactory(repo = repo, syncManager = syncManager))
            VortXAccountScreen(viewModel = vortxAccountVm, onBack = { showVortxAccount = false })
            return@VortXTheme
        }

        if (showAccount) {
            // System Back = the screen's own back affordance (dismiss to Settings), never an app exit.
            BackHandler { showAccount = false }
            AccountScreen(viewModel = accountVm, onBack = { showAccount = false })
            return@VortXTheme
        }

        if (showAddons) {
            BackHandler { showAddons = false }
            val addonsVm: AddonsViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            AddonsScreen(viewModel = addonsVm, onBack = { showAddons = false })
            return@VortXTheme
        }

        if (showIntegrations) {
            // Settings > Integrations: connect Trakt / SIMKL. Self-contained (drives the auth singletons
            // directly), so it needs no repository or ViewModel, matching its own doc comment.
            BackHandler { showIntegrations = false }
            IntegrationsScreen(onBack = { showIntegrations = false })
            return@VortXTheme
        }

        if (showMediaServers) {
            // Settings > Media servers: connect Plex / Jellyfin / Emby. Self-contained like Integrations
            // (drives the MediaServerRepository singleton directly), so it needs no repository or ViewModel.
            BackHandler { showMediaServers = false }
            MediaServersScreen(onBack = { showMediaServers = false })
            return@VortXTheme
        }

        if (showDownloads) {
            // Settings > Downloads: the device's offline downloads. Self-contained like Integrations and Media
            // servers (it drives the DownloadManager / DownloadStore singletons directly), so it needs no
            // repository or ViewModel. Play-from-local hands a Playable up to the same `playing` slot a streamed
            // source uses, so a downloaded title opens the ordinary player rather than a parallel one.
            BackHandler { showDownloads = false }
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
            BackHandler { showPlayback = false }
            PlaybackSettingsScreen(onBack = { showPlayback = false })
            return@VortXTheme
        }

        if (showSources) {
            // Settings > Sources: source ranking + filters. Self-contained for the same reason as Playback:
            // it drives `SourcePreferencesStore`, which is the same `vortx_settings` file, and the ranker
            // rebuilds its snapshot from that store on every source list. Nothing here needs the engine
            // repository, so a change is picked up on the next load with no plumbing through this shell.
            BackHandler { showSources = false }
            SourcesSettingsScreen(onBack = { showSources = false })
            return@VortXTheme
        }

        if (showProfiles) {
            // Settings > Profiles: the "Who's watching?" switcher + create/rename/delete. Self-contained
            // (it drives the ProfileStore singleton directly, whose select() fires the engine reload +
            // Home-rebuild seams), so it needs no repository or ViewModel, matching the other settings
            // overlays. Switching to a non-owner profile only swaps the active selection + its private
            // overlay; the account library is never touched (the never-poison split lives in the store).
            BackHandler { showProfiles = false }
            ProfilesScreen(onBack = { showProfiles = false })
            return@VortXTheme
        }

        if (showLibraryTransfer) {
            // Settings > Library: export / import the active profile's saved titles. UNLIKE the two screens
            // above it this one is NOT self-contained: export reads the account library and import writes to
            // it, both through the engine's own dispatch, so it takes [repo] the same way the Account and
            // Detail screens do. It holds no ViewModel because it owns no state that survives the screen: a
            // transfer is one shot, driven by the file picker.
            BackHandler { showLibraryTransfer = false }
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
            // System Back closes the detail overlay back to the browse shell. Composed BEFORE
            // DetailScreen so the screen's own nested overlay handlers (person page / nested title,
            // DetailScreen.kt) register later and therefore take precedence while they are open.
            BackHandler { detail = null }
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
                    // The VortX account row: live signed-in summary straight off the sync manager's
                    // account flow. Null manager (preview / keystore failure) hides the row entirely.
                    // The conditional collect is safe: [syncManager] is process-constant, so the
                    // composition never flips between the two branches.
                    vortxAccountValue = syncManager?.let { manager ->
                        val vortxAccount by manager.account.collectAsStateWithLifecycle()
                        vortxAccount?.let { it.username.ifEmpty { it.email } } ?: "Not signed in"
                    },
                    onVortxAccountClick = { showVortxAccount = true },
                    onProfilesClick = { showProfiles = true },
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

/// The Up Next card shown over the ended player: episode label, a Play-now action, a Cancel back to
/// the detail page, and a countdown that auto-plays when it runs out. [resolving] (the next episode's
/// source resolve in flight) freezes the card on "Starting…"; a resolve failure never strands it (the
/// shell's collector exits to the detail page on [Playback.Failed]).
@Composable
private fun UpNextOverlay(
    episode: Episode,
    resolving: Boolean,
    onPlayNow: () -> Unit,
    onCancel: () -> Unit,
) {
    var secondsLeft by remember(episode.id) { mutableStateOf(UP_NEXT_COUNTDOWN_S) }
    // Latched once the advance has been kicked (countdown expiry OR the Play-now tap), so neither path
    // can double-fire the other.
    var fired by remember(episode.id) { mutableStateOf(false) }
    val currentOnPlayNow by rememberUpdatedState(onPlayNow)
    LaunchedEffect(episode.id) {
        while (secondsLeft > 0) {
            delay(1_000)
            secondsLeft--
        }
        if (!fired) {
            fired = true
            currentOnPlayNow()
        }
    }
    Box(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(24.dp)
                .vortxGlassPanel(RoundedCornerShape(14.dp))
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "Up Next",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = buildString {
                    append("S${episode.season} E${episode.episode}")
                    if (episode.title.isNotBlank()) append(" · ${episode.title}")
                },
                color = Color.White,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (resolving || fired) "Starting…" else "Play now · ${secondsLeft}s",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .vortxGlassProminent(shape = RoundedCornerShape(8.dp), tint = DefaultEmber)
                        .clickable(enabled = !resolving && !fired) {
                            fired = true
                            currentOnPlayNow()
                        }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                )
                Text(
                    text = "Cancel",
                    color = Color.White.copy(alpha = 0.85f),
                    fontSize = 14.sp,
                    modifier = Modifier
                        .clickable(onClick = onCancel)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                )
            }
        }
    }
}

/// The bad-source ladder's in-flight affordance: a dimmed frame + spinner while the next ranked source
/// resolves, so a junk/dead source reads as "finding you a working file", never as a finished episode
/// or a dead player. Closed automatically when the retried source's playable swaps in (the overlay
/// state is keyed per playable).
@Composable
private fun RetryingSourceOverlay() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.6f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .vortxGlassPanel(RoundedCornerShape(14.dp))
                .padding(horizontal = 28.dp, vertical = 22.dp),
        ) {
            CircularProgressIndicator(color = DefaultEmber, modifier = Modifier.size(40.dp))
            Text(
                text = "That file wasn't right",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
            )
            Text(
                text = "Trying another source",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
            )
        }
    }
}

/// The manual fallback after the auto-retry ladder exhausts: a clear splash listing the ranked sources
/// for THIS target so the viewer picks one to keep watching. Never auto-advances and never silently
/// gives up; the only exits are a pick (which plays) or Back (to the detail page's full list). Rows are
/// disabled while a pick is resolving so a double-tap cannot race two resolves.
@Composable
private fun ManualSourcePickOverlay(
    sources: List<StreamSource>,
    resolving: Boolean,
    onPick: (StreamSource) -> Unit,
    onClose: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.8f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth(0.92f)
                .vortxGlassPanel(RoundedCornerShape(14.dp))
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "Couldn't find a working source",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 17.sp,
            )
            Text(
                text = "The last few files didn't play right. Pick a source to keep watching.",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 13.sp,
            )
            if (sources.isEmpty()) {
                Text(
                    text = "No sources are loaded for this title. Go back to browse the full list.",
                    color = Color.White.copy(alpha = 0.75f),
                    fontSize = 14.sp,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.heightIn(max = 320.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(sources, key = { it.id }) { source ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .vortxGlassProminent(shape = RoundedCornerShape(10.dp), tint = DefaultEmber)
                                .clickable(enabled = !resolving) { onPick(source) }
                                .padding(horizontal = 14.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                text = listOf(StreamRanking.qualityLabel(source), source.addon)
                                    .filter { it.isNotBlank() }
                                    .joinToString(" · "),
                                color = Color.White,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                            )
                            Text(
                                text = source.title,
                                color = Color.White.copy(alpha = 0.8f),
                                fontSize = 12.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
            Text(
                text = if (resolving) "Starting…" else "Back",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
                modifier = Modifier
                    .clickable(enabled = !resolving, onClick = onClose)
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
    }
}

/// Seconds the Up Next overlay counts down before auto-playing the next episode. Long enough to cancel,
/// short enough that a binge never waits.
private const val UP_NEXT_COUNTDOWN_S = 6
