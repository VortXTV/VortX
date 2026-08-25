package com.vortx.android.ui.screens

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.BuildConfig
import com.vortx.android.R
import com.vortx.android.downloads.DownloadManager
import com.vortx.android.downloads.DownloadStore
import com.vortx.android.model.AuthState
import com.vortx.android.model.DiscoverFilters
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.LibraryFilters
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.LiveTypes
import com.vortx.android.model.MetaItem
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.PosterArt
import com.vortx.android.ui.components.PosterCard
import com.vortx.android.ui.components.SignedOutState
import com.vortx.android.ui.components.shimmer
import com.vortx.android.ui.search.RecentSearchesRow
import com.vortx.android.ui.search.SearchResultSection
import com.vortx.android.ui.search.textResourceId
import com.vortx.android.ui.search.searchEmptyMessage
import com.vortx.android.ui.search.searchResultItemKey
import com.vortx.android.ui.search.searchResultSectionHeaderKey
import com.vortx.android.ui.search.searchResultSections
import com.vortx.android.ui.search.titleResourceId
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.DiscoverViewModel
import com.vortx.android.ui.viewmodel.LibraryViewModel
import com.vortx.android.ui.viewmodel.SearchViewModel
import com.vortx.android.update.UpdateAvailableBanner

/// Discover (S04, DESIGN-SYSTEM.md §4 "Discover / Search"): type switch -> catalog chips -> genre
/// chips (when the selected catalog declares one) -> dense poster grid -> "Load more". Every chip
/// dispatches the engine's OWN `request` for that option (see [DiscoverViewModel.select]) -- the fix
/// for the S03-era bug where every chip dispatched the identical default Load and nothing ever
/// actually changed on tap.
@Composable
fun DiscoverScreen(
    viewModel: DiscoverViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
    // SD-6: when Live TV is hidden (TabBarPrefs.hideLive) the Discover TYPE chips drop every live/tv type
    // too (Apple `iOSRootView` `hideLiveTab ? types.filter { !LiveTypes.contains($0.type) }`).
    hideLive: Boolean = false,
    reselectSignal: Int = 0,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val loadingMore by viewModel.loadingMore.collectAsStateWithLifecycle()
    val advancedFilters by viewModel.advancedFilters.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<DiscoverResult>)?.data?.filters
    var showAdvancedFilters by remember { mutableStateOf(false) }
    val gridState = rememberLazyGridState()
    LaunchedEffect(reselectSignal) {
        if (reselectSignal > 0) gridState.animateScrollToItem(0)
    }

    // SD-8: without a Stremio or VortX sign-in there are no catalogs to pivot; show the sign-in prompt.
    if (!signedIn) {
        SignedOutState(modifier = modifier.fillMaxSize())
        return
    }

    Column(modifier = modifier.fillMaxSize()) {
        if (filters != null) {
            ChipScrollRow {
                Chip(
                    label = if (advancedFilters.isActive) {
                        stringResource(R.string.discover_filters_count, advancedFilters.activeCount)
                    } else {
                        stringResource(R.string.discover_filters)
                    },
                    selected = advancedFilters.isActive,
                    onClick = { showAdvancedFilters = true },
                )
                if (advancedFilters.isActive) {
                    Chip(
                        label = stringResource(R.string.discover_clear),
                        selected = false,
                        onClick = viewModel::clearAdvancedFilters,
                    )
                }
            }
        }
        DiscoverFilterChips(filters = filters, hideLive = hideLive, onSelect = { viewModel.select(it) })
        when (val s = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(s.message, onRetry = viewModel::retry)
            is UiState.Success -> {
                val shown = viewModel.filteredItems(s.data)
                if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = VortXTheme.spacing.edge),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    ) {
                        Text(
                            stringResource(R.string.discover_shown_count, shown.size),
                            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                        )
                        Chip(
                            label = stringResource(R.string.discover_clear_filters),
                            selected = false,
                            onClick = viewModel::clearAdvancedFilters,
                        )
                    }
                }
                PosterGrid(
                    items = shown,
                    onItem = onItem,
                    emptyHint = if (advancedFilters.isActive && s.data.items.isNotEmpty()) {
                        stringResource(R.string.discover_no_matches_message)
                    } else {
                        stringResource(R.string.discover_catalog_empty)
                    },
                    showMenu = true,
                    gridState = gridState,
                    footer = if (s.data.filters.hasNextPage) {
                        { LoadMoreFooter(loading = loadingMore, onClick = viewModel::loadMore) }
                    } else {
                        null
                    },
                )
                if (showAdvancedFilters) {
                    DiscoverFilterSheet(
                        filters = advancedFilters,
                        genreOptions = viewModel.advancedGenreOptions(s.data),
                        showSeasons = viewModel.showsAdvancedSeasonFilters(s.data),
                        onChange = viewModel::setAdvancedFilters,
                        onDismiss = { showAdvancedFilters = false },
                    )
                }
            }
        }
    }
}

