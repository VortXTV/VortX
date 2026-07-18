import SwiftUI
import UserNotifications

/// Settings: who you're signed in as, the embedded streaming-server status, subtitles, and app info.
/// Mirrors the official tvOS app's Settings sections, on the StremioX design system.
struct SettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    // VortX-sync account (api.vortx.tv): the identity that mints the moat token which un-gates the Singularity
    // SERVE read. The Singularity toggle gates on THIS, not the Stremio `account` -- a Stremio-only sign-in
    // mints no token, so the toggle must require the VortX sign-in that the helper text already names.
    @EnvironmentObject private var vortxSync: VortXSyncManager
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @EnvironmentObject private var profiles: ProfileStore
    @State private var serverOnline: Bool?
    /// Settings search query. Empty shows the full settings tree; a non-empty query filters the sections
    /// below to those whose title or any of their row keywords contain it (case-insensitive substring).
    @State private var settingsQuery = ""
    @AppStorage("stremiox.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage("stremiox.hdrToneMapMode") private var hdrToneMapMode = "auto"   // auto / on / off
    // Match Frame Rate: HDRDisplayMode owns both the key and the display-mode behavior it drives, so the key
    // string lives there rather than being duplicated as a literal across the Settings screens.
    @AppStorage(HDRDisplayMode.matchFrameRateKey) private var matchFrameRate = HDRDisplayMode.defaultMatchFrameRate
    @State private var showRestartConfirm = false
    @State private var editingProfile: UserProfile?
    /// In-app UI language (tvOS had no picker before). "system" follows the Apple TV language.
    @State private var langSelection: String = AppLanguage.current ?? "system"
    @State private var showLangRestart = false
    // Diagnostic-log export over the LAN: the QR overlay flag + the started (url, qr) payload.
    @State private var showDiagExport = false
    @State private var diagExport: (url: String, qr: Image)?
    // Per-tab bar visibility (#117): the four hideable tabs, one key each (TabBarPrefs). Home,
    // Add-ons, and Settings have no toggle so the app can never lose its anchor or this screen.
    @AppStorage(TabBarPrefs.hideLive) private var hideLiveTab = false
    @AppStorage(TabBarPrefs.hideDiscover) private var hideDiscoverTab = false
    @AppStorage(TabBarPrefs.hideLibrary) private var hideLibraryTab = false
    @AppStorage(TabBarPrefs.hideSearch) private var hideSearchTab = false
    @AppStorage("vortx.home.showCollectionsHub") private var showHubHome = true
    @AppStorage("vortx.discover.showCollectionsHub") private var showHubDiscover = true
    // Top Shelf mirror of Continue Watching (the tvOS Home screen row). The writer reads this same key,
    // and the change handler below republishes so a toggle takes effect without waiting for a re-seed.
    @AppStorage(TopShelfSnapshotWriter.showKey) private var topShelfCW = TopShelfSnapshotWriter.showDefault
    @AppStorage("vortx.collections.refreshCadence") private var hubCadence = "daily"
    @AppStorage("vortx.detail.showFinancials") private var showFinancials = true
    @AppStorage("vortx.spoilerBlur") private var spoilerBlur = true
    // Spoiler-safe mode (SourcePreferences.spoilerSafeKey) supersets the legacy thumbnail-only blur: the ONE
    // visible row below drives both keys together so the detail views' `(spoilerSafe || spoilerBlur)` gate has
    // a single source of truth (no leftover legacy default-on blur when the user turns spoiler-safe off).
    @AppStorage(SourcePreferences.spoilerSafeKey) private var spoilerSafe = SourcePreferences.defaultSpoilerSafe
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @AppStorage(TrackPreferences.Key.forced) private var prefForced = TrackPreferences.ForcedPolicy.forced.rawValue
    @AppStorage(TrackPreferences.Key.audio) private var prefAudioLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subtitle) private var prefSubLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subOnlyPreferred) private var subOnlyPreferred = false
    // When "1", the audio language chain mirrors the subtitle chain (the audio pickers hide); "0" = independent.
    @AppStorage("stremiox.matchAudioSub") private var matchAudioSubRaw = "0"
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @AppStorage(PlaybackSettings.Key.customMpvOptions) private var customMpvOptions = ""
    @AppStorage(VXProbe.defaultsKey) private var probeLogging = false   // gated diagnostic logging + heartbeat
    @AppStorage(PerformanceMode.overrideKey) private var perfMode = "auto"
    @AppStorage(AudioOutputMode.key) private var audioOutput = AudioOutputMode.auto.rawValue
    @AppStorage(PlaybackSettings.Key.videoUpscaling) private var videoUpscaling = PlaybackSettings.videoUpscaling.rawValue
    // Streaming/seek cache budget, raw byte count (0 = Off, -1 = Unlimited). Int-typed @AppStorage; Int
    // is 64-bit on Apple TV, so the byte budgets are exact.
    @AppStorage(DiskCacheSetting.key) private var diskCacheBytes = 0   // Off by default, matching DiskCacheSetting.storedBytes; the cache is opt-in
    @AppStorage("stremiox.seekStep") private var seekStep = "10"   // skip step in seconds, shared with the player
    @AppStorage(PlayerEngineRouter.overrideKey) private var playerEngine = PlayerEngineRouter.Override.auto.rawValue
    @AppStorage(PlayerEngineRouter.dvRemuxKey) private var dvRemux = false   // Dolby Vision for MKV (Beta): in-app remux -> AVPlayer; default OFF
    @AppStorage("stremiox.autoSkip") private var autoSkip = false  // auto-skip intro/credits, shared with iOS/Mac
    // Trailer language (D11): the ISO-639-1 code the trailer picker prefers when choosing the YouTube id. Empty
    // = follow the app UI language (the default). Read by TMDBClient.preferredTrailerLanguages / trailerLanguageBaseCode.
    @AppStorage("stremiox.trailerLanguage") private var trailerLanguage = ""
    @AppStorage(CommunityTrickplay.settingKey) private var communityTrickplay = true  // share/fetch scrub previews
    // Give-to-get master switch: contribute + consume the whole community data pool. Default ON. Off = out of
    // the pool entirely (no contribute, no consume of any moat feature). See MoatConsent.
    @AppStorage(MoatConsent.key) private var moatContribute = true
    // "Singularity" community source index SERVE opt-in (per device). Default ON; requires sign-in to use.
    @AppStorage(SourceIndexClient.serveKey) private var singularityServe = true
    @AppStorage(SkipTimestampService.providerKey) private var skipProvider = "both"
    @AppStorage(ExternalPlayers.defaultKey) private var defaultExternalPlayer = ""   // "" == built-in libmpv
    // Stremio mirror (account-owns-everything): default OFF = VortX keeps its own copy of each category;
    // ON = VortX tracks Stremio (adds and removes) for that category.
    @AppStorage(MirrorSettings.addonsKey) private var mirrorAddons = false
    @AppStorage(MirrorSettings.libraryKey) private var mirrorLibrary = false
    @AppStorage(MirrorSettings.continueWatchingKey) private var mirrorCW = false
    @ObservedObject private var sourcePrefs = SourcePreferences.shared
    @ObservedObject private var pinStore = SourcePinStore.shared
    // Autoplay trailers (the "hero" master switch): the muted autoplay trailer in the featured hero /
    // detail hero. Default ON. SAME key the iOS/Mac view binds. Read by the hero + trailer paths.
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
    // Auto-add watched to Library (D8): a title is added to the Library once ~60s of it has played.
    // Default ON. SAME key iOS/Mac binds; read at the 60s progress tick in the player.
    @AppStorage("stremiox.autoAddLibrary") private var autoAddLibrary = true
    // Default player volume 0-100 (D5): the level a new playback starts at. The in-player volume slider
    // writes this same key, so the last level persists; this picker sets it explicitly. SAME key as iOS/Mac.
    @AppStorage("stremiox.playerVolume") private var playerVolume = 100.0
    // Compact source rows (#117): parsed quality line instead of the raw release name. SAME key as iOS/Mac.
    @AppStorage("vortx.streams.compactLabels") private var compactStreamLabels = false
    // New-episode alerts (F5): a local notification at each upcoming episode's air time. Default ON. SAME key
    // the iOS view's NewEpisodeNotifications.enabledKey resolves to ("stremiox.notifyNewEpisodes"); that type
    // lives in a SourcesiOS file the tvOS target does not compile, so tvOS reads the raw key and requests
    // authorization through UNUserNotificationCenter directly (see setNotifyNewEpisodes below).
    @AppStorage("stremiox.notifyNewEpisodes") private var notifyNewEpisodes = true
    // Auto-delete watched downloads: a completed download whose title becomes fully finished-watched has its
    // file + record removed to reclaim space. Default OFF, so the feature stays inert until opted into. SAME
    // key iOS/Mac binds (DownloadManager.autoDeleteWatchedDefaultsKey is the single source of truth for the
    // name). Enforcement is already cross-platform: DownloadManager reads this key straight off UserDefaults
    // at each finished-watched signal, and that path is in SourcesShared with no os(iOS) guard, so tvOS was
    // already honouring the key with no way to set it here.
    @AppStorage(DownloadManager.autoDeleteWatchedDefaultsKey) private var autoDeleteWatched = false
    /// Deterministic Down-chain insurance across the three top account rows so the spatial focus
    /// engine cannot skip Log Out (it stranded far-right before 80fb9d2 and the owner could not reach it).
    private enum AccountFocus: Hashable { case vortx, importStremio }
    @FocusState private var accountFocus: AccountFocus?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Settings").screenTitleStyle()
                    // Focusable search field: typing filters the sections below (additive, the whole tree
                    // stays intact and returns the moment the field is cleared). Each section is gated by
                    // `sectionMatches`, so an empty query shows everything and a query keeps only the hits.
                    searchSection
                    if isSearching && !hasAnySettingsMatch {
                        noSettingsMatchSection
                    }
                    if sectionMatches(.profiles) { profilesSection }
                    if sectionMatches(.account) { accountSection }
                    if sectionMatches(.stremioMirror) { stremioMirrorSection }
                    if sectionMatches(.playback) { playbackSection }
                    if sectionMatches(.downloads) { downloadsSection }
                    if sectionMatches(.notifications) { notificationsSection }
                    if sectionMatches(.streams) { streamsSection }
                    if sectionMatches(.community) { communitySection }
                    if sectionMatches(.server) { serverSection }
                    if sectionMatches(.tabBar) { tabBarSection }
                    if sectionMatches(.appearance) { appearanceSection }
                    if sectionMatches(.audioSubtitle) { audioSubtitleSection }
                    if sectionMatches(.subtitle) { subtitleSection }
                    if sectionMatches(.advanced) { advancedSection }
                    if sectionMatches(.backup) { backupSection }
                    if sectionMatches(.about) { aboutSection }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        .fullScreenCover(isPresented: $showDiagExport, onDismiss: {
            VXDiagExport.shared.stop()
            diagExport = nil
        }) {
            diagExportSheet
        }
        // Track-language and subtitle-style edits belong to the ACTIVE profile: fold every
        // flat-key change back into it (the captureTheme pattern, RootTabView does the same for
        // the theme). The equality guard inside capturePlayback stops a profile switch's own
        // flat-key writes from echoing back as roster edits.
        .onChange(of: prefAudioLang) { StreamRanking.invalidateCaches(); ProfileStore.shared.capturePlayback() }
        .onChange(of: prefSubLang) { if matchAudioSubRaw == "1", prefAudioLang != prefSubLang { prefAudioLang = prefSubLang }; ProfileStore.shared.capturePlayback() }
        .onChange(of: matchAudioSubRaw) { if matchAudioSubRaw == "1", prefAudioLang != prefSubLang { prefAudioLang = prefSubLang } }
        .onChange(of: prefForced) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subFont) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subSize) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subColor) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subBackground) { ProfileStore.shared.capturePlayback() }
        // Source-ranking taste AND the 13 stream filters are per-profile, but they bind DIRECTLY to
        // the SourcePreferences singleton (no @AppStorage mirror), so without a capture a filter
        // edit lived ONLY in the flat keys: the roster stayed nil and the first profile switch's
        // resetUnset apply wiped it (b176 review finding). ONE aggregate trigger instead of a
        // per-field chain: rankingSignature already folds every ranking/filter knob (type order,
        // add-on order, all 13 filters) into a single string by design, so any change re-fires it,
        // and 13 chained onChange modifiers blew this body's type-check budget (b176 gate). The
        // equality guard inside capturePlayback keeps a switch's own reload() echo from becoming a
        // roster edit unless it genuinely materializes new values.
        .onChange(of: sourcePrefs.rankingSignature) { ProfileStore.shared.capturePlayback() }
        .task {
            // Live server monitor that NEVER gives up. The embedded server cold-starts well after
            // launch on a real Apple TV (node boots while the engine and sync are also busy), and
            // the old 24-second window could expire first, showing "Offline" until a relaunch.
            // Retries fast while offline, keeps the badge fresh once up; restarts on each visit.
            while !Task.isCancelled {
                if effectiveDirectLinksOnly {
                    serverOnline = nil
                    try? await Task.sleep(for: .seconds(12))
                    continue
                }
                let online = await StremioServer.isOnline()
                serverOnline = online
                try? await Task.sleep(for: .seconds(online ? 12 : 3))
            }
        }
    }

    // MARK: Settings search

    /// The trimmed, lowercased query, computed once per body pass so `sectionMatches` is a plain `contains`.
    private var trimmedSettingsQuery: String {
        settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether the user is actively filtering. An empty (or whitespace-only) field is treated as no filter.
    private var isSearching: Bool { !trimmedSettingsQuery.isEmpty }

    /// A section shows when there is no query, or when the query is a case-insensitive substring of the
    /// section's title or any of its row keywords.
    private func sectionMatches(_ id: SettingsSearchSection) -> Bool {
        let q = trimmedSettingsQuery
        guard !q.isEmpty else { return true }
        if id.title.lowercased().contains(q) { return true }
        return id.keywords.contains { $0.contains(q) }
    }

    /// True when at least one section matches the current query (drives the empty-state card).
    private var hasAnySettingsMatch: Bool {
        SettingsSearchSection.allCases.contains { sectionMatches($0) }
    }

    /// The focusable search field at the top of Settings. Focusing it opens the tvOS keyboard; typing
    /// filters the sections below and the Clear chip (or emptying the field) restores the full tree. Sits
    /// on the same settings-card glass as every section so it reads as part of the same surface.
    private var searchSection: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search settings", text: $settingsQuery)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .autocorrectionDisabled(true)
            if !settingsQuery.isEmpty {
                Button { settingsQuery = "" } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
        .focusSection()
    }

    /// Shown in place of the settings tree when a query matches nothing, so the screen is never blank.
    private var noSettingsMatchSection: some View {
        section("No matches") {
            Text("No settings match \"\(settingsQuery)\".")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        section("Profiles") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            editingProfile = profile
                        } label: {
                            HStack(spacing: 8) {
                                Text(profile.avatar)
                                Text(profile.name)
                                if profile.hasPin { Image(systemName: "lock.fill") }
                            }
                        }
                        .buttonStyle(ChipButtonStyle(selected: profile.id == profiles.activeID))
                    }
                    Button {
                        editingProfile = UserProfile(name: "", avatar: "🎬", accentID: theme.accentID)
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .buttonStyle(ChipButtonStyle())
                    if profiles.profiles.count > 1 {
                        Button {
                            profiles.pickedThisLaunch = false   // re-presents the launch picker
                        } label: {
                            Label("Switch Profile", systemImage: "person.2.fill")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(.vertical, Theme.Space.xs / 2)
            }
            Text("Select a profile to edit it. Each profile keeps its own look, languages, PIN, and optionally its own Stremio account. A profile with a PIN asks for it before it can be edited.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
        .fullScreenCover(item: $editingProfile) { profile in
            ProfileEditorView(original: profile)
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        section(String(localized: "Account")) {
            // The whole account block is one focus section so Down keeps stepping DOWN through its
            // stacked rows instead of leaving after the first hit. Every focusable row (including the
            // Log Out button below) is left-aligned and full-width, so the spatial focus engine's
            // downward beam stays in-column and never skips a row.
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                // LEAD with the VortX account: the app's own identity, shown prominently at the very top.
                // Its state is `vortxSync` (api.vortx.tv), NOT the Stremio `account`. Stremio, Trakt, and
                // SIMKL are optional and now live behind the Integrations screen.
                if vortxSync.isSignedIn, let vx = vortxSync.account {
                    // Identity is a non-focusable info row; the account/sync row below is the focus target.
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(vx.email).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                            Text("VortX · @\(vx.username) · end-to-end encrypted sync")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    NavigationLink { SyncSettingsView() } label: {
                        Label("VortX account & sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .focused($accountFocus, equals: .vortx)
                } else {
                    Text("Sign in to VortX to sync your profiles, settings, and library across your devices.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    // LoginView is VortX-primary (its QR joiner defaults to the VortX account), so it is
                    // labelled and routed as the VortX sign-in, correcting the old "Sign in to your Stremio
                    // account" mislabel that opened this same VortX-primary screen.
                    NavigationLink { LoginView(account: account) } label: {
                        Label("Sign in to VortX", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .focused($accountFocus, equals: .vortx)
                    NavigationLink { SyncSettingsView() } label: {
                        Label("VortX account & sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
                // Optional imports and services that enrich VortX (Stremio, Trakt, SIMKL, Nuvio).
                NavigationLink { IntegrationsSettingsView() } label: {
                    Label("Integrations", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { StremioImportView() } label: {
                    Label("Import from Stremio", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .focused($accountFocus, equals: .importStremio)
                NavigationLink { MetadataKeysView() } label: {
                    Label("Metadata (TMDB, MDBList, fanart)", systemImage: "sparkles")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { DebridKeysView() } label: {
                    Label("Debrid services", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { XRDBSettingsView() } label: {
                    Label("Poster artwork (ERDB, ratings)", systemImage: "star.circle")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { IPTVSettingsView() } label: {
                    Label("Live TV (IPTV playlists)", systemImage: "tv")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { MediaServersSettingsView() } label: {
                    Label("Media servers (Plex, Jellyfin, Emby)", systemImage: "externaldrive.connected.to.line.below")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    // MARK: Stremio mirror

    /// Per-category control of whether VortX mirrors a connected Stremio account. Off (the default) keeps
    /// a VortX copy of each category so a Stremio removal never removes it from VortX; On makes VortX
    /// track Stremio (adds and removes) for that category. Hydration always keeps the VortX-owned set
    /// alive even when signed out of Stremio, independent of these.
    @ViewBuilder private var stremioMirrorSection: some View {
        section(String(localized: "Stremio mirror")) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                choiceRow(String(localized: "Two-way sync add-ons with Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorAddons ? "1" : "0" }, set: { mirrorAddons = ($0 == "1") }))
                choiceRow(String(localized: "Mirror library from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorLibrary ? "1" : "0" }, set: { mirrorLibrary = ($0 == "1") }))
                choiceRow(String(localized: "Mirror Continue Watching from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorCW ? "1" : "0" }, set: { mirrorCW = ($0 == "1") }))
                Text("Off (recommended) is one-way: VortX pulls in your Stremio add-ons but never edits your Stremio account, so removing an add-on in VortX hides it here only and leaves your Stremio account untouched. On is two-way: adding or removing an add-on in VortX also adds or removes it in your Stremio account. Your add-ons, library, and Continue Watching always stay even when you are signed out of Stremio.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        section("Playback") {
            if PlaybackSettings.directLinksOnlyForced {
                directLinksOnlyRow
                    .vortxSettingsCard()
            } else {
                Button { setDirectLinksOnly(!directLinksOnly) } label: {
                    directLinksOnlyRow
                }
                .buttonStyle(RowFocusStyle())
            }
            choiceRow(String(localized: "Audio output"), AudioOutputMode.allCases.map { ($0.rawValue, $0.label) }, selection: $audioOutput)
            Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? "")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Video upscaling"), VideoUpscaling.allCases.map { ($0.rawValue, $0.label) }, selection: $videoUpscaling)
            Text(VideoUpscaling(rawValue: videoUpscaling)?.detail ?? "")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Streaming cache"),
                      DiskCacheSetting.pickerOptions.map { (String($0.id), $0.label) },
                      selection: Binding(get: { String(diskCacheBytes) },
                                         set: { diskCacheBytes = Int($0) ?? Int(DiskCacheSetting.defaultBytes) }))
            Text(diskCacheFooter)
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Player engine"), PlayerEngineRouter.Override.allCases.map { ($0.rawValue, $0.label) }, selection: $playerEngine)
            Text("Auto plays HLS and Dolby Vision through AVPlayer (AirPlay and Picture in Picture), with the full player controls, and uses the built-in libmpv player for torrents, MKV, and anything AVPlayer cannot open. If a stream will not start, choose Always libmpv.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Dolby Vision for MKV (Beta)"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { dvRemux ? "1" : "0" }, set: { dvRemux = ($0 == "1") }))
            Text("Plays Dolby Vision .mkv from debrid via an in-app remux. Experimental; falls back automatically if it fails.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Skip step"), [("10", "10s"), ("15", "15s"), ("30", "30s")], selection: $seekStep)
            choiceRow(String(localized: "Auto-skip intro & credits"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoSkip ? "1" : "0" }, set: { autoSkip = ($0 == "1") }))
            choiceRow(String(localized: "Skip timestamps source"), [("theintrodb", "TheIntroDB"), ("skipdb", "SkipDB"), ("both", "Both")],
                      selection: $skipProvider)
            NavigationLink { SkipKeysView() } label: {
                Label("Skip database key", systemImage: "checkmark.bubble")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            // Autoplay trailers: the master switch for the muted autoplay trailer in the featured hero /
            // detail hero (the "hero" setting). Default ON. SAME key iOS/Mac binds.
            choiceRow(String(localized: "Autoplay trailers"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoplayTrailers ? "1" : "0" }, set: { autoplayTrailers = ($0 == "1") }))
            Text("Play a muted trailer automatically in the featured hero and on a title's detail page.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Trailer language (D11): the language the trailer picker prefers when choosing the YouTube id.
            // "App language" (the empty tag, the default) follows the app UI language; a set value becomes the
            // highest-priority trailer language in TMDBClient.preferredTrailerLanguages. Mirrors iOS/Mac.
            choiceRow(String(localized: "Trailer language"), trailerLanguageOptions, selection: $trailerLanguage)
            choiceRow(String(localized: "Play in"), externalPlayerChoices, selection: $defaultExternalPlayer)
            Text("Direct and debrid streams open in your chosen player automatically. Torrents and the built-in player are unaffected.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            NavigationLink { SeekBarStylePicker() } label: {
                Label("Seek bar style", systemImage: "slider.horizontal.below.rectangle")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            choiceRow(String(localized: "Community scrub previews"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { communityTrickplay ? "1" : "0" }, set: { communityTrickplay = ($0 == "1") }))
            Text("Share and reuse scrub-preview thumbnails across the community, so previews appear instantly without each device regenerating them. Only the generated thumbnails are shared, never any account data.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Default player volume (D5): the level a new playback starts at. The in-player volume slider
            // writes the same key, so this also reflects the last level used. Coarse 0/25/50/75/100 steps,
            // plus the exact current level as its own chip when the in-player slider left it off-step (e.g.
            // 60%), so the picker never snap-misreports the real starting level. SAME key as iOS/Mac.
            choiceRow(String(localized: "Default volume"), playerVolumeOptions,
                      selection: Binding(get: { String(Int(playerVolume.rounded())) },
                                         set: { playerVolume = Double(Int($0) ?? 100) }))
            // Auto-add a title to the Library once ~60s of it has played (D8). Default ON. The engine adds it
            // through the account library on the main profile; overlay profiles are skipped. SAME key as iOS/Mac.
            choiceRow(String(localized: "Auto-add watched to Library"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoAddLibrary ? "1" : "0" }, set: { autoAddLibrary = ($0 == "1") }))
            Text("Adds a title to your Library once about a minute of it has played, so it is easy to find again.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Coarse 0/25/50/75/100 volume steps, plus the exact current level as its own chip when the in-player
    /// fine slider left `stremiox.playerVolume` off-step (e.g. 60), so the picker shows the real value
    /// instead of snapping it to a wrong neighbour. Mirrors the iOS `playerVolumeSteps`.
    private var playerVolumeOptions: [(id: String, label: String)] {
        let steps = [0, 25, 50, 75, 100]
        let current = Int(playerVolume.rounded())
        let all = steps.contains(current) ? steps : (steps + [current]).sorted()
        return all.map { (id: String($0), label: $0 == 100 ? String(localized: "Max (100%)") : "\($0)%") }
    }

    // MARK: Downloads

    /// Auto-delete watched downloads. UI only: the enforcement already runs here, since DownloadManager
    /// reads the same key off UserDefaults at each finished-watched signal from shared code. This is the
    /// switch that was missing on Apple TV, bound to the SAME key the iOS/Mac view binds, with the same copy.
    /// Downloads have their own screen on Apple TV, so this sits in Settings next to the other opt-ins rather
    /// than on the Downloads screen, matching where iOS/Mac put it.
    private var downloadsSection: some View {
        section(String(localized: "Downloads")) {
            choiceRow(String(localized: "Auto-delete watched downloads"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoDeleteWatched ? "1" : "0" },
                                         set: { autoDeleteWatched = ($0 == "1") }))
            Text("When on, a completed download is removed automatically once you finish watching it, to reclaim space. Off by default, so downloads stay until you delete them.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Notifications

    /// New-episode alerts (F5). Same key + behavior as the iOS view: enabling requests notification
    /// authorization and settles the stored flag to the real grant; disabling clears pending alerts.
    private var notificationsSection: some View {
        section(String(localized: "Notifications")) {
            choiceRow(String(localized: "New episode alerts"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { notifyNewEpisodes ? "1" : "0" },
                                         set: { setNotifyNewEpisodes($0 == "1") }))
            Text("Get a notification when a new episode of a series you open is about to air. Scheduled on-device for upcoming episodes, so no background tracking is needed.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Turn new-episode alerts on/off. Enabling asks the system for permission and stores the real grant (a
    /// denial settles the flag back off); disabling clears the flag and every pending alert. This mirrors
    /// `NewEpisodeNotifications.setEnabled`, inlined here because that type lives in a SourcesiOS file the
    /// tvOS target does not compile. The SAME `stremiox.notifyNewEpisodes` key is written either way.
    private func setNotifyNewEpisodes(_ on: Bool) {
        guard on else {
            notifyNewEpisodes = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notifyNewEpisodes = granted
        }
    }

    /// Give-to-get master switch + the opt-in "Singularity" community source index. The master toggle
    /// governs whether this device both contributes anonymized metadata AND consumes every pooled feature;
    /// off = out of the whole pool. Singularity SERVE is a further per-device opt-in that also needs sign-in.
    private var communitySection: some View {
        section(String(localized: "Community")) {
            choiceRow(String(localized: "Contribute anonymized data to improve results"),
                      [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { moatContribute ? "1" : "0" }, set: { moatContribute = ($0 == "1") }))
            Text(MoatConsent.disclosure)
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            if moatContribute {
                if vortxSync.isSignedIn {
                    choiceRow(String(localized: "Singularity sources"), [("0", "Off"), ("1", "On")],
                              selection: Binding(get: { singularityServe ? "1" : "0" }, set: { singularityServe = ($0 == "1") }))
                    Text("Show extra community-corroborated sources alongside your own, pooled across signed-in VortX users.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text("Sign in to VortX to turn on Singularity sources.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    /// Built-in plus every curated external player; picking one auto-hands eligible streams to it.
    private var externalPlayerChoices: [(String, String)] {
        [("", "Built-in player")] + ExternalPlayers.menu().map { ($0.id, $0.name) }
    }

    /// Explains the streaming cache and shows live on-disk usage when on. On the Apple TV HD the cache
    /// is additionally capped tight; Unlimited is always bounded to half of free storage and cleared
    /// when a title finishes, so it never fills the device.
    private var diskCacheFooter: String {
        let base = String(localized: "A bigger streaming cache buffers more video on disk so you can seek minutes ahead without re-buffering. Unlimited is still capped to half your free storage and the cache clears when a title finishes, so it never fills your Apple TV.")
        guard diskCacheBytes != 0 else { return base }
        // currentUsageBytes sums the on-disk mpv-cache dir, which stays EMPTY on this MPVKit build (the
        // buffer is RAM-resident, not offloaded to disk), so it always read "0 KB" and looked broken. Show
        // the real RAM-bounded budget the player will actually use instead (floored at 64 MiB, clamped to
        // the device-safe ceiling), which is an honest non-zero number visible in Settings.
        let budget = DiskCacheSetting.humanReadable(DiskCacheSetting.resolvedMaxBytes())
        return base + " " + String(localized: "Cache budget: \(budget).")
    }

    private var effectiveDirectLinksOnly: Bool {
        PlaybackSettings.directLinksOnly
    }

    private var directLinksOnlyRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Direct Links Only")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(PlaybackSettings.directLinksOnlyForced
                     ? "This build does not bundle the torrent engine. Only direct and debrid links can play."
                     : "Hide torrent and magnet sources. Only direct and debrid links will play.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.md)
            if PlaybackSettings.directLinksOnlyForced {
                UnavailableBadge(text: "Not bundled")
            } else {
                TogglePill(isOn: effectiveDirectLinksOnly)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func setDirectLinksOnly(_ value: Bool) {
        directLinksOnly = value
        #if !VORTX_NO_EMBEDDED_SERVER
        if !value, !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
        }
        #endif
    }

    // MARK: Streaming server

    private var serverSection: some View {
        section("Streaming Server") {
            HStack(spacing: Theme.Space.sm) {
                Circle().fill(serverColor).frame(width: 16, height: 16)
                Text(serverText).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(serverBadgeText)
                    .font(Theme.Typography.eyebrow).tracking(1)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.Palette.surface3, in: Capsule())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            if effectiveDirectLinksOnly {
                Text(PlaybackSettings.directLinksOnlyForced
                     ? "This build does not bundle the streaming server."
                     : "Direct Links Only is enabled, so torrent streaming and server configuration are inactive.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(StremioServer.base)
                    .font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                // When the embedded server is unreachable, explain itself: node's run state and the
                // server's own last log lines, so a dead server is diagnosable from the couch.
                if serverOnline == false && !StremioServer.isCustom {
                    #if !VORTX_NO_EMBEDDED_SERVER
                    Text(NodeServer.statusDescription)
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    ForEach(NodeServer.logTail(), id: \.self) { line in
                        Text(line).font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
                    }
                    #endif
                }
                // Apple TV has no user-facing force quit, and a dead embedded server can
                // only come back with a fresh process (node starts once per process).
                Button { showRestartConfirm = true } label: {
                    Label("Restart App", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(ChipButtonStyle())
                .confirmationDialog("Restart VortX?", isPresented: $showRestartConfirm, titleVisibility: .visible) {
                    Button("Quit Now", role: .destructive) {
                        DiagnosticsLog.logSync("app", "user requested app restart from Settings")
                        exit(0)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The app quits immediately. Open it again from the Home Screen; the streaming server restarts with it.")
                }
                NavigationLink {
                    ServerConfigView { Task { serverOnline = await StremioServer.isOnline() } }
                } label: {
                    Label("Configure server", systemImage: "server.rack")
                }
                .buttonStyle(PrimaryActionStyle())
            }
        }
    }

    private var serverColor: Color {
        if effectiveDirectLinksOnly { return Theme.Palette.textTertiary }
        switch serverOnline {
        case .some(true): return Color(.sRGB, red: 0.45, green: 0.72, blue: 0.42)
        case .some(false): return Theme.Palette.danger
        default: return Theme.Palette.accent
        }
    }
    private var serverText: String {
        if effectiveDirectLinksOnly { return "Disabled by Direct Links Only" }
        switch serverOnline { case .some(true): return "Online"; case .some(false): return "Offline"; default: return "Checking…" }
    }
    private var serverBadgeText: String {
        if effectiveDirectLinksOnly {
            return PlaybackSettings.directLinksOnlyForced ? "NOT BUNDLED" : "DISABLED"
        }
        return StremioServer.isCustom ? "CUSTOM" : "EMBEDDED"
    }

    // MARK: Tab bar

    /// Which tabs show in the tab bar (#117), generalizing the old "Show Live TV tab" toggle into a
    /// per-tab choice (SAME TabBarPrefs keys the iOS/Mac shell binds). Home / Add-ons / Settings have
    /// no toggle: the shell must always keep its landing anchor and the way back to this screen.
    /// RootTabView heals the selection to Home when the active tab is hidden.
    private var tabBarSection: some View {
        section("Tab Bar") {
            choiceRow(String(localized: "Discover tab"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideDiscoverTab ? "0" : "1" }, set: { hideDiscoverTab = ($0 == "0") }))
            choiceRow(String(localized: "Live TV tab"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideLiveTab ? "0" : "1" }, set: { hideLiveTab = ($0 == "0") }))
            choiceRow(String(localized: "Library tab"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideLibraryTab ? "0" : "1" }, set: { hideLibraryTab = ($0 == "0") }))
            choiceRow(String(localized: "Search tab"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideSearchTab ? "0" : "1" }, set: { hideSearchTab = ($0 == "0") }))
            Text("Choose which tabs appear in the tab bar. Home, Add-ons, and Settings always stay. If the tab you are on is hidden, you land on Home.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Appearance (accent + chrome)

    /// "App language" (the empty tag = follow the app UI language) + every shipped language, for the Trailer
    /// language picker (D11). Distinct from `appLanguageOptions`: the empty tag matches the `stremiox.trailerLanguage`
    /// unset convention (`TMDBClient.trailerLanguageOverride` treats empty as unset), mirroring iOS/Mac.
    private var trailerLanguageOptions: [(id: String, label: String)] {
        [(id: "", label: String(localized: "App language"))] + AppLanguage.supported.map { (id: $0.code, label: $0.name) }
    }

    /// "System Default" + every shipped language, for the App Language picker on tvOS.
    private var appLanguageOptions: [(id: String, label: String)] {
        [(id: "system", label: "System Default")] + AppLanguage.supported.map { (id: $0.code, label: $0.name) }
    }

    private var appearanceSection: some View {
        section("Appearance") {
            ThemeAccentPicker(selection: $theme.accentID).focusSection()
            ThemeBackgroundPicker(oled: $theme.oled).focusSection()
            Text("Accent recolors focus, selection, and progress across the app. OLED Black uses true black, best on AMOLED panels.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "App Language"), appLanguageOptions, selection: Binding(
                get: { langSelection },
                set: { newValue in
                    langSelection = newValue
                    AppLanguage.set(newValue == "system" ? nil : newValue)
                    showLangRestart = true
                }))
            Text("Switches the whole app to this language. VortX must quit and reopen to apply it.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Cinematic catalog cards"), [("1", "Landscape"), ("0", "Portrait")],
                      selection: Binding(get: { catalogPrefs.landscapeCards ? "1" : "0" }, set: { catalogPrefs.landscapeCards = ($0 == "1") }))
            Text("Show catalog posters as wide cinematic cards using clean TMDB artwork. Needs a TMDB key (set one under API keys); without it cards stay portrait. Choose Portrait for the classic poster grid.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Standalone hide-labels toggle (SAME key as the Poster Style screen's toggle), surfaced here so
            // it is discoverable without opening Poster style. Applies across every poster rail.
            choiceRow(String(localized: "Hide poster labels"), [("1", "Hide"), ("0", "Show")],
                      selection: Binding(get: { catalogPrefs.hidePosterLabels ? "1" : "0" }, set: { catalogPrefs.hidePosterLabels = ($0 == "1") }))
            NavigationLink { TVPosterStyleView() } label: {
                Label("Poster style", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Tune poster width, corner radius, landscape 16:9 art, and labels, with a live preview.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Top Shelf: the row tvOS shows on its OWN Home screen when VortX is focused, above the app
            // grid. Opt-out (default Show), because that row is visible to the whole room the moment the
            // TV wakes, without opening VortX and without passing the profile picker.
            // Republished from the SETTER, not a chained `.onChange` on the body: this section's body
            // already sits against the type-check budget that the b176 gate hit, and one more chained
            // modifier is how that regresses. It also has to be immediate rather than left to Home's
            // next re-seed, because someone who just hid the row may well press the TV button straight
            // from here, and the shelf must already be cleared when they land. @AppStorage writes
            // through synchronously, so the publish below reads the value just set.
            choiceRow(String(localized: "Continue Watching on the TV Home screen"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { topShelfCW ? "1" : "0" },
                                         set: { topShelfCW = ($0 == "1"); TopShelfSnapshotWriter.publishCurrent() }))
            Text("Puts what you are part-way through on the Apple TV Home screen, above the apps, so it is one press away. Hide it to keep your viewing off that screen.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Collections on Home"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showHubHome ? "1" : "0" }, set: { showHubHome = ($0 == "1") }))
            choiceRow(String(localized: "Collections on Discover"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showHubDiscover ? "1" : "0" }, set: { showHubDiscover = ($0 == "1") }))
            choiceRow(String(localized: "Refresh collections"), [("daily", "Daily"), ("twiceDaily", "Twice"), ("fourTimesDaily", "4x")],
                      selection: $hubCadence)
            NavigationLink { TVReorderServicesView() } label: {
                Label("Streaming services", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            NavigationLink { TVDiscoverSettingsView() } label: {
                Label("Discover & region", systemImage: "globe")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            // The full "Upcoming" calendar (next air / release dates of library + watchlisted titles).
            NavigationLink { TVUpcomingScreen() } label: {
                Label("Upcoming", systemImage: "calendar")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Discover cards, Streaming-service tiles, and Genre tiles high on Home and Discover; tap a tile to browse its catalogs (Movies, Shows, New, Top week/month/year, Trending). Needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Budget & box office"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showFinancials ? "1" : "0" }, set: { showFinancials = ($0 == "1") }))
            Text("Show a movie's budget, box office, and profit on its detail page. Movies only; needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Spoiler-safe mode supersets the old thumbnail-only blur: it veils an unwatched episode's art AND
            // synopsis. One row drives both the new key and the legacy `vortx.spoilerBlur` so turning it off
            // fully clears the veil (no leftover legacy default-on blur). Retires the separate blur row.
            choiceRow(String(localized: "Spoiler-safe mode"), [("1", "On"), ("0", "Off")],
                      selection: Binding(get: { spoilerSafe ? "1" : "0" },
                                         set: { spoilerSafe = ($0 == "1"); spoilerBlur = ($0 == "1") }))
            Text("Veils art and synopsis for episodes you have not watched yet, to avoid spoilers.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Dolby Vision / HDR"), [("auto", "Auto"), ("on", "Tone-map to SDR"), ("off", "Always HDR")], selection: $hdrToneMapMode)
            Text("Auto tone-maps HDR and Dolby Vision to SDR only on a TV that can't show HDR. Choose Tone-map to SDR if 4K Dolby Vision remuxes look washed out, green or purple on your TV; Always HDR forces pass-through.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Frame-rate matching is SDR-only by design: HDR and Dolby Vision titles already ask for their own
            // frame rate as part of the display-mode switch, so this row adds nothing for them and does not
            // gate them either.
            choiceRow(String(localized: "Match Frame Rate"), [("1", "On"), ("0", "Off")],
                      selection: Binding(get: { matchFrameRate ? "1" : "0" }, set: { matchFrameRate = ($0 == "1") }))
            Text("Sends a film at its own frame rate, so 24p titles play smoothly instead of juddering in slow pans. Needs Settings > Video and Audio > Match Content > Match Frame Rate turned on in tvOS. Takes effect on the next title you play.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            stepperRow(String(localized: "App text size"), value: theme.textScale,
                       range: ThemeManager.textScaleRange,
                       onMinus: { theme.adjustTextScale(-1) },
                       onPlus: { theme.adjustTextScale(1) })
            Text("Makes every screen's text larger or smaller. Changes apply instantly.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Performance"), [("auto", "Auto"), ("full", "Full"), ("reduced", "Reduced")], selection: $perfMode)
            Text("Auto keeps the full experience on capable Apple TVs and switches to a lighter one on older models like the Apple TV HD. Reduced trims animations and shrinks playback buffers so the remote stays responsive on weak hardware. Restart the app after changing this.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        .confirmationDialog("Apply language?", isPresented: $showLangRestart, titleVisibility: .visible) {
            Button("Quit Now", role: .destructive) {
                DiagnosticsLog.logSync("app", "user requested app restart to apply language")
                exit(0)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("VortX needs to quit and reopen to display the app in the new language. Open it again from the Home Screen.")
        }
    }

    // MARK: Stream source preferences

    private var streamsSection: some View {
        section("Streams") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Quality preset")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: Theme.Space.md) {
                    ForEach(SourcePreset.allCases) { preset in
                        Button(preset.label) { sourcePrefs.apply(preset) }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
                Text("A one-tap starting point; fine-tune the controls below. Your source-type order saves per profile.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            .focusSection()
            // Smart Source Selection (Lane A): the shared chip panel (Prefer / Only / Avoid + Avoid behavior +
            // Auto-pick + live preview), binding directly to the SourcePreferences singleton like the rest of
            // this section.
            SourceFilterChipsView(prefs: sourcePrefs)
                .focusSection()
            Toggle(isOn: $sourcePrefs.useAddonOrder) {
                Text("Use add-on ranking order")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            Text("When on, streams appear in the order your add-ons return them. Useful if you use a ranking add-on like AIOStreams. When off, the app's own ranking applies.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            if !sourcePrefs.useAddonOrder {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Source type priority")
                        .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    ForEach(Array(sourcePrefs.typeOrder.enumerated()), id: \.element) { index, sourceType in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sourceType.label)
                                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                                Text(sourceType.detail)
                                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Button {
                                    sourcePrefs.moveType(at: index, direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .opacity(index == 0 ? 0.3 : 1)
                                .disabled(index == 0)
                                Button {
                                    sourcePrefs.moveType(at: index, direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .opacity(index == sourcePrefs.typeOrder.count - 1 ? 0.3 : 1)
                                .disabled(index == sourcePrefs.typeOrder.count - 1)
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
                .focusSection()
                Text("Sources matching the top type are ranked first within each quality tier. Debrid and Usenet are always instant; Torrent streams require peer availability.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            choiceRow(String(localized: "Safety filter"), [("off", "Off"), ("balanced", "Balanced"), ("strict", "Strict")], selection: $sourcePrefs.safetyMode)
            Text(sourcePrefs.keywordsAreRegex
                 ? "Hides CAM and fake-quality sources. Match words as regex treats the Only / Avoid words in Smart source selection as case-insensitive regex patterns (an invalid pattern is ignored)."
                 : "Hides CAM and fake-quality sources. Turn on Match words as regex to treat the Only / Avoid words in Smart source selection as full patterns.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Hide / Require word fields moved to the Smart source selection chip panel above (Avoid / Only
            // words, same keys); the regex toggle stays because it governs those word fields and the panel
            // does not cover it.
            Toggle(isOn: $sourcePrefs.keywordsAreRegex) {
                Text("Match words as regex")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            choiceRow(String(localized: "Max file size"),
                      [(0.0, "Off"), (2.0, "2 GB"), (5.0, "5 GB"), (10.0, "10 GB"),
                       (15.0, "15 GB"), (20.0, "20 GB"), (30.0, "30 GB"), (50.0, "50 GB")],
                      selection: $sourcePrefs.maxFileSizeGB)
            Text("Hides sources larger than the cap (e.g. 1080p but not a 20 GB file). Sources with no stated size are kept.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Instant sources / Hide dead torrents / HDR only / Hide AV1 / Preferred audio only / Hide unknown
            // quality moved to the Smart source selection chip panel above (Cached / Dead swarms / HDR-DV /
            // AV1 / My audio / Stated quality chips, same SourcePreferences keys). The resolution caps below
            // stay because the chip panel does not cover them.
            choiceRow(String(localized: "Max quality"),
                      [("0", String(localized: "Unlimited")), ("4000", "4K"), ("1080", "1080p"), ("720", "720p")],
                      selection: Binding(get: { String(sourcePrefs.maxResolution) }, set: { sourcePrefs.maxResolution = Int($0) ?? 0 }))
            // Minimum quality (#117): the floor twin of Max quality (SAME SourcePreferences property the
            // iOS/Mac picker binds). Only drops a source whose KNOWN resolution sits below the floor.
            choiceRow(String(localized: "Minimum quality"),
                      [("0", String(localized: "Off")), ("720", "720p"), ("1080", "1080p"), ("2160", "4K")],
                      selection: Binding(get: { String(sourcePrefs.minResolution) }, set: { sourcePrefs.minResolution = Int($0) ?? 0 }))
            Text("Max quality caps the resolution shown; Minimum quality hides sources below the floor. Sources with no stated resolution are kept unless the Stated quality chip is on.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Compact source rows (#117): display-only (SAME vortx.streams.compactLabels key iOS/Mac binds).
            choiceRow(String(localized: "Compact source rows"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { compactStreamLabels ? "1" : "0" }, set: { compactStreamLabels = ($0 == "1") }))
            Text("Show each source as its parsed quality line (resolution, format, size) instead of the raw release name.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Pinned sources: long-press a source on any title to pin it; this clears them all. Shown only
            // when there is something to clear (SAME SourcePinStore the iOS/Mac view uses).
            if pinStore.pinnedCount > 0 {
                Button { pinStore.clearAll() } label: {
                    Label("Clear pinned sources (\(pinStore.pinnedCount))", systemImage: "pin.slash")
                }
                .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
            }
        }
    }

    // MARK: Audio & subtitle preferences

    private var audioSubtitleSection: some View {
        section("Audio & Subtitles") {
            choiceRow(String(localized: "Match audio to subtitle languages"), [("0", "Off"), ("1", "On")], selection: $matchAudioSubRaw)
            if matchAudioSubRaw != "1" {
                choiceRow(String(localized: "Audio language"), TrackPreferences.commonLanguages, selection: primaryAudioLang)
                choiceRow(String(localized: "Fallback audio language"),
                          [(id: "", label: String(localized: "None"))] + TrackPreferences.commonLanguages,
                          selection: fallbackAudioLang)
            }
            choiceRow(String(localized: "Subtitle language"), TrackPreferences.commonLanguages, selection: primarySubLang)
            choiceRow(String(localized: "Fallback subtitle language"),
                      [(id: "", label: String(localized: "None"))] + TrackPreferences.commonLanguages,
                      selection: fallbackSubLang)
            choiceRow(String(localized: "Subtitles"), TrackPreferences.ForcedPolicy.allCases.map { ($0.rawValue, $0.label) }, selection: $prefForced)
            Toggle(isOn: $subOnlyPreferred) {
                Text("Only show subtitles in my languages")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            Text("The player auto-picks these when a title starts. Each language falls back to your second choice when a title has none in the first. Turn on Match audio to subtitle languages to drive both from one list. Forced shows only foreign-dialogue captions; Always shows full subtitles in your language. Foreign-language titles always get full subtitles so you can follow. Only show subtitles in my languages hides add-on and community subtitles in other languages from the in-player list (untagged-language subtitles always stay).")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// The stored subtitle preference (`TrackPreferences.Key.subtitle`) is a comma-separated PRIORITY LIST
    /// ("tr,en") that TrackSelector already walks in order; the UI presents it as two pickers via these
    /// derived bindings. Primary = the first entry; setting it keeps the existing fallback (dropping it only
    /// when it would duplicate the new primary). The raw `prefSubLang` @AppStorage stays the storage anchor,
    /// so profile capture (.onChange(of: prefSubLang)) and cross-device sync round-trip the whole list.
    private var primarySubLang: Binding<String> {
        Binding(
            get: { prefSubLang.split(separator: ",").first.map(String.init) ?? "en" },
            set: { newPrimary in
                let parts = prefSubLang.split(separator: ",").map(String.init)
                let fallback = parts.count > 1 ? parts[1] : ""
                prefSubLang = (fallback.isEmpty || fallback == newPrimary) ? newPrimary : "\(newPrimary),\(fallback)"
            })
    }

    /// Fallback = the second entry of the stored chain ("" = none). Choosing None (or the primary itself)
    /// stores just the primary.
    private var fallbackSubLang: Binding<String> {
        Binding(
            get: {
                let parts = prefSubLang.split(separator: ",").map(String.init)
                return parts.count > 1 ? parts[1] : ""
            },
            set: { newFallback in
                let primary = prefSubLang.split(separator: ",").first.map(String.init) ?? "en"
                prefSubLang = (newFallback.isEmpty || newFallback == primary) ? primary : "\(primary),\(newFallback)"
            })
    }

    /// Audio primary / fallback: the SAME two-picker derivation as the subtitle chain, over the
    /// `TrackPreferences.Key.audio` list. Shown only when "Match audio to subtitle languages" is off.
    private var primaryAudioLang: Binding<String> {
        Binding(
            get: { prefAudioLang.split(separator: ",").first.map(String.init) ?? "en" },
            set: { newPrimary in
                let parts = prefAudioLang.split(separator: ",").map(String.init)
                let fallback = parts.count > 1 ? parts[1] : ""
                prefAudioLang = (fallback.isEmpty || fallback == newPrimary) ? newPrimary : "\(newPrimary),\(fallback)"
            })
    }

    private var fallbackAudioLang: Binding<String> {
        Binding(
            get: {
                let parts = prefAudioLang.split(separator: ",").map(String.init)
                return parts.count > 1 ? parts[1] : ""
            },
            set: { newFallback in
                let primary = prefAudioLang.split(separator: ",").first.map(String.init) ?? "en"
                prefAudioLang = (newFallback.isEmpty || newFallback == primary) ? primary : "\(primary),\(newFallback)"
            })
    }

    // MARK: Subtitle style

    private var subtitleSection: some View {
        section("Subtitle Style") {
            choiceRow(String(localized: "Font"), SubtitleStyle.fonts.map { ($0.id, $0.label) }, selection: $subFont)
            choiceRow(String(localized: "Size"), SubtitleStyle.sizes.map { ($0.id, $0.label) }, selection: $subSize)
            stepperRow(String(localized: "Fine size"), value: subSizeScale,
                       range: SubtitleStyle.sizeScaleRange,
                       onMinus: { adjustSubScale(-1) },
                       onPlus: { adjustSubScale(1) })
            choiceRow(String(localized: "Color"), SubtitleStyle.colors.map { ($0.id, $0.label) }, selection: $subColor)
            choiceRow("Background", SubtitleStyle.backgrounds.map { ($0.id, $0.label) }, selection: $subBackground)
            Text("Styles the built-in player's subtitles. Pick which subtitle track to show from the player while watching.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Advanced (mpv options)

    private var advancedSection: some View {
        section("Advanced (mpv options)") {
            Text("For power users; one option=value per line. Applied on top of VortX's defaults the next time a video starts.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            TextField("profile=gpu-hq", text: $customMpvOptions, axis: .vertical)
                .lineLimit(3...10)
                .autocorrectionDisabled(true)
                .focusSection()
            // Gated diagnostic logging: turning it on starts the once-a-second heartbeat immediately
            // (no relaunch); the same key can also be set with VORTX_PROBE=1 at launch.
            choiceRow(String(localized: "Diagnostic logging"),
                      [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { probeLogging ? "1" : "0" },
                                         set: { probeLogging = ($0 == "1"); if probeLogging { VXProbeHeartbeat.start() } }))
            Text("Logs detailed activity for troubleshooting.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Apple TV has no share sheet, so the diagnostic log is exported over the LAN: this stands up a
            // tiny local server and shows a QR the owner scans with their phone to download the log file.
            Button {
                diagExport = VXDiagExport.shared.start()
                showDiagExport = true
            } label: { Text("Export diagnostic log") }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
    }

    /// Full-screen QR export overlay: the phone scans the code, downloads vortx-diag.log over the LAN, and
    /// sends it on. Dismissing stops the local server so the log is not left served.
    @ViewBuilder private var diagExportSheet: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Export diagnostic log")
                .font(Theme.Typography.screenTitle).foregroundStyle(Theme.Palette.textPrimary)
            if let export = diagExport {
                export.qr
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420, height: 420)
                    .background(Color.white)
                    .padding(Theme.Space.md)
                Text(export.url)
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Scan with your phone on the same Wi-Fi to download the log, then send it over.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Connect this device to Wi-Fi to export the diagnostic log.")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showDiagExport = false
                VXDiagExport.shared.stop()
                diagExport = nil
            } label: { Text("Done") }
                .buttonStyle(ChipButtonStyle(selected: true))
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private func choiceRow(_ label: String, _ options: [(id: String, label: String)],
                           selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: { Text(opt.label) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
        }
        // Each row is its own focus section so Down moves between stacked rows (e.g. Size ->
        // Color -> Background) without first leveling onto the chip beneath the focused one.
        .focusSection()
    }

    /// Numeric variant of `choiceRow` for a `Double`-backed setting (e.g. the max file-size cap).
    private func choiceRow(_ label: String, _ options: [(id: Double, label: String)],
                           selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: { Text(opt.label) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
        }
        .focusSection()
    }

    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        ProfileStore.shared.capturePlayback()
    }

    /// A label with minus / value / plus controls, for continuous settings (text and subtitle size).
    private func stepperRow(_ label: String, value: Double, range: ClosedRange<Double>,
                            onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.md) {
                Button(action: onMinus) { Image(systemName: "minus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(value <= range.lowerBound + 0.001)
                    .opacity(value <= range.lowerBound + 0.001 ? 0.3 : 1)
                Text("\(Int((value * 100).rounded()))%")
                    .font(Theme.Typography.body.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(minWidth: 90)
                Button(action: onPlus) { Image(systemName: "plus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(value >= range.upperBound - 0.001)
                    .opacity(value >= range.upperBound - 0.001 ? 0.3 : 1)
            }
        }
        .focusSection()
    }

    // MARK: About

    private var backupSection: some View {
        section("Backup & Restore") {
            Text("A backup saves your profiles, theme, and player preferences so they travel with you and survive a future major update. On iPhone, iPad, and Mac you can save that to a file today.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("On Apple TV it is scan-with-your-phone: Back up shows a QR you scan on a device signed in to VortX to save this Apple TV's data to your account, and Restore shows a code to bring it back onto a fresh install.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Space.xs)
            NavigationLink { BackupExportView() } label: {
                Label("Back up", systemImage: "arrow.up.circle")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            NavigationLink { BackupImportView() } label: {
                Label("Restore", systemImage: "arrow.down.circle")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Export Library, which saves a profile's titles and watch progress to a file, lives on iPhone, iPad, and Mac (Apple TV has no file picker). On Apple TV your library and history follow you through your VortX account.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Space.xs)
        }
    }

    private var aboutSection: some View {
        section(String(localized: "About")) {
            if let update = updates.available {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update available: \(update.name)", systemImage: "arrow.down.circle.fill")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Sideload the new IPA from the GitHub releases page, your sign-in and settings carry over.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.vertical, Theme.Space.xs)
            }
            infoRow(String(localized: "Version"), appVersion)
            infoRow(String(localized: "Player"), String(localized: "libmpv · MPVKit"))
            infoRow(String(localized: "Server"), String(localized: "Stremio streaming server (nodejs-mobile)"))
            NavigationLink { TVWhatsNewView() } label: {
                Label("What's New", systemImage: "sparkles")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
        }
        .task { updates.checkIfStale(maxAge: 30 * 60) }   // a Settings visit deserves a fresh answer
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    // MARK: Section chrome

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(title).eyebrowStyle()
            content()
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
        // tvOS focus is spatial: "Log Out" sits far right (after a Spacer) while the next focusable
        // views are left-aligned, outside the downward beam. Making each section a focus section lets
        // the engine redirect focus into it even when it's off the movement axis.
        .focusSection()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(value).foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(Theme.Typography.body)
    }
}

/// The searchable Settings sections on Apple TV. Each case carries the section's on-screen title plus the
/// row keywords it should match, so the search field can filter the tree by a case-insensitive substring of
/// any title or row label. Keywords are stored lowercased so matching is a plain `contains`. Kept in sync
/// with the sections `SettingsView` actually renders (the iOS `iOSSettingsView` keeps its own equivalent).
private enum SettingsSearchSection: CaseIterable {
    case profiles, account, stremioMirror, playback, downloads, notifications, streams, community,
         server, tabBar, appearance, audioSubtitle, subtitle, advanced, backup, about

    var title: String {
        switch self {
        case .profiles: return "Profiles"
        case .account: return "Account"
        case .stremioMirror: return "Stremio mirror"
        case .playback: return "Playback"
        case .downloads: return "Downloads"
        case .notifications: return "Notifications"
        case .streams: return "Streams"
        case .community: return "Community"
        case .server: return "Streaming Server"
        case .tabBar: return "Tab Bar"
        case .appearance: return "Appearance"
        case .audioSubtitle: return "Audio & Subtitles"
        case .subtitle: return "Subtitle Style"
        case .advanced: return "Advanced (mpv options)"
        case .backup: return "Backup & Restore"
        case .about: return "About"
        }
    }

    var keywords: [String] {
        switch self {
        case .profiles: return ["profile", "avatar", "pin", "switch profile", "add profile"]
        case .account: return ["vortx account", "sync", "sign in", "integrations", "stremio", "trakt", "simkl",
                               "import", "metadata", "tmdb", "mdblist", "fanart", "debrid", "real-debrid",
                               "poster artwork", "erdb", "ratings", "iptv", "live tv", "playlist",
                               "media server", "plex", "jellyfin", "emby", "api key"]
        case .stremioMirror: return ["mirror", "two-way sync", "add-ons", "library", "continue watching"]
        case .playback: return ["direct links only", "audio output", "video upscaling", "streaming cache",
                                "player engine", "dolby vision", "mkv", "skip step", "auto-skip", "intro",
                                "credits", "skip timestamps", "skip database", "seek bar", "community scrub previews",
                                "trickplay", "autoplay trailers", "trailer language", "default volume",
                                "auto-add watched", "play in", "external player"]
        case .downloads: return ["downloads", "auto-delete", "delete watched", "offline", "storage", "reclaim space"]
        case .notifications: return ["new episode alerts", "episode", "notification"]
        case .streams: return ["quality preset", "smart source selection", "add-on ranking", "source type",
                               "safety filter", "regex", "max quality", "minimum quality", "max file size",
                               "compact source rows", "pinned sources", "resolution"]
        case .community: return ["contribute", "anonymized data", "singularity", "privacy"]
        case .server: return ["server", "configure server", "restart", "embedded", "node"]
        case .tabBar: return ["tab", "discover tab", "live tv tab", "library tab", "search tab"]
        case .appearance: return ["accent", "background", "oled", "app language", "language",
                                  "cinematic catalog cards", "hide poster labels", "poster style",
                                  "collections on home", "collections on discover", "refresh collections",
                                  "streaming services", "discover & region", "budget & box office", "spoiler",
                                  "blur", "dolby vision", "hdr", "match frame rate", "frame rate", "judder",
                                  "24p", "refresh rate", "text size", "performance",
                                  "top shelf", "tv home screen", "home screen", "continue watching"]
        case .audioSubtitle: return ["audio language", "fallback audio", "subtitle language", "fallback subtitle",
                                     "subtitles", "forced", "match audio to subtitle"]
        case .subtitle: return ["font", "size", "fine size", "color", "background", "subtitle style"]
        case .advanced: return ["mpv", "custom options", "diagnostic logging", "diagnostic log", "export log"]
        case .backup: return ["backup", "restore", "export library", "import library"]
        case .about: return ["version", "player", "what's new", "update", "libmpv", "mpvkit"]
        }
    }
}

private struct TogglePill: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(isOn ? "On" : "Off")
                .font(Theme.Typography.eyebrow)
                .tracking(1)
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.Palette.accent.opacity(0.24) : Theme.Palette.surface3)
                    .frame(width: 64, height: 34)
                Circle()
                    .fill(isOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 5)
            }
        }
        .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Palette.surface2, in: Capsule(style: .continuous))
    }
}

private struct UnavailableBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(Theme.Typography.eyebrow)
            .tracking(1)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.Palette.surface2, in: Capsule(style: .continuous))
    }
}

struct ThemeAccentPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Accent").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.md) {
                    ForEach(ThemeManager.accents) { opt in
                        Button { selection = opt.id } label: {
                            AccentCircle(color: opt.base, selected: selection == opt.id)
                        }
                        .buttonStyle(CardFocusStyle())
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.md)   // room for the focus halo on the swatches
            }
        }
    }
}

struct ThemeBackgroundPicker: View {
    @Binding var oled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Background").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.sm) {
                Button("Warm") { oled = false }
                    .buttonStyle(ChipButtonStyle(selected: !oled))
                Button("OLED Black") { oled = true }
                    .buttonStyle(ChipButtonStyle(selected: oled))
            }
        }
    }
}

private struct AccentCircle: View {
    let color: Color
    let selected: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 58, height: 58)
            .overlay(Circle().strokeBorder(ringColor, lineWidth: ringWidth))
    }

    private var ringColor: Color {
        focused ? Theme.Palette.accentBright : Theme.Palette.textPrimary
    }

    private var ringWidth: CGFloat {
        focused || selected ? 5 : 0
    }
}

/// One tapped Upcoming row, routed to its detail page. `metaId` is the meta (series / movie) catalog id.
private struct TVUpcomingSelection: Identifiable {
    let metaId: String
    let type: String
    var id: String { metaId + "|" + type }
}

/// The Settings "Upcoming" entry: a self-contained calendar of the next air / release dates of the user's
/// library AND watchlisted titles. Owns its own `ReleaseCalendarModel` (so it is reachable without visiting
/// Home) and refreshes it via `refreshUpcoming`, which folds the local watchlist (`LibraryAutoAdd`) in beside
/// the library. A tapped row opens that title's `DetailView` in a sheet with its own NavigationStack, so the
/// detail page keeps the navigation context its internal source / episode links need.
struct TVUpcomingScreen: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @StateObject private var releaseCalendar = ReleaseCalendarModel()
    @State private var selected: TVUpcomingSelection?

    var body: some View {
        UpcomingView(model: releaseCalendar) { id, type in
            selected = TVUpcomingSelection(metaId: id, type: type)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in refresh() }
        .onChange(of: core.library?.catalog.count ?? 0) { refresh() }
        .onChange(of: account.addons.count) { refresh() }
        .sheet(item: $selected) { sel in
            NavigationStack { DetailView(type: sel.type, id: sel.metaId) }
        }
    }

    /// Derived exactly like the Home `refreshReleaseCalendar`: series / movie library ids + names / posters and
    /// the `providesMeta` add-on bases, handed to `refreshUpcoming` (which adds the watchlisted-not-in-library titles).
    private func refresh() {
        let catalog = core.library?.catalog ?? []
        let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
        let series = catalog.filter { $0.type == "series" }
        let seriesNames = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let movies = catalog.filter { $0.type == "movie" }
        let movieNames = Dictionary(movies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let moviePosters = Dictionary(movies.compactMap { m in m.poster.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        releaseCalendar.refreshUpcoming(librarySeriesIDs: series.map(\.id), librarySeriesNames: seriesNames,
                                        libraryMovieIDs: movies.map(\.id), libraryMovieNames: movieNames,
                                        libraryMoviePosters: moviePosters, metaBases: bases)
    }
}
