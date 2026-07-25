import SwiftUI

/// EXTERNAL ENGINE MODE, the CLIENT half of the settings UI: the one screen where an Apple TV, iPhone, iPad
/// or Mac says "use that Mac".
///
/// WHY THIS SCREEN IS THE WHOLE CONFIGURATION SURFACE. `VortXEngineHostPolicy.mountPlan` will not route a
/// single playback off-device until three things are true at once: the user turned the feature on, the fleet
/// kill switch is still on, and a host string is stored. Nothing else in the app can make the first and third
/// true. There is no onboarding nudge, no "we found a Mac, shall we?" banner, and no code path anywhere that
/// adopts a discovered host on its own (see the never-adopts rule at the top of `VortXEngineDiscovery`). So if
/// nobody opens this screen, external engine mode never runs, which is exactly the default the feature ships
/// with and the property the DV lane's two field regressions bought.
///
/// DISCOVERY ONLY OFFERS. `VortXEngineBrowser` publishes a list and owns no setting. This view is the half
/// that could most easily violate that, so it is written so the violation is not available: the ONLY code
/// below that ever writes `VortXExternalEngine.shared.host` is `VortXExternalEngine.pair`, which is reached
/// from a human tapping a row and then typing a code a human read off the Mac's own screen. A row that is
/// merely visible, merely resolved, or merely the only one in the list still does nothing.
///
/// MANUAL ENTRY IS AN EQUAL PATH, NOT A FALLBACK. mDNS does not cross a Tailscale tunnel, a VLAN, or most
/// mesh-router guest separations, and those are ordinary setups rather than exotic ones. A user on any of
/// them would see an empty list forever, so the address field is a first-class card with its own heading
/// rather than something buried behind "having trouble?". Both paths end in the same `pair(host:code:)` call
/// against the same normalizer, so neither is second class in behaviour either.
///
/// TVOS FOCUS. Every actionable thing here is a `Button`, a `Toggle` or a `TextField`, because those are what
/// the tvOS focus engine can reach with a remote. There is no hover-only affordance, no swipe action and no
/// context menu, since none of those exist on a TV. The rows are plain (no per-row `focusSection`), because
/// stacked sibling focus sections make tvOS skip rows, which is the lesson `AddonPairingView` records.
///
/// ONE MORE HONEST NOTE, kept on screen rather than in a comment: the media crosses the network as cleartext
/// HTTP. Pairing is what stops another device on the same Wi-Fi fetching it. `VortXEngineProtocol` says the
/// UI must not imply transport security we do not have, so the closing card says exactly that in the user's
/// words.
struct ExternalEngineSettingsView: View {

    /// Screen-scoped, exactly as `VortXEngineBrowser` documents: mDNS traffic while nobody is looking at a
    /// host list is waste, and on tvOS it is waste on a device with a small radio budget. Started in
    /// `onAppear`, stopped in `onDisappear`, so its lifetime is this screen's.
    @StateObject private var browser = VortXEngineBrowser()

    // MARK: - Mirrors of the engine singleton
    //
    // `VortXExternalEngine` is a plain `@unchecked Sendable` singleton over UserDefaults and the Keychain,
    // deliberately not an ObservableObject (it is the reference client implementation and is meant to stay
    // free of SwiftUI). So this view keeps @State mirrors and re-reads them through `refreshFromEngine`
    // after every write. The alternative, reading the singleton directly inside `body`, renders correctly
    // once and then never updates, because nothing would invalidate the view.

    @State private var isEnabled = false
    @State private var isPaired = false
    @State private var pairedHostName: String?
    @State private var pairedHost: String?
    @State private var capabilities: [VortXEngineProtocol.Capability] = []

    /// The hand-typed address. Never committed anywhere until a pairing against it SUCCEEDS.
    @State private var manualHost = ""

    /// The host a pairing is currently being attempted against, which also drives the sheet.
    @State private var pairingTarget: PairingTarget?
    @State private var code = ""
    @State private var isPairing = false
    @State private var pairingError: String?
    /// Set for one screen visit after a successful pairing, so the paired card can say so plainly instead of
    /// the user having to infer it from the fields changing.
    @State private var justPaired = false