/// The type/catalog/genre chip rows above Discover's grid. No-ops while [filters] is null (still
/// loading) so the grid below owns the loading/error/empty state exclusively.
///
/// GROUP 3b fix (Fold cover-screen device round: "three stacked chip rows... look wonky"): the parent
/// [DiscoverScreen] `Column` has no `verticalArrangement`, so up to three independently-emitted
/// [ChipScrollRow]s (type / catalog / genre) previously sat back-to-back with only each row's own tiny
/// `xs` vertical padding between them (2x `xs` total) -- on a wide phone that gap reads as "tight but
/// fine"; on the Fold's ~344dp-wide cover screen, where every row ALSO wraps its chips onto a horizontal
/// scroll almost immediately, the rows visually collide into a dense, hard-to-parse block. Wrapping the
/// (at most three) rows in their own [Column] with explicit `sm` spacing keeps every row scrollable
/// and unchanged in content, just legibly separated -- a minimal, cosmetic-only fix, not a redesign.
@Composable
private fun DiscoverFilterChips(filters: DiscoverFilters?, hideLive: Boolean, onSelect: (String) -> Unit) {
    if (filters == null) return
    // SD-6: when Live TV is hidden, drop live/tv type chips (the label is the capitalized engine type, so
    // LiveTypes matches it case-insensitively). Catalog/genre rows are untouched, exactly like Apple.
    val types = if (hideLive) filters.types.filterNot { LiveTypes.contains(it.label) } else filters.types
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        if (types.isNotEmpty()) {
            ChipScrollRow {
                types.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
        if (filters.catalogs.size > 1) {
            ChipScrollRow {
                filters.catalogs.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
        if (filters.genres.isNotEmpty()) {
            ChipScrollRow {
                filters.genres.forEach { option ->
                    Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
                }
            }
        }
    }
}

/// Library (S04, DESIGN-SYSTEM.md §4 "Library"): type/sort chips over the saved poster grid with the
/// remove ("x") control per poster.
@Composable
fun LibraryScreen(viewModel: LibraryViewModel, onItem: (MetaItem) -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val filters = (state as? UiState.Success<LibraryResult>)?.data?.filters
    // Client-side smart filters (audit R01, Apple LibraryView.LibrarySmartFilter): multi-select and
    // AND-combined, applied on top of the engine's type/sort. Reset when the screen's engine query
    // changes is NOT wanted - the set survives refilters, exactly like Apple's @State.
    var activeFilters by remember { mutableStateOf(emptySet<LibrarySmartFilter>()) }

    Column(modifier = modifier.fillMaxSize()) {
        LibraryFilterChips(filters = filters, onSelect = { viewModel.load(it) })
        LibrarySmartFilterChips(active = activeFilters, onToggle = { f ->
            activeFilters = if (f in activeFilters) activeFilters - f else activeFilters + f
        })
        when (val s = state) {
            is UiState.Loading -> ShimmerGrid()
            is UiState.Error -> ErrorState(s.message, onRetry = viewModel::retry)
            is UiState.Success -> PosterGrid(
                items = s.data.items.filter { item ->
                    activeFilters.all { it.matches(item) }
                },
                onItem = onItem,
                emptyHint = if (activeFilters.isEmpty()) "Titles you save appear here."
                            else "Nothing matches these filters.",
                onRemove = viewModel::remove,
            )
        }
    }
}

/// Client-side SMART filters for the Library: Unwatched / In Progress / Watched / Short, evaluated as
/// predicates over fields a saved entry already carries (the read-only watched signal, 0..1 watch
/// progress, and the preview runtime). Multi-select AND-combined, so combinations read as one smart
/// list ("Unwatched" + "Short" = unwatched short films). A field the entry does not carry (runtime
/// for a title never played) simply does not match; it never crashes. Mirrors Apple
/// `LibraryView.swift` `LibrarySmartFilter` with identical thresholds.
internal enum class LibrarySmartFilter(val label: String) {
    UNWATCHED("Unwatched"),
    IN_PROGRESS("In Progress"),
    WATCHED("Watched"),
    SHORT("Short");

    fun matches(item: MetaItem): Boolean = when (this) {
        UNWATCHED -> !item.watched
        WATCHED -> item.watched
        // The actively-resumable band: played into, but below the engine's own ~0.9 finished ceiling.
        IN_PROGRESS -> (item.progress ?: 0f) > 0f && (item.progress ?: 0f) < IN_PROGRESS_CEIL
        // Runtime strictly under 100 minutes counts as Short; an unknown runtime cannot match.
        SHORT -> (item.previewRuntimeMinutes ?: Int.MAX_VALUE) < SHORT_RUNTIME_MINUTES
    }

    internal companion object {
        /** Runtime strictly under this many minutes counts as "Short" (100 minutes). */
        const val SHORT_RUNTIME_MINUTES = 100

        /** The actively-resumable progress ceiling, matching Apple's `inProgressCeil`. */
        const val IN_PROGRESS_CEIL = 0.9f
    }
}

@Composable
private fun LibrarySmartFilterChips(active: Set<LibrarySmartFilter>, onToggle: (LibrarySmartFilter) -> Unit) {
    ChipScrollRow {
        LibrarySmartFilter.entries.forEach { f ->
            Chip(label = f.label, selected = f in active, onClick = { onToggle(f) })
        }
    }
}

@Composable
private fun LibraryFilterChips(filters: LibraryFilters?, onSelect: (String) -> Unit) {
    if (filters == null) return
    if (filters.types.size > 1) {
        ChipScrollRow {
            filters.types.forEach { option ->
                Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
            }
        }
    }
    if (filters.sorts.isNotEmpty()) {
        ChipScrollRow {
            filters.sorts.forEach { option ->
                Chip(label = option.label, selected = option.selected, onClick = { onSelect(option.requestJson) })
            }
        }
    }
}

/// Search: a query field over a poster grid of matches across every installed add-on, with recent
/// searches as chips when the query is empty (DESIGN-SYSTEM.md §4 "Discover / Search").
///
/// SD-6 polish: a trailing clear button, an IME "Search" action that skips the debounce
/// ([SearchViewModel.submitQuery]), a "Recent Searches" heading with clock/trash glyphs, the long-press
/// catalog menu + watched badge on result cards, and [reselectSignal] -- bumped by the shell when the
/// already-active Search tab is re-tapped -- to scroll the results back to the top. [leadingSlot] renders
/// above the field (the "Play a link" entry, SD-1).
@Composable
fun SearchScreen(
    viewModel: SearchViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    signedIn: Boolean = true,
    reselectSignal: Int = 0,
    leadingSlot: (@Composable () -> Unit)? = null,
) {
    val searchState by viewModel.screenState.collectAsStateWithLifecycle()
    val history by viewModel.history.collectAsStateWithLifecycle()
    val suggestions by viewModel.suggestions.collectAsStateWithLifecycle()
    val query = searchState.query
    val state = searchState.content
    val openItem: (MetaItem) -> Unit = {
        viewModel.recordHistory()
        onItem(it)
    }
    val gridState = rememberLazyGridState()
    // Re-tap of the active Search tab scrolls the results back to top (Apple `TabScrollToTop`).
    LaunchedEffect(reselectSignal) {
        if (reselectSignal > 0) gridState.animateScrollToItem(0)
    }

    // SD-8: a signed-out device sees a sign-in prompt, not empty add-on results. Gate on either account.
    if (!signedIn) {
        SignedOutState(modifier = modifier.fillMaxSize())
        return
    }

    Column(modifier = modifier.fillMaxSize()) {
        leadingSlot?.invoke()
        SearchField(
            query = query,
            onQueryChange = viewModel::onQueryChange,
            onSubmit = viewModel::submitQuery,
            onClear = { viewModel.onQueryChange("") },
        )
        if (query.isBlank() && history.isNotEmpty()) {
            RecentSearchesRow(
                history = history,
                onPick = viewModel::onQueryChange,
                onClear = viewModel::clearHistory,
                modifier = Modifier.padding(top = VortXTheme.spacing.xs),
            )
        }
        // SD-4: as-you-type suggestions under the field. Surfaced from one character (client-side); the
        // engine's own local-search index feeds in from two characters. Cleared when the query is empty.
        if (suggestions.isNotEmpty()) {
            ChipScrollRow {
                suggestions.forEach { suggestion ->
                    Chip(
                        label = suggestion,
                        selected = false,
                        onClick = { viewModel.onQueryChange(suggestion) },
                    )
                }
            }
        }
        when (val s = state) {
            is UiState.Loading -> EmptyState("Searching your add-ons…")
            is UiState.Error -> ErrorState(s.message)
            is UiState.Success -> PosterGrid(
                items = s.data,
                onItem = openItem,
                emptyHint = when (val message = searchEmptyMessage(query, s)) {
                    null -> ""
                    else -> stringResource(message.textResourceId)
                },
                sectioned = true,
                showMenu = true,
                gridState = gridState,
            )
        }
    }
}

/// The shared search text field (phone Search + the merged Discover surface): a leading magnifier, the
/// query, a trailing clear ("x") button when non-empty, and an IME "Search" action that fires
/// [onSubmit] (which skips the debounce) and dismisses the keyboard.
@Composable
internal fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    val focusManager = LocalFocusManager.current
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        leadingIcon = { Icon(VortXIcons.search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = onClear) {
                    Icon(VortXIcons.close, contentDescription = "Clear search", tint = colors.textSecondary)
                }
            }
        },
        placeholder = { Text("Search movies, series, channels", style = VortXTheme.type.body) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(
            onSearch = {
                onSubmit()
                focusManager.clearFocus()
            },
        ),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline,
            cursorColor = colors.accent,
        ),
        modifier = modifier.fillMaxWidth().padding(VortXTheme.spacing.edge),
    )
}

