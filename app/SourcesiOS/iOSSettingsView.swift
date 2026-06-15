import SwiftUI

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
    @State private var serverOnline: Bool?
    @State private var editingProfile: UserProfile?
    @State private var showSignIn = false
    #if os(macOS)
    /// Drives the "Share streaming server on this network" toggle (macOS only). Backed by
    /// NodeServer.sharedOnLAN, which persists + restarts the node process when it flips.
    @State private var shareOnLAN = NodeServer.sharedOnLAN
    @State private var didCopyLAN = false
    #endif

    @AppStorage("stremiox.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @AppStorage(TrackPreferences.Key.forced) private var prefForced = TrackPreferences.ForcedPolicy.forced.rawValue
    @AppStorage(TrackPreferences.Key.audio) private var prefAudioLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subtitle) private var prefSubLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @AppStorage(PerformanceMode.overrideKey) private var perfMode = "auto"
    @AppStorage(AudioOutputMode.key) private var audioOutput = AudioOutputMode.auto.rawValue
    // Empty string == built-in libmpv player; otherwise an ExternalPlayer.Target id to auto-open in.
    @AppStorage(ExternalPlayer.defaultKey) private var defaultExternalPlayer = ""

    var body: some View {
        NavigationStack {
            Form {
                // Each section's row cards use the brand surface, not the system grouped grey (#49
                // follow-up): `.listRowBackground` on a Section repaints all its rows. Combined with
                // `.scrollContentBackground(.hidden)` + the canvas background below, the cards now read
                // as warm dark surfaces with canvas showing between them, matching the rest of the app
                // (and identical on iPadOS, which shares this view).
                profilesSection.listRowBackground(Theme.Palette.surface1)
                accountSection.listRowBackground(Theme.Palette.surface1)
                playbackSection.listRowBackground(Theme.Palette.surface1)
                streamsSection.listRowBackground(Theme.Palette.surface1)
                serverSection.listRowBackground(Theme.Palette.surface1)
                appearanceSection.listRowBackground(Theme.Palette.surface1)
                audioSubtitleSection.listRowBackground(Theme.Palette.surface1)
                subtitleSection.listRowBackground(Theme.Palette.surface1)
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
            .navigationTitle("Settings")
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            .platformFullScreenCover(item: $editingProfile) { profile in
                ProfileEditorView(original: profile)
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

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section("Account") {
            if account.isSignedIn {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email ?? "Signed in")
                    Text("\(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
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
                     ? "This build does not bundle the torrent engine. Only direct and debrid links can play."
                     : "Hide torrent and magnet sources. Only direct and debrid links will play.")
                Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? "")
                if !installedExternalPlayers.isEmpty {
                    Text("Direct and debrid streams open straight in your chosen player, which then handles playback and resume. Torrents, header-protected sources, and trailers always use the built-in player.")
                }
            }
        }
    }

    /// External players present on this device, the choices the "Play in" picker offers. Evaluated once
    /// per view build; installing a new player after launch needs a Settings re-open to appear.
    private var installedExternalPlayers: [ExternalPlayer.Target] { ExternalPlayer.installed }

    private var effectiveDirectLinksOnly: Bool { PlaybackSettings.directLinksOnly }

    /// Direct Links Only writes the flat key; turning it OFF cold-starts the embedded server so
    /// torrents work again without a relaunch (guarded out of the Lite build that ships no server).
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
        } header: {
            Text("Streams")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When on, streams appear in the order your add-ons return them. Useful if you use a ranking add-on like AIOStreams. When off, the app's own ranking applies.")
                if !sourcePrefs.useAddonOrder {
                    Text("Sources matching the top type are ranked first within each quality tier. Debrid and Usenet are always instant; Torrent streams require peer availability.")
                }
            }
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
                        Label("Restart server (quits StremioX, then reopen it)", systemImage: "arrow.clockwise")
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
                     ? "This build does not bundle the streaming server."
                     : "Direct Links Only is enabled, so torrent streaming and server configuration are inactive.")
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
        if effectiveDirectLinksOnly { return "Disabled by Direct Links Only" }
        switch serverOnline {
        case .some(true): return "Online"
        case .some(false): return "Offline"
        default: return "Checking…"
        }
    }
    private var serverBadgeText: String {
        if effectiveDirectLinksOnly {
            return PlaybackSettings.directLinksOnlyForced ? "NOT BUNDLED" : "DISABLED"
        }
        return StremioServer.isCustom ? "CUSTOM" : "EMBEDDED"
    }

    // MARK: Appearance

    @ViewBuilder private var appearanceSection: some View {
        Section {
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

            Toggle("Dolby Vision / HDR compatibility", isOn: $forceSDRTonemap)
                .tint(Theme.Palette.accent)

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
                Text("Dolby Vision / HDR compatibility tone-maps HDR and Dolby Vision to SDR. Turn this on only if 4K Dolby Vision remuxes look washed out, green, or purple; most displays should leave it off.")
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
            .tint(Theme.Palette.accent).id(theme.accentID)
            Picker("Subtitle language", selection: $prefSubLang) {
                ForEach(languageOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id(theme.accentID)
            Picker("Subtitles", selection: $prefForced) {
                ForEach(TrackPreferences.ForcedPolicy.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            .tint(Theme.Palette.accent).id(theme.accentID)
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
            .tint(Theme.Palette.accent).id(theme.accentID)
            Picker("Size", selection: $subSize) {
                ForEach(SubtitleStyle.sizes, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id(theme.accentID)
            Stepper(value: subSizeScaleBinding,
                    in: SubtitleStyle.sizeScaleRange,
                    step: SubtitleStyle.sizeScaleStep) {
                Text("Fine size  ·  \(Int((subSizeScale * 100).rounded()))%")
            }
            Picker("Color", selection: $subColor) {
                ForEach(SubtitleStyle.colors, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id(theme.accentID)
            Picker("Background", selection: $subBackground) {
                ForEach(SubtitleStyle.backgrounds, id: \.id) { Text($0.label).tag($0.id) }
            }
            .tint(Theme.Palette.accent).id(theme.accentID)
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
            LabeledContent("Player", value: "libmpv · MPVKit")
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
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
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