    /// One host a pairing may be attempted against. Carries the ALREADY-RESOLVED dial string rather than a
    /// `VortXDiscoveredHost`, so the manual field and a discovered row produce the same value and the sheet
    /// has one code path instead of two.
    private struct PairingTarget: Identifiable {
        /// Identity is the address: re-tapping the same host while its sheet is up is a no-op rather than a
        /// second presentation.
        var id: String { address }
        let address: String
        let displayName: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Use a Mac as the engine").screenTitleStyle()
                introCard
                if isPaired { pairedCard }
                discoveredCard
                manualCard
                honestyCard
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear {
            refreshFromEngine()
            browser.start()
        }
        .onDisappear { browser.stop() }
        // A visit is the right moment to re-ask what the host can currently do: `transcode` depends on the
        // Mac having found ffmpeg and `seekAnywhere` on it still having disk, so a cached list can be stale
        // in ways that matter. Fail-soft by construction, `refreshCapabilities` returns without writing
        // anything when the host is unreachable, so a sleeping Mac leaves the last known list on screen.
        .task {
            await VortXExternalEngine.shared.refreshCapabilities()
            refreshFromEngine()
        }
        .sheet(item: $pairingTarget) { target in pairingSheet(target) }
    }

    // MARK: - Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("A Mac on your network can do the heavy container work for this device: unpacking the file, rewriting the Dolby Vision layer, and holding the stream on its disk. This device still decodes and shows the picture, so the image is identical and nothing is re-encoded.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Off until you pair a Mac and turn it on. If the Mac goes to sleep or leaves the network mid-film, playback rebuilds here automatically.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: - The paired host

