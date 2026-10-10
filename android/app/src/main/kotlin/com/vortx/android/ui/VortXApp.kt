package com.vortx.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.DurableWatchReclaimCoordinator
import com.vortx.android.data.DurableWatchedPlaybackReceipt
import com.vortx.android.data.PlaybackSessionLifecycle
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.deeplink.VortXDeepLink
import com.vortx.android.deeplink.VortXDeepLinkEvent
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.WatchedDownloadReclaimRequest
import com.vortx.android.engine.StreamRanking
import com.vortx.android.library.LibraryAutoAdd
import com.vortx.android.moat.WatchSignalClient
import com.vortx.android.model.AuthState
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.model.StreamSource
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.BadSourceAutoRetrySetting
import com.vortx.android.player.DefaultEmber
import com.vortx.android.player.NextEpisodePreloadPolicy
import com.vortx.android.player.NextEpisodePreloadTaskOwner
import com.vortx.android.player.MpvEngineFactory
import com.vortx.android.player.PlayerEngineRouter
import com.vortx.android.player.PlayerEpisodeHistoryIdentity
import com.vortx.android.player.PlayerLaunchPolicy
import com.vortx.android.player.PlayerScreen
import com.vortx.android.player.PlayerEpisodeHandoffRequest
import com.vortx.android.player.advancePlayerEpisodeHistory
import com.vortx.android.profile.ProfileStore
import com.vortx.android.BuildConfig
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.ProfileSelectionHandoff
import com.vortx.android.ui.profilepicker.ProfileSelectionSurface
import com.vortx.android.sources.SourceSettingsRevision
import com.vortx.android.update.UpdatePromptHost
import com.vortx.android.ui.components.Wordmark
import com.vortx.android.ui.gallery.GalleryScreen
import com.vortx.android.ui.prefs.AppearancePrefs
import com.vortx.android.ui.prefs.HomeDiscoverPreferences
import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.prefs.TabSlot
import com.vortx.android.ui.screens.AccountScreen
import com.vortx.android.ui.screens.AddonPairingScreen
import com.vortx.android.ui.screens.AddonStoreScreen
import com.vortx.android.ui.screens.AddonsScreen
import com.vortx.android.ui.screens.AppearanceScreen
import com.vortx.android.stats.WatchStatsScreen
import com.vortx.android.ui.screens.BackupRestoreScreen
import com.vortx.android.ui.screens.CustomizeHomeScreen
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.screens.CinemaQuickViewScreen
import com.vortx.android.ui.screens.DebridKeysScreen
import com.vortx.android.ui.screens.DebridLibraryScreen
import com.vortx.android.ui.screens.DetailScreen
import com.vortx.android.ui.screens.DiscoverScreen
import com.vortx.android.ui.screens.DownloadQueueScreen
import com.vortx.android.ui.screens.DownloadsScreen
import com.vortx.android.ui.screens.HomeDiscoverSettingsScreen
import com.vortx.android.ui.screens.HomeCatalogBrowseScreen
import com.vortx.android.ui.screens.HomeCatalogSnapshotBrowseScreen
import com.vortx.android.ui.screens.HomeScreen
import com.vortx.android.ui.screens.IntegrationsScreen
import com.vortx.android.ui.screens.LiveScreen
import com.vortx.android.ui.screens.LibraryScreen
import com.vortx.android.ui.screens.LibraryTransferScreen
import com.vortx.android.ui.screens.MediaServersScreen
import com.vortx.android.ui.screens.MergedDiscoverSearchScreen
import com.vortx.android.ui.screens.MetadataKeysScreen
import com.vortx.android.ui.screens.PosterStyleScreen
import com.vortx.android.ui.screens.PreviouslyWatchedScreen
import com.vortx.android.ui.screens.PlaybackSettingsScreen
import com.vortx.android.ui.screens.ProfilesScreen
import com.vortx.android.ui.screens.SearchScreen
import com.vortx.android.ui.search.PlayLinkEntry
import com.vortx.android.ui.search.PlayLinkScreen
import com.vortx.android.ui.screens.SettingsScreen
import com.vortx.android.ui.screens.TabBarScreen
import com.vortx.android.iptv.IPTVSettingsScreen
import com.vortx.android.iptv.LiveViewModel
import com.vortx.android.ui.screens.SourcesSettingsScreen
import com.vortx.android.ui.screens.ConfiguredUsenetServersSettingsScreen
import com.vortx.android.ui.screens.ConfiguredNzbIndexerSettingsScreen
import com.vortx.android.ui.screens.UnifiedSignInScreen
import com.vortx.android.ui.screens.WhatsNewScreen
import com.vortx.android.ui.screens.WhosWatchingScreen
import com.vortx.android.ui.screens.WatchlistScreen
import com.vortx.android.sync.AccountLibrarySync
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent
import com.vortx.android.ui.theme.vortxGlassStrip
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.AddonPairingViewModel
import com.vortx.android.ui.viewmodel.AddonStoreViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.DetailViewModel
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.HomeCatalogBrowseViewModel
import com.vortx.android.ui.viewmodel.HomeCatalogTarget
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.LibraryLandingViewModel
import com.vortx.android.ui.viewmodel.Playback
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import com.vortx.android.ui.viewmodel.rememberReplacingViewModelStoreOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/// Auto-add fires at ~60s of playback, matching Apple's `d >= 60` at PlayerScreen.swift:972 and
/// TVPlayerView.swift:810. Expressed in ms because Android reports position in ms.
private const val AUTO_ADD_AFTER_MS = 60_000L

/** One-shot resume intent; type + id prevent an old card tap from arming a colliding later Detail route. */
private data class DirectResumeTarget(val type: MediaType, val id: String)

internal fun detailViewModelKey(
    prefix: String,
    typeId: String,
    mediaId: String,
    ownerEpoch: String,
    preferredEpisode: PreferredEpisode? = null,
): String = "$prefix-$typeId-$mediaId-$ownerEpoch-episode-${detailEpisodeRouteKey(preferredEpisode)}"

/** Makes a route hint part of the ViewModel lifetime without parsing display-only captions. */
internal fun detailEpisodeRouteKey(preferredEpisode: PreferredEpisode?): String {
    val hint = preferredEpisode ?: return "none"
    val identity = hint.videoIdentity.orEmpty()
    return "${hint.season}:${hint.episode}:${identity.length}:$identity"
}

private enum class Tab(
    val label: String,
    val icon: ImageVector,
    val slot: TabSlot,
) {
    HOME("Home", VortXIcons.home, TabSlot.HOME),
    DISCOVER("Discover", VortXIcons.discover, TabSlot.DISCOVER),
    LIVE("Live TV", VortXIcons.live, TabSlot.LIVE),
    LIBRARY("Library", VortXIcons.library, TabSlot.LIBRARY),
    SEARCH("Search", VortXIcons.search, TabSlot.SEARCH),
    ADDONS("Add-ons", VortXIcons.addon, TabSlot.ADDONS),
    SETTINGS("Settings", VortXIcons.settings, TabSlot.SETTINGS),
}

