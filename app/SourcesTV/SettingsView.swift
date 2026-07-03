import SwiftUI

/// Settings: who you're signed in as, the embedded streaming-server status, subtitles, and app info.
/// Mirrors the official tvOS app's Settings sections, on the StremioX design system.
struct SettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @EnvironmentObject private var profiles: ProfileStore
    @State private var serverOnline: Bool?
    @AppStorage("stremiox.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage("stremiox.hdrToneMapMode") private var hdrToneMapMode = "auto"   // auto / on / off
    @State private var showRestartConfirm = false
    @State private var editingProfile: UserProfile?
    /// In-app UI language (tvOS had no picker before). "system" follows the Apple TV language.
    @State private var langSelection: String = AppLanguage.current ?? "system"
    @State private var showLangRestart = false
    @AppStorage("stremiox.hideLiveTab") private var hideLiveTab = false
    @AppStorage("vortx.home.showCollectionsHub") private var showHubHome = true
    @AppStorage("vortx.discover.showCollectionsHub") private var showHubDiscover = true
    @AppStorage("vortx.collections.refreshCadence") private var hubCadence = "daily"
    @AppStorage("vortx.detail.showFinancials") private var showFinancials = true
    @AppStorage("vortx.spoilerBlur") private var spoilerBlur = true
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @AppStorage(TrackPreferences.Key.forced) private var prefForced = TrackPreferences.ForcedPolicy.forced.rawValue
    @AppStorage(TrackPreferences.Key.audio) private var prefAudioLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subtitle) private var prefSubLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @AppStorage(PlaybackSettings.Key.customMpvOptions) private var customMpvOptions = ""
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
    // "Singularity" community source index SERVE opt-in (per device). Default OFF; requires sign-in to use.
    @AppStorage(SourceIndexClient.serveKey) private var singularityServe = false
    @AppStorage(SkipTimestampService.providerKey) private var skipProvider = "both"
    @AppStorage(ExternalPlayers.defaultKey) private var defaultExternalPlayer = ""   // "" == built-in libmpv
    // Stremio mirror (account-owns-everything): default OFF = VortX keeps its own copy of each category;
    // ON = VortX tracks Stremio (adds and removes) for that category.
    @AppStorage(MirrorSettings.addonsKey) private var mirrorAddons = false
    @AppStorage(MirrorSettings.libraryKey) private var mirrorLibrary = false
    @AppStorage(MirrorSettings.continueWatchingKey) private var mirrorCW = false
    @ObservedObject private var sourcePrefs = SourcePreferences.shared
    /// Deterministic Down-chain insurance across the three top account rows so the spatial focus
    /// engine cannot skip Log Out (it stranded far-right before 80fb9d2 and the owner could not reach it).
    private enum AccountFocus: Hashable { case vortx, logOut, importStremio }
    @FocusState private var accountFocus: AccountFocus?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Settings").screenTitleStyle()
                    profilesSection
                    accountSection
                    stremioMirrorSection
                    playbackSection
                    streamsSection
                    communitySection
                    serverSection
                    appearanceSection
                    audioSubtitleSection
                    subtitleSection
                    advancedSection
                    backupSection
                    aboutSection
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Track-language and subtitle-style edits belong to the ACTIVE profile: fold every
        // flat-key change back into it (the captureTheme pattern, RootTabView does the same for
        // the theme). The equality guard inside capturePlayback stops a profile switch's own
        // flat-key writes from echoing back as roster edits.
        .onChange(of: prefAudioLang) { StreamRanking.invalidateCaches(); ProfileStore.shared.capturePlayback() }
        .onChange(of: prefSubLang) { ProfileStore.shared.capturePlayback() }
        .onChange(of: prefForced) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subFont) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subSize) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subColor) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subBackground) { ProfileStore.shared.capturePlayback() }
        // Source-ranking taste is per-profile too: the toggle and the up/down reorder mutate
        // SourcePreferences.shared, so fold those into the active profile the same way.
        .onChange(of: sourcePrefs.useAddonOrder) { ProfileStore.shared.capturePlayback() }
        .onChange(of: sourcePrefs.typeOrder) { ProfileStore.shared.capturePlayback() }
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
                // Lead with the VortX account (the app's own E2E account + sync); the Stremio account sits beneath.
                NavigationLink { SyncSettingsView() } label: {
                    Label("VortX account & sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .focused($accountFocus, equals: .vortx)
                if account.isSignedIn {
                    // Identity is a non-focusable info row; Log Out is its OWN full-width row directly
                    // BELOW it, in the same left-aligned column as every other account row. The old layout
                    // stranded Log Out far-right after a Spacer(), so the spatial focus engine's downward
                    // beam from the left-aligned rows missed it and the owner could not reach it on tvOS.
                    // Stacking it in-column makes it a deterministic D-pad target (down lands on it, then
                    // continues to the rows below). The .focusSection() on the enclosing VStack stays.
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.email ?? "Signed in").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                            Text("Stremio · \(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Button { account.signOut(); core.logOut() } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($accountFocus, equals: .logOut)
                } else {
                    NavigationLink { LoginView(account: account) } label: {
                        Label("Sign in to your Stremio account", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
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
                choiceRow(String(localized: "Mirror add-ons from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorAddons ? "1" : "0" }, set: { mirrorAddons = ($0 == "1") }))
                choiceRow(String(localized: "Mirror library from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorLibrary ? "1" : "0" }, set: { mirrorLibrary = ($0 == "1") }))
                choiceRow(String(localized: "Mirror Continue Watching from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorCW ? "1" : "0" }, set: { mirrorCW = ($0 == "1") }))
                Text("Off keeps a VortX copy of each one, so it stays even if you remove it in Stremio. On makes VortX track your Stremio account for that item. Your add-ons, library, and Continue Watching always stay even when you are signed out of Stremio.")
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
                    .background(Theme.Palette.surface1,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                if account.isSignedIn {
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
        #if !STREMIOX_NO_EMBEDDED_SERVER
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
                    #if !STREMIOX_NO_EMBEDDED_SERVER
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

            choiceRow(String(localized: "Show Live TV tab"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideLiveTab ? "0" : "1" }, set: { hideLiveTab = ($0 == "0") }))
            Text("Hide the Live TV tab if you do not use it.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Cinematic catalog cards"), [("1", "Landscape"), ("0", "Portrait")],
                      selection: Binding(get: { catalogPrefs.landscapeCards ? "1" : "0" }, set: { catalogPrefs.landscapeCards = ($0 == "1") }))
            Text("Show catalog posters as wide cinematic cards using clean TMDB artwork. Needs a TMDB key (set one under API keys); without it cards stay portrait. Choose Portrait for the classic poster grid.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Collections on Home"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showHubHome ? "1" : "0" }, set: { showHubHome = ($0 == "1") }))
            choiceRow(String(localized: "Collections on Discover"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showHubDiscover ? "1" : "0" }, set: { showHubDiscover = ($0 == "1") }))
            choiceRow(String(localized: "Refresh collections"), [("daily", "Daily"), ("twiceDaily", "Twice"), ("fourTimesDaily", "4x")],
                      selection: $hubCadence)
            NavigationLink { TVReorderServicesView() } label: {
                Label("Reorder streaming services", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            NavigationLink { TVDiscoverSettingsView() } label: {
                Label("Discover & region", systemImage: "globe")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Discover cards, Streaming-service tiles, and Genre tiles high on Home and Discover; tap a tile to browse its catalogs (Movies, Shows, New, Top week/month/year, Trending). Needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Budget & box office"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showFinancials ? "1" : "0" }, set: { showFinancials = ($0 == "1") }))
            Text("Show a movie's budget, box office, and profit on its detail page. Movies only; needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Blur unwatched episodes"), [("1", "Blur"), ("0", "Show")],
                      selection: Binding(get: { spoilerBlur ? "1" : "0" }, set: { spoilerBlur = ($0 == "1") }))
            Text("Blur episode thumbnails you have not watched yet, to avoid spoilers.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Dolby Vision / HDR"), [("auto", "Auto"), ("on", "Tone-map to SDR"), ("off", "Always HDR")], selection: $hdrToneMapMode)
            Text("Auto tone-maps HDR and Dolby Vision to SDR only on a TV that can't show HDR. Choose Tone-map to SDR if 4K Dolby Vision remuxes look washed out, green or purple on your TV; Always HDR forces pass-through.")
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
                 ? "Hides CAM and fake-quality sources. Hide / Require words are case-insensitive regex patterns (an invalid pattern is ignored)."
                 : "Hides CAM and fake-quality sources. Hide / Require words filter the list by name (comma-separated).")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Space.md) {
                Text("Hide words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.excludeKeywords)
            }
            HStack(spacing: Theme.Space.md) {
                Text("Require words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.includeKeywords)
            }
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
        }
    }

    // MARK: Audio & subtitle preferences

    private var audioSubtitleSection: some View {
        section("Audio & Subtitles") {
            choiceRow(String(localized: "Audio language"), TrackPreferences.commonLanguages, selection: $prefAudioLang)
            choiceRow(String(localized: "Subtitle language"), TrackPreferences.commonLanguages, selection: $prefSubLang)
            choiceRow(String(localized: "Subtitles"), TrackPreferences.ForcedPolicy.allCases.map { ($0.rawValue, $0.label) }, selection: $prefForced)
            Text("The player auto-picks these when a title starts. Forced shows only foreign-dialogue captions; Always shows full subtitles in your language. Foreign-language titles always get full subtitles so you can follow.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
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
        }
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
            Text("On Apple TV a scan-with-your-phone backup is coming: Backup will show a QR code, you scan it with your phone, and your settings save to your VortX account. Restore shows another code to bring them right back. Until then, signing in restores your library, add-ons, and watch history here.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Space.xs)
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
