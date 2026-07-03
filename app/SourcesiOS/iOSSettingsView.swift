import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

/// Touch Settings at full parity with the tvOS Settings screen: profiles, account, playback,
/// stream-source ranking, the embedded streaming server, appearance, audio & subtitle preferences,
/// subtitle styling, and app info, plus the engine FFI smoke check kept off the Home page.
///
/// Same shared state the tvOS SettingsView binds (the SAME flat UserDefaults keys, the SAME
/// observed singletons), rendered with native iOS controls inside a `Form`: tvOS chip-scrollers
/// become `Picker`s, tvOS stepperRows become `Stepper`s, tvOS TogglePills become `Toggle`s, and
/// the NavigationLinks to ServerConfigView / ProfileEditorView stay. Device-scoped settings (audio
/// output, HDR tonemap, performance mode, Direct Links Only) do NOT fold into the active profile;
/// everything that follows a viewer (languages, subtitle style, source order, text size) does.
struct iOSSettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var sourcePrefs = SourcePreferences.shared
    @ObservedObject private var pinStore = SourcePinStore.shared
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @State private var serverOnline: Bool?
    @State private var editingProfile: UserProfile?
    @State private var pendingDelete: UserProfile?   // context-menu delete confirmation target
    @State private var showSignIn = false
    #if os(macOS)
    /// Drives the "Share streaming server on this network" toggle (macOS only). Backed by
    /// NodeServer.sharedOnLAN, which persists + restarts the node process when it flips.
    @State private var shareOnLAN = NodeServer.sharedOnLAN
    @State private var didCopyLAN = false
    #endif

    @AppStorage("stremiox.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage("stremiox.hdrToneMapMode") private var hdrToneMapMode = "auto"   // auto / on / off
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @AppStorage(TrackPreferences.Key.forced) private var prefForced = TrackPreferences.ForcedPolicy.forced.rawValue
    @AppStorage(TrackPreferences.Key.audio) private var prefAudioLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subtitle) private var prefSubLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @AppStorage(PlaybackSettings.Key.keepPlayingInBackground) private var keepPlayingInBackground = true
    @AppStorage(PlaybackSettings.Key.customMpvOptions) private var customMpvOptions = ""
    @AppStorage(PerformanceMode.overrideKey) private var perfMode = "auto"
    @AppStorage(AudioOutputMode.key) private var audioOutput = AudioOutputMode.auto.rawValue
    @AppStorage(PlaybackSettings.Key.videoUpscaling) private var videoUpscaling = PlaybackSettings.videoUpscaling.rawValue
    // Streaming/seek cache budget, stored as a raw byte count (0 = Off, -1 = Unlimited). @AppStorage is
    // Int-typed; Int is 64-bit on every Apple device this runs on, so the byte budgets are exact.
    @AppStorage(DiskCacheSetting.key) private var diskCacheBytes = 0   // Off by default, matching DiskCacheSetting.storedBytes; the cache is opt-in
    @AppStorage("stremiox.hideLiveTab") private var hideLiveTab = false
    @AppStorage("vortx.home.showCuratedRails") private var showCuratedRails = true
    @AppStorage("vortx.home.showCollectionsHub") private var showHubHome = true
    @AppStorage("vortx.discover.showCollectionsHub") private var showHubDiscover = true
    @AppStorage("vortx.collections.refreshCadence") private var hubCadence = "daily"
    @AppStorage("vortx.detail.showFinancials") private var showFinancials = true
    @AppStorage("vortx.spoilerBlur") private var spoilerBlur = true
    @AppStorage("vortx.mergeDiscoverSearch") private var mergeDiscoverSearch = false   // fold Search into Discover (one surface)
    #if os(iOS) || os(macOS)
    @AppStorage(PlayerEngineRouter.overrideKey) private var playerEngine = PlayerEngineRouter.Override.auto.rawValue
    @AppStorage(PlayerEngineRouter.dvRemuxKey) private var dvRemux = false   // Dolby Vision for MKV (Beta): in-app remux -> AVPlayer; default OFF
    #endif
    @AppStorage("stremiox.autoSkip") private var autoSkip = false
    @AppStorage(CommunityTrickplay.settingKey) private var communityTrickplay = true   // share/fetch scrub previews
    // Give-to-get master switch: contribute + consume the whole community data pool. Default ON. Off = out of
    // the pool entirely (no contribute, no consume of any moat feature). See MoatConsent.
    @AppStorage(MoatConsent.key) private var moatContribute = true
    // "Singularity" community source index SERVE opt-in (per device). Default OFF; requires sign-in to use.
    @AppStorage(SourceIndexClient.serveKey) private var singularityServe = false
    @AppStorage(SkipTimestampService.providerKey) private var skipProvider = "both"
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
    /// Trailer language (D11): the ISO-639-1 code the trailer picker prefers when choosing the YouTube id.
    /// Empty = follow the app UI language (the default; `TMDBClient.trailerLanguageOverride` treats empty as
    /// unset). Read by TMDBClient.preferredTrailerLanguages / trailerLanguageBaseCode.
    @AppStorage("stremiox.trailerLanguage") private var trailerLanguage = ""
    /// Auto-add watched to Library (D8): when playback of a title crosses ~60s it is added to the Library.
    /// Default ON. Read at the 60s progress tick in PlayerScreen / TVPlayerView via LibraryAutoAdd.
    @AppStorage("stremiox.autoAddLibrary") private var autoAddLibrary = true
    /// Default player volume 0-100 (D5): the level a new playback starts at. The in-player volume slider
    /// writes this same key, so the last level persists; this picker sets it explicitly. Read by PlayerScreen.
    @AppStorage("stremiox.playerVolume") private var playerVolume = 100.0
    // Empty string == built-in libmpv player; otherwise an ExternalPlayer.Target id to auto-open in.
    @AppStorage(ExternalPlayer.defaultKey) private var defaultExternalPlayer = ""
    @AppStorage("stremiox.seekStep") private var seekStep = "10"   // skip-button step in seconds; String to match the player + the picker tags
    @AppStorage(NewEpisodeNotifications.enabledKey) private var notifyNewEpisodes = true
    @AppStorage("stremiox.autoLandscapeInPlayer") private var autoLandscapeInPlayer = true
    // Stremio mirror (account-owns-everything): default OFF = VortX keeps its own copy of each category
    // and a Stremio removal never removes it from VortX; ON = VortX tracks Stremio for that category.
    @AppStorage(MirrorSettings.addonsKey) private var mirrorAddons = false
    @AppStorage(MirrorSettings.libraryKey) private var mirrorLibrary = false
    @AppStorage(MirrorSettings.continueWatchingKey) private var mirrorCW = false
    /// App-language override ("system" = follow the device). Applied via AppLanguage; needs a relaunch.
    @State private var langSelection: String = AppLanguage.current ?? "system"
    /// Shown after a language pick to offer the relaunch that actually applies it (the localized bundle is
    /// chosen once at launch, so the change is invisible until the app quits and reopens).
    @State private var pendingLangRestart = false

    // Backup & Restore: carry local settings across the StremioX -> VortX move (see SettingsBackup).
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupDocument: BackupDocument?
    @State private var backupAlert: BackupAlert?
    // Library import/export: carry a profile's saved titles + watch progress to another device or
    // profile, account-free (see LibraryPortability + ProfileStore.export/importLibraryItems).
    @State private var showLibraryExporter = false
    @State private var showLibraryImporter = false
    @State private var libraryDocument: BackupDocument?

    var body: some View {
        NavigationStack {
            Form {
                // Each section's row cards use the brand surface, not the system grouped grey (#49
                // follow-up): `.listRowBackground` on a Section repaints all its rows. Combined with
                // `.scrollContentBackground(.hidden)` + the canvas background below, the cards now read
                // as warm dark surfaces with canvas showing between them, matching the rest of the app
                // (and identical on iPadOS, which shares this view).
                profilesSection.listRowBackground(Theme.Palette.surface1)
                languageSection.listRowBackground(Theme.Palette.surface1)
                accountSection.listRowBackground(Theme.Palette.surface1)
                stremioMirrorSection.listRowBackground(Theme.Palette.surface1)
                playbackSection.listRowBackground(Theme.Palette.surface1)
                notificationsSection.listRowBackground(Theme.Palette.surface1)
                streamsSection.listRowBackground(Theme.Palette.surface1)
                communitySection.listRowBackground(Theme.Palette.surface1)
                serverSection.listRowBackground(Theme.Palette.surface1)
                appearanceSection.listRowBackground(Theme.Palette.surface1)
                audioSubtitleSection.listRowBackground(Theme.Palette.surface1)
                subtitleSection.listRowBackground(Theme.Palette.surface1)
                advancedSection.listRowBackground(Theme.Palette.surface1)
                backupSection.listRowBackground(Theme.Palette.surface1)
                aboutSection.listRowBackground(Theme.Palette.surface1)
                engineSection.listRowBackground(Theme.Palette.surface1)
            }
            // Grouped form style renders proper inset section cards + headers and a centered column
            // on macOS (the default macOS form style is the ugly full-width label-left layout). On the
            // brand canvas instead of the system gray, so it reads like the rest of the app.
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            // The whole Form follows the app accent (#49): toggles, segmented selections, picker
            // checkmarks, stepper +/- glyphs, navigation chevrons, and any selected row tint inherit
            // this instead of the system blue/grey, matching how tvOS SettingsView colors its
            // controls. Per-control `.tint` overrides below stay (destructive red, etc.).
            .tint(Theme.Palette.accent)
            // navigationTitle bridges into the single shared window toolbar on macOS where every mounted
            // tab stamps its own title, crashing NSToolbar on duplicate inserts. So it is iOS-only.
            #if os(iOS)
            .navigationTitle("Settings")
            #endif
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            .fileExporter(isPresented: $showBackupExporter, document: backupDocument,
                          contentType: .json, defaultFilename: SettingsBackup.defaultFilename()) { result in
                switch result {
                case .success:
                    backupAlert = BackupAlert(title: String(localized: "Backup Saved"),
                        message: String(localized: "Keep this file safe. Restore it in VortX to bring your settings across."))
                case .failure(let error):
                    backupAlert = BackupAlert(title: String(localized: "Backup Failed"), message: error.localizedDescription)
                }
            }
            .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let count = try SettingsBackup.restore(from: try Data(contentsOf: url))
                        backupAlert = BackupAlert(title: String(localized: "Restore Complete"),
                            message: "\(count) settings restored. Relaunch the app to apply everything.")
                    } catch {
                        backupAlert = BackupAlert(title: String(localized: "Restore Failed"), message: error.localizedDescription)
                    }
                case .failure(let error):
                    backupAlert = BackupAlert(title: String(localized: "Restore Failed"), message: error.localizedDescription)
                }
            }
            .fileExporter(isPresented: $showLibraryExporter, document: libraryDocument,
                          contentType: .json,
                          defaultFilename: LibraryPortability.defaultFilename(profile: profiles.active?.name ?? "Library")) { result in
                switch result {
                case .success:
                    backupAlert = BackupAlert(title: String(localized: "Library Exported"),
                        message: String(localized: "Saved this profile's titles and watch history. Import it on another device or into another profile."))
                case .failure(let error):
                    backupAlert = BackupAlert(title: String(localized: "Export Failed"), message: error.localizedDescription)
                }
            }
            .fileImporter(isPresented: $showLibraryImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let items = try LibraryPortability.decode(from: try Data(contentsOf: url))
                        let target = profiles.active?.name ?? String(localized: "this profile")
                        Task {
                            let result = await profiles.importLibraryItems(items)
                            var message = "\(result.applied) \(result.applied == 1 ? "title" : "titles") added to \(target)."
                            if result.skipped > 0 {
                                message += " \(result.skipped) \(result.skipped == 1 ? "title was" : "titles were") skipped: only standard catalog titles can be added to the main profile's account library."
                            }
                            backupAlert = BackupAlert(title: String(localized: "Library Imported"), message: message)
                        }
                    } catch {
                        backupAlert = BackupAlert(title: String(localized: "Import Failed"), message: error.localizedDescription)
                    }
                case .failure(let error):
                    backupAlert = BackupAlert(title: String(localized: "Import Failed"), message: error.localizedDescription)
                }
            }
            .alert(item: $backupAlert) { info in
                Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
            }
            .platformFullScreenCover(item: $editingProfile) { profile in
                ProfileEditorView(original: profile)
            }
            .confirmationDialog(pendingDelete.map { "Delete \($0.name)? Its settings and sign-in are removed." } ?? "",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let p = pendingDelete { _ = profiles.remove(p) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            // Track-language and subtitle-style edits belong to the ACTIVE profile: fold every
            // flat-key change back into it (the capturePlayback pattern, same as tvOS SettingsView).
            // The equality guard inside capturePlayback stops a profile switch's own flat-key writes
            // from echoing back as roster edits. Single-param onChange: the zero-/two-param forms are
            // iOS 17+, target here is iOS 16.
            .onChange(of: prefAudioLang) { _ in StreamRanking.invalidateCaches(); ProfileStore.shared.capturePlayback() }
            .onChange(of: prefSubLang) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: prefForced) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: subFont) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: subSize) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: subColor) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: subBackground) { _ in ProfileStore.shared.capturePlayback() }
            // Source-ranking taste is per-profile too: the toggle and the reorder mutate
            // SourcePreferences.shared, so fold those into the active profile the same way.
            .onChange(of: sourcePrefs.useAddonOrder) { _ in ProfileStore.shared.capturePlayback() }
            .onChange(of: sourcePrefs.typeOrder) { _ in ProfileStore.shared.capturePlayback() }
            // Appearance is per-profile (accent + OLED chrome + text size, all mirrored into
            // ThemeManager); fold each change back into the active profile so it survives a
            // switch/relaunch, same as tvOS RootTabView. Without the accent/oled captures, the
            // launch-time applyTheme(active) in ProfileStore.init would write the profile's stale
            // accentID back over the just-picked one, resetting the accent on every relaunch.
            .onChange(of: theme.accentID) { _ in ProfileStore.shared.captureTheme() }
            .onChange(of: theme.oled) { _ in ProfileStore.shared.captureTheme() }
            .onChange(of: theme.textScale) { _ in ProfileStore.shared.captureTheme() }
            // Device-scoped settings (audioOutput, forceSDRTonemap, perfMode, directLinksOnly) are
            // deliberately NOT folded back: they describe THIS device, not the viewer.
            .task {
                // Live server monitor that never gives up: the embedded server cold-starts well
                // after launch, so a fixed window could expire and show "Offline" until a relaunch.
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
            .task { updates.checkIfStale(maxAge: 30 * 60) }   // a Settings visit deserves a fresh answer
        }
    }

    // MARK: Profiles

    @ViewBuilder private var profilesSection: some View {
        Section {
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
                        // Discoverable delete without opening the editor: right-click (Mac) / long-press
                        // (touch). The main profile can't be deleted; deleting the active one is blocked too
                        // (switch away first). Editor "Delete Profile" still works as the in-editor path.
                        .contextMenu {
                            if !profile.isOwner {
                                Button("Edit Profile") { editingProfile = profile }
                                if profile.id != profiles.activeID {
                                    Button("Delete Profile", role: .destructive) { pendingDelete = profile }
                                }
                            }
                        }
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
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        } header: {
            Text("Profiles")
        } footer: {
            Text("Select a profile to edit it. Each profile keeps its own look, languages, PIN, and optionally its own Stremio account. A profile with a PIN asks for it before it can be edited.")
        }
    }

    // MARK: Language

    @ViewBuilder private var languageSection: some View {
        Section {
            Picker("App Language", selection: $langSelection) {
                Text("System Default").tag("system")
                ForEach(AppLanguage.supported, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .onChange(of: langSelection) { newValue in
                AppLanguage.set(newValue == "system" ? nil : newValue)
                pendingLangRestart = true
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Choose the app's language. \"System Default\" follows your device language. VortX must quit and reopen to apply a new language.")
        }
        .confirmationDialog("Apply language?", isPresented: $pendingLangRestart, titleVisibility: .visible) {
            Button("Quit Now", role: .destructive) { exit(0) }
            Button("Later", role: .cancel) {}
        } message: {
            Text("VortX needs to quit and reopen to display the app in the new language. Reopen it after it closes.")
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section("Account") {
            // Lead with the VortX account (the app's own end-to-end-encrypted account + sync); the Stremio
            // account is shown beneath it as a connected source.
            NavigationLink("VortX account & sync") { SyncSettingsView() }
            if account.isSignedIn {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email ?? String(localized: "Signed in"))
                    Text("Stremio · \(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Log Out", role: .destructive) {
                    account.signOut()
                    core.logOut()
                }
            } else {
                Button("Sign in to your Stremio account") { showSignIn = true }
            }
            NavigationLink("Import from Stremio") { StremioImportView() }
            NavigationLink("Metadata (TMDB, MDBList, fanart)") { MetadataKeysView() }
            NavigationLink("Debrid services") { DebridKeysView() }
            NavigationLink("Poster artwork (ERDB, ratings)") { XRDBSettingsView() }
        }
    }

    // MARK: Stremio mirror

    /// Per-category control of whether VortX mirrors a connected Stremio account. Default OFF for all
    /// three = VortX owns its own add-ons / library / Continue Watching: Stremio removals never remove
    /// them from VortX. Turn one ON to make VortX track Stremio for that category (adds and removes).
    @ViewBuilder private var stremioMirrorSection: some View {
        Section {
            Toggle("Mirror add-ons from Stremio", isOn: $mirrorAddons).tint(Theme.Palette.accent)
            Toggle("Mirror library from Stremio", isOn: $mirrorLibrary).tint(Theme.Palette.accent)
            Toggle("Mirror Continue Watching from Stremio", isOn: $mirrorCW).tint(Theme.Palette.accent)
        } header: {
            Text("Stremio mirror")
        } footer: {
            Text("Off keeps a VortX copy of each one, so it stays even if you remove it in Stremio. On makes VortX track your Stremio account for that item. Your add-ons, library, and Continue Watching always stay even when you are signed out of Stremio.")
        }
    }

    // MARK: Playback

    @ViewBuilder private var playbackSection: some View {
        Section {
            if PlaybackSettings.directLinksOnlyForced {
                // This build does not bundle the torrent engine: read-only, no toggle.
                HStack {
                    Text("Direct Links Only")
                    Spacer()
                    Label("Not bundled", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle("Direct Links Only", isOn: directLinksOnlyBinding)
                    .tint(Theme.Palette.accent)
            }
            Picker("Audio output", selection: $audioOutput) {
                ForEach(AudioOutputMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Video upscaling", selection: $videoUpscaling) {
                ForEach(VideoUpscaling.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Streaming cache", selection: $diskCacheBytes) {
                ForEach(DiskCacheSetting.pickerOptions, id: \.id) { Text($0.label).tag(Int($0.id)) }
            }
            #if os(iOS) || os(macOS)
            Picker("Player engine", selection: $playerEngine) {
                ForEach(PlayerEngineRouter.Override.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Text("Auto plays HLS and Dolby Vision through AVPlayer (AirPlay and Picture in Picture) and uses the built-in libmpv player for torrents, MKV, and anything AVPlayer cannot open. If a stream will not start, choose Always libmpv.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Dolby Vision for MKV (Beta)", isOn: $dvRemux)
                .tint(Theme.Palette.accent)
            Text("Plays Dolby Vision .mkv from debrid via an in-app remux. Experimental; falls back automatically if it fails.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            Picker("Skip step", selection: $seekStep) {
                ForEach(["10", "15", "30"], id: \.self) { Text("\($0)s").tag($0) }
            }
            Toggle("Auto-skip intro & credits", isOn: $autoSkip)
                .tint(Theme.Palette.accent)
            Picker("Skip timestamps source", selection: $skipProvider) {
                Text("TheIntroDB").tag("theintrodb")
                Text("SkipDB").tag("skipdb")
                Text("Both").tag("both")
            }
            NavigationLink("Skip database key") { SkipKeysView() }
            NavigationLink("Seek bar style") { SeekBarStylePicker() }
            Toggle("Community scrub previews", isOn: $communityTrickplay)
                .tint(Theme.Palette.accent)
            Text("Share and reuse scrub-preview thumbnails across the community, so previews appear instantly without each device regenerating them. Only the generated thumbnails are shared, never any account data.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Autoplay trailers", isOn: $autoplayTrailers)
                .tint(Theme.Palette.accent)
            // Trailer language (D11): the language the trailer picker prefers when choosing the YouTube id.
            // "App language" (the default) leaves the key empty so it follows the app UI language; a set
            // value becomes the highest-priority trailer language in TMDBClient.preferredTrailerLanguages.
            Picker("Trailer language", selection: $trailerLanguage) {
                Text("App language").tag("")
                ForEach(AppLanguage.supported, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            // Default player volume (D5): the level a new playback starts at. The in-player volume slider
            // writes the same key, so this also reflects the last level used. Coarse 0/25/50/75/100 steps,
            // plus the exact current level as its own row when the in-player slider left it off-step (e.g.
            // 60%), so the picker never snap-misreports the real starting level.
            Picker("Default volume", selection: playerVolumeSelection) {
                ForEach(playerVolumeSteps, id: \.self) { pct in
                    Text(pct == 100 ? "Max (100%)" : "\(pct)%").tag(pct)
                }
            }
            // Auto-add a title to the Library once ~60s of it has played (D8). Default ON. The engine adds it
            // through the account library on the main profile; overlay profiles are skipped (never touch the
            // account library). A manual removal is remembered so a title is not force-re-added on replay.
            Toggle("Auto-add watched to Library", isOn: $autoAddLibrary)
                .tint(Theme.Palette.accent)
            #if os(iOS)
            Toggle("Landscape in player", isOn: $autoLandscapeInPlayer)
                .tint(Theme.Palette.accent)
            if !PlaybackSettings.directLinksOnlyForced {
                Toggle("Keep playing in background", isOn: $keepPlayingInBackground)
                    .tint(Theme.Palette.accent)
            }
            #endif
            if !installedExternalPlayers.isEmpty {
                Picker("Play in", selection: $defaultExternalPlayer) {
                    Text("Built-in player").tag("")
                    ForEach(installedExternalPlayers) { Label($0.name, systemImage: $0.icon).tag($0.id) }
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(PlaybackSettings.directLinksOnlyForced
                     ? String(localized: "This build does not bundle the torrent engine. Only direct and debrid links can play.")
                     : String(localized: "Hide torrent and magnet sources. Only direct and debrid links will play."))
                Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? "")
                Text(VideoUpscaling(rawValue: videoUpscaling)?.detail ?? "")
                Text(diskCacheFooter)
                if !installedExternalPlayers.isEmpty {
                    Text("Direct and debrid streams open straight in your chosen player, which then handles playback and resume. Torrents, header-protected sources, and trailers always use the built-in player.")
                }
            }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        Section {
            TextField("profile=gpu-hq\nscale=ewa_lanczossharp", text: $customMpvOptions, axis: .vertical)
                .lineLimit(3...10)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Advanced (mpv options)")
        } footer: {
            Text("For power users; one option=value per line. Applied on top of VortX's defaults the next time a video starts.")
        }
    }

    /// External players present on this device, the choices the "Play in" picker offers. Evaluated once
    /// per view build; installing a new player after launch needs a Settings re-open to appear.
    private var installedExternalPlayers: [ExternalPlayer.Target] { ExternalPlayer.installed }

    private var effectiveDirectLinksOnly: Bool { PlaybackSettings.directLinksOnly }

    /// Explains the streaming cache and, when on, shows the live on-disk usage. Unlimited is always
    /// capped at half of free disk and cleared when a title finishes, so it can never fill the device.
    private var diskCacheFooter: String {
        let base = String(localized: "A bigger streaming cache buffers more video on disk so you can seek minutes ahead without re-buffering. Unlimited is still capped to half your free space and the cache clears when a title finishes, so it never fills your device.")
        guard diskCacheBytes != 0 else { return base }
        // currentUsageBytes sums the on-disk mpv-cache dir, which stays EMPTY on this MPVKit build (the
        // buffer is RAM-resident), so it always read "0 KB". Show the real RAM-bounded budget instead.
        let budget = DiskCacheSetting.humanReadable(DiskCacheSetting.resolvedMaxBytes())
        return base + "\n" + String(localized: "Cache budget: \(budget).")
    }

    /// Direct Links Only writes the flat key; turning it OFF cold-starts the embedded server so
    /// torrents work again without a relaunch (guarded out of the Lite build that ships no server).
    /// Toggling new-episode alerts: enabling asks the system for permission, and `setEnabled` writes the
    /// stored key (which this @AppStorage mirrors), so the switch settles to the real authorization state.
    /// Picker rows for default volume: the coarse 0/25/50/75/100 steps, plus the exact current level when the
    /// in-player fine slider left `stremiox.playerVolume` off-step (e.g. 60), so the picker can show the real
    /// value instead of snapping it to a wrong neighbour.
    private var playerVolumeSteps: [Int] {
        let steps = [0, 25, 50, 75, 100]
        let current = Int(playerVolume.rounded())
        return steps.contains(current) ? steps : (steps + [current]).sorted()
    }

    /// Maps the continuous `stremiox.playerVolume` (0-100 Double, shared with the in-player slider) onto the
    /// `playerVolumeSteps` picker. The getter returns the exact current level (which `playerVolumeSteps`
    /// always includes) so the shown selection matches the real starting level; the setter writes the chosen
    /// percentage so the player launches at that level.
    private var playerVolumeSelection: Binding<Int> {
        Binding(
            get: { Int(playerVolume.rounded()) },
            set: { playerVolume = Double($0) }
        )
    }

    private var notifyNewEpisodesBinding: Binding<Bool> {
        Binding(
            get: { notifyNewEpisodes },
            set: { value in Task { await NewEpisodeNotifications.setEnabled(value) } }
        )
    }

    @ViewBuilder private var notificationsSection: some View {
        Section {
            Toggle("New episode alerts", isOn: notifyNewEpisodesBinding)
                .tint(Theme.Palette.accent)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get a notification when a new episode of a series you open is about to air. Scheduled on-device for upcoming episodes, so no background tracking is needed.")
        }
    }

    private var directLinksOnlyBinding: Binding<Bool> {
        Binding(
            get: { directLinksOnly },
            set: { value in
                directLinksOnly = value
                #if !STREMIOX_NO_EMBEDDED_SERVER
                if !value, !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
                    NodeServer.startIfNeeded()
                }
                #endif
            }
        )
    }

    // MARK: Streams

    @ViewBuilder private var streamsSection: some View {
        Section {
            Menu {
                ForEach(SourcePreset.allCases) { preset in
                    Button { sourcePrefs.apply(preset) } label: {
                        Text(preset.label)
                        Text(preset.detail)
                    }
                }
            } label: {
                Label("Apply a quality preset", systemImage: "wand.and.stars")
            }
            .tint(Theme.Palette.accent)
            Toggle("Use add-on ranking order", isOn: $sourcePrefs.useAddonOrder)
                .tint(Theme.Palette.accent)

            if !sourcePrefs.useAddonOrder {
                ForEach(Array(sourcePrefs.typeOrder.enumerated()), id: \.element) { index, sourceType in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourceType.label)
                            Text(sourceType.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Reorder controls follow the accent (#49), dimmed when disabled at an end —
                        // the touch twin of tvOS's accent reorder chips.
                        Button {
                            sourcePrefs.moveType(at: index, direction: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(index == 0 ? Theme.Palette.textTertiary : Theme.Palette.accent)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button {
                            sourcePrefs.moveType(at: index, direction: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(index == sourcePrefs.typeOrder.count - 1 ? Theme.Palette.textTertiary : Theme.Palette.accent)
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == sourcePrefs.typeOrder.count - 1)
                    }
                }
            }
            Picker("Safety filter", selection: $sourcePrefs.safetyMode) {
                Text("Off").tag("off")
                Text("Balanced").tag("balanced")
                Text("Strict").tag("strict")
            }
            TextField("Hide words", text: $sourcePrefs.excludeKeywords)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Require words", text: $sourcePrefs.includeKeywords)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Toggle("Match words as regex", isOn: $sourcePrefs.keywordsAreRegex).tint(Theme.Palette.accent)
            Text(sourcePrefs.keywordsAreRegex
                 ? String(localized: "Hide / Require are case-insensitive regex patterns (e.g. require 2160p.*(remux|bluray), hide \\b(cam|ts)\\b). An invalid pattern is ignored.")
                 : String(localized: "Hide / Require match comma-separated words in the source name. Turn on regex for full patterns."))
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Instant sources only", isOn: $sourcePrefs.instantOnly).tint(Theme.Palette.accent)
            Toggle("Hide dead torrents", isOn: $sourcePrefs.hideDeadTorrents).tint(Theme.Palette.accent)
            Toggle("HDR sources only", isOn: $sourcePrefs.hdrOnly).tint(Theme.Palette.accent)
            Toggle("Hide AV1 sources", isOn: $sourcePrefs.excludeAV1).tint(Theme.Palette.accent)
            Picker("Max quality", selection: $sourcePrefs.maxResolution) {
                Text("Unlimited").tag(0)
                Text("4K").tag(4000)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
            }
            Picker("Max file size", selection: $sourcePrefs.maxFileSizeGB) {
                Text("Unlimited").tag(0.0)
                Text("2 GB").tag(2.0)
                Text("5 GB").tag(5.0)
                Text("10 GB").tag(10.0)
                Text("15 GB").tag(15.0)
                Text("20 GB").tag(20.0)
                Text("30 GB").tag(30.0)
                Text("50 GB").tag(50.0)
            }
            // Pinned sources (#15): long-press a source on any title to pin it; this clears them all.
            if pinStore.pinnedCount > 0 {
                Button(role: .destructive) { pinStore.clearAll() } label: {
                    Label("Clear pinned sources (\(pinStore.pinnedCount))", systemImage: "pin.slash")
                }
                .tint(Theme.Palette.danger)
            }
        } header: {
            Text("Streams")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When on, streams appear in the order your add-ons return them. Useful if you use a ranking add-on like AIOStreams. When off, the app's own ranking applies.")
                if !sourcePrefs.useAddonOrder {
                    Text("Sources matching the top type are ranked first within each quality tier. Debrid and Usenet are always instant; Torrent streams require peer availability.")
                }
                Text("Safety filter hides CAM and fake-quality sources. Hide / Require words filter the source list by name, comma-separated (e.g. hide \"cam, ts\", require \"remux\").")
            }
        }
    }

    // MARK: Community & privacy

    /// The give-to-get master switch + the opt-in "Singularity" community source index. The master toggle
    /// governs whether this device both contributes anonymized metadata AND consumes every pooled feature;
    /// off = out of the whole pool. Singularity SERVE is a further per-device opt-in that also needs sign-in.
    @ViewBuilder private var communitySection: some View {
        Section {
            Toggle("Contribute anonymized data to improve results", isOn: $moatContribute)
                .tint(Theme.Palette.accent)
            Text(MoatConsent.disclosure)
                .font(.caption).foregroundStyle(.secondary)
            if moatContribute {
                Toggle("Singularity sources", isOn: $singularityServe)
                    .tint(Theme.Palette.accent)
                    .disabled(!account.isSignedIn)
                if account.isSignedIn {
                    Text("Show extra community-corroborated sources alongside your own, pooled across signed-in VortX users.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sign in to VortX to turn on Singularity sources.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Community")
        }
    }

    // MARK: Streaming server

    @ViewBuilder private var serverSection: some View {
        Section {
            HStack(spacing: Theme.Space.sm) {
                Circle().fill(serverColor).frame(width: 12, height: 12)
                Text(serverText)
                Spacer()
                Text(serverBadgeText)
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.Palette.surface3, in: Capsule())
                    .foregroundStyle(.secondary)
            }

            if !effectiveDirectLinksOnly {
                Text(StremioServer.base)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                NavigationLink {
                    ServerConfigView { Task { serverOnline = await StremioServer.isOnline() } }
                } label: {
                    Label("Configure server", systemImage: "server.rack")
                }

                #if !os(macOS)
                // The embedded server tees its console + uncaught errors + a per-second heartbeat to a log
                // file. Surfacing it lets a user whose server dies on-device read/share the exact cause
                // (the sim can't reproduce it). iOS/iPad only: this is the in-process NodeServer.
                if !StremioServer.isCustom {
                    NavigationLink {
                        ServerLogView()
                    } label: {
                        Label("Server log", systemImage: "doc.text.magnifyingglass")
                    }
                    // The in-process Node server CANNOT re-init once it exits (a nodejs-mobile limit), so a
                    // "restart" on iOS is necessarily a fresh app launch. Always offered now (the user asked
                    // for a one-tap restart to reclaim memory before/after the server is killed under
                    // pressure), not only once it has already exited. role:.destructive + the label make the
                    // quit explicit, and the status line below says whether the server is currently running.
                    Button(role: .destructive) { exit(0) } label: {
                        Label("Restart server (quits VortX, then reopen it)", systemImage: "arrow.clockwise")
                    }
                }
                #endif

                #if os(macOS)
                if !StremioServer.isCustom {
                    // macOS: the server is a CHILD process, so restart it IN PLACE without quitting the app
                    // (unlike iOS' one-shot in-process nodejs-mobile). Reaps the child, frees its accumulated
                    // memory, and rebinds 11470. Same restart() the LAN-sharing toggle already uses.
                    Button {
                        NodeServer.restart()
                        Task {   // re-check status once the child has respawned
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            serverOnline = await StremioServer.isOnline()
                        }
                    } label: {
                        Label("Restart streaming server", systemImage: "arrow.clockwise")
                    }
                    // macOS only: let this Mac act as a Stremio streaming server for the rest of the
                    // LAN (like the desktop app), so the Apple TV / phone can use it as their server.
                    lanSharingControls
                }
                #endif
            }
        } header: {
            Text("Streaming Server")
        } footer: {
            if effectiveDirectLinksOnly {
                Text(PlaybackSettings.directLinksOnlyForced
                     ? String(localized: "This build does not bundle the streaming server.")
                     : String(localized: "Direct Links Only is enabled, so torrent streaming and server configuration are inactive."))
            }
        }
    }

    #if os(macOS)
    /// The "Share on this network" toggle + LAN URL + transcoding status (macOS only). Shown when
    /// the embedded server is in use. Flipping the toggle restarts node so the new bind takes hold.
    @ViewBuilder private var lanSharingControls: some View {
        Toggle(isOn: Binding(
            get: { shareOnLAN },
            set: { newValue in
                shareOnLAN = newValue
                NodeServer.sharedOnLAN = newValue            // persists + restarts node
                didCopyLAN = false
                Task {                                        // re-check status after the restart
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    serverOnline = await StremioServer.isOnline()
                }
            }
        )) {
            Label("Share streaming server on this network", systemImage: "wifi")
        }
        .tint(Theme.Palette.accent)

        if shareOnLAN {
            if let url = NodeServer.lanURL {
                // The address other devices paste into their own "Configure server" field.
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(url, forType: .string)
                    didCopyLAN = true
                } label: {
                    HStack {
                        Label(url, systemImage: "link")
                            .font(.system(.footnote, design: .monospaced))
                        Spacer()
                        Image(systemName: didCopyLAN ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Label("Connect to Wi-Fi or Ethernet to get a shareable address",
                      systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if !NodeServer.canTranscode {
            Label("Install ffmpeg (brew install ffmpeg) to enable VideoToolbox transcoding",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private var serverColor: Color {
        if effectiveDirectLinksOnly { return Theme.Palette.textTertiary }
        switch serverOnline {
        case .some(true): return Color(.sRGB, red: 0.45, green: 0.72, blue: 0.42, opacity: 1)
        case .some(false): return Theme.Palette.danger
        default: return Theme.Palette.accent
        }
    }
    private var serverText: String {
        if effectiveDirectLinksOnly { return String(localized: "Disabled by Direct Links Only") }
        switch serverOnline {
        case .some(true): return String(localized: "Online")
        case .some(false): return String(localized: "Offline")
        default: return String(localized: "Checking…")
        }
    }
    private var serverBadgeText: String {
        if effectiveDirectLinksOnly {
            return PlaybackSettings.directLinksOnlyForced ? String(localized: "NOT BUNDLED") : String(localized: "DISABLED")
        }
        return StremioServer.isCustom ? String(localized: "CUSTOM") : String(localized: "EMBEDDED")
    }

    // MARK: Appearance

    @ViewBuilder private var appearanceSection: some View {
        Section {
            // Placed first so the Live TV tab toggle is easy to find at the top of Appearance
            // (it was previously buried below all the pickers and steppers).
            Toggle("Show Live TV tab", isOn: Binding(get: { !hideLiveTab }, set: { hideLiveTab = !$0 }))
            // The built-in editorial Home rails (Critically Acclaimed, Hidden Gems, etc.) are Cinemeta-
            // backed and show even with no add-ons installed; this hides them (the "extra catalogs I
            // cannot remove from Home" report).
            Toggle("Show editorial Home rows", isOn: $showCuratedRails)
            // Collections hub (Discover cards + Streaming-service tiles + Genre tiles) on Home / Discover; needs a TMDB key.
            Toggle("Collections on Home", isOn: $showHubHome)
            Toggle("Collections on Discover", isOn: $showHubDiscover)
            Picker("Refresh collections", selection: $hubCadence) {
                Text("Daily").tag("daily")
                Text("Twice daily").tag("twiceDaily")
                Text("4x daily").tag("fourTimesDaily")
            }
            NavigationLink("Reorder streaming services") { iOSReorderServicesView() }
            NavigationLink("Discover & region") { iOSDiscoverSettingsView() }
            // Fold Search into Discover (one combined surface with a search field above the browse) so the
            // tab bar is less cluttered on mobile. Default OFF, fully reversible — Search returns as its own tab.
            Toggle("Combine Discover & Search", isOn: $mergeDiscoverSearch)
            Toggle("Budget & box office", isOn: $showFinancials)
            Toggle("Blur unwatched episode thumbnails", isOn: $spoilerBlur)
            // Poster appearance (width / corner radius / landscape art / labels) lives on its own screen
            // with a live preview. The old inline "Cinematic landscape cards" toggle moved there.
            NavigationLink("Poster style") { iOSPosterStyleView() }
            // Surface the hide-labels toggle here too so it is discoverable without opening Poster style.
            // It applies across every poster rail (Discover, Home, Continue Watching, More Like This) since
            // they all render through the shared PosterCardiOS which reads this same preference.
            Toggle("Hide poster labels", isOn: $catalogPrefs.hidePosterLabels)

            // ThemeAccentPicker / ThemeBackgroundPicker are tvOS-only (declared in SourcesTV); on
            // iOS we bind native Pickers to the SAME ThemeManager state (accentID, oled).
            Picker("Accent", selection: $theme.accentID) {
                ForEach(ThemeManager.accents) { accent in
                    Text(accent.label).tag(accent.id)
                }
            }
            Picker("Background", selection: $theme.oled) {
                Text("Warm").tag(false)
                Text("OLED Black").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Dolby Vision / HDR", selection: $hdrToneMapMode) {
                Text("Auto").tag("auto")
                Text("Tone-map to SDR").tag("on")
                Text("Always HDR").tag("off")
            }

            Stepper(value: $theme.textScale,
                    in: ThemeManager.textScaleRange,
                    step: ThemeManager.textScaleStep) {
                Text("App text size  ·  \(Int((theme.textScale * 100).rounded()))%")
            }

            Picker("Performance", selection: $perfMode) {
                Text("Auto").tag("auto")
                Text("Full").tag("full")
                Text("Reduced").tag("reduced")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accent recolors selection and progress across the app. OLED Black uses true black, best on AMOLED panels.")
                Text("Auto tone-maps HDR and Dolby Vision to SDR only on a screen that can't show HDR. Choose Tone-map to SDR if 4K Dolby Vision remuxes look washed out, green or purple; Always HDR to force pass-through.")
                Text("Performance Auto keeps the full experience on capable devices and switches to a lighter one on weaker hardware. Reduced trims animations and shrinks playback buffers. Restart the app after changing this.")
            }
        }
    }

    // MARK: Audio & subtitle preferences

    @ViewBuilder private var audioSubtitleSection: some View {
        Section {
            // Each menu Picker carries its OWN .tint plus an .id keyed to the accent. UIKit only
            // re-realizes the FIRST menu Picker per Section when the inherited Form tint changes, so
            // without this the 2nd+ pickers' trailing value labels kept the previous accent color
            // (the "not all settings change colour" report, #21 follow-up). The .id forces a rebuild.
            Picker("Audio language", selection: $prefAudioLang) {
                ForEach(languageOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("audioLang-\(theme.accentID)")
            Picker("Subtitle language", selection: $prefSubLang) {
                ForEach(languageOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("subLang-\(theme.accentID)")
            Picker("Subtitles", selection: $prefForced) {
                ForEach(TrackPreferences.ForcedPolicy.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            .tint(Theme.Palette.accent).id("subForced-\(theme.accentID)")
        } header: {
            Text("Audio & Subtitles")
        } footer: {
            Text("The player auto-picks these when a title starts. Forced shows only foreign-dialogue captions; Always shows full subtitles in your language. Foreign-language titles always get full subtitles so you can follow.")
        }
    }

    /// The curated list, plus the device languages so a stored value that isn't in the curated set
    /// still resolves to a Picker tag (an unmatched selection renders blank otherwise).
    private var languageOptions: [(id: String, label: String)] {
        var seen = Set(TrackPreferences.commonLanguages.map(\.id))
        var out = TrackPreferences.commonLanguages
        for code in TrackPreferences.deviceLanguages where seen.insert(code).inserted {
            out.append((id: code, label: code.uppercased()))
        }
        return out
    }

    // MARK: Subtitle style

    @ViewBuilder private var subtitleSection: some View {
        Section {
            // Per-Picker .tint + .id(accentID) so every value label repaints on accent change, not
            // just the first one in the section (see Audio & Subtitles note, #21 follow-up).
            Picker("Font", selection: $subFont) {
                ForEach(SubtitleStyle.fonts, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("subFont-\(theme.accentID)")
            Picker("Size", selection: $subSize) {
                ForEach(SubtitleStyle.sizes, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("subSize-\(theme.accentID)")
            Stepper(value: subSizeScaleBinding,
                    in: SubtitleStyle.sizeScaleRange,
                    step: SubtitleStyle.sizeScaleStep) {
                Text("Fine size  ·  \(Int((subSizeScale * 100).rounded()))%")
            }
            Picker("Color", selection: $subColor) {
                ForEach(SubtitleStyle.colors, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("subColor-\(theme.accentID)")
            Picker("Background", selection: $subBackground) {
                ForEach(SubtitleStyle.backgrounds, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id("subBackground-\(theme.accentID)")
        } header: {
            Text("Subtitle Style")
        } footer: {
            Text("Styles the built-in player's subtitles. Pick which subtitle track to show from the player while watching.")
        }
    }

    /// Mirrors tvOS adjustSubScale: clamp to range, round to 0.01, then fold into the active
    /// profile. (The flat-key write alone wouldn't capture, since subSizeScale has no .onChange.)
    private var subSizeScaleBinding: Binding<Double> {
        Binding(
            get: { subSizeScale },
            set: { next in
                let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound),
                                  SubtitleStyle.sizeScaleRange.upperBound)
                subSizeScale = (clamped * 100).rounded() / 100
                ProfileStore.shared.capturePlayback()
            }
        )
    }

    // MARK: About

    private var backupSection: some View {
        Section {
            Button {
                do {
                    backupDocument = BackupDocument(data: try SettingsBackup.makeBackup())
                    showBackupExporter = true
                } catch {
                    backupAlert = BackupAlert(title: String(localized: "Backup Failed"), message: error.localizedDescription)
                }
            } label: {
                Label("Create Backup", systemImage: "arrow.up.doc")
            }
            Button {
                showBackupImporter = true
            } label: {
                Label("Restore from Backup", systemImage: "arrow.down.doc")
            }
            Button {
                exportActiveLibrary()
            } label: {
                Label("Export Library", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                showLibraryImporter = true
            } label: {
                Label("Import Library", systemImage: "square.and.arrow.down.on.square")
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Save your profiles, theme, and playback preferences to a file you can keep, so a future major update can never lose them. Export Library carries the active profile's saved titles and watch progress to another device or profile, no account needed.")
        }
    }

    /// Serialize the active profile's library + watch history and present the file exporter. Reads the
    /// right source per the per-profile invariant (engine library for the owner, the private overlay
    /// otherwise); an empty library is surfaced instead of writing a useless empty file.
    private func exportActiveLibrary() {
        let items = profiles.exportActiveLibraryItems()
        guard !items.isEmpty else {
            backupAlert = BackupAlert(title: String(localized: "Nothing to Export"),
                message: String(localized: "This profile has no saved titles or watch history yet."))
            return
        }
        do {
            let data = try LibraryPortability.encode(items: items, profile: profiles.active?.name ?? "Profile")
            libraryDocument = BackupDocument(data: data)
            showLibraryExporter = true
        } catch {
            backupAlert = BackupAlert(title: String(localized: "Export Failed"), message: error.localizedDescription)
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section("About") {
            if let update = updates.available {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update available: \(update.name)", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Install the new build from the GitHub releases page; your sign-in and settings carry over.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Version", value: appVersion)
            LabeledContent("Player", value: String(localized: "libmpv · MPVKit"))
            NavigationLink {
                WhatsNewView()
            } label: {
                Label("What's New", systemImage: "sparkles")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    // MARK: Engine diagnostics (the FFI smoke check kept off the Home page)

    @ViewBuilder private var engineSection: some View {
        Section("Engine") {
            LabeledContent("stremio-core schema", value: "\(core.schemaVersion)")
            LabeledContent("Home rows", value: "\(core.boardRows.count)")
        }
    }
}

/// Wraps the backup JSON for SwiftUI's `.fileExporter` / `.fileImporter`. Works on iOS and
/// macOS; tvOS has no document UI, so file backup lives on the other platforms.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Identifiable wrapper so a backup / restore result can drive a one-off `.alert(item:)`.
struct BackupAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#if !os(macOS)
/// Read-only view of the embedded streaming server's status + recent log. The server tees its console
/// output, uncaught exceptions, and a per-second heartbeat to a log file; surfacing it lets a user whose
/// server dies on a real device (which the simulator does not reproduce) read and share the exact cause.
private struct ServerLogView: View {
    @State private var lines: [String] = []
    @State private var status = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(status)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if lines.isEmpty {
                    Text("No log yet. If the server stopped, play a torrent title to start it, then return here.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Server log")
        .inlineNavigationTitle()
        .toolbar {
            HStack {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                Button {
                    UIPasteboard.general.string = status + "\n\n" + lines.joined(separator: "\n")
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        status = NodeServer.statusDescription
        lines = NodeServer.logTail(80)
        copied = false
    }
}
#endif

/// New-episode alerts (F5). Schedules a one-shot local notification at the air time of each upcoming
/// episode of a series the user opens, so a show they follow pings the moment its next episode drops,
/// with no polling and no background task (the system delivers scheduled local notifications on its own).
/// Keyed by episode id, so re-opening a show refreshes its alerts instead of duplicating them. Our own
/// native take on Stremio's library-notification idea, built on Apple's local notification scheduling.
enum NewEpisodeNotifications {
    static let enabledKey = "stremiox.notifyNewEpisodes"

    /// On by default: an unset key reads as enabled, so a followed show pings out of the box and the first
    /// schedule asks for permission in context. Once the user flips the toggle, the stored value wins.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Turn alerts on or off. Enabling asks the system for permission; a denial flips the stored flag back
    /// off so the toggle reflects the real authorization. Disabling clears every pending alert. Returns the
    /// effective state so a caller's toggle can settle to the truth.
    @discardableResult
    @MainActor static func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    /// Ask for permission the first time there is something to schedule (alerts are on by default, so the
    /// prompt lands in context). Returns whether we may post. A denial is respected, we schedule nothing.
    @discardableResult
    static func ensureAuthorized() async -> Bool {
        guard isEnabled else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    /// Schedule a single alert at the air time of the SOONEST not-yet-aired episode of a series within the
    /// next 45 days. Keyed by series id, so each series holds exactly one pending request (re-scheduling
    /// replaces it), which keeps even a large library sweep comfortably under iOS's 64 pending-request cap.
    /// No-op when alerts are off, or when the series has nothing upcoming.
    static func scheduleUpcoming(seriesId: String, seriesName: String, videos: [CoreVideo]) {
        guard isEnabled else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(45 * 86_400)
        let center = UNUserNotificationCenter.current()
        let identifier = "stremiox.nextep.\(seriesId)"
        let next = videos
            .compactMap { v -> (CoreVideo, Date)? in v.releasedDate.map { (v, $0) } }
            .filter { $0.1 > now && $0.1 < horizon }
            .min { $0.1 < $1.1 }
        guard let (v, air) = next else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])   // nothing upcoming -> clear any stale one
            return
        }
        let content = UNMutableNotificationContent()
        content.title = seriesName
        let epLabel = v.season.map { "S\($0)E\(v.episodeNumber)" } ?? "Episode \(v.episodeNumber)"
        content.body = "New episode is out: \(epLabel)"
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: air)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Convenience for the open-series hook: ensure permission, then schedule that one series.
    static func scheduleUpcomingAuthorized(seriesId: String, seriesName: String, videos: [CoreVideo]) async {
        guard await ensureAuthorized() else { return }
        scheduleUpcoming(seriesId: seriesId, seriesName: seriesName, videos: videos)
    }

    /// Library-wide sweep: schedule the next-episode alert for EVERY series in the library, not just the
    /// ones the user opens. Each series' meta is fetched straight from the installed meta add-ons (never the
    /// engine, so the open detail page's meta slot is untouched), capped and off the main thread, so a show
    /// the user follows pings even if they never reopen its page.
    static func sweepLibrary(seriesIDs: [String], seriesNames: [String: String], metaBases: [String]) async {
        guard await ensureAuthorized(), !metaBases.isEmpty else { return }
        for id in seriesIDs.prefix(60) {
            guard let meta = await fetchSeriesMeta(id: id, bases: metaBases) else { continue }
            scheduleUpcoming(seriesId: id, seriesName: meta.name.isEmpty ? (seriesNames[id] ?? meta.name) : meta.name,
                             videos: meta.videos ?? [])
        }
    }

    /// One series' full meta, fetched directly over the add-on protocol from the first meta add-on that
    /// answers. Never touches the engine. nil if none decode.
    /// The implementation moved to the OS-agnostic `SeriesMetaFetcher` (SourcesShared) so the shared
    /// `ReleaseCalendarModel` reuses the EXACT same fetch and the tvOS targets — which don't compile this
    /// SourcesiOS file — can reach it. This thin shim keeps the existing callers unchanged; behavior is identical.
    static func fetchSeriesMeta(id: String, bases: [String]) async -> CoreMetaItem? {
        await SeriesMetaFetcher.fetch(id: id, bases: bases)
    }
}