/// The touch app: adaptive tab chrome around one persistent content and detail route owner.
/// [repo] defaults to the offline preview source; the real stremio-core engine is injected here (from
/// `VortXApplication`), with no change to any screen; every screen consumes a ViewModel, and every
/// ViewModel depends only on [CatalogRepository] (or, for the account screen, [AuthRepository]).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VortXApp(
    repo: CatalogRepository = PreviewCatalogRepository(),
    auth: AuthRepository = PreviewAuthRepository(),
    // The app-process VortX account + sync engine (VortXApplication.syncManager). Null in @Previews and
    // when the manager could not be stood up (keystore failure): the VortX Account settings row is then
    // hidden and everything else is unchanged -- sync is off the critical path by design.
    syncManager: VortXSyncManager? = null,
    deepLinkEvent: VortXDeepLinkEvent? = null,
) {
    val appContext = LocalContext.current.applicationContext
    // VortXApplication binds the persistence-backed owner before either the phone or TV launcher creates
    // consumers. Compose only reads the shared binding; it must never redefine process ownership.
    val debridKeys = remember(appContext) { DebridKeys(appContext) }
    val vortxSessionUi by (
        syncManager?.sessionUiState?.collectAsStateWithLifecycle()
            ?: remember { mutableStateOf<VortXSyncManager.SessionUiState?>(null) }
    )
    val profileStore = ProfileStore.sharedOrNull()
    val activeProfile by (
        profileStore?.activeProfile?.collectAsStateWithLifecycle()
            ?: remember { mutableStateOf(null) }
    )
    // Reading the bound identity after collecting account makes Compose reset the debrid editor at the same
    // account transition that every resolver/coordinator/view-model DebridKeys instance observes.
    val debridAccountIdentity = debridKeys.ownerIdentity()
    val debridOwnerEpoch = debridKeys.ownerToken()?.let { "${it.identity}:${it.generation}" } ?: "unknown"
    val debridCredentialRevision by DebridKeys.credentialRevision.collectAsStateWithLifecycle()
    val sourceSettingsRevision by SourceSettingsRevision.observe(appContext).collectAsStateWithLifecycle()
    val detailSourceEpoch = "$debridOwnerEpoch:$debridCredentialRevision:$sourceSettingsRevision"
    val appearancePrefs = remember(appContext) { AppearancePrefs(appContext) }
    val tabBarPrefs = remember(appContext) { TabBarPrefs(appContext) }
    val appearance by appearancePrefs.state.collectAsStateWithLifecycle()
    val hiddenTabs by tabBarPrefs.state.collectAsStateWithLifecycle()

    LaunchedEffect(activeProfile) {
        appearancePrefs.applyProfile(activeProfile)
        // Drain any offline Trakt/SIMKL watchlist pushes that failed earlier. No-ops for an overlay
        // profile and when the queue is empty; runs on the main profile at launch and on each switch back.
        AccountLibrarySync.drainPending(appContext)
    }

    val accentId = activeProfile?.accentID ?: appearance.accentId
    val oled = activeProfile?.oled ?: appearance.oled
    val textScale = (activeProfile?.textScale ?: appearance.textScale)
        .takeIf { it.isFinite() }
        ?.coerceIn(AppearancePrefs.TEXT_SCALE_MIN, AppearancePrefs.TEXT_SCALE_MAX)
        ?: AppearancePrefs.TEXT_SCALE_DEFAULT
    val deviceDensity = LocalDensity.current

    CompositionLocalProvider(
        LocalDensity provides Density(
            density = deviceDensity.density,
            fontScale = deviceDensity.fontScale * textScale.toFloat(),
        ),
    ) {
        VortXTheme(
            accentId = accentId,
            oled = oled,
        ) {
            // WHY audit R02: save enum identity, not ordinal, so shell selection survives process death safely.
            var savedTabName by rememberSaveable { mutableStateOf(Tab.HOME.name) }
            var savedHomeModeName by rememberSaveable { mutableStateOf(CinemaHomeMode.FEATURED.name) }
            val requestedTab = Tab.entries.first { it.slot == cinemaStoredTabSlot(savedTabName) }
            val requestedHomeMode = CinemaHomeMode.entries.firstOrNull { it.name == savedHomeModeName } ?: CinemaHomeMode.FEATURED
            // SD-2: the combined Discover+Search surface folds Search into Discover, so the standalone
            // Search tab is dropped from the bar while the pref is on (Apple `visibleTabs`).
            val homeDiscoverPrefs = remember(appContext) { HomeDiscoverPreferences(appContext) }
            var mergeDiscoverSearch by remember { mutableStateOf(homeDiscoverPrefs.mergeDiscoverSearch) }
            var mergeHomeDiscover by remember { mutableStateOf(homeDiscoverPrefs.mergeHomeDiscover) }
            var cinemaQuickView by remember { mutableStateOf(homeDiscoverPrefs.cinemaQuickView) }
            val route = cinemaTabRoute(requestedTab.slot, requestedHomeMode, hiddenTabs, mergeHomeDiscover, mergeDiscoverSearch)
            val tab = Tab.entries.first { it.slot == route.tab }
            val homeMode = route.homeMode
            val visibleSlots = cinemaVisibleTabs(hiddenTabs, mergeHomeDiscover, mergeDiscoverSearch)
            val visibleTabs = Tab.entries.filter { it.slot in visibleSlots }
            DisposableEffect(homeDiscoverPrefs) {
                val stop = homeDiscoverPrefs.observeChanges {
                    val nextHomeMerge = homeDiscoverPrefs.mergeHomeDiscover
                    if (nextHomeMerge != mergeHomeDiscover) {
                        val currentRoute = cinemaTabRoute(
                            cinemaStoredTabSlot(savedTabName),
                            CinemaHomeMode.entries.firstOrNull { it.name == savedHomeModeName } ?: CinemaHomeMode.FEATURED,
                            tabBarPrefs.state.value, mergeHomeDiscover, mergeDiscoverSearch,
                        )
                        val nextRoute = cinemaRouteAfterHomeMergeChange(currentRoute, nextHomeMerge,
                            homeDiscoverPrefs.mergeDiscoverSearch, tabBarPrefs.state.value)
                        savedTabName = Tab.entries.first { it.slot == nextRoute.tab }.name
                        savedHomeModeName = nextRoute.homeMode.name
                    }
                    mergeDiscoverSearch = homeDiscoverPrefs.mergeDiscoverSearch
                    mergeHomeDiscover = nextHomeMerge
                    cinemaQuickView = homeDiscoverPrefs.cinemaQuickView
                }
                onDispose { stop() }
            }
            LaunchedEffect(route) {
                savedTabName = tab.name
                savedHomeModeName = homeMode.name
            }
        // WHY audit R02: save only the stable route strings, then rehydrate through the deep-link target hook.
        var savedDetailId by rememberSaveable { mutableStateOf<String?>(null) }
        var savedDetailType by rememberSaveable { mutableStateOf<String?>(null) }
        var savedDetailEpisodeSeason by rememberSaveable { mutableStateOf<Int?>(null) }
        var savedDetailEpisodeNumber by rememberSaveable { mutableStateOf<Int?>(null) }
        var savedDetailEpisodeIdentity by rememberSaveable { mutableStateOf<String?>(null) }
        var liveDetailEpisode by remember { mutableStateOf<PreferredEpisode?>(null) }
        var liveDetailAdmission by remember { mutableStateOf<com.vortx.android.home.ContinueWatchingAdmission?>(null) }
        var unavailableContinueWatching by remember { mutableStateOf<String?>(null) }
        val savedDetailPreferredEpisode = remember(
            savedDetailEpisodeSeason,
            savedDetailEpisodeNumber,
            savedDetailEpisodeIdentity,
        ) {
            if (savedDetailEpisodeSeason != null && savedDetailEpisodeNumber != null) {
                PreferredEpisode(
                    season = savedDetailEpisodeSeason!!,
                    episode = savedDetailEpisodeNumber!!,
                    videoIdentity = savedDetailEpisodeIdentity,
                )
            } else {
                null
            }
        }
        val detail = remember(savedDetailId, savedDetailType, savedDetailPreferredEpisode, liveDetailEpisode, liveDetailAdmission) {
            val restoredType = MediaType.entries.firstOrNull { it.id == savedDetailType }
            if (restoredType != null && !savedDetailId.isNullOrEmpty()) {
                VortXDeepLink(restoredType, savedDetailId!!).toMetaItem().copy(
                    preferredEpisode = liveDetailEpisode ?: savedDetailPreferredEpisode,
                    continueWatchingAdmission = liveDetailAdmission,
                )
            } else {
                null
            }
        }
        var pendingDirectResumeTarget by remember { mutableStateOf<DirectResumeTarget?>(null) }
        val openDetail: (MetaItem?) -> Unit = open@{ item ->
            if (item?.continueWatchingAdmission?.isCurrent() == false) return@open
            if (item?.continueWatchingUnavailableMessage != null) {
                unavailableContinueWatching = "${item.name}\n\n${item.continueWatchingUnavailableMessage}"
                return@open
            }
            // Every ordinary Detail route revokes any previous one-shot direct-resume request. Direct
            // Continue Watching callers install their exact target immediately after opening it.
            pendingDirectResumeTarget = null
            savedDetailId = item?.id
            savedDetailType = item?.type?.id
            liveDetailAdmission = item?.continueWatchingAdmission
            liveDetailEpisode = item?.preferredEpisode.takeIf { liveDetailAdmission != null }
            // Remote hints are session-only. Activity restoration preserves the ordinary title route,
            // but neither its hint nor the capability can be restored without the original authority.
            val saveableHint = com.vortx.android.home.saveableContinueWatchingEpisode(item?.preferredEpisode, liveDetailAdmission)
            savedDetailEpisodeSeason = saveableHint?.season
            savedDetailEpisodeNumber = saveableHint?.episode
            savedDetailEpisodeIdentity = saveableHint?.videoIdentity
        }
        unavailableContinueWatching?.let { message ->
            androidx.compose.material3.AlertDialog(onDismissRequest = { unavailableContinueWatching = null },
                title = { Text("Continue Watching") }, text = { Text(message) },
                confirmButton = { androidx.compose.material3.TextButton(onClick = { unavailableContinueWatching = null }) { Text("OK") } })
        }
        var detailGeneration by remember { mutableStateOf(0L) }
        var playing by remember { mutableStateOf<Playable?>(null) }
        // Session-only route chosen on Detail. It rides source retries and episode advances inside the same
        // player, but every non-detail launch below explicitly resets it to Automatic. No preference store is
        // mutated, so one title's choice cannot become the next title's global default.
        var playingEngineOverride by remember {
            mutableStateOf(PlayerLaunchPolicy.defaultPreference(MpvEngineFactory.isBundled))
        }
        val automaticEngineFor: (Playable) -> PlayerEngineRouter.Override = { candidate ->
            PlayerLaunchPolicy.effectivePreference(
                requested = PlayerEngineRouter.Override.AUTO,
                playable = candidate,
                mpvAvailable = MpvEngineFactory.isBundled,
            )
        }
        // "Still watching?" binge streak: consecutive auto-advanced episodes with no manual play between
        // them, so the player can raise the prompt at the binge boundary (Apple `consecutiveAutoAdvances`).
        // Incremented on each Up Next AUTO-advance (countdown expiry), reset on any manual play. A one-element
        // holder so bumping it never itself recomposes.
        val autoAdvanceStreak = remember { intArrayOf(0) }
        val detailVmOwner = rememberReplacingViewModelStoreOwner(
            detail?.let {
                "${it.type}:${it.id}:${detailEpisodeRouteKey(it.preferredEpisode)}:$detailSourceEpoch:${it.continueWatchingAdmission?.let(System::identityHashCode)}"
            } ?: "no-detail:$detailSourceEpoch",
        )
        // The catalog meta of the title currently in [playing], captured at the moment play starts. This is
        // the Android analogue of Apple's `curMeta` (`PlaybackMeta`): [Playable] itself carries only the
        // resolved stream (url/flags/mediaRef), never the library identity, so the auto-add seam below would
        // otherwise have nothing to add. Bound explicitly at each play entrypoint rather than read off the
        // `detail` slot, so an entrypoint with no catalog title (a local download) can never inherit a stale
        // detail and auto-add the WRONG title. Null = an ad-hoc play, which auto-add skips (fail-soft, and
        // exactly what Apple's `let m = curMeta` does).
        var playingMeta by remember { mutableStateOf<MetaDetail?>(null) }
        var showGallery by remember { mutableStateOf(false) }
        var showAccount by remember { mutableStateOf(false) }
        var showVortxAccount by remember { mutableStateOf(false) }
        var showAddons by rememberSaveable { mutableStateOf(false) }
        // Nested under Add-ons: the community store browser and the Install-by-QR pairing sheet. Checked
        // BEFORE the showAddons overlay so they render on top, and cleared on Back to reveal Add-ons.
        var showAddonStore by rememberSaveable { mutableStateOf(false) }
        var showAddonPairing by rememberSaveable { mutableStateOf(false) }
        var showIntegrations by remember { mutableStateOf(false) }
        var showMediaServers by remember { mutableStateOf(false) }
        var showDownloads by remember { mutableStateOf(false) }
        var showWatchlist by remember { mutableStateOf(false) }
        var showPreviouslyWatched by remember { mutableStateOf(false) }
        var catalogBrowseTarget by remember { mutableStateOf<HomeCatalogTarget?>(null) }
        var catalogBrowseIsClientRail by remember { mutableStateOf(false) }
        var quickViewItem by remember { mutableStateOf<MetaItem?>(null) }
        var quickWatchIdentity by remember { mutableStateOf<String?>(null) }
        // Nested under Downloads: the queue manager (reorder / concurrency / storage). Checked BEFORE the
        // showDownloads overlay so it renders on top, and cleared on Back to reveal Downloads underneath.
        var showDownloadQueue by remember { mutableStateOf(false) }
        var showPlayback by remember { mutableStateOf(false) }
        var showSources by remember { mutableStateOf(false) }
        var showUsenetServers by remember { mutableStateOf(false) }
        var showNzbIndexers by remember { mutableStateOf(false) }
        var showMetadataKeys by remember { mutableStateOf(false) }
        var showPosterStyle by remember { mutableStateOf(false) }
        var showHomeDiscover by remember { mutableStateOf(false) }
        var showDebridKeys by remember { mutableStateOf(false) }
        var showDebridLibrary by remember { mutableStateOf(false) }
        var restoreDebridServicesFocus by remember { mutableStateOf(false) }
        val settingsScrollState = rememberScrollState()
        val debridServicesFocusRequester = remember { FocusRequester() }
        var showLiveTv by remember { mutableStateOf(false) }
        var showLibraryTransfer by remember { mutableStateOf(false) }
        var showBackup by remember { mutableStateOf(false) }
        var showProfiles by remember { mutableStateOf(false) }
        var showAppearance by remember { mutableStateOf(false) }
        var showCustomizeHome by remember { mutableStateOf(false) }
        var showTabBar by remember { mutableStateOf(false) }
        var showWatchStats by remember { mutableStateOf(false) }
        var showWhatsNew by remember { mutableStateOf(false) }
        // SD-1: the "Play a link / magnet" sheet, reachable from the top of Search.
        var showPlayLink by remember { mutableStateOf(false) }
        // Cold-launch "Who's watching?" picker (ACC-3): shown once per launch only when there is a real
        // choice (more than one profile, not yet picked). Seeded from ProfileStore.needsPicker at first
        // composition so it never re-appears after the user has picked (select() sets pickedThisLaunch).
        var showWhosWatching by remember { mutableStateOf(profileStore?.needsPicker == true) }
        // SD-2: re-read "Combine Discover & Search" whenever the Home & Discover settings screen closes (the
        // only place it is toggled) so the combined surface flips without a relaunch, matching Apple's
        // reactive @AppStorage. When it turns ON while the (now-dropped) Search tab is selected, heal
        // selection to Discover -- or Home if Discover itself is hidden -- exactly like Apple's
        // `.onChange(of: mergeDiscoverSearch)` healer.
        LaunchedEffect(showHomeDiscover) {
            if (!showHomeDiscover) {
                mergeDiscoverSearch = homeDiscoverPrefs.mergeDiscoverSearch
                mergeHomeDiscover = homeDiscoverPrefs.mergeHomeDiscover
                cinemaQuickView = homeDiscoverPrefs.cinemaQuickView
            }
        }
        // SD-6: per-tab re-tap tokens. The shell bumps one when the ALREADY-active tab is re-tapped, and the
        // active screen scrolls its list to the top in response (Apple `TabScrollToTop`).
        var searchReselect by remember { mutableStateOf(0) }
        var discoverReselect by remember { mutableStateOf(0) }
        LaunchedEffect(deepLinkEvent) {
            val event = deepLinkEvent ?: return@LaunchedEffect
            val target = event.target
            playing = null
            playingMeta = null
            showGallery = false
            showAccount = false
            showVortxAccount = false
            showAddons = false
            showAddonStore = false
            showAddonPairing = false
            showIntegrations = false
            showMediaServers = false
            showDownloads = false
            showWatchlist = false
            showPreviouslyWatched = false
            catalogBrowseTarget = null
            quickViewItem = null
            quickWatchIdentity = null
            showDownloadQueue = false
            showPlayback = false
            showSources = false
            showUsenetServers = false
            showNzbIndexers = false
            showMetadataKeys = false
            showPosterStyle = false
            showHomeDiscover = false
            showDebridKeys = false
            showDebridLibrary = false
            restoreDebridServicesFocus = false
            showLiveTv = false
            showLibraryTransfer = false
            showBackup = false
            showProfiles = false
            showAppearance = false
            showCustomizeHome = false
            showWatchStats = false
            showWhatsNew = false
            showTabBar = false
            showPlayLink = false
            detailGeneration += 1
            openDetail(target.toMetaItem())
        }
        val onItem: (MetaItem) -> Unit = {
            detailGeneration += 1
            openDetail(it)
        }
        val onCinemaItem: (MetaItem) -> Unit = { item ->
            if (com.vortx.android.ui.components.cinemaCardOpensQuickView(item, cinemaQuickView)) {
                quickViewItem = item
            } else {
                onItem(item)
            }
        }
        // A scope tied to the whole shell (not the player overlay), so the end-of-playback engine write
        // (final progress tick + Player unload) still runs after the player leaves composition.
        val appScope = rememberCoroutineScope()
        val playbackSessions = remember(repo, appScope) { PlaybackSessionLifecycle(repo, appScope) }
        // One AccountViewModel for the whole shell (not per-screen-visit like the catalog ViewModels):
        // Settings' Account row summary and the AccountScreen overlay both read the SAME live
        // authState, so a sign-in on one immediately reflects on the other with no extra plumbing.
        val accountVm: AccountViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo, auth = auth))
        val closeDebridKeys: () -> Unit = {
            showDebridKeys = false
            restoreDebridServicesFocus = true
        }

        LaunchedEffect(showDebridKeys, restoreDebridServicesFocus, tab) {
            if (!showDebridKeys && restoreDebridServicesFocus && tab == Tab.SETTINGS) {
                var focused = false
                repeat(3) {
                    if (!focused) {
                        withFrameNanos { }
                        focused = runCatching {
                            debridServicesFocusRequester.requestFocus()
                        }.getOrDefault(false)
                    }
                }
                if (focused) restoreDebridServicesFocus = false
            }
        }

        // The cold-launch profile picker sits ABOVE everything: on a shared account it answers "who is
        // watching" before any content renders. It self-dismisses when the store has nothing to pick.
        var profileSelection by remember { mutableStateOf<ProfileSelectionRequest?>(null) }
        profileSelection?.let { request ->
            val handoff = remember(request, auth) { ProfileSelectionHandoff(auth, BuildConfig.NATIVE_ENGINE_ENABLED) }
            ProfileSelectionSurface(request, handoff,
                onComplete = { profileSelection = null; showWhosWatching = false; showProfiles = false },
                onChooseAgain = { profileSelection = null; showWhosWatching = true; showProfiles = false })
            return@VortXTheme
        }
        if (showWhosWatching) {
            WhosWatchingScreen(onDone = { showWhosWatching = false }, onSelected = { profileSelection = it })
            return@VortXTheme
        }

        // The once-per-launch "update available" popup (sideloaded Android has no store channel). A Dialog,
        // so it floats above whatever screen is showing rather than replacing it; driven by UpdateChecker's
        // prompt flow (set by the launch/hourly check for a newer stable build). Placed after the cold-launch
        // profile picker so it never stacks on top of it. UpdateChecker.start() is kicked in
        // VortXApplication.onCreate, so this only observes.
        UpdatePromptHost()

        // The debug-only design-system gallery (S02) is the topmost overlay when open, above even the
        // detail/player layers below; it is a review tool, not part of the product navigation graph.
        if (showGallery) {
            // Hardware/gesture Back dismisses the overlay instead of exiting the app. Every overlay layer
            // in this shell installs its own BackHandler the same way: with none, the system back (which
            // the manifest opts into via enableOnBackInvokedCallback) falls through to the Activity and
            // finishes it, so Back on any overlay quit the whole app (the device-audit finding).
            BackHandler { showGallery = false }
            GalleryScreen(onBack = { showGallery = false })
            return@VortXTheme
        }

        if (showCustomizeHome) {
            CustomizeHomeScreen(
                preferences = remember(appContext) { com.vortx.android.home.HomeRailPreferences.shared(appContext) },
                onBack = { showCustomizeHome = false },
            )
            return@VortXTheme
        }

        if (showAppearance) {
            BackHandler { showAppearance = false }
            AppearanceScreen(
                prefs = appearancePrefs,
                onCustomizeHome = { showCustomizeHome = true },
                onBack = { showAppearance = false },
            )
            return@VortXTheme
        }

        if (showTabBar) {
            BackHandler { showTabBar = false }
            TabBarScreen(
                prefs = tabBarPrefs,
                onBack = { showTabBar = false },
                mergeHomeDiscover = mergeHomeDiscover,
            )
            return@VortXTheme
        }

        if (showWatchStats) {
            BackHandler { showWatchStats = false }
            WatchStatsScreen(onBack = { showWatchStats = false })
            return@VortXTheme
        }

        if (showWhatsNew) {
            WhatsNewScreen(onBack = { showWhatsNew = false })
            return@VortXTheme
        }

        // Player is the topmost layer: when a source resolves to a Playable, it covers everything and
        // back returns to the detail page underneath.
        val playable = playing
        if (playable != null) {
            // History identity for the engine playback session. An in-player episode switch stays inside
            // the mounted player (it never changes [playing]), so it advances THIS identity instead, which
            // rekeys the session effects below so the new episode gets its own begin/end history session.
            var historyIdentity by remember(playable) {
                mutableStateOf(PlayerEpisodeHistoryIdentity(playable))
            }
            val historyPlayable = historyIdentity.playable
            // Capture the complete owner once with the immutable local context. The repository validates
            // this same token when begin/end run; the reclaim coordinator rechecks it at its final flush.
            val historyOwnerToken = remember(historyIdentity, repo) {
                if (historyPlayable.isTrailer) null else repo.continueWatchingOwner()
            }
            val watchedDownloadReclaim = remember(historyIdentity, historyOwnerToken, appContext, repo) {
                val context = historyPlayable.playbackContext
                if (context == null || !historyPlayable.url.startsWith("file:") || historyOwnerToken == null) {
                    null
                } else {
                    DurableWatchReclaimCoordinator(
                        request = WatchedDownloadReclaimRequest.from(context, historyPlayable.url),
                        capturedOwner = historyOwnerToken,
                        verifyAndReclaim = { receipt, request ->
                            repo.reclaimAfterDurableWatchedPlaybackReceipt(receipt) {
                                if (!DownloadManager.isAutoDeleteWatchedEnabled(appContext)) {
                                    false
                                } else {
                                    DownloadManager.reclaimWatchedDownloadAfterDurableWatchAndDecoderRelease(appContext, request)
                                    true
                                }
                            }
                        },
                    )
                }
            }
            // These sinks capture THIS generation's coordinator before the player sees them. The player
            // retains the exact callback per source/episode generation until its outer holder aggregate
            // is fully released; neither sink may follow a later recomposition into a newer coordinator.
            val reclaimCoordinatorForGeneration = watchedDownloadReclaim
            val onDurableWatchReceipt = remember(reclaimCoordinatorForGeneration, appScope) {
                { receipt: DurableWatchedPlaybackReceipt ->
                    reclaimCoordinatorForGeneration?.let { capturedCoordinator ->
                        appScope.launch(Dispatchers.IO) { capturedCoordinator.onDurableWatch(receipt) }
                    }
                    Unit
                }
            }
            val onWatchedDownloadResourcesReleased = remember(reclaimCoordinatorForGeneration, appScope) {
                {
                    reclaimCoordinatorForGeneration?.let { capturedCoordinator ->
                        appScope.launch(Dispatchers.IO) { capturedCoordinator.onResourcesReleased() }
                    }
                    Unit
                }
            }
            // Freshest reported position/duration (ms) for the save-on-exit write: [0] = position,
            // [1] = duration. Reset when the history identity changes (new source, or a switched episode).
            val lastProgress = remember(historyIdentity) { longArrayOf(0L, 0L) }
            // Auto-add-to-Library (D8). One instance per player session; its own SharedPreferences ledger
            // makes the add idempotent ACROSS playbacks (so a later manual removal sticks), while the latch
            // below keeps it to one attempt WITHIN a playback. Reset per source, mirroring Apple's
            // `autoAddedThisPlayback` being a per-playback @State.
            val autoAdd = remember(appContext) { LibraryAutoAdd(appContext) }
            val autoAddedThisPlayback = remember(playable) { booleanArrayOf(false) }
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
                        viewModelStoreOwner = detailVmOwner,
                        key = detailViewModelKey(
                            prefix = "detail",
                            typeId = showForNext.type.id,
                            mediaId = showForNext.id,
                            ownerEpoch = detailSourceEpoch,
                            preferredEpisode = showForNext.preferredEpisode,
                        ),
                        factory = StremioXViewModelFactory(
                            repo = repo,
                            detailArgs = StremioXViewModelFactory.DetailArgs(
                                showForNext.type,
                                showForNext.id,
                                showForNext.name,
                                showForNext.preferredEpisode,
                                showForNext.continueWatchingAdmission,
                            ),
                            appContext = appContext,
                        ),
                    )
                } else {
                    null
                }
            // Hardware/gesture back pops the player overlay instead of exiting the app. It also
            // revokes an Up Next or retry resolver that may still be running behind the player.
            BackHandler {
                advanceVm?.abandonPlaybackRoute()
                playing = null
            }
            DisposableEffect(historyIdentity, advanceVm) {
                onDispose { advanceVm?.recordLastStreamProgress(lastProgress[0], force = true) }
            }
            // Keep the in-player Sources/Quality sheets live as late add-ons settle. The options themselves
            // come from the ViewModel's unified, filtered, ranked assembly, never from an ad-hoc UI sort.
            val playerSourceState = if (advanceVm != null) {
                advanceVm.streams.collectAsStateWithLifecycle().value
            } else {
                null
            }
            val playerSourceOptions = remember(advanceVm, playerSourceState) {
                advanceVm?.playerSourceOptions().orEmpty()
            }
            val playerQualityOptions = remember(advanceVm, playerSourceState) {
                advanceVm?.playerQualityOptions().orEmpty()
            }
            val playerEpisodeOptions = remember(advanceVm, playerSourceState) {
                advanceVm?.playerEpisodeOptions().orEmpty()
            }
            // PLR-8 next-episode preload policy, owned per player session (reset when an episode is switched
            // or advanced). The task owner makes the fetch itself player-owned: dispose and target replacement
            // cancel its network work rather than merely fencing a stale completion.
            val preloadPolicy = remember(historyIdentity, advanceVm) { NextEpisodePreloadPolicy() }
            val preloadScope = rememberCoroutineScope()
            val preloadTaskOwner = remember(historyIdentity, advanceVm) { NextEpisodePreloadTaskOwner(preloadScope) }
            DisposableEffect(historyIdentity, advanceVm) {
                onDispose {
                    preloadTaskOwner.cancel()
                    preloadPolicy.invalidate()
                }
            }
            // The next episode being offered, set by onEnded. Keyed per playable so advancing into the
            // next episode (a NEW playable) clears the offer automatically.
            var upNext by remember(playable) { mutableStateOf<Episode?>(null) }
            var episodeHandoffSequence by remember(playable) { mutableStateOf(0L) }
            var episodeHandoffRequest by remember(playable) { mutableStateOf<PlayerEpisodeHandoffRequest?>(null) }
            // Bad-source ladder surfaces, keyed per playable DELIBERATELY: a successful retry swaps
            // [playing] to the new source's playable, which resets both to false and closes the
            // overlay on its own. The ladder's cross-retry memory (failed sources + the 3-attempt
            // cap per episode) lives in [DetailViewModel], which survives the swaps.
            var retryingSource by remember(playable) { mutableStateOf(false) }
            var manualSourcePick by remember(playable) { mutableStateOf(false) }
            val playbackSession = remember(historyIdentity) { playbackSessions.newHandle() }
            var retryResumePositionMs by remember(playable) { mutableStateOf(playable.startPositionMs) }
            // Engine playback session: load the Player so progress attributes to the right library item,
            // then end it (final tick + unload + watched-near-end) when the player closes. A TRAILER is not
            // the feature (it must not write a resume position, mark watched, or attribute progress to any
            // library item), so it opens NO engine playback session -- exactly as Apple plays trailers through
            // dedicated player instances that never touch the library. Keyed on the history identity so an
            // in-player episode switch ends the finished episode's session and begins the new one.
            DisposableEffect(historyIdentity) {
                // Bind THIS play's immutable identity into the history session: for a local download
                // the repository must never scrape resident metadata (it may still describe another
                // title); for a stream the context is null and behavior is unchanged. The full owner
                // token is captured SYNCHRONOUSLY here, at play launch, and the repository verifies it
                // under the owner fence when the async begin runs -- any profile/account/principal/
                // revision change in between fails closed instead of retargeting the session.
                if (!historyPlayable.isTrailer) {
                    playbackSessions.begin(playbackSession, historyPlayable.playbackContext, historyOwnerToken)
                }
                onDispose {
                    if (!historyPlayable.isTrailer) {
                        playbackSessions.end(playbackSession, lastProgress[0], lastProgress[1]) { receipt ->
                            onDurableWatchReceipt(receipt)
                        }
                    }
                }
            }
            Box {
                PlayerScreen(
                    playable = playable,
                    engineOverride = playingEngineOverride,
                    onResourcesReleased = onWatchedDownloadResourcesReleased,
                    // "Still watching?" binge boundary: how many episodes auto-advanced to reach this one.
                    autoAdvanceCount = autoAdvanceStreak[0],
                    onBingePrompted = { autoAdvanceStreak[0] = 0 },
                    sourceOptions = playerSourceOptions,
                    qualityOptions = playerQualityOptions,
                    episodeOptions = playerEpisodeOptions,
                    currentSource = advanceVm?.currentPlayerSource(),
                    onSwitchSource = advanceVm?.let { vm ->
                        { source ->
                            // A new explicit source can teach a different release family. Retire warm
                            // scheduling before AND after resolution; the accepted VM commit also
                            // invalidates its published cache, while a failed pick leaves choice intact.
                            preloadTaskOwner.cancel()
                            preloadPolicy.invalidate()
                            try { vm.resolveSourceSwitch(source) } finally {
                                preloadTaskOwner.cancel()
                                preloadPolicy.invalidate()
                            }
                        }
                    },
                    onSwitchEpisode = advanceVm?.let { vm ->
                        { episodeId ->
                            // A manual episode target makes the current warm irrelevant immediately.
                            // The accepted transition re-keys the owner; a failed resolver may later
                            // re-admit a fresh warm through the policy instead of keeping hidden I/O alive.
                            preloadTaskOwner.cancel()
                            vm.resolveEpisodeSwitch(episodeId)
                        }
                    },
                    episodeHandoffRequest = episodeHandoffRequest,
                    onEpisodeHandoffQueued = { sequence ->
                        if (episodeHandoffRequest?.sequence == sequence) episodeHandoffRequest = null
                    },
                    onAudioIntentChanged = { intent ->
                        preloadTaskOwner.cancel()
                        preloadPolicy.invalidate()
                        advanceVm?.notePlaybackAudioIntent(intent.language)
                    },
                    onEpisodeSwitched = { replacement, acceptedRevision, automatic ->
                        autoAdvanceStreak[0] = if (automatic) autoAdvanceStreak[0] + 1 else 0
                        historyIdentity = advancePlayerEpisodeHistory(
                            current = historyIdentity,
                            replacement = replacement,
                            acceptedRevision = acceptedRevision,
                        )
                    },
                    // PLR-8: drive the preload policy on each position tick; when it commits an attempt, warm
                    // the next episode's source off the fence and report the outcome back to the policy. All
                    // policy access stays on this composition dispatcher (the tick and the launch both run on
                    // it), so the plain state machine is never touched concurrently.
                    onWarmNext = onWarmNext@{ pos, dur ->
                        val vm = advanceVm ?: return@onWarmNext
                        val next = vm.nextEpisode() ?: return@onWarmNext
                        val target = NextEpisodePreloadPolicy.Target(
                            episodeId = next.id,
                            generation = historyIdentity.acceptedRevision,
                        )
                        val now = android.os.SystemClock.elapsedRealtime()
                        if (preloadPolicy.isReady(target) && !vm.hasPreparedNextEpisode(next.id)) preloadPolicy.warmFailed(target)
                        val attempt = preloadPolicy.evaluate(target, pos, dur, now) ?: return@onWarmNext
                        preloadTaskOwner.launch(
                            target = target,
                            prepare = { vm.warmNextEpisode(next.id) },
                            onComplete = { ok ->
                                preloadPolicy.complete(attempt, ok, android.os.SystemClock.elapsedRealtime())
                            },
                            timeoutMs = (attempt.deadlineMs - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0L),
                        )
                    },
                    onBack = {
                        advanceVm?.abandonPlaybackRoute()
                        playing = null
                    },
                    onError = {
                        advanceVm?.abandonPlaybackRoute()
                        playing = null
                    },
                    // Natural end of the stream: offer the next episode when the open series has one,
                    // otherwise keep the old exit back to the detail page.
                    onEnded = {
                        val next = advanceVm?.nextEpisode()
                        if (next != null) upNext = next else {
                            advanceVm?.abandonPlaybackRoute()
                            playing = null
                        }
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
                        { positionMs ->
                            retryResumePositionMs = positionMs
                            // SAME-SOURCE TIER FIRST (audit 05.1): a fresh mount of the same source heals
                            // link-shaped failures without a quality/continuity downgrade; hop only after.
                            val healed = advanceVm.retrySameSource(positionMs) || advanceVm.retryNextSource(positionMs)
                            if (healed) retryingSource = true else manualSourcePick = true
                        }
                    } else {
                        null
                    },
                    onProgress = { pos, dur ->
                        lastProgress[0] = pos
                        lastProgress[1] = dur
                        // A trailer reports no progress and never auto-adds to the library (it is not the feature).
                        if (playable.isTrailer) return@PlayerScreen
                        playbackSessions.report(playbackSession, pos, dur)
                        advanceVm?.recordLastStreamProgress(pos)
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
                            // Same 60s "really watching this" moment sends the anonymized fleet watch signal,
                            // exactly as Apple hangs it off the same tick beside the auto-add
                            // (PlayerScreen.swift:1777 / TVPlayerView.swift:1733). Gated only by the pool
                            // consent + a per-title/day dedup INSIDE [WatchSignalClient], independent of the
                            // auto-add-to-Library setting, so the same latch that guards the add covers it once
                            // per playback. A `tmdb:` hub/catalog id resolves to its `tt` identity first
                            // (fire-and-forget); a `tt` id pings inline. Never blocks and fully fail-soft.
                            WatchSignalClient.pingResolvingTmdb(
                                context = appContext,
                                contentId = meta.id,
                                type = meta.type.id,
                                seriesHint = meta.type == MediaType.SERIES,
                            )
                        }
                    },
                )
                // Countdown and Play now enter the mounted player's acknowledged episode handoff.
                // A failure keeps its outgoing revision/history and exposes the exact-target retry.
                val nextEp = upNext
                if (nextEp != null && advanceVm != null) {
                    fun requestNext(automatic: Boolean) {
                        upNext = null
                        episodeHandoffRequest = PlayerEpisodeHandoffRequest(++episodeHandoffSequence, nextEp, automatic)
                    }
                    UpNextOverlay(
                        episode = nextEp,
                        resolving = false,
                        // A countdown-expiry advance is an AUTO-advance: grow the streak so the binge
                        // boundary can fire on the next episode. A manual "Play now" tap or Cancel is
                        // presence, so it resets the streak (Apple's `noteInteraction`). Both paths play.
                        onAutoAdvance = { requestNext(automatic = true) },
                        onPlayNow = { requestNext(automatic = false) },
                        onCancel = {
                            autoAdvanceStreak[0] = 0
                            advanceVm.abandonPlaybackRoute()
                            playing = null
                        },
                    )
                }
                // The bad-source ladder's surfaces + their resolution collector. This is the only
                // [Playback] observer while its overlay is up (the
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
                                if (!manualSourcePick && !advanceVm.retryNextSource(retryResumePositionMs)) {
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
                            onRefind = {
                                advanceVm.refreshSources()
                                playing = null
                            },
                            onClose = {
                                advanceVm.abandonPlaybackRoute()
                                playing = null
                            },
                        )
                    } else {
                        RetryingSourceOverlay()
                    }
                }
            }
            return@VortXTheme
        }

        if (showVortxAccount && syncManager != null) {
            // Settings > VortX Account opens the UNIFIED sign-in surface (ACC-8): the E2E VortX account
            // (sign in / create / recover + cross-device sync + QR joiner, driving the app-process
            // VortXSyncManager) as the PRIMARY block, with the optional Stremio import below it, in one
            // screen. Both blocks are the same card stacks their standalone screens use, so nothing drifts.
            BackHandler { showVortxAccount = false }
            val vortxAccountVm: VortXAccountViewModel =
                viewModel(factory = StremioXViewModelFactory(repo = repo, syncManager = syncManager))
            UnifiedSignInScreen(
                vortxViewModel = vortxAccountVm,
                stremioViewModel = accountVm,
                onBack = { showVortxAccount = false },
            )
            return@VortXTheme
        }

        if (showAccount) {
            // System Back = the screen's own back affordance (dismiss to Settings), never an app exit.
            BackHandler { showAccount = false }
            AccountScreen(viewModel = accountVm, onBack = { showAccount = false })
            return@VortXTheme
        }

        if (showAddonStore) {
            // Nested under Add-ons > Discover: the community collection browser. Rendered on top of the
            // Add-ons overlay; Back reveals Add-ons again.
            BackHandler { showAddonStore = false }
            val storeVm: AddonStoreViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            AddonStoreScreen(viewModel = storeVm, onBack = { showAddonStore = false })
            return@VortXTheme
        }

        if (showAddonPairing) {
            // Nested under Add-ons > Install by QR: the keyboardless pairing sheet (show a QR, a phone
            // pastes manifest URLs, this device installs each).
            BackHandler { showAddonPairing = false }
            val pairingVm: AddonPairingViewModel = viewModel(factory = StremioXViewModelFactory(repo = repo))
            AddonPairingScreen(viewModel = pairingVm, onBack = { showAddonPairing = false })
            return@VortXTheme
        }

        if (showAddons) {
            BackHandler { showAddons = false }
            val addonsVm: AddonsViewModel = viewModel(key = "addons-content", factory = StremioXViewModelFactory(repo = repo))
            AddonsScreen(
                viewModel = addonsVm,
                onBack = { showAddons = false },
                onDiscover = { showAddonStore = true },
                onInstallByQr = { showAddonPairing = true },
            )
            return@VortXTheme
        }

        if (showIntegrations) {
            // Settings > Integrations: connect Trakt / SIMKL, plus the Stremio / Nuvio / list imports and the
            // Stremio mirror toggles. It drives the auth singletons directly and reaches the import sub-screens
            // in-place; [repo] is passed through only so the Stremio/Nuvio batch installers can reuse
            // [CatalogRepository.installAddon] (the same path the Add-ons screen uses).
            BackHandler { showIntegrations = false }
            IntegrationsScreen(repo = repo, onBack = { showIntegrations = false })
            return@VortXTheme
        }

        if (showMediaServers) {
            // Settings > Media servers: connect Plex / Jellyfin / Emby. Self-contained like Integrations
            // (drives the MediaServerRepository singleton directly), so it needs no repository or ViewModel.
            BackHandler { showMediaServers = false }
            MediaServersScreen(onBack = { showMediaServers = false })
            return@VortXTheme
        }

        if (showDownloadQueue) {
            // Settings > Downloads > Manage queue: the download QUEUE manager (reorder / pause / retry /
            // concurrency cap / storage), Android port of Apple's `DownloadQueueView`. Checked BEFORE the
            // showDownloads overlay so it renders on top; Back clears it and reveals Downloads underneath.
            // Self-contained like Downloads (drives the DownloadManager / DownloadStore singletons directly).
            BackHandler { showDownloadQueue = false }
            DownloadQueueScreen(onBack = { showDownloadQueue = false })
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
                onPlay = {
                    playingEngineOverride = automaticEngineFor(it)
                    playing = it
                    playingMeta = null
                    autoAdvanceStreak[0] = 0
                },
                onManageQueue = { showDownloadQueue = true },
            )
            return@VortXTheme
        }

        if (showWatchlist) {
            BackHandler { showWatchlist = false }
            WatchlistScreen(
                store = com.vortx.android.library.WatchlistStore.shared(appContext),
                onBack = { showWatchlist = false },
                onItem = { item ->
                    showWatchlist = false
                    onItem(item)
                },
            )
            return@VortXTheme
        }

        if (showPreviouslyWatched) {
            BackHandler { showPreviouslyWatched = false }
            val historyVm: LibraryLandingViewModel = viewModel(
                key = "library-history",
                factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext),
            )
            PreviouslyWatchedScreen(
                viewModel = historyVm,
                onBack = { showPreviouslyWatched = false },
                onItem = { item ->
                    showPreviouslyWatched = false
                    onItem(item)
                },
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

        if (showUsenetServers) {
            BackHandler { showUsenetServers = false }
            ConfiguredUsenetServersSettingsScreen(onBack = { showUsenetServers = false })
            return@VortXTheme
        }

        if (showNzbIndexers) {
            BackHandler { showNzbIndexers = false }
            ConfiguredNzbIndexerSettingsScreen(onBack = { showNzbIndexers = false })
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

        if (showMetadataKeys) {
            // Settings > Metadata keys (SET-2): three encrypted provider-key fields. Self-contained like the
            // other settings overlays (it constructs its own MetadataProviderKeys secure store), so it needs
            // no repository or ViewModel.
            BackHandler { showMetadataKeys = false }
            MetadataKeysScreen(onBack = { showMetadataKeys = false })
            return@VortXTheme
        }

        if (showPosterStyle) {
            // Settings > Poster Style (poster-artwork lane): width / corner-radius presets + landscape 16:9 +
            // hide-labels, on Apple's exact `stremiox.catalog.*` keys, with a live preview. Self-contained
            // (its own PosterStylePreferences store), so no ViewModel.
            BackHandler { showPosterStyle = false }
            PosterStyleScreen(onBack = { showPosterStyle = false })
            return@VortXTheme
        }

        if (showHomeDiscover) {
            // Settings > Home & Discover (SET-3): content toggles + collections cadence on the shared
            // vortx_settings file. Self-contained (its own HomeDiscoverPreferences store), so no ViewModel.
            BackHandler { showHomeDiscover = false }
            HomeDiscoverSettingsScreen(onBack = { showHomeDiscover = false })
            return@VortXTheme
        }

        if (showPlayLink) {
            // SD-1: the "Play a link / magnet" sheet. Handing back a Playable sets [playing] with a null
            // [playingMeta], so this ad-hoc play never scrobbles or auto-adds to the library (Apple's
            // paste-a-link launch carries no meta either).
            BackHandler { showPlayLink = false }
            PlayLinkScreen(
                repo = repo,
                onPlay = { playable ->
                    playingEngineOverride = automaticEngineFor(playable)
                    playingMeta = null
                    playing = playable
                    showPlayLink = false
                },
                onBack = { showPlayLink = false },
            )
            return@VortXTheme
        }

        if (showDebridKeys) {
            BackHandler(onBack = closeDebridKeys)
            DebridKeysScreen(
                keys = debridKeys,
                accountIdentity = debridAccountIdentity,
                onBack = closeDebridKeys,
            )
            return@VortXTheme
        }

        if (showDebridLibrary) {
            // Settings > Debrid > Your cloud: browse + play what is already in the user's debrid accounts.
            // Self-contained like the other settings overlays: it builds its own DebridCoordinator off the
            // shared [debridKeys] and hands a resolved DIRECT url up to the same `playing` slot the Downloads
            // screen uses, so a chosen cloud item covers everything with the standard player.
            BackHandler { showDebridLibrary = false }
            DebridLibraryScreen(
                keys = debridKeys,
                onPlay = {
                    playingEngineOverride = automaticEngineFor(it)
                    playing = it
                    playingMeta = null
                    showDebridLibrary = false
                },
                onBack = { showDebridLibrary = false },
            )
            return@VortXTheme
        }

        if (showLiveTv) {
            // Settings > Live TV (IPTV): add / remove M3U + Xtream playlists. UNLIKE the self-contained
            // settings overlays it takes [repo], the same way LibraryTransferScreen does: adding installs the
            // converter's manifest through the engine's add-on pipeline and removing uninstalls it, while the
            // playlist record rides the IPTVPlaylists singleton.
            BackHandler { showLiveTv = false }
            IPTVSettingsScreen(repo = repo, onBack = { showLiveTv = false })
            return@VortXTheme
        }

        if (showProfiles) {
            // Settings > Profiles: the "Who's watching?" switcher + create/rename/delete. Self-contained
            // (it drives the ProfileStore singleton directly, whose select() fires the engine reload +
            // Home-rebuild seams), so it needs no repository or ViewModel, matching the other settings
            // overlays. Switching to a non-owner profile only swaps the active selection + its private
            // overlay; the account library is never touched (the never-poison split lives in the store).
            BackHandler { showProfiles = false }
            ProfilesScreen(onBack = { showProfiles = false }, onSelected = { profileSelection = it })
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

        if (showBackup) {
            // Settings > Backup: export/import this device's syncable settings (profiles included) to a file
            // (TV-5). Self-contained like the other settings overlays: it reads/writes the shared
            // `vortx_settings` SharedPreferences directly via SettingsBackup, and never touches account sync.
            BackHandler { showBackup = false }
            BackupRestoreScreen(onBack = { showBackup = false })
            return@VortXTheme
        }

        quickViewItem?.let { item ->
            BackHandler { quickViewItem = null }
            androidx.compose.ui.window.Dialog(
                onDismissRequest = { quickViewItem = null },
                properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
            ) {
            CinemaQuickViewScreen(
                item = item,
                watchlistStore = com.vortx.android.library.WatchlistStore.shared(appContext),
                onClose = { quickViewItem = null },
                onWatch = {
                    quickWatchIdentity = "${item.type.id}:${item.id}"
                    quickViewItem = null
                    catalogBrowseTarget = null
                    onItem(item)
                },
                onDetails = {
                    quickViewItem = null
                    catalogBrowseTarget = null
                    onItem(item)
                },
                modifier = Modifier.widthIn(max = 840.dp).fillMaxWidth(0.94f).fillMaxHeight(0.9f)
                    .clip(com.vortx.android.ui.theme.VortXShapes.card),
            )
            }
        }

        // Home's "See all" grid is a first-class touch route, backed by the same Home board row rather
        // than a second provider request. It sits above the shell and below detail so opening a tile can
        // transfer cleanly into the established detail route.
        catalogBrowseTarget?.let { target ->
            BackHandler { catalogBrowseTarget = null }
            val onBrowseItem: (MetaItem) -> Unit = { item ->
                if (target.id != "continue" && com.vortx.android.ui.components.cinemaCardOpensQuickView(item, cinemaQuickView)) {
                    quickViewItem = item
                } else {
                    catalogBrowseTarget = null
                    onItem(item)
                }
            }
            if (catalogBrowseIsClientRail) {
                HomeCatalogSnapshotBrowseScreen(
                    viewModel = viewModel<HomeViewModel>(factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)),
                    target = target,
                    onBack = { catalogBrowseTarget = null },
                    onItem = onBrowseItem,
                )
                return@VortXTheme
            }
            val catalogVm: HomeCatalogBrowseViewModel = viewModel(
                key = "home-catalog-${target.id}",
                factory = HomeCatalogBrowseViewModel.Creator(repo, target),
            )
            HomeCatalogBrowseScreen(
                viewModel = catalogVm,
                title = target.title,
                onBack = { catalogBrowseTarget = null },
                onItem = onBrowseItem,
            )
            return@VortXTheme
        }

        val current = detail
        if (current != null) {
            // The generation boundary deliberately tears down DetailScreen's local person/nested-title
            // navigation when a new deep-link event targets the same media id again.
            key(current.type, current.id, detailGeneration) {
                // The Compose generation resets local nested-screen state, while the Activity-scoped
                // ViewModel key remains bounded by target and owner. Reopening the same title therefore
                // reuses its ViewModel instead of retaining one live repository subscription per visit.
                val detailVm: DetailViewModel = viewModel(
                    viewModelStoreOwner = detailVmOwner,
                    key = detailViewModelKey(
                        prefix = "detail",
                        typeId = current.type.id,
                        mediaId = current.id,
                        ownerEpoch = detailSourceEpoch,
                        preferredEpisode = current.preferredEpisode,
                    ),
                    factory = StremioXViewModelFactory(
                        repo = repo,
                        detailArgs = StremioXViewModelFactory.DetailArgs(
                            current.type,
                            current.id,
                            current.name,
                            current.preferredEpisode,
                            current.continueWatchingAdmission,
                        ),
                        appContext = appContext,
                    ),
                )
                LaunchedEffect(detailVm, pendingDirectResumeTarget) {
                    val target = pendingDirectResumeTarget
                    if (target?.type == current.type && target.id == current.id) {
                        // One attempt only. Cross-device history frequently has no local exact source;
                        // that case remains a normal Detail screen and must never arm a later visit.
                        detailVm.playLastStream()
                        pendingDirectResumeTarget = null
                    }
                }
                // System Back closes the detail overlay back to the browse shell. Composed BEFORE
                // DetailScreen so the screen's own nested overlay handlers (person page / nested title,
                // DetailScreen.kt) register later and therefore take precedence while they are open.
                BackHandler {
                    detailVm.abandonPlaybackRoute()
                    openDetail(null)
                }
                DetailScreen(
                    viewModel = detailVm,
                    title = current.name,
                    onBack = {
                        detailVm.abandonPlaybackRoute()
                        openDetail(null)
                    },
                    // DetailScreen supplies the successfully loaded MetaDetail, not the provisional
                    // deep-link MetaItem. This keeps auto-add title/poster truth tied to engine metadata.
                    onPlay = { playable, loadedMeta, requestedEngine ->
                        if (detailVm.isRouteAdmissionCurrent()) {
                            playingEngineOverride = PlayerLaunchPolicy.effectivePreference(
                                requested = requestedEngine,
                                playable = playable,
                                mpvAvailable = MpvEngineFactory.isBundled,
                            )
                            playingMeta = loadedMeta
                            playing = playable
                            autoAdvanceStreak[0] = 0
                        } else playable.playbackLease?.close()
                    },
                    autoWatch = quickWatchIdentity == "${current.type.id}:${current.id}",
                    onAutoWatchConsumed = { quickWatchIdentity = null },
                )
            }
            return@VortXTheme
        }

        val factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)
        val authState by accountVm.authState.collectAsStateWithLifecycle()
        BackHandler(enabled = mergeHomeDiscover && tab == Tab.HOME && homeMode == CinemaHomeMode.BROWSE) {
            savedHomeModeName = CinemaHomeMode.FEATURED.name
        }
        BackHandler(enabled = tab == Tab.ADDONS) { savedTabName = Tab.HOME.name }
        val selectTab: (Tab) -> Unit = { destination ->
            val selection = cinemaNavigationSelection(tab.slot, destination.slot)
            if (selection.popToRoot) {
                openDetail(null)
                when (destination) {
                    Tab.SEARCH -> searchReselect++
                    Tab.DISCOVER -> discoverReselect++
                    Tab.HOME -> if (homeMode == CinemaHomeMode.BROWSE) discoverReselect++
                    else -> Unit
                }
            } else {
                savedTabName = destination.name
            }
        }
        val switchProfile: () -> Unit = {
            if (profileStore != null && profileStore.profiles.size > 1) showWhosWatching = true
            else showProfiles = true
        }
        // Resize changes only chrome. The Scaffold/content call remains at this same composition path,
        // preserving screen state, ViewModel keys and effect subscriptions in either window layout.
        BoxWithConstraints(Modifier.fillMaxSize()) {
        val navigation = cinemaWindowNavigation(maxWidth.value, visibleSlots)
        Scaffold(
            topBar = {
                if (navigation.topNavigation) {
                    CinemaWideNavigation(
                        tabs = visibleTabs,
                        selected = tab,
                        onSelect = selectTab,
                        onSwitchProfile = switchProfile,
                    )
                } else if (navigation.usesCompactTitleBar(tab.slot)) {
                    TopAppBar(
                        title = {
                            if (tab == Tab.HOME) Wordmark()
                            else Text(tab.label, style = VortXTheme.type.screenTitle)
                        },
                        actions = {
                            IconButton(onClick = switchProfile, modifier = Modifier.size(48.dp)) {
                                Icon(VortXIcons.profiles, contentDescription = "Switch Profile", tint = VortXTheme.colors.textPrimary)
                            }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = Color.Transparent,
                            scrolledContainerColor = Color.Transparent,
                        ),
                        modifier = Modifier.vortxGlassStrip(),
                    )
                }
            },
            bottomBar = {
                if (!navigation.topNavigation) {
                    CinemaCompactNavigation(navigation = navigation, selected = tab, onSelect = selectTab)
                }
            },
            // OFFLINE SURFACE (audit 12 cross-cut): the phone shell had no offline chip; the TV shell did
            // (TvConnectivity). The pill floats just above the bottom bar whenever the default network
            // loses its VALIDATED capability, debounced so transient drops do not flash it.
            snackbarHost = { OfflineChip(Modifier.padding(VortXTheme.spacing.md)) },
        ) { padding ->
            val content = Modifier.padding(padding)
            // SD-8: Search and Discover unlock on EITHER a Stremio or a VortX sign-in, mirroring Apple's
            // `account.isSignedIn || vortxSync.isSignedIn` gate. Signed out, both show a sign-in prompt.
            val accountSignedIn = authState is AuthState.SignedIn ||
                vortxSessionUi is VortXSyncManager.SessionUiState.SignedIn
            val browseContent: @Composable (Modifier) -> Unit = { browseModifier ->
                if (mergeDiscoverSearch) {
                    MergedDiscoverSearchScreen(
                        discoverViewModel = viewModel<DiscoverViewModel>(factory = factory),
                        searchViewModel = viewModel<SearchViewModel>(factory = factory),
                        onItem = onCinemaItem,
                        modifier = browseModifier,
                        signedIn = accountSignedIn,
                        hideLive = hiddenTabs.hideLive,
                        reselectSignal = discoverReselect,
                        quickActions = {
                            PlayLinkEntry(onClick = { showPlayLink = true }, onDebridLibraryClick = { showDebridLibrary = true })
                        },
                    )
                } else {
                    DiscoverScreen(
                        viewModel = viewModel<DiscoverViewModel>(factory = factory),
                        onItem = onCinemaItem,
                        modifier = browseModifier,
                        signedIn = accountSignedIn,
                        hideLive = hiddenTabs.hideLive,
                        reselectSignal = discoverReselect,
                    )
                }
            }
            when (tab) {
                Tab.HOME -> Column(content.fillMaxSize()) {
                    if (mergeHomeDiscover && !hiddenTabs.hideDiscover) {
                        Row(
                            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                                .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
                            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                        ) {
                            Chip("Featured", homeMode == CinemaHomeMode.FEATURED,
                                onClick = { savedHomeModeName = CinemaHomeMode.FEATURED.name }, modifier = Modifier.heightIn(min = 48.dp))
                            Chip("Discover", homeMode == CinemaHomeMode.BROWSE,
                                onClick = { savedHomeModeName = CinemaHomeMode.BROWSE.name }, modifier = Modifier.heightIn(min = 48.dp))
                        }
                    }
                    if (mergeHomeDiscover && homeMode == CinemaHomeMode.BROWSE) {
                        browseContent(Modifier.weight(1f))
                    } else {
                        HomeScreen(
                            viewModel = viewModel<HomeViewModel>(factory = factory),
                            onItem = onItem,
                            modifier = Modifier.weight(1f),
                            onDirectResume = { item ->
                                openDetail(item)
                                pendingDirectResumeTarget = DirectResumeTarget(item.type, item.id)
                                detailGeneration += 1
                            },
                            onDiscover = if (hiddenTabs.hideDiscover) null else {
                                {
                                    if (mergeHomeDiscover) savedHomeModeName = CinemaHomeMode.BROWSE.name
                                    else savedTabName = Tab.DISCOVER.name
                                }
                            },
                            onBrowseCatalog = { catalog ->
                                catalogBrowseIsClientRail = catalog.engineIndex == null
                                catalogBrowseTarget = HomeCatalogTarget(catalog.id, catalog.title)
                            },
                            onCatalogItem = onCinemaItem,
                            onQuickView = { item -> quickViewItem = item },
                        )
                    }
                }
                Tab.DISCOVER -> browseContent(content)
                Tab.LIVE -> LiveScreen(viewModel<LiveViewModel>(factory = factory), onItem, content)
                Tab.LIBRARY -> LibraryScreen(
                    viewModel = viewModel<LibraryViewModel>(factory = factory),
                    landingViewModel = viewModel<LibraryLandingViewModel>(key = "library-history", factory = factory),
                    onItem = onCinemaItem,
                    modifier = content,
                    onDirectResume = { item ->
                        openDetail(item)
                        pendingDirectResumeTarget = DirectResumeTarget(item.type, item.id)
                        detailGeneration += 1
                    },
                    onDownloads = { showDownloads = true },
                    onWatchlist = { showWatchlist = true },
                    onPreviouslyWatched = { showPreviouslyWatched = true },
                )
                Tab.SEARCH -> SearchScreen(
                    viewModel<SearchViewModel>(factory = factory),
                    onCinemaItem,
                    content,
                    signedIn = accountSignedIn,
                    reselectSignal = searchReselect,
                    leadingSlot = {
                        PlayLinkEntry(
                            onClick = { showPlayLink = true },
                            onDebridLibraryClick = { showDebridLibrary = true },
                        )
                    },
                )
                Tab.ADDONS -> AddonsScreen(
                    // The direct destination and legacy Settings overlay share one content owner.
                    viewModel = viewModel<AddonsViewModel>(key = "addons-content", factory = factory),
                    onBack = { savedTabName = Tab.HOME.name },
                    // This screen owns its compact toolbar. Consume shell padding so that toolbar
                    // never reapplies the status inset, including under persistent wide navigation.
                    modifier = content.consumeWindowInsets(padding),
                    onDiscover = { showAddonStore = true },
                    onInstallByQr = { showAddonPairing = true },
                )
                Tab.SETTINGS -> SettingsScreen(
                    authState = authState,
                    // The VortX account row: live signed-in summary straight off the sync manager's
                    // account flow. Null manager (preview / keystore failure) hides the row entirely.
                    // The conditional collect is safe: [syncManager] is process-constant, so the
                    // composition never flips between the two branches.
                    vortxAccountValue = syncManager?.let {
                        when (val session = vortxSessionUi) {
                            is VortXSyncManager.SessionUiState.SignedIn ->
                                session.account.username.ifEmpty { session.account.email }
                            VortXSyncManager.SessionUiState.SignedOut -> "Not signed in"
                            VortXSyncManager.SessionUiState.UnknownOrUnavailable ->
                                "Secure session unavailable · Tap to retry"
                            null -> "Secure session unavailable · Tap to retry"
                        }
                    },
                    onVortxAccountClick = {
                        if (vortxSessionUi == VortXSyncManager.SessionUiState.UnknownOrUnavailable) {
                            syncManager?.retrySessionRestore()
                        } else {
                            showVortxAccount = true
                        }
                    },
                    onProfilesClick = { showProfiles = true },
                    onAppearanceScreenClick = { showAppearance = true },
                    onTabBarScreenClick = { showTabBar = true },
                    onAccountClick = { showAccount = true },
                    onAddonsClick = { showAddons = true },
                    onIntegrationsClick = { showIntegrations = true },
                    onMediaServersClick = { showMediaServers = true },
                    onLiveTvClick = { showLiveTv = true },
                    onDownloadsClick = { showDownloads = true },
                    onPlaybackClick = { showPlayback = true },
                    onSourcesClick = { showSources = true },
                    onUsenetServersClick = { showUsenetServers = true },
                    onNzbIndexersClick = { showNzbIndexers = true },
                    onMetadataKeysClick = { showMetadataKeys = true },
                    onPosterStyleClick = { showPosterStyle = true },
                    onHomeDiscoverClick = { showHomeDiscover = true },
                    onDebridKeysScreenClick = {
                        restoreDebridServicesFocus = false
                        showDebridKeys = true
                    },
                    onLibraryClick = { showLibraryTransfer = true },
                    onBackupClick = { showBackup = true },
                    onWatchStatsClick = { showWatchStats = true },
                    onWhatsNewClick = { showWhatsNew = true },
                    settingsScrollState = settingsScrollState,
                    debridServicesFocusRequester = debridServicesFocusRequester,
                    modifier = content,
                    onOpenGallery = { showGallery = true },
                )
            }
        }
        }
    }
    }
}