/// Settings: the same controls the iOS app exposes (DESIGN-SYSTEM.md §4 "Settings / Profiles"). The
/// VortX Account row is the PRIMARY login (the E2E account + cross-device sync, opened via
/// [onVortxAccountClick]); the Stremio row below it is real too (S03): it reflects the live engine
/// [AuthState] and opens [AccountScreen] via
/// [onAccountClick]. The Add-ons row (S04) opens the add-on management screen via [onAddonsClick]. In
/// debug builds only, one extra row opens the S02 design-system gallery for visual review; the boundary
/// is [BuildConfig.DEBUG], not a build variant, so it never ships in a release build.
///
/// The Playback row opens [PlaybackSettingsScreen]. It REPLACES two hardcoded rows ("Audio output / Auto"
/// and "Subtitle size / Medium") that rendered fixed strings, read no preference and had no onClick: they
/// showed a value the app was not necessarily using and could not be tapped to change it. Every value
/// shown here now comes from the store that the engines actually read.
///
/// The Sources row opens [SourcesSettingsScreen], the control surface over `SourcePreferencesStore`: the
/// ranker read those preferences on every source list, but nothing in `ui/` could write them, so the whole
/// filtering/ranking layer was stuck at its defaults.
///
/// The Library row opens [LibraryTransferScreen] (library export / import), which is this screen's analogue
/// of the Apple settings backup section (iOSSettingsView.swift:222-256). Same shape of gap as the two above:
/// `LibraryPortability` + `LibraryTransfer` were complete and had no caller anywhere in `ui/`.
@Composable
fun SettingsScreen(
    authState: AuthState,
    // The VortX account row (the E2E account + cross-device sync, VortXSyncManager): the live
    // signed-in summary, or null to hide the row when the sync manager could not be stood up
    // (@Previews, a keystore failure). The VortX account is the PRIMARY login; the [authState]
    // row below stays the engine's optional Stremio account.
    vortxAccountValue: String?,
    onVortxAccountClick: () -> Unit,
    onProfilesClick: () -> Unit,
    onAppearanceScreenClick: () -> Unit,
    onTabBarScreenClick: () -> Unit,
    onAccountClick: () -> Unit,
    onAddonsClick: () -> Unit,
    onIntegrationsClick: () -> Unit,
    onMediaServersClick: () -> Unit,
    onLiveTvClick: () -> Unit,
    onPlaybackClick: () -> Unit,
    onSourcesClick: () -> Unit,
    onMetadataKeysClick: () -> Unit,
    onPosterStyleClick: () -> Unit,
    onHomeDiscoverClick: () -> Unit,
    onDebridKeysScreenClick: () -> Unit,
    onDebridLibraryClick: () -> Unit,
    onDownloadsClick: () -> Unit,
    onLibraryClick: () -> Unit,
    onBackupClick: () -> Unit,
    onWatchStatsClick: () -> Unit,
    onWhatsNewClick: () -> Unit,
    settingsScrollState: ScrollState,
    debridServicesFocusRequester: FocusRequester,
    modifier: Modifier = Modifier,
    onOpenGallery: (() -> Unit)? = null,
) {
    val accountValue = when (authState) {
        is AuthState.SignedIn -> authState.email ?: "Signed in"
        AuthState.SignedOut -> "Not signed in"
    }
    // The Playback summary reads the live persisted value rather than restating a default, so the row can
    // never disagree with the screen it opens.
    val appContext = LocalContext.current.applicationContext
    val playbackValue = AudioOutputMode.current(appContext).label
    // The Sources summary names the top-ranked source type, which is the one decision on that screen a
    // viewer is most likely to have changed. Read on every recomposition and deliberately NOT `remember`ed,
    // exactly like the Playback row above: returning from the Sources screen recomposes this, so a cached
    // value would leave the row asserting an order the viewer just changed. The store's constructor is a
    // `getSharedPreferences` call, which the framework serves from its own cache.
    val sourcesStore = SourcePreferencesStore(appContext)
    val sourcesValue = if (sourcesStore.useAddonOrder) {
        "Add-on order"
    } else {
        sourcesStore.typeOrder.firstOrNull()?.label ?: "Ranked"
    }
    // Live download count + size, recomputed when the index changes rather than sampled once, so the row tracks a
    // transfer that finishes while Settings is open.
    val downloadRecords by DownloadStore.records.collectAsStateWithLifecycle()
    val downloadsValue = if (downloadRecords.isEmpty()) {
        "None"
    } else {
        val count = downloadRecords.size
        "${if (count == 1) "1 title" else "$count titles"}  ·  ${DownloadStore.formattedTotalSize()}"
    }
    // The active profile name (with a Kids marker), read live rather than remembered so returning from the
    // profile switcher shows the profile just picked. Falls back to "Default" before ProfileStore is up.
    val activeProfile = ProfileStore.sharedOrNull()?.active
    val profilesValue = activeProfile?.let { if (it.isKids) "${it.name}  ·  Kids" else it.name } ?: "Default"
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(settingsScrollState)
            .padding(VortXTheme.spacing.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        // The passive "update available" banner (sideloaded Android has no store channel). Renders nothing
        // when up to date or when the user dismissed this build; tapping it opens the install channel.
        UpdateAvailableBanner()
        // Profiles first: it answers "who is watching" and is the entry to the "Who's watching?" switcher that
        // makes the whole multi-profile subsystem reachable.
        SettingRow(VortXIcons.profiles, "Profiles", profilesValue, onClick = onProfilesClick)
        SettingRow(
            VortXIcons.settings,
            "Appearance",
            "Theme, text size",
            onClick = onAppearanceScreenClick,
        )
        // Poster Style (poster-artwork lane): card width / corner-radius presets + landscape + hide-labels,
        // on Apple's exact `stremiox.catalog.*` keys, with a live preview.
        SettingRow(
            VortXIcons.settings,
            "Poster Style",
            "Card size, corners, layout",
            onClick = onPosterStyleClick,
        )
        // Home & Discover content settings (SET-3): editorial rows, collections hub, spoiler-safe, etc.
        SettingRow(
            VortXIcons.home,
            "Home & Discover",
            "Rows, collections, spoilers",
            onClick = onHomeDiscoverClick,
        )
        // New-episode alerts (F5, Apple's `stremiox.notifyNewEpisodes`). An inline toggle rather than a
        // sub-screen: it is a single on/off with nothing to configure. Owns the POST_NOTIFICATIONS request.
        NewEpisodeAlertsRow()
        SettingRow(
            VortXIcons.listBullet,
            "Tab bar",
            "Choose visible tabs",
            onClick = onTabBarScreenClick,
        )
        // VortX Account above the Stremio row: the VortX account is the primary login (sign in /
        // create / recover + cross-device sync); Stremio below is the optional engine import.
        if (vortxAccountValue != null) {
            SettingRow(VortXIcons.account, "VortX Account", vortxAccountValue, onClick = onVortxAccountClick)
        }
        SettingRow(VortXIcons.account, "Stremio", accountValue, onClick = onAccountClick)
        SettingRow(VortXIcons.addon, "Add-ons", "Manage", onClick = onAddonsClick)
        // Metadata keys (SET-2): between Add-ons and Debrid, per the Apple placement.
        SettingRow(VortXIcons.lock, "Metadata keys", "TMDB, MDBList, fanart", onClick = onMetadataKeysClick)
        SettingRow(VortXIcons.link, "Integrations", "Trakt, SIMKL", onClick = onIntegrationsClick)
        SettingRow(VortXIcons.mediaServer, "Media servers", "Plex, Jellyfin, Emby", onClick = onMediaServersClick)
        // Live TV (IPTV): add an M3U playlist or Xtream login; the converter output installs as a normal
        // add-on so channels flow through the existing catalog pipeline (com.vortx.android.iptv).
        SettingRow(VortXIcons.playRectangle, "Live TV", "IPTV", onClick = onLiveTvClick)
        SettingRow(VortXIcons.audioOutput, "Playback", playbackValue, onClick = onPlaybackClick)
        SettingRow(VortXIcons.sources, "Sources", sourcesValue, onClick = onSourcesClick)
        SettingRow(
            VortXIcons.lock,
            "Debrid services",
            "API keys",
            onClick = onDebridKeysScreenClick,
            modifier = Modifier.focusRequester(debridServicesFocusRequester),
        )
        // Browse-your-debrid-cloud: list + play what is already in the connected debrid accounts, no add-on
        // needed. Mirrors the Apple Settings "Your cloud" entry (DebridLibraryView).
        SettingRow(VortXIcons.playCircle, "Your cloud", "Play from debrid", onClick = onDebridLibraryClick)
        // The Downloads summary reads the live index, so the row can never disagree with the screen it opens
        // (the same rule the Playback row above follows). "None" rather than a byte count when empty: "0 B" reads
        // like a broken measurement, not like an empty list.
        // Shown now that DownloadManager.CREATE_PATH_WIRED is true: the detail-screen source-row "Download for
        // offline" action calls DownloadManager.download(), so a tester can actually fill this screen. The gate
        // is kept as a guard so the row and its create-path flip together in one place if it is ever revisited.
        if (DownloadManager.CREATE_PATH_WIRED) {
            SettingRow(VortXIcons.download, "Downloads", downloadsValue, onClick = onDownloadsClick)
        }
        // A fixed descriptor of what the screen holds, NOT a live summary like the three rows above it. A
        // title count would have to come from an engine library read on every recomposition of Settings, and
        // the two things a viewer might do here (export, import) are the honest summary anyway. Same rule as
        // the Add-ons and Media servers rows.
        SettingRow(VortXIcons.library, "Library", "Export, import", onClick = onLibraryClick)
        // Backup: a device-wide settings backup to a file (profiles included), distinct from the Library
        // export above (which carries saved titles only). Neither routes through account sync.
        SettingRow(VortXIcons.download, "Backup", "Settings to a file", onClick = onBackupClick)
        // Watch Stats: a read-only "year in review" over the ACTIVE profile's existing watch history
        // (com.vortx.android.stats). It reads the engine buckets (owner) or the private overlay (shared
        // profile) per the history boundary and never writes any watched state.
        SettingRow(VortXIcons.checkmarkCircle, "Watch Stats", "Your year in review", onClick = onWatchStatsClick)
        SettingRow(
            VortXIcons.checkmarkCircle,
            "What's New",
            "Version ${BuildConfig.VERSION_NAME}",
            onClick = onWhatsNewClick,
        )
        if (BuildConfig.DEBUG && onOpenGallery != null) {
            SettingRow(VortXIcons.checkmarkCircle, "Design gallery", "Debug", onClick = onOpenGallery)
        }
    }
}