    /// Everything about the Mac this device is currently paired with, including the master switch.
    ///
    /// The switch lives HERE rather than at the top of the screen on purpose: it is meaningless without a
    /// pairing (`mountPlan` returns `.onDevice` the moment `isPaired` is false), and a toggle that is present
    /// but permanently disabled reads as broken. Pair first, then the switch exists.
    private var pairedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if justPaired {
                Label("Paired", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.ok)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pairedHostName ?? String(localized: "Paired Mac"))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let pairedHost {
                    Text(pairedHost)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            if !capabilities.isEmpty {
                VortXEngineCapabilityChips(capabilities: capabilities)
            }

            Toggle(isOn: Binding(get: { isEnabled }, set: { setEnabled($0) })) {
                Text("Send playback to this Mac")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            .disabled(!isPaired)

            Text("When off, this device plays everything itself, exactly as it always has.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) { unpair() } label: {
                Label("Stop using this Mac", systemImage: "xmark.circle")
            }
            .buttonStyle(ChipButtonStyle(selected: false,
                                         accent: Theme.Palette.danger,
                                         accentText: Theme.Palette.danger))

            Text("Forgetting the Mac here also turns playback back to this device. To cancel this device's access on the Mac itself, revoke it in the Mac's own engine settings.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: - Discovered hosts

    /// The browse list. Offers, never adopts.
    ///
    /// Three states are rendered separately and none of them collapse into each other, because they mean
    /// different things to somebody staring at an empty screen: "not looking" (the browser never reached
    /// `.ready`, usually the local-network permission prompt), "looking and found nothing yet", and "here is
    /// what is on the network".
    private var discoveredCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Text("Macs on this network")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: Theme.Space.sm)
                if browser.isBrowsing { ProgressView().tint(Theme.Palette.accent) }
            }

            if browser.hosts.isEmpty {
                Text(browser.isBrowsing
                     ? String(localized: "Looking for Macs running VortX as an engine. Open VortX on the Mac, turn on \"Act as the engine for this network\", and it appears here.")
                     : String(localized: "Not searching. VortX needs permission to find devices on your local network; allow it and come back, or type the Mac's address below."))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(browser.hosts) { host in discoveredRow(host) }

            Text("Nothing here is used until you choose it. Finding a Mac never routes your playback to it.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    /// One discovered host.
    ///
    /// An INCOMPATIBLE host is shown greyed out with a reason rather than hidden, exactly as
    /// `VortXDiscoveredHost.isProtocolCompatible` asks: "a hidden host looks like a discovery bug to the
    /// owner, and a visible-but-explained one looks like the upgrade prompt it is".
    ///
    /// An UNRESOLVED host (address still nil) shows a spinner and offers a retry rather than a dead tap.
    /// Resolving costs a real TCP connection to the service endpoint, so it can legitimately take a few
    /// seconds against a Mac whose Wi-Fi radio is asleep, and it can legitimately never land.
    @ViewBuilder private func discoveredRow(_ host: VortXDiscoveredHost) -> some View {
        let usable = host.isProtocolCompatible && host.address != nil
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24))
                .foregroundStyle(usable ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(host.displayName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                Text(rowSubtitle(host))
                    .font(Theme.Typography.label)
                    .foregroundStyle(host.isProtocolCompatible ? Theme.Palette.textSecondary : Theme.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                if host.isProtocolCompatible, !host.capabilities.isEmpty {
                    VortXEngineCapabilityChips(capabilities: host.capabilities)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if host.isProtocolCompatible, host.address == nil {
                // Still resolving, or a probe that never landed. Both get a spinner plus a retry, because
                // the two are indistinguishable from here and the retry is harmless in either case.
                VStack(spacing: Theme.Space.xs) {
                    ProgressView().tint(Theme.Palette.accent)
                    Button { browser.reresolve(host) } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .fixedSize()
                }
            } else if usable, let address = host.address {
                Button { beginPairing(address: address, displayName: host.displayName) } label: {
                    Label("Use this Mac", systemImage: "link")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
        .opacity(host.isProtocolCompatible ? 1 : 0.6)
    }

    private func rowSubtitle(_ host: VortXDiscoveredHost) -> String {
        guard host.isProtocolCompatible else {
            return String(localized: "This Mac runs a different version of VortX. Update both to the same version to use it as an engine.")
        }
        guard host.address != nil else {
            return String(localized: "Finding its address…")
        }
        return String(localized: "Ready to pair")
    }

    // MARK: - Manual address

    /// The typed-address path. First class, not a fallback: see the note at the top of this file.
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Or enter the address")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Use this when the Mac is reachable but does not show up above: over Tailscale or another VPN, across VLANs, or on a router that blocks device discovery. The Mac's engine settings show the address to type.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("192.168.1.20:11471", text: $manualHost)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .padding(Theme.Space.sm)
                .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))

            Button {
                beginPairing(address: manualHost, displayName: manualHost.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Label("Pair with this address", systemImage: "link")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .disabled(!manualHostIsUsable)
            .opacity(manualHostIsUsable ? 1 : 0.4)

            Text("The port is 11471 unless the Mac was set to another one. Leaving the port off assumes 11471.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    /// Whether what is typed parses as an authority at all. Uses the SAME normalizer the pairing call and
    /// `mountPlan` use, so the button cannot enable for a string that would later be treated as "not
    /// configured".
    private var manualHostIsUsable: Bool {
        VortXEngineHostPolicy.normalizeHost(manualHost) != nil
    }

    // MARK: - Honesty

    /// The transport note. `VortXEngineProtocol` requires it in these words: the token and the per-session
    /// capability "are NOT transport security and the UI must not imply otherwise".
    private var honestyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("What crosses your network", systemImage: "lock.open")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Video travels from the Mac to this device as ordinary, unencrypted HTTP over your own network. Pairing is what stops other devices on the same Wi-Fi from fetching it: without the code, they get nothing. It is not encryption, so treat this as a feature for a network you trust.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    // MARK: - Pairing sheet

    /// Enter the six digits the Mac is showing.
    ///
    /// The code is DIGITS ONLY on the way in, because `VortXEngineProtocol.pairingCodeMatches` strips
    /// everything else anyway and a field that silently accepts letters would let someone type six
    /// characters and be told, correctly but uselessly, that the code was wrong.
    @ViewBuilder private func pairingSheet(_ target: PairingTarget) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Pair with \(target.displayName)")
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("On the Mac, open VortX settings, turn on \"Act as the engine for this network\", and choose \"Pair a device\". Type the six digits it shows.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("000000", text: Binding(
                    get: { code },
                    set: { code = Self.digitsOnly($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.numberPad)
                #endif
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                if let pairingError {
                    Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Space.md) {
                    Button { submitPairing(target) } label: {
                        HStack(spacing: Theme.Space.sm) {
                            if isPairing { ProgressView().tint(Theme.Palette.accent) }
                            Text(isPairing ? "Pairing…" : "Pair")
                        }
                    }
                    .buttonStyle(ChipButtonStyle(selected: true))
                    .disabled(isPairing || code.count != VortXEngineProtocol.pairingCodeDigits)

                    Button { cancelPairing() } label: { Text("Cancel") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .disabled(isPairing)
                }

                Text("The code lasts five minutes and stops working after five wrong tries. If it expires, choose \"Pair a device\" on the Mac again for a fresh one.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.Palette.canvas)
        #else
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #endif
    }

    /// Keep only decimal digits, capped at the protocol's code length. Written against
    /// `CharacterSet.decimalDigits` on unicode scalars rather than `isNumber`, so a full-width or Arabic-Indic
    /// digit from a system keyboard is handled the same way the host's own comparison handles it.
    private static func digitsOnly(_ raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
        return String(filtered.prefix(VortXEngineProtocol.pairingCodeDigits))
    }

    // MARK: - Actions

    private func beginPairing(address: String, displayName: String) {
        code = ""
        pairingError = nil
        isPairing = false
        justPaired = false
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        pairingTarget = PairingTarget(address: trimmed,
                                      displayName: displayName.isEmpty ? trimmed : displayName)
    }

    private func cancelPairing() {
        pairingTarget = nil
        code = ""
        pairingError = nil
    }

    /// Exchange the code for a token.
    ///
    /// `pair` commits the host, the host name and the capability list ONLY on success, so a wrong code
    /// leaves this device exactly as it was: still unpaired, still on-device, with nothing half-written into
    /// settings. That is why the failure branch here has nothing to undo.
    private func submitPairing(_ target: PairingTarget) {
        isPairing = true
        pairingError = nil
        let typed = code
        Task { @MainActor in
            let paired = await VortXExternalEngine.shared.pair(host: target.address, code: typed)
            isPairing = false
            guard paired != nil else {
                // One message for every failure, because the host deliberately answers the same way for a
                // wrong code, a closed window and an expired one (so a prober cannot tell them apart), and
                // an unreachable host is indistinguishable from here too. Inventing a more specific reason
                // would be inventing information we do not have.
                pairingError = String(localized: "That did not work. Check the six digits on the Mac, make sure its pairing screen is still open, and try again.")
                return
            }
            justPaired = true
            manualHost = ""
            pairingTarget = nil
            code = ""
            refreshFromEngine()
        }
    }

    /// Write the master switch through to the singleton, then re-read. Never enabled without a pairing: the
    /// toggle is disabled in that state, and this guard makes the invariant true in code as well as in
    /// layout, so a future change to the disabled condition cannot quietly create an enabled-but-unpaired
    /// device.
    private func setEnabled(_ value: Bool) {
        guard VortXExternalEngine.shared.isPaired || !value else { return }
        VortXExternalEngine.shared.isEnabled = value
        refreshFromEngine()
    }

    /// Forget the host. Local only, as `VortXExternalEngine.unpair` documents: it does not tell the Mac,
    /// because a device being unpaired may well be unable to reach it. `unpair` also clears `isEnabled`, so
    /// this device is back to on-device playback the moment it returns.
    private func unpair() {
        VortXExternalEngine.shared.unpair()
        justPaired = false
        refreshFromEngine()
    }

    private func refreshFromEngine() {
        let engine = VortXExternalEngine.shared
        isEnabled = engine.isEnabled
        isPaired = engine.isPaired
        pairedHostName = engine.hostName
        pairedHost = engine.host
        capabilities = engine.capabilities
    }
}

// MARK: - Capability chips

/// A host's advertised capabilities, as chips a person can read.
///
/// Shared by the client screen above and the Mac's own host settings, so the two surfaces cannot drift into
/// describing the same capability with different words. The labels are deliberately about the OUTCOME rather
/// than the mechanism ("Seek anywhere", not "full timeline retention"), since the mechanism is documented in
/// `VortXEngineProtocol` for engineers and is not what a person choosing a Mac needs to know.
struct VortXEngineCapabilityChips: View {
    let capabilities: [VortXEngineProtocol.Capability]

    var body: some View {
        // A wrapping flow layout would be nicer, but `Layout` conformances are one more thing to keep
        // working on four platforms; a horizontal scroller is what every other chip row in this app uses and
        // it stays focus-navigable on tvOS for free.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(capabilities, id: \.rawValue) { capability in
                    Text(Self.label(for: capability))
                        .font(Theme.Typography.eyebrow)
                        .tracking(1)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.Palette.surface2, in: Capsule(style: .continuous))
                }
            }
        }
    }

    static func label(for capability: VortXEngineProtocol.Capability) -> String {
        switch capability {
        case .remux:         return String(localized: "Dolby Vision remux")
        case .seekAnywhere:  return String(localized: "Seek anywhere")
        case .torrentServer: return String(localized: "Torrent server")
        case .transcode:     return String(localized: "Transcoding")
        case .trickplay:     return String(localized: "Scrub previews")
        }
    }
}