@Composable
private fun CinemaWideNavigation(
    tabs: List<Tab>,
    selected: Tab,
    onSelect: (Tab) -> Unit,
    onSwitchProfile: () -> Unit,
) {
    val tabsState = rememberLazyListState()
    LaunchedEffect(selected, tabs) {
        val index = tabs.indexOf(selected)
        if (index >= 0) tabsState.scrollToItem(index)
    }
    Box(
        modifier = Modifier.fillMaxWidth().vortxGlassStrip().statusBarsPadding(),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier.widthIn(max = 1_200.dp).fillMaxWidth()
                .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Wordmark()
            LazyRow(
                state = tabsState,
                modifier = Modifier.weight(1f).selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                items(tabs, key = { it.name }) { destination ->
                    Chip(
                        label = destination.label,
                        selected = destination == selected,
                        onClick = { onSelect(destination) },
                        leadingIcon = destination.icon,
                        modifier = Modifier.heightIn(min = 48.dp),
                    )
                }
            }
            IconButton(onClick = onSwitchProfile, modifier = Modifier.size(48.dp)) {
                Icon(VortXIcons.profiles, contentDescription = "Switch Profile", tint = VortXTheme.colors.textPrimary)
            }
        }
    }
}

@Composable
private fun CinemaCompactNavigation(
    navigation: CinemaWindowNavigation,
    selected: Tab,
    onSelect: (Tab) -> Unit,
) {
    var moreExpanded by remember { mutableStateOf(false) }
    val colors = VortXTheme.colors
    val itemColors = NavigationBarItemDefaults.colors(
        selectedIconColor = colors.accentBright,
        selectedTextColor = colors.accentBright,
        indicatorColor = colors.accentSoft,
        unselectedIconColor = colors.textSecondary,
        unselectedTextColor = colors.textSecondary,
    )
    NavigationBar(
        containerColor = Color.Transparent,
        tonalElevation = 0.dp,
        modifier = Modifier.vortxGlassStrip(),
    ) {
        navigation.primary.forEach { slot ->
            val destination = Tab.entries.first { it.slot == slot }
            key(destination.name) {
                NavigationBarItem(
                    selected = destination == selected,
                    onClick = { onSelect(destination) },
                    icon = { Icon(destination.icon, contentDescription = null) },
                    label = { Text(destination.label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    colors = itemColors,
                    modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = destination.label },
                )
            }
        }
        if (navigation.overflow.isNotEmpty()) {
            val overflowSelected = navigation.selectsOverflow(selected.slot)
            key("navigation-more") {
                NavigationBarItem(
                    selected = overflowSelected,
                    onClick = { moreExpanded = true },
                    icon = {
                        Box {
                            Icon(if (overflowSelected) selected.icon else VortXIcons.moreHoriz, contentDescription = null)
                            DropdownMenu(
                                expanded = moreExpanded,
                                onDismissRequest = { moreExpanded = false },
                                containerColor = Color.Transparent,
                                modifier = Modifier.heightIn(max = 480.dp).vortxGlassPanel(RoundedCornerShape(20.dp)),
                            ) {
                                navigation.overflow.forEach { slot ->
                                    val destination = Tab.entries.first { it.slot == slot }
                                    key(destination.name) {
                                        DropdownMenuItem(
                                            text = { Text(destination.label, color = colors.textPrimary) },
                                            leadingIcon = {
                                                Icon(destination.icon, contentDescription = null,
                                                    tint = if (destination == selected) colors.accentBright else colors.textSecondary)
                                            },
                                            trailingIcon = {
                                                if (destination == selected) Icon(VortXIcons.checkmarkCircle, contentDescription = "Selected", tint = colors.accentBright)
                                            },
                                            onClick = { moreExpanded = false; onSelect(destination) },
                                            modifier = Modifier.heightIn(min = 48.dp),
                                        )
                                    }
                                }
                            }
                        }
                    },
                    label = { Text(if (overflowSelected) selected.label else "More", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    colors = itemColors,
                    modifier = Modifier.heightIn(min = 48.dp).semantics {
                        contentDescription = "More destinations"
                        stateDescription = if (overflowSelected) selected.label else "Opens navigation menu"
                    },
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
    /// Fired instead of [onPlayNow] when the COUNTDOWN expires (an automatic advance), so the host can
    /// distinguish an unattended binge from a deliberate "Play now" tap. Both ultimately play the episode.
    onAutoAdvance: () -> Unit = onPlayNow,
) {
    var secondsLeft by remember(episode.id) { mutableStateOf(UP_NEXT_COUNTDOWN_S) }
    // Latched once the advance has been kicked (countdown expiry OR the Play-now tap), so neither path
    // can double-fire the other.
    var fired by remember(episode.id) { mutableStateOf(false) }
    val currentOnPlayNow by rememberUpdatedState(onPlayNow)
    val currentOnAutoAdvance by rememberUpdatedState(onAutoAdvance)
    LaunchedEffect(episode.id) {
        while (secondsLeft > 0) {
            delay(1_000)
            secondsLeft--
        }
        if (!fired) {
            fired = true
            currentOnAutoAdvance()
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
    onRefind: () -> Unit,
    onClose: () -> Unit,
) {
    val firstSourceFocus = remember { FocusRequester() }
    val closeFocus = remember { FocusRequester() }
    // Move remote focus away from the covered player. Back remains reachable while resolving,
    // and a failed resolve returns focus to the re-enabled source list on the next frame.
    LaunchedEffect(sources.firstOrNull()?.id, resolving) {
        withFrameNanos { }
        runCatching {
            if (sources.isNotEmpty() && !resolving) firstSourceFocus.requestFocus()
            else closeFocus.requestFocus()
        }
    }
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
                                .then(manualSourceControlFocus(if (source.id == sources.firstOrNull()?.id) firstSourceFocus else null))
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
            // Re-find is the escape hatch when the ranked ladder is exhausted: re-query the add-ons fresh
            // (all logic in [DetailViewModel.refreshSources]) so expired/dead sources are replaced, then
            // drop back to the detail page where the fresh, re-ranked list appears. Back keeps today's exit.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Re-find sources",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .then(manualSourceControlFocus())
                        .clickable(enabled = !resolving, onClick = onRefind)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                )
                Text(
                    text = if (resolving) "Cancel loading" else "Back",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .then(manualSourceControlFocus(closeFocus))
                        .clickable(onClick = onClose)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun manualSourceControlFocus(requester: FocusRequester? = null): Modifier {
    var focused by remember { mutableStateOf(false) }
    return Modifier
        .then(if (requester != null) Modifier.focusRequester(requester) else Modifier)
        .onFocusChanged { focused = it.isFocused }
        .border(2.dp, if (focused) DefaultEmber else Color.Transparent, RoundedCornerShape(10.dp))
}

/// Seconds the Up Next overlay counts down before auto-playing the next episode. Long enough to cancel,
/// short enough that a binge never waits.
private const val UP_NEXT_COUNTDOWN_S = 6