@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    value: String,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        Icon(icon, contentDescription = null, tint = colors.accent)
        Text(title, style = VortXTheme.type.cardTitle, modifier = Modifier.fillMaxWidth(0.6f))
        Text(value, style = VortXTheme.type.label.copy(color = colors.textSecondary))
    }
}

/// A horizontally-scrolling row of [Chip]s, the shared shape behind every filter row in this file
/// (Discover type/catalog/genre, Library type/sort, Search recents).
@Composable
private fun ChipScrollRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        content = content,
    )
}

/// The dense poster grid shared by Discover/Library/Search (DESIGN-SYSTEM.md §4: "dense poster grid
/// (auto-fill minmax)"). [onRemove] non-null adds the Library "x" remove control per poster (§4
/// "Library": "poster grid with the remove (x) control"); [footer] renders a full-width trailing row
/// (Discover's "Load more").
@Composable
internal fun PosterGrid(
    items: List<MetaItem>,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    emptyHint: String,
    sectioned: Boolean = false,
    onRemove: ((String) -> Unit)? = null,
    // S10: attach the long-press catalog quick-action menu (Add to Library / Mark Watched / Unwatched)
    // to each card and honor the item's watched flag. On for Discover/Search result cards, off for the
    // Library grid (which uses its own remove ("x") badge instead).
    showMenu: Boolean = false,
    // Hoisted so the shell's active-tab re-tap can scroll this grid to the top; null = the grid owns its
    // own scroll state (Library, the offline preview).
    gridState: LazyGridState? = null,
    footer: (@Composable () -> Unit)? = null,
) {
    if (items.isEmpty()) {
        EmptyState(emptyHint, modifier)
        return
    }
    // Defense-in-depth against the "Load more" crash (GROUP 2a): `LazyVerticalGrid` requires unique keys.
    // The real fix dedupes
    // at the source ([com.vortx.android.engine.EngineState.parseCatalogWithFilters], where pages get
    // flattened/appended), but this grid is shared by Discover/Library/Search, so a belt-and-suspenders
    // dedupe HERE means no future caller can reintroduce this crash class either. distinctBy is a no-op
    // allocation-wise when there are no duplicates (the common case).
    val deduped = remember(items) { items.distinctBy(::searchResultItemKey) }
    val sections = remember(deduped, sectioned) {
        if (sectioned) searchResultSections(deduped) else listOf(SearchResultSection(null, deduped))
    }
    // Always remember a fallback state (unconditional Composable call); use the hoisted one when supplied.
    val ownGridState = rememberLazyGridState()
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 112.dp),
        state = gridState ?: ownGridState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(VortXTheme.spacing.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        sections.forEach { section ->
            section.kind?.let { kind ->
                item(key = searchResultSectionHeaderKey(kind), span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        text = stringResource(kind.titleResourceId),
                        style = VortXTheme.type.sectionTitle,
                        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.sm),
                    )
                }
            }
            items(section.items, key = ::searchResultItemKey) { item ->
                Box {
                    PosterCard(
                        title = item.name,
                        subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · "),
                        onClick = { onItem(item) },
                        progress = item.progress,
                        watched = item.watched,
                        menuItem = if (showMenu) item else null,
                        art = { PosterArt(item.poster, item.name, id = item.id, type = item.type.id) },
                    )
                    if (onRemove != null) {
                        RemoveBadge(
                            onClick = { onRemove(item.id) },
                            modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
                        )
                    }
                }
            }
        }
        if (footer != null) {
            item(span = { GridItemSpan(maxLineSpan) }) { footer() }
        }
    }
}

/// The Library grid's per-poster remove ("x") control: a small dark circular badge so it reads clearly
/// over any poster art, tapped directly (no long-press menu yet -- S10 adds the full long-press poster
/// menu per DESIGN-SYSTEM.md §4 "Collections").
@Composable
private fun RemoveBadge(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(26.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            VortXIcons.delete,
            contentDescription = "Remove from Library",
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
    }
}

/// The "Load more" control at the bottom of a Discover grid with another page available
/// (DESIGN-SYSTEM.md §4 "Discover / Search": "'Load more' (per-catalog skip)").
@Composable
private fun LoadMoreFooter(loading: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.md),
        horizontalArrangement = Arrangement.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(color = VortXTheme.colors.accent, modifier = Modifier.size(28.dp))
        } else {
            Chip(label = "Load more", selected = false, onClick = onClick)
        }
    }
}

/// The shimmer loading state for a poster grid (DESIGN-SYSTEM.md §3 "skeleton shimmer for loading").
@Composable
private fun ShimmerGrid() {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 112.dp),
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(VortXTheme.spacing.edge),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        items(List(9) { it }) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(2f / 3f)
                    .clip(VortXShapes.card)
                    .shimmer(),
            )
        }
    }
}
