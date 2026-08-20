package com.vortx.android.ui.tv

import android.Manifest
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.R
import com.vortx.android.BuildConfig
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.skip.SkipConfig
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.prefs.TabBarPrefs
import com.vortx.android.ui.screens.AccountContent
import com.vortx.android.ui.screens.AppearanceScreen
import com.vortx.android.ui.screens.HomeDiscoverSettingsScreen
import com.vortx.android.ui.screens.IntegrationsScreen
import com.vortx.android.ui.screens.MediaServersScreen
import com.vortx.android.ui.screens.MetadataKeysScreen
import com.vortx.android.ui.screens.PlaybackSettingsScreen
import com.vortx.android.ui.screens.SourcesSettingsScreen
import com.vortx.android.iptv.IPTVSettingsScreen
import com.vortx.android.ui.prefs.AppearancePrefs
import com.vortx.android.trickplay.CommunityTrickplay
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import com.vortx.android.home.HomeRailPreferences
import com.vortx.android.notifications.NewEpisodeNotifications
import com.vortx.android.update.UpdateAvailableBanner
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.model.VideoUpscaling
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.AutoAddLibrarySetting
import com.vortx.android.player.MatchFrameRateSetting
import com.vortx.android.player.MpvEngineFactory
import com.vortx.android.player.PlaybackBehaviorSettings
import com.vortx.android.player.PerformanceMode
import com.vortx.android.player.SubtitleStyle
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.tv.TopShelfSettings
import com.vortx.android.tv.WatchNextPublisher
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonPairingViewModel
import com.vortx.android.ui.viewmodel.AddonStoreViewModel
import com.vortx.android.ui.viewmodel.AddonsViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

