import SwiftUI

/// Settings: who you're signed in as, the embedded streaming-server status, subtitles, and app info.
/// Mirrors the official tvOS app's Settings sections, on the StremioX design system.
struct SettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @EnvironmentObject private var profiles: ProfileStore
    @State private var serverOnline: Bool?
    @AppStorage("stremiox.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage("stremiox.hdrToneMapMode") private var hdrToneMapMode = "auto"   // auto / on / off
    @State private var showRestartConfirm = false
    @State private var editingProfile: UserProfile?
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
    @AppStorage("stremiox.seekStep") private var seekStep = "10"   // skip step in seconds, shared with the player
    @AppStorage(ExternalPlayers.defaultKey) private var defaultExternalPlayer = ""   // "" == built-in libmpv
    @ObservedObject private var sourcePrefs = SourcePreferences.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Settings").screenTitleStyle()
                    profilesSection
                    accountSection
                    playbackSection
                    streamsSection
                    serverSection
                    appearanceSection
                    audioSubtitleSection
                    subtitleSection
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
        section("Account") {
            // The whole account block is one focus section so Down keeps stepping DOWN through
            // its stacked rows instead of leaving after the first hit. "Log Out" sits far right
            // (after a Spacer) while the rows below it are left-aligned; without this grouping
            // the downward beam from Log Out misses the left-aligned links and the engine exits
            // the section, skipping "VortX account & sync" and the metadata-keys row.
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if account.isSignedIn {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.email ?? "Signed in").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                            Text("\(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Button { account.signOut(); core.logOut() } label: {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    }
                } else {
                    NavigationLink { LoginView(account: account) } label: {
                        Label("Sign in to your Stremio account", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
                NavigationLink { SyncSettingsView() } label: {
                    Label("VortX account & sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { MetadataKeysView() } label: {
                    Label("Metadata (TMDB, MDBList)", systemImage: "sparkles")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
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
            choiceRow("Audio output", AudioOutputMode.allCases.map { ($0.rawValue, $0.label) }, selection: $audioOutput)
            Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? "")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow("Skip step", [("10", "10s"), ("15", "15s"), ("30", "30s")], selection: $seekStep)
            choiceRow("Play in", externalPlayerChoices, selection: $defaultExternalPlayer)
            Text("Direct and debrid streams open in your chosen player automatically. Torrents and the built-in player are unaffected.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Built-in plus every curated external player; picking one auto-hands eligible streams to it.
    private var externalPlayerChoices: [(String, String)] {
        [("", "Built-in player")] + ExternalPlayers.menu().map { ($0.id, $0.name) }
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

    private var appearanceSection: some View {
        section("Appearance") {
            ThemeAccentPicker(selection: $theme.accentID).focusSection()
            ThemeBackgroundPicker(oled: $theme.oled).focusSection()
            Text("Accent recolors focus, selection, and progress across the app. OLED Black uses true black, best on AMOLED panels.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow("Dolby Vision / HDR", [("auto", "Auto"), ("on", "Tone-map to SDR"), ("off", "Always HDR")], selection: $hdrToneMapMode)
            Text("Auto tone-maps HDR and Dolby Vision to SDR only on a TV that can't show HDR. Choose Tone-map to SDR if 4K Dolby Vision remuxes look washed out, green or purple on your TV; Always HDR forces pass-through.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            stepperRow("App text size", value: theme.textScale,
                       range: ThemeManager.textScaleRange,
                       onMinus: { theme.adjustTextScale(-1) },
                       onPlus: { theme.adjustTextScale(1) })
            Text("Makes every screen's text larger or smaller. Changes apply instantly.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow("Performance", [("auto", "Auto"), ("full", "Full"), ("reduced", "Reduced")], selection: $perfMode)
            Text("Auto keeps the full experience on capable Apple TVs and switches to a lighter one on older models like the Apple TV HD. Reduced trims animations and shrinks playback buffers so the remote stays responsive on weak hardware. Restart the app after changing this.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Stream source preferences

    private var streamsSection: some View {
        section("Streams") {
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
            choiceRow("Safety filter", [("off", "Off"), ("balanced", "Balanced"), ("strict", "Strict")], selection: $sourcePrefs.safetyMode)
            Text("Hides CAM and fake-quality sources. Hide / Require words filter the list by name (comma-separated).")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Space.md) {
                Text("Hide words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.excludeKeywords)
            }
            HStack(spacing: Theme.Space.md) {
                Text("Require words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.includeKeywords)
            }
            choiceRow("Max file size",
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
            choiceRow("Audio language", TrackPreferences.commonLanguages, selection: $prefAudioLang)
            choiceRow("Subtitle language", TrackPreferences.commonLanguages, selection: $prefSubLang)
            choiceRow("Subtitles", TrackPreferences.ForcedPolicy.allCases.map { ($0.rawValue, $0.label) }, selection: $prefForced)
            Text("The player auto-picks these when a title starts. Forced shows only foreign-dialogue captions; Always shows full subtitles in your language. Foreign-language titles always get full subtitles so you can follow.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Subtitle style

    private var subtitleSection: some View {
        section("Subtitle Style") {
            choiceRow("Font", SubtitleStyle.fonts.map { ($0.id, $0.label) }, selection: $subFont)
            choiceRow("Size", SubtitleStyle.sizes.map { ($0.id, $0.label) }, selection: $subSize)
            stepperRow("Fine size", value: subSizeScale,
                       range: SubtitleStyle.sizeScaleRange,
                       onMinus: { adjustSubScale(-1) },
                       onPlus: { adjustSubScale(1) })
            choiceRow("Color", SubtitleStyle.colors.map { ($0.id, $0.label) }, selection: $subColor)
            choiceRow("Background", SubtitleStyle.backgrounds.map { ($0.id, $0.label) }, selection: $subBackground)
            Text("Styles the built-in player's subtitles. Pick which subtitle track to show from the player while watching.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
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
        }
    }

    private var aboutSection: some View {
        section("About") {
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
            infoRow("Version", appVersion)
            infoRow("Player", "libmpv · MPVKit")
            infoRow("Server", "Stremio streaming server (nodejs-mobile)")
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