/// TV Settings: a focusable 10-foot list surfacing the couch-relevant toggles PLUS the "Who's watching?"
/// profile switcher. Every playback control writes through the EXACT SAME store the phone Settings and the
/// player read: [AudioOutputMode], [PerformanceMode], [AutoAddLibrarySetting], [SubtitleStyle],
/// [TrackPreferencesStore], and [PlaybackBehaviorSettings]. A couch change and a phone change therefore
/// write the SAME value in `vortx_settings`. There are no TV-only settings keys.
///
/// PROFILE SWITCHING (this round): the roster is now focusable and switchable from the couch. Tapping a
/// profile calls [ProfileStore.select], which applies its theme/filters, fires the engine reload +
/// Home-rebuild seams, and swaps in that profile's private watch overlay -- the account library is never
/// touched (`EngineStremioRepository.overlayProfiles()` gates every watch path: the never-poison split). A
/// PIN-gated profile prompts for its PIN through a 10-foot numeric keypad before switching, so a Kids profile
/// cannot walk into a locked parent profile from the remote. [ProfileStore] exposes plain main-thread fields
/// (Apple's `@Published` analogue, no Flow), so this screen bumps a local counter after a switch to re-read
/// `profiles` / `activeID`.
///
/// SCOPE, honestly: this ships the primary 10-foot toggles a viewer changes from the couch plus profile
/// SWITCHING. Creating / renaming / deleting a profile stays on the phone/tablet app for now (text entry is a
/// touch job); add-ons and debrid API keys have their own nested TV routes, while the remaining deep phone-only surfaces
/// (Account sign-in, Integrations, Media servers, advanced subtitle styling, Sources ranking,
/// Downloads, Library transfer) are named at the foot of the list rather than reproduced. Binding a profile
/// to its own separate account is not wired on Android yet, so a
/// [ProfileStore.select] returning `SwitchAccount` / `NeedsSignIn` is surfaced as a note.
@Composable
fun TvSettingsScreen(
    repo: CatalogRepository,
    modifier: Modifier = Modifier,
    auth: AuthRepository = PreviewAuthRepository(),
    syncManager: VortXSyncManager? = null,
) {
    val appContext = LocalContext.current.applicationContext
    val homeRailPreferences = remember(appContext) { HomeRailPreferences.shared(appContext) }
    val debridKeys = remember(appContext) { DebridKeys(appContext) }
    val trackStore = remember(appContext) {
        TrackPreferencesStore(appContext, PerformanceMode.isConstrainedDevice(appContext))
    }
    // The tab-visibility store is the SAME one the phone Tab bar screen and the TV shell read (TabBarPrefs,
    // keys `vortx.tabs.hide.*`); toggling here moves the exact value the rail filters on.
    val tabBarPrefs = remember(appContext) { TabBarPrefs(appContext) }
    val tabState by tabBarPrefs.state.collectAsStateWithLifecycle()
    // The crowd skip-provider choice is a preference (`stremiox.skipProvider`), the same key/default the
    // player read path uses; init is idempotent.
    LaunchedEffect(appContext) { SkipConfig.init(appContext) }
    var skipProvider by remember { mutableStateOf(SkipConfig.provider) }
    var route by remember { mutableStateOf(TvSettingsRoute.ROOT) }
    val settingsListState = rememberLazyListState()
    val debridServicesFocus = remember { FocusRequester() }
    val addonsFocus = remember { FocusRequester() }
    var restoreFocusTarget by remember { mutableStateOf<TvDebridFocusTarget?>(null) }
    var restoreAddonsFocus by remember { mutableStateOf(false) }

    // Seed each control from its store once; write through on every change. There is no reactive prefs stream
    // in these modules and none is needed -- the values are read at player load, so a write-through keeps the
    // UI and the engine in step, exactly as the phone Playback screen does.
    var audioMode by remember { mutableStateOf(AudioOutputMode.current(appContext)) }
    var performance by remember { mutableStateOf(PerformanceMode.currentOverride(appContext)) }
    var autoAdd by remember { mutableStateOf(AutoAddLibrarySetting.isEnabled(appContext)) }
    var subtitleStyle by remember { mutableStateOf(SubtitleStyle.current(appContext)) }
    var subtitlesOnlyPreferred by remember { mutableStateOf(trackStore.subtitlesOnlyPreferred) }
    var videoUpscaling by remember { mutableStateOf(trackStore.videoUpscaling) }
    var autoSkip by remember { mutableStateOf(PlaybackBehaviorSettings.autoSkip(appContext)) }
    var directLinksOnly by remember {
        mutableStateOf(PlaybackBehaviorSettings.directLinksOnly(appContext))
    }
    // TV-2: the Play Next "Continue Watching" row Show/Hide toggle. Seeded from the same key the publisher
    // reads; turning it off clears the published rows immediately (an on flip republishes on the next CW tick).
    var showCwOnHome by remember { mutableStateOf(TopShelfSettings.showContinueWatching(appContext)) }
    // New-episode alerts (F5), same key `stremiox.notifyNewEpisodes` as every other surface. Enabling arms
    // the library sweep and (API 33+) requests POST_NOTIFICATIONS in context.
    var notifyNewEpisodes by remember { mutableStateOf(NewEpisodeNotifications.isEnabled(appContext)) }
    val notifyPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* the schedule already stands; the post is permission-gated at fire time */ }
    // Match Frame Rate (AFR): the cheap fix. The controller ([MatchFrameRateSetting], key
    // `vortx.player.matchFrameRate`, read per play at PlayerScreen) was wired but NO UI wrote the key, so it
    // could never be turned on. This is its first (and the natural 10-foot) writer: refresh-rate matching is a
    // TV-panel setting. Same key/default as Apple, so the account restores one value.
    var matchFrameRate by remember { mutableStateOf(MatchFrameRateSetting.isEnabled(appContext)) }
    // Community scrub previews (trickplay contribution). The read side existed on the same key Apple writes
    // (`stremiox.communityTrickplay`); this row is its first writer via the new [CommunityTrickplay.setEnabled].
    var communityScrub by remember { mutableStateOf(CommunityTrickplay.isEnabled(appContext)) }
    // The 10-foot settings search: filters which sections render. Blank shows everything.
    var settingsQuery by remember { mutableStateOf("") }

    val store = ProfileStore.sharedOrNull()
    // Bumped after a switch to force a fresh read of the plain (non-observable) store fields.
    var refresh by remember { mutableStateOf(0) }
    val roster = remember(refresh) { store?.profiles ?: emptyList() }
    val activeId = remember(refresh) { store?.activeID }
    val debridAccountIdentity = remember(refresh) {
        store?.activeKeychainAccount ?: ProfileStore.PRIMARY_TOKEN_ACCOUNT
    }
    var pinTarget by remember { mutableStateOf<UserProfile?>(null) }
    var status by remember { mutableStateOf<String?>(null) }

    fun returnToSettingsRoot() {
        route = route.back()
        restoreFocusTarget = tvDebridFocusTarget(TvDebridFocusEvent.BACK_TO_SETTINGS)
    }

    fun returnFromAddons() {
        route = route.back()
        restoreAddonsFocus =
            tvAddonsFocusTarget(TvAddonsFocusEvent.BACK_TO_SETTINGS) == TvAddonsFocusTarget.SETTINGS_ADDONS
    }

    if (route == TvSettingsRoute.ADDON_STORE) {
        BackHandler { route = TvSettingsRoute.ADDONS }
        val storeVm: AddonStoreViewModel = viewModel<AddonStoreViewModel>(
            factory = StremioXViewModelFactory(repo = repo),
        )
        TvAddonStoreScreen(
            viewModel = storeVm,
            onBack = { route = TvSettingsRoute.ADDONS },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.ADDON_PAIRING) {
        BackHandler { route = TvSettingsRoute.ADDONS }
        val pairingVm: AddonPairingViewModel = viewModel<AddonPairingViewModel>(
            factory = StremioXViewModelFactory(repo = repo),
        )
        TvAddonPairingScreen(
            viewModel = pairingVm,
            onBack = { route = TvSettingsRoute.ADDONS },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.ADDONS) {
        BackHandler { returnFromAddons() }
        val addonsVm: AddonsViewModel = viewModel<AddonsViewModel>(
            factory = StremioXViewModelFactory(repo = repo),
        )
        TvAddonsScreen(
            viewModel = addonsVm,
            onBack = ::returnFromAddons,
            onDiscover = { route = TvSettingsRoute.ADDON_STORE },
            onInstallByQr = { route = TvSettingsRoute.ADDON_PAIRING },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.DEBRID) {
        BackHandler { returnToSettingsRoot() }
        TvDebridKeysScreen(
            keys = debridKeys,
            accountIdentity = debridAccountIdentity,
            onBack = ::returnToSettingsRoot,
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.WHATS_NEW) {
        TvWhatsNewScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.CUSTOMIZE_HOME) {
        TvCustomizeHomeScreen(
            preferences = homeRailPreferences,
            onBack = { route = TvSettingsRoute.ROOT },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.ACCOUNT) {
        BackHandler { route = TvSettingsRoute.ROOT }
        TvAccountRoute(
            repo = repo,
            auth = auth,
            syncManager = syncManager,
            onBack = { route = TvSettingsRoute.ROOT },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.IMPORT_STREMIO) {
        BackHandler { route = TvSettingsRoute.ROOT }
        TvStremioImportRoute(
            repo = repo,
            auth = auth,
            onBack = { route = TvSettingsRoute.ROOT },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.INTEGRATIONS) {
        // Trakt / SIMKL plus the Stremio / Nuvio / list-import surfaces. The auth flows drive the singletons
        // directly; the import cards need the repository to install add-ons and register imported list rows,
        // so the screen takes [repo] -- reused verbatim from the phone.
        BackHandler { route = TvSettingsRoute.ROOT }
        IntegrationsScreen(repo = repo, onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.METADATA) {
        // TMDB / OMDB metadata keys. Self-contained like Integrations; reused verbatim from the phone.
        BackHandler { route = TvSettingsRoute.ROOT }
        MetadataKeysScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    // The deep configuration surfaces reuse the EXACT phone screens behind a D-pad route, so every control
    // reads and writes the identical `vortx_settings` keys the phone and Apple write -- a couch change and a
    // phone change are the same value. Each phone screen is self-contained (it builds its own stores) and takes
    // only an `onBack`, except Appearance (an injected `AppearancePrefs` + a Customize-Home hop) and IPTV (the
    // catalog repository), mirrored here exactly as the phone nav constructs them.
    if (route == TvSettingsRoute.APPEARANCE) {
        BackHandler { route = TvSettingsRoute.ROOT }
        AppearanceScreen(
            prefs = remember(appContext) { AppearancePrefs(appContext) },
            onCustomizeHome = { route = TvSettingsRoute.CUSTOMIZE_HOME },
            onBack = { route = TvSettingsRoute.ROOT },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.HOME_DISCOVER) {
        BackHandler { route = TvSettingsRoute.ROOT }
        HomeDiscoverSettingsScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.MEDIA_SERVERS) {
        BackHandler { route = TvSettingsRoute.ROOT }
        MediaServersScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.IPTV) {
        // Live TV: add / remove M3U + Xtream playlists. Needs the catalog repository (the converter output
        // installs as a normal add-on), exactly like the phone nav's IPTVSettingsScreen call.
        BackHandler { route = TvSettingsRoute.ROOT }
        IPTVSettingsScreen(repo = repo, onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.PLAYBACK) {
        BackHandler { route = TvSettingsRoute.ROOT }
        PlaybackSettingsScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.SOURCES) {
        BackHandler { route = TvSettingsRoute.ROOT }
        SourcesSettingsScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    if (route == TvSettingsRoute.BACKUP) {
        // Backup / restore IS the VortX account QR pairing on a TV (no D-pad file picker), mirroring Apple TV
        // BackupExportView / BackupImportView. Built from the SAME sync manager the Account route uses.
        BackHandler { route = TvSettingsRoute.ROOT }
        val vortxVm: VortXAccountViewModel? = if (syncManager != null) {
            viewModel(factory = StremioXViewModelFactory(repo = repo, syncManager = syncManager))
        } else {
            null
        }
        TvBackupRestoreScreen(
            vortxViewModel = vortxVm,
            onBack = { route = TvSettingsRoute.ROOT },
            modifier = modifier,
        )
        return
    }

    if (route == TvSettingsRoute.DIAGNOSTICS) {
        BackHandler { route = TvSettingsRoute.ROOT }
        TvDiagnosticsScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)
        return
    }

    fun commitSwitch(profile: UserProfile) {
        if (store == null) return
        status = null
        when (store.select(profile)) {
            ProfileStore.SwitchOutcome.SameAccount -> Unit
            is ProfileStore.SwitchOutcome.SwitchAccount ->
                status = "Now watching as ${profile.name}. Per-profile sign-in isn't wired on Android yet, " +
                    "so this profile keeps the current session."
            ProfileStore.SwitchOutcome.NeedsSignIn ->
                status = "Now watching as ${profile.name}. This profile has its own account; per-profile " +
                    "sign-in isn't available on Android yet."
        }
        refresh++
    }

    // A section renders when the search field is blank, or when the query matches any of the section's terms
    // (its title plus the labels a viewer might type). Case-insensitive substring; trimmed. Keeps the couch
    // search dumb-simple and never hides a section the query names.
    val trimmedQuery = settingsQuery.trim()
    fun show(vararg terms: String): Boolean =
        trimmedQuery.isEmpty() || terms.any { it.contains(trimmedQuery, ignoreCase = true) }

    Box(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            state = settingsListState,
            contentPadding = PaddingValues(TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(TvDimens.rowGap),
        ) {
            item { TvProfileHeader(store?.active) }

            item {
                TvSettingsSearchField(query = settingsQuery, onQueryChange = { settingsQuery = it })
            }

            if (roster.isNotEmpty() && show("who's watching", "profile", "switch profile", "kids")) {
                item {
                    TvSettingsSection("Who's watching") {
                        roster.forEach { profile ->
                            TvProfileRow(
                                profile = profile,
                                isActive = profile.id == activeId,
                                onClick = {
                                    when {
                                        profile.id == activeId -> Unit          // already active
                                        profile.hasPin -> pinTarget = profile    // gate the switch on the PIN
                                        else -> commitSwitch(profile)
                                    }
                                },
                            )
                        }
                    }
                }
            }

            if (show("account", "sign in", "sign-in", "stremio", "trakt", "simkl", "metadata", "tmdb", "omdb")) item {
                TvSettingsSection("Account") {
                    TvSettingsNavigationRow(
                        label = "Account & sign-in",
                        detail = "Sign in to VortX by scanning a code for cross-device sync, or connect Stremio.",
                        onClick = { route = TvSettingsRoute.ACCOUNT },
                    )
                    TvSettingsNavigationRow(
                        label = "Import from Stremio",
                        detail = "Sign in to Stremio to bring in your library and add-ons.",
                        onClick = { route = TvSettingsRoute.IMPORT_STREMIO },
                    )
                    TvSettingsNavigationRow(
                        label = "Trakt & SIMKL",
                        detail = "Connect Trakt or SIMKL to scrobble and sync watched history.",
                        onClick = { route = TvSettingsRoute.INTEGRATIONS },
                    )
                    TvSettingsNavigationRow(
                        label = "Metadata keys",
                        detail = "Add your own TMDB / OMDB keys for ratings and artwork.",
                        onClick = { route = TvSettingsRoute.METADATA },
                    )
                }
            }

            if (show(
                    "appearance", "theme", "accent", "oled", "text size", "app language",
                    "home", "discover", "collections", "spoiler", "poster", "continue watching",
                )
            ) item {
                TvSettingsSection("Appearance") {
                    TvSettingsNavigationRow(
                        label = "Theme & text size",
                        detail = "Accent color, OLED black, app language, and text size.",
                        onClick = { route = TvSettingsRoute.APPEARANCE },
                    )
                    TvSettingsNavigationRow(
                        label = "Home & Discover",
                        detail = "Home rows, collections hub, and spoiler-safe mode.",
                        onClick = { route = TvSettingsRoute.HOME_DISCOVER },
                    )
                    TvSettingsNavigationRow(
                        label = "Customize Home",
                        detail = "Reorder or hide Home rows",
                        onClick = { route = TvSettingsRoute.CUSTOMIZE_HOME },
                    )
                    TvToggleRow(
                        label = "Continue Watching on the TV home screen",
                        detail = "Show your Continue Watching titles on the Android TV Play Next row.",
                        checked = showCwOnHome,
                        onToggle = {
                            val next = !showCwOnHome
                            showCwOnHome = next
                            TopShelfSettings.setShowContinueWatching(appContext, next)
                            // Turning it off clears the rows now; turning it on lets the next CW update publish.
                            if (!next) WatchNextPublisher.clearOwnedRows(appContext)
                        },
                    )
                }
            }

            status?.let { message ->
                item {
                    Text(
                        text = message,
                        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.xs),
                    )
                }
            }

            if (show("library", "auto-add", "watched", "new episode", "alerts", "notifications")) item {
                TvSettingsSection("Library") {
                    TvToggleRow(
                        label = "Auto-add watched to Library",
                        detail = "Adds a title once about a minute has played. A title you remove by hand stays removed.",
                        checked = autoAdd,
                        onToggle = {
                            val next = !autoAdd
                            autoAdd = next
                            AutoAddLibrarySetting.setEnabled(appContext, next)
                        },
                    )
                    TvToggleRow(
                        label = "New episode alerts",
                        detail = "Notify me when a series in my Library has a new episode.",
                        checked = notifyNewEpisodes,
                        onToggle = {
                            val next = !notifyNewEpisodes
                            notifyNewEpisodes = next
                            NewEpisodeNotifications.setEnabled(appContext, next)
                            if (next && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                notifyPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        },
                    )
                }
            }

            if (show(
                    "services", "add-ons", "addons", "debrid", "api keys",
                    "media server", "plex", "jellyfin", "emby", "live tv", "iptv", "m3u", "xtream",
                )
            ) item {
                TvSettingsSection(stringResource(R.string.tv_settings_section_services)) {
                    TvSettingsNavigationRow(
                        label = stringResource(R.string.addons_title),
                        detail = stringResource(R.string.addon_health_tv_navigation_description),
                        onClick = { route = TvSettingsRoute.ADDONS },
                        focusRequester = addonsFocus,
                    )
                    TvSettingsNavigationRow(
                        label = stringResource(R.string.tv_debrid_services_title),
                        detail = stringResource(R.string.tv_debrid_services_navigation_description),
                        onClick = { route = TvSettingsRoute.DEBRID },
                        focusRequester = debridServicesFocus,
                    )
                    TvSettingsNavigationRow(
                        label = "Media servers",
                        detail = "Connect Plex, Jellyfin, or Emby.",
                        onClick = { route = TvSettingsRoute.MEDIA_SERVERS },
                    )
                    TvSettingsNavigationRow(
                        label = "Live TV (IPTV)",
                        detail = "Add an M3U or Xtream playlist as channels.",
                        onClick = { route = TvSettingsRoute.IPTV },
                    )
                }
            }

            if (show(
                    "playback", "player", "still watching", "seek", "volume", "default volume",
                    "match frame rate", "afr", "refresh rate", "24p", "community scrub previews",
                    "trickplay", "scrub", "trailers",
                )
            ) item {
                TvSettingsSection("Playback") {
                    TvSettingsNavigationRow(
                        label = "All playback settings",
                        detail = "Still watching, seek step, default volume, subtitles, and more.",
                        onClick = { route = TvSettingsRoute.PLAYBACK },
                    )
                    // Match Frame Rate: the toggle that was missing. Its controller reads the same key per
                    // play; this is its first writer. A no-op on panels that expose no matching mode.
                    TvToggleRow(
                        label = "Match Frame Rate",
                        detail = "Switch the TV to the video's refresh rate so 24p film runs judder-free.",
                        checked = matchFrameRate,
                        onToggle = {
                            val next = !matchFrameRate
                            matchFrameRate = next
                            MatchFrameRateSetting.setEnabled(appContext, next)
                        },
                    )
                    // Community scrub previews: contribute anonymized scrub thumbnails so every viewer gets
                    // instant previews. Writes the same key Apple writes (no token or PII is ever sent).
                    TvToggleRow(
                        label = "Community scrub previews",
                        detail = "Share anonymized scrub previews so titles get instant thumbnails for everyone.",
                        checked = communityScrub,
                        onToggle = {
                            val next = !communityScrub
                            communityScrub = next
                            CommunityTrickplay.setEnabled(appContext, next)
                        },
                    )
                }
            }

            if (show("audio output", "audio", "sound", "passthrough")) item {
                TvSettingsSection("Audio output") {
                    AudioOutputMode.entries.forEach { mode ->
                        TvOptionRow(
                            label = mode.label,
                            detail = mode.detail,
                            selected = mode == audioMode,
                            onClick = {
                                audioMode = mode
                                AudioOutputMode.setCurrent(appContext, mode)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "caption", "subtitle color")) item {
                TvSettingsSection("Subtitle color") {
                    SubtitleStyle.colors.forEach { (id, label) ->
                        TvOptionRow(
                            label = label,
                            detail = null,
                            selected = subtitleStyle.colorId == id,
                            onClick = {
                                subtitleStyle = subtitleStyle.copy(colorId = id)
                                SubtitleStyle.save(appContext, subtitleStyle)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "caption", "subtitle brightness")) item {
                TvSettingsSection("Subtitle brightness") {
                    SubtitleStyle.brightnessLevels.forEach { level ->
                        TvOptionRow(
                            label = level.label,
                            detail = null,
                            selected = subtitleStyle.brightnessId == level.id,
                            onClick = {
                                subtitleStyle = subtitleStyle.copy(brightnessId = level.id)
                                SubtitleStyle.save(appContext, subtitleStyle)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "caption", "subtitle font")) item {
                TvSettingsSection("Subtitle font") {
                    SubtitleStyle.fonts.forEach { (id, label) ->
                        TvOptionRow(
                            label = label,
                            detail = null,
                            selected = subtitleStyle.fontId == id,
                            onClick = {
                                subtitleStyle = subtitleStyle.copy(fontId = id)
                                SubtitleStyle.save(appContext, subtitleStyle)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "caption", "subtitle size")) item {
                TvSettingsSection("Subtitle size") {
                    SubtitleStyle.sizes.forEach { (id, label) ->
                        TvOptionRow(
                            label = label,
                            detail = null,
                            selected = subtitleStyle.sizeId == id,
                            onClick = {
                                subtitleStyle = subtitleStyle.copy(sizeId = id)
                                SubtitleStyle.save(appContext, subtitleStyle)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "caption", "subtitle background")) item {
                TvSettingsSection("Subtitle background") {
                    SubtitleStyle.backgrounds.forEach { (id, label) ->
                        TvOptionRow(
                            label = label,
                            detail = null,
                            selected = subtitleStyle.backgroundId == id,
                            onClick = {
                                subtitleStyle = subtitleStyle.copy(backgroundId = id)
                                SubtitleStyle.save(appContext, subtitleStyle)
                            },
                        )
                    }
                }
            }

            if (show("subtitle", "subtitles", "external subtitles", "preferred")) item {
                TvSettingsSection("External subtitles") {
                    TvToggleRow(
                        label = "Only preferred external subtitles",
                        detail = "Keep embedded tracks, but limit add-on subtitles to your preferred languages.",
                        checked = subtitlesOnlyPreferred,
                        onToggle = {
                            subtitlesOnlyPreferred = !subtitlesOnlyPreferred
                            trackStore.subtitlesOnlyPreferred = subtitlesOnlyPreferred
                        },
                    )
                }
            }

            if (MpvEngineFactory.isBundled) {
                if (show("video quality", "upscaling", "quality")) item {
                    TvSettingsSection("Video quality") {
                        VideoUpscaling.androidChoices.forEach { preset ->
                            TvOptionRow(
                                label = preset.label,
                                detail = preset.detail,
                                selected = preset == videoUpscaling,
                                onClick = {
                                    videoUpscaling = preset
                                    trackStore.videoUpscaling = preset
                                },
                            )
                        }
                    }
                }
            }

            if (show(
                    "source selection", "sources", "source ranking", "quality preset", "size cap",
                    "min quality", "max quality", "add-on order", "regex", "stated quality", "direct links",
                )
            ) item {
                TvSettingsSection("Sources") {
                    TvSettingsNavigationRow(
                        label = "Source ranking",
                        detail = "Quality preset, type priority, size cap, min/max quality, add-on order, regex.",
                        onClick = { route = TvSettingsRoute.SOURCES },
                    )
                    TvToggleRow(
                        label = "Direct links only",
                        detail = "Hide unresolved torrents; keep direct, resolved debrid, and media-server links.",
                        checked = directLinksOnly,
                        onToggle = {
                            directLinksOnly = !directLinksOnly
                            PlaybackBehaviorSettings.setDirectLinksOnly(appContext, directLinksOnly)
                        },
                    )
                }
            }

            if (show("skip", "skip segments", "intro", "recap", "credits", "preview")) item {
                TvSettingsSection("Skip segments") {
                    TvToggleRow(
                        label = "Skip automatically",
                        detail = "Jump past each detected intro, recap, credits, or preview once.",
                        checked = autoSkip,
                        onToggle = {
                            autoSkip = !autoSkip
                            PlaybackBehaviorSettings.setAutoSkip(appContext, autoSkip)
                        },
                    )
                }
            }

            if (show("skip", "skip provider", "theintrodb", "skipdb", "database")) item {
                TvSettingsSection("Skip provider") {
                    tvSkipProviderOptions.forEach { (id, copy) ->
                        TvOptionRow(
                            label = copy.first,
                            detail = copy.second,
                            selected = id == skipProvider,
                            onClick = {
                                skipProvider = id
                                SkipConfig.setProvider(id)
                            },
                        )
                    }
                }
            }

            if (show("tabs", "tab bar", "discover", "live tv", "library", "search")) item {
                TvSettingsSection("Tabs") {
                    TvToggleRow(
                        label = "Show Discover tab",
                        detail = null,
                        checked = !tabState.hideDiscover,
                        onToggle = { tabBarPrefs.setDiscoverVisible(tabState.hideDiscover) },
                    )
                    TvToggleRow(
                        label = "Show Live TV tab",
                        detail = "Channels from your installed Live TV add-ons.",
                        checked = !tabState.hideLive,
                        onToggle = { tabBarPrefs.setLiveVisible(tabState.hideLive) },
                    )
                    TvToggleRow(
                        label = "Show Library tab",
                        detail = null,
                        checked = !tabState.hideLibrary,
                        onToggle = { tabBarPrefs.setLibraryVisible(tabState.hideLibrary) },
                    )
                    TvToggleRow(
                        label = "Show Search tab",
                        detail = "Home and Settings always stay. Hiding the current tab returns you to Home.",
                        checked = !tabState.hideSearch,
                        onToggle = { tabBarPrefs.setSearchVisible(tabState.hideSearch) },
                    )
                }
            }

            if (show("performance", "battery", "smoothness", "power")) item {
                TvSettingsSection("Performance") {
                    PerformanceMode.Override.entries.forEach { option ->
                        TvOptionRow(
                            label = option.label,
                            detail = null,
                            selected = option == performance,
                            onClick = {
                                performance = option
                                PerformanceMode.setOverride(appContext, option)
                            },
                        )
                    }
                }
            }

            if (show("backup", "restore", "back up", "export", "import", "sync", "qr", "code")) item {
                TvSettingsSection("Backup & Restore") {
                    TvSettingsNavigationRow(
                        label = "Backup & Restore",
                        detail = "Scan a code to back up to, or restore from, your VortX account.",
                        onClick = { route = TvSettingsRoute.BACKUP },
                    )
                }
            }

            if (show("about", "diagnostics", "version", "what's new", "whats new", "update")) item {
                TvSettingsSection("About") {
                    // The passive "update available" banner (sideloaded, no store channel). Renders nothing
                    // when up to date or dismissed; focusing + selecting it opens the install channel.
                    UpdateAvailableBanner()
                    TvSettingsNavigationRow(
                        label = "Diagnostics",
                        detail = "App, device, and engine info for support.",
                        onClick = { route = TvSettingsRoute.DIAGNOSTICS },
                    )
                    TvSettingsNavigationRow(
                        label = "What's New",
                        detail = "VortX ${BuildConfig.VERSION_NAME}",
                        onClick = { route = TvSettingsRoute.WHATS_NEW },
                    )
                }
            }

            if (trimmedQuery.isEmpty()) item { TvSettingsFootnote() }
        }

        pinTarget?.let { target ->
            TvPinGate(
                profile = target,
                onUnlock = { pinTarget = null; commitSwitch(target) },
                onCancel = { pinTarget = null },
            )
        }
    }

    LaunchedEffect(restoreFocusTarget) {
        if (restoreFocusTarget == TvDebridFocusTarget.DEBRID_SERVICES) {
            var restored = false
            repeat(3) {
                if (!restored) {
                    restored = runCatching { debridServicesFocus.requestFocus() }.getOrDefault(false)
                    if (!restored) withFrameNanos { }
                }
            }
            if (restored) restoreFocusTarget = null
        }
    }

    LaunchedEffect(restoreAddonsFocus) {
        if (restoreAddonsFocus) {
            var restored = false
            repeat(3) {
                if (!restored) {
                    restored = runCatching { addonsFocus.requestFocus() }.getOrDefault(false)
                    if (!restored) withFrameNanos { }
                }
            }
            if (restored) restoreAddonsFocus = false
        }
    }
}

internal enum class TvSettingsRoute {
    ROOT,
    ADDONS,
    ADDON_STORE,
    ADDON_PAIRING,
    DEBRID,
    WHATS_NEW,
    CUSTOMIZE_HOME,
    ACCOUNT,
    IMPORT_STREMIO,
    INTEGRATIONS,
    METADATA,
    APPEARANCE,
    HOME_DISCOVER,
    MEDIA_SERVERS,
    IPTV,
    PLAYBACK,
    SOURCES,
    BACKUP,
    DIAGNOSTICS;

    internal fun back(): TvSettingsRoute = when (this) {
        // The store + pairing screens are nested under Add-ons; Back returns there, not to the root.
        ADDON_STORE, ADDON_PAIRING -> ADDONS
        else -> ROOT
    }
}

/// The active profile, shown large above the switcher (avatar + name + a Kids marker), so "who is watching"
/// is legible at ten feet and the Kids badge confirms the content guard is engaged.
@Composable
private fun TvProfileHeader(profile: UserProfile?) {
    val colors = VortXTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(text = profile?.avatar ?: "🍿", style = VortXTheme.type.hero)
        Spacer(Modifier.width(VortXTheme.spacing.md))
        Column {
            Text(text = profile?.name ?: "VortX", style = VortXTheme.type.sectionTitle)
            Text(
                text = if (profile?.isKids == true) "Kids profile · active" else "Active profile",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
        }
    }
}

/// One focusable profile in the switcher, the tv-Surface 10-foot analogue of the phone profile row: an
/// accent disc with the avatar (its [UserProfile.accentID] color), the name with a Kids badge, and a trailing
/// check (active) or lock (PIN-gated). The whole row is the D-pad target.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvProfileRow(profile: UserProfile, isActive: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(VortXAccents.byId(profile.accentID).base.copy(alpha = 0.26f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(profile.avatar, style = VortXTheme.type.cardTitle)
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                Text(
                    text = profile.name.ifBlank { "Profile" },
                    style = VortXTheme.type.body.copy(
                        color = if (isActive) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (profile.isKids) TvKidsBadge()
            }
            Spacer(Modifier.width(VortXTheme.spacing.sm))
            when {
                isActive -> Icon(VortXIcons.checkmarkCircle, contentDescription = "Active profile", tint = colors.accent)
                profile.hasPin -> Icon(VortXIcons.lock, contentDescription = "Locked", tint = colors.textTertiary)
            }
        }
    }
}

/// A small "Kids" pill beside a Kids profile's name (the explicit badge at 10 feet).
@Composable
private fun TvKidsBadge() {
    val colors = VortXTheme.colors
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.accentSoft)
            .padding(horizontal = VortXTheme.spacing.xs, vertical = 2.dp),
    ) {
        Text("Kids", style = VortXTheme.type.eyebrow.copy(color = colors.accent))
    }
}

/// A titled group: the eyebrow header over a stack of focusable rows. The 10-foot analogue of the phone
/// `SettingsSection`, minus the glass card (the rows carry their own focus surface here).
@Composable
private fun TvSettingsSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = title.uppercase(),
            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.textTertiary),
            modifier = Modifier.padding(start = VortXTheme.spacing.xs),
        )
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) { content() }
    }
}

/// One focusable radio option, the tv-Surface 10-foot analogue of the phone `OptionRow`. The [RadioButton]
/// is a pure indicator (onClick = null); the whole row is the target, so the D-pad selects it in one press
/// and a focus ring makes the target unambiguous from the couch. Carries the store's own [detail] copy.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvOptionRow(label: String, detail: String?, selected: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {
                role = Role.RadioButton
                this.selected = selected
            },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RadioButton(
                selected = selected,
                onClick = null,
                colors = RadioButtonDefaults.colors(
                    selectedColor = colors.accent,
                    unselectedColor = colors.textTertiary,
                ),
            )
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Column {
                Text(
                    text = label,
                    style = VortXTheme.type.body.copy(
                        color = if (selected) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                )
                if (detail != null) {
                    Text(
                        text = detail,
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/// One focusable on/off row, the tv-Surface 10-foot analogue of the phone `ToggleRow`. The [Switch] is a
/// pure indicator; the row is the target.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvToggleRow(label: String, detail: String?, checked: Boolean, onToggle: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onToggle,
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {
                role = Role.Switch
                toggleableState = if (checked) ToggleableState.On else ToggleableState.Off
            },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = label,
                    style = VortXTheme.type.body.copy(
                        color = if (checked) colors.textPrimary else colors.textSecondary,
                        fontWeight = if (checked) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                )
                if (detail != null) {
                    Text(
                        text = detail,
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Switch(
                checked = checked,
                onCheckedChange = null,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = colors.accent,
                    uncheckedTrackColor = colors.surface3,
                ),
            )
        }
    }
}

/// A focusable nested-settings destination. The entire surface is one D-pad target.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvSettingsNavigationRow(
    label: String,
    detail: String,
    onClick: () -> Unit,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (focusRequester != null) {
                    Modifier.focusRequester(focusRequester)
                } else {
                    Modifier
                },
            ),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
        ) {
            Text(label, style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold))
            Text(
                detail,
                style = VortXTheme.type.label.copy(color = colors.textTertiary),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/// The 10-foot settings search field. Its query drives the `show` filter in [TvSettingsScreen], so typing
/// narrows the list to matching sections and clearing it (or leaving it blank) shows everything again. A plain
/// Material [OutlinedTextField] is D-pad-focusable and raises the on-screen keyboard on select, the same field
/// the TV debrid-keys screen already uses on the couch.
@Composable
private fun TvSettingsSearchField(query: String, onQueryChange: (String) -> Unit) {
    val colors = VortXTheme.colors
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Search settings") },
        singleLine = true,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline,
            cursorColor = colors.accent,
        ),
    )
}

/// A 10-foot PIN gate: a dimmed scrim over a panel with the entered digits and a focusable numeric keypad,
/// the couch analogue of the phone `PinGateOverlay`. A TV has no reliable soft keyboard, so entry is a grid
/// of D-pad-focusable digit keys. [UserProfile.pinMatches] does the check, so the salted hash never leaves the
/// store. Unlock only enables at 4 digits.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvPinGate(profile: UserProfile, onUnlock: () -> Unit, onCancel: () -> Unit) {
    val colors = VortXTheme.colors
    var input by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.78f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(24.dp))
                .background(colors.surface1)
                .padding(VortXTheme.spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Enter PIN for ${profile.name}", style = VortXTheme.type.sectionTitle)
            Text(
                text = if (input.isEmpty()) "----" else "•".repeat(input.length).padEnd(4, '-'),
                style = VortXTheme.type.hero.copy(color = colors.textPrimary),
            )
            if (wrong) Text("Wrong PIN", style = VortXTheme.type.label.copy(color = colors.danger))
            // 1-9 in a 3x3, then Delete / 0 / Cancel across the bottom.
            val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"))
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    row.forEach { digit ->
                        TvKeypadKey(label = digit, onClick = {
                            if (input.length < 4) { input += digit; wrong = false }
                        })
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                TvKeypadKey(label = "Del", onClick = { input = input.dropLast(1); wrong = false })
                TvKeypadKey(label = "0", onClick = { if (input.length < 4) { input += "0"; wrong = false } })
                TvKeypadKey(label = "Cancel", onClick = onCancel)
            }
            TvKeypadKey(
                label = "Unlock",
                wide = true,
                enabled = input.length == 4,
                onClick = { if (profile.pinMatches(input)) onUnlock() else wrong = true },
            )
        }
    }
}

/// One focusable keypad key for [TvPinGate]. A disabled key (Unlock before 4 digits) is a dim,
/// non-focusable/inert surface so the D-pad skips it until it becomes usable.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvKeypadKey(label: String, onClick: () -> Unit, enabled: Boolean = true, wide: Boolean = false) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = if (wide) Modifier.fillMaxWidth() else Modifier.size(width = 76.dp, height = 56.dp),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (enabled) colors.surface2 else colors.surface1,
            contentColor = if (enabled) colors.textPrimary else colors.textTertiary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Box(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold))
        }
    }
}

/// An honest pointer to what is NOT here: the deep settings surfaces that stay on the phone/tablet app for
/// now. Named rather than hidden, so a tester knows where to reach them.
@Composable
private fun TvSettingsFootnote() {
    Text(
        text = "Creating, renaming, and deleting profiles, plus media servers, source ranking, " +
            "downloads, and library transfer, are managed in the VortX phone and tablet app.",
        style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.sm),
    )
}

/// The crowd skip-database choices. The ids are the EXACT strings [SkipConfig.provider] stores (and that
/// [com.vortx.android.skip.SkipTimestampService] selects a leg from), matching the phone
/// PlaybackSettingsScreen's `skipProviderOptions` and the Apple `SkipTimestampService.provider` values.
/// "both" is first because it is the stored default.
private val tvSkipProviderOptions: List<Pair<String, Pair<String, String>>> = listOf(
    "both" to ("Both" to "Ask both databases. The widest coverage, and the default."),
    "theintrodb" to ("TheIntroDB" to "Ask TheIntroDB only."),
    "skipdb" to ("SkipDB" to "Ask SkipDB only."),
)

/// The account / sign-in route: the 10-foot [TvLoginScreen] built with the SAME view models the phone Settings
/// rows drive. The VortX side ([VortXAccountViewModel]) needs the app-process [VortXSyncManager] and is only
/// built when one is available; the Stremio side ([AccountViewModel]) rides the shared [AuthRepository].
@Composable
private fun TvAccountRoute(
    repo: CatalogRepository,
    auth: AuthRepository,
    syncManager: VortXSyncManager?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val stremioVm: AccountViewModel = viewModel(
        factory = StremioXViewModelFactory(repo = repo, auth = auth),
    )
    val vortxVm: VortXAccountViewModel? = if (syncManager != null) {
        viewModel(factory = StremioXViewModelFactory(repo = repo, syncManager = syncManager))
    } else {
        null
    }
    TvLoginScreen(
        vortxViewModel = vortxVm,
        stremioViewModel = stremioVm,
        onBack = onBack,
        modifier = modifier,
    )
}

/// The Import-from-Stremio route: the phone [AccountContent] (Stremio sign-in / import, driven by the shared
/// [AccountViewModel] over [AuthRepository]) inside 10-foot chrome. Reused verbatim so the import flow and its
/// credential handling can never drift from the phone.
@Composable
private fun TvStremioImportRoute(
    repo: CatalogRepository,
    auth: AuthRepository,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler { onBack() }
    val stremioVm: AccountViewModel = viewModel(
        factory = StremioXViewModelFactory(repo = repo, auth = auth),
    )
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Text("Import from Stremio", style = VortXTheme.type.sectionTitle)
            Text(
                "Sign in to your Stremio account to import its library and add-ons. VortX stays your " +
                    "primary account.",
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
            )
        }
        AccountContent(
            viewModel = stremioVm,
            modifier = Modifier.widthIn(max = TvDimens.formMaxWidth).fillMaxWidth(),
        )
    }
}
