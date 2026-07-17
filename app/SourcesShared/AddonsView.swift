import SwiftUI
import CoreImage   // CIQRCodeGenerator for the Apple TV "Configure" QR

/// Reachability of one installed add-on, from a lightweight manifest probe.
enum AddonHealth: Equatable {
    case unknown          // not checked yet
    case checking         // probe in flight
    case ok(ms: Int)      // reachable, fast
    case slow(ms: Int)    // reachable, sluggish
    case down             // unreachable, errored, or non-2xx/3xx

    var label: String {
        switch self {
        case .unknown:      return "Not checked"
        case .checking:     return "Checking…"
        case .ok(let ms):   return "Online \(ms) ms"
        case .slow(let ms): return "Slow \(ms) ms"
        case .down:         return "Unreachable"
        }
    }
    var color: Color {
        switch self {
        case .unknown, .checking: return Theme.Palette.textTertiary
        case .ok:                 return Theme.Palette.ok
        case .slow:               return Theme.Palette.warn
        case .down:               return Theme.Palette.danger
        }
    }
}

/// Probes installed add-ons' manifest URLs so the Add-ons screen can show which sources are actually
/// up. Plain HTTP with a short timeout, run on demand (the screen appears, or the Re-check button):
/// the engine never exposes this. An add-on that returns its manifest quickly is Online, a slow one is
/// Slow, a failed / timed-out / non-2xx-3xx one is Unreachable. Keyed by transport URL.
@MainActor
final class AddonHealthStore: ObservableObject {
    static let shared = AddonHealthStore()
    @Published private(set) var status: [String: AddonHealth] = [:]
    private var lastProbe: Date?
    private init() {}

    private static let okThresholdMs = 1500
    private static let timeout: TimeInterval = 6
    private static let rateLimit: TimeInterval = 20

    /// Probe every add-on concurrently. Debounced to once per `rateLimit` seconds unless `force`.
    func probe(_ transportUrls: [String], force: Bool = false) {
        guard !transportUrls.isEmpty else { return }
        if !force, let last = lastProbe, Date().timeIntervalSince(last) < Self.rateLimit { return }
        lastProbe = Date()
        for url in transportUrls where status[url] == nil || status[url] == .unknown {
            status[url] = .checking
        }
        Task { [weak self] in
            await withTaskGroup(of: (String, AddonHealth).self) { group in
                for url in transportUrls { group.addTask { (url, await Self.check(url)) } }
                for await (url, health) in group { self?.status[url] = health }
            }
        }
    }

    /// Probe a SINGLE add-on on demand, skipping the global rate-limit debounce but keeping the per-URL
    /// dedup. The Discover store calls this per row as rows appear, so a long catalog probes lazily as the
    /// viewer scrolls (bounded by visible rows) instead of firing a 200-wide burst from `probe`.
    func probeOne(_ transportUrl: String) {
        guard status[transportUrl] == nil || status[transportUrl] == .unknown else { return }
        status[transportUrl] = .checking
        Task { let health = await Self.check(transportUrl); status[transportUrl] = health }
    }

    nonisolated private static func check(_ transportUrl: String) async -> AddonHealth {
        guard let url = URL(string: transportUrl) else { return .down }
        // SSRF guard, same policy as installAddon/previewAddonManifest (AddonURLGuard). A transportUrl can
        // arrive from a synced account doc or the web dashboard, not just a user paste, so never let this
        // auto-firing reachability probe hit an arbitrary private / LAN / link-local / metadata target and
        // turn the app into a network scanner. The ONE legitimate private target is the app's own loopback
        // streaming server (the default 127.0.0.1 local add-on); a discard-response GET to loopback has no
        // attacker feedback channel, so it is exempt while everything else private is refused.
        if !isLoopbackHost(url.host), await AddonURLGuard.validate(url) != nil { return .down }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // Some add-on CDNs reject non-browser User-Agents (same lesson as AddonClient + the libmpv fetches).
        req.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return .down }
            return ms <= okThresholdMs ? .ok(ms: ms) : .slow(ms: ms)
        } catch {
            return .down
        }
    }

    /// True when `host` is on-device loopback (localhost / 127.0.0.0/8 / ::1). Exempt from the probe's SSRF
    /// guard so the default 127.0.0.1 local-add-on still reports its real status (see check(_:)).
    nonisolated private static func isLoopbackHost(_ host: String?) -> Bool {
        guard var h = host, !h.isEmpty else { return false }
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }  // unbracket IPv6 literals
        let lower = h.lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }
}

/// Add-ons installed on your account, read live from the engine. Install one by its manifest URL,
/// or remove a non-default add-on here. Changes sync to your account and to the official apps.
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks add-on management even with no Stremio account connected
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var health = AddonHealthStore.shared
    @State private var newAddonURL = ""
    @State private var installing = false
    @State private var installMessage: String?
    @State private var installFailed = false
    @State private var addonSheet: AddonSheet?   // the per-add-on Configure / Change-URL sheet
    @State private var showUpdateConfirm = false   // "already installed -> update?" prompt
    @State private var showPairing = false         // the Install-by-QR "pair once, add many" sheet
    // Observed + READ in body (see `let _ = orderObserver.revision`) so the list re-sorts LIVE after a
    // reorder. appliedAddonOrder is a plain UserDefaults static, not @Published, so this is SwiftUI's only
    // signal to re-run orderedByApplied; without it the new order showed only on the next cold launch.
    @ObservedObject private var orderObserver = AddonOrderObserver.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    // Read the shared order revision so a reorder (in-app drag or remote pull) re-runs body and
                    // re-sorts the ForEach below via orderedByApplied. Must be READ in body to be tracked.
                    let _ = orderObserver.revision
                    Text("Add-ons").screenTitleStyle()
                    if !(account.isSignedIn || vortxSync.isSignedIn) {
                        hint("Sign in to manage your add-ons. They sync across your devices and the official apps.")
                    } else {
                        installSection
                        discoverLink
                        if core.addons.isEmpty {
                            hint("No add-ons yet. Paste an add-on's manifest URL above to install one.")
                        } else {
                            NavigationLink { CatalogManagerView() } label: {
                                HStack(spacing: Theme.Space.md) {
                                    Label("Customize catalogs", systemImage: "slider.horizontal.3")
                                        .font(Theme.Typography.cardTitle)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                                }
                                .padding(Theme.Space.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // glass-Browse: this nav row is bespoke chrome, not routed through a shared
                                // row style, so it flips straight to the settings-card glass preset in place
                                // of the flat surface1 fill (same throughout this file: install/discover/
                                // reorder rows, the add-on card).
                                .vortxSettingsCard()
                            }
                            // tvOS: `.plain` left the system focus platter on over this settings-card row. See ChipButtonStyle.
                            .vortxCardButton()
                            // Drag add-ons into the order you want. The order is the PRIORITY spine (which
                            // add-on's catalogs and sources come first) and syncs to the dashboard + your
                            // other devices via doc.addonOrder, the same order the dashboard drag writes.
                            // iOS / Mac only: the drag-reorder List needs the touch/pointer drag tvOS lacks
                            // (tvOS reorder is a separate focus-based UX); the dashboard covers tvOS ordering.
                            #if !os(tvOS)
                            if core.addons.count > 1 {
                                NavigationLink { AddonReorderView() } label: {
                                    HStack(spacing: Theme.Space.md) {
                                        Label("Reorder add-ons", systemImage: "arrow.up.arrow.down")
                                            .font(Theme.Typography.cardTitle)
                                            .foregroundStyle(Theme.Palette.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                                    }
                                    .padding(Theme.Space.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .vortxSettingsCard()
                                }
                                .buttonStyle(.plain)
                            }
                            #endif
                            hint("Tap the eye to turn an add-on off for \(profiles.active?.name ?? "this profile") only. It stays installed on your account and stays on for your other profiles.")
                            HStack {
                                // tvOS: keep the button LEFT-aligned so it sits directly above the first
                                // add-on row (also left-aligned) and a Down press lands on that row. Right-
                                // aligned behind a Spacer, it sat off the rows' downward focus beam, so focus
                                // stalled at "Re-check status" and never entered the list (owner-reported).
                                // NOT wrapping rows in per-row .focusSection() on purpose: stacked sibling
                                // focus sections make tvOS skip rows (the Collections-hub region-jump lesson);
                                // plain VStack rows step geometrically once entry is on-axis.
                                #if !os(tvOS)
                                Spacer()
                                #endif
                                Button { health.probe(core.addons.map(\.transportUrl), force: true) } label: {
                                    Label("Re-check status", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .fixedSize()
                                #if os(tvOS)
                                Spacer()
                                #endif
                            }
                            ForEach(VortXSyncManager.orderedByApplied(core.addons, url: { $0.transportUrl })) { addon in addonRow(addon) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .task(id: core.addons.count) { health.probe(core.addons.map(\.transportUrl)) }
            .sheet(item: $addonSheet) { sheet in
                switch sheet {
                case .configure(let a): ConfigureAddonView(addon: a)
                case .editURL(let a): EditAddonURLView(addon: a)
                }
            }
            .sheet(isPresented: $showPairing) { AddonPairingView() }
            .confirmationDialog("Add-on already installed", isPresented: $showUpdateConfirm, titleVisibility: .visible) {
                Button("Update") { runInstall(replacingExisting: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This add-on is already installed. Update it to its latest manifest?")
            }
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Add an add-on")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.md) {
                TextField("https://…/manifest.json", text: $newAddonURL)
                    .font(.system(size: 16, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(maxWidth: 560)
                Button(installing ? "Installing…" : "Install") { install() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(installing || newAddonURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let installMessage {
                Text(installMessage)
                    .font(Theme.Typography.label)
                    .foregroundStyle(installFailed ? Theme.Palette.danger : Theme.Palette.textSecondary)
            }
            // Install by QR: pair a phone once, then paste as many add-on URLs there as you like and
            // install each here. Handy on Apple TV (no keyboard) but offered on every platform.
            Button { showPairing = true } label: {
                Label("Install by QR", systemImage: "qrcode")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .fixedSize()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    private var discoverLink: some View {
        NavigationLink { AddonStoreView() } label: {
            HStack(spacing: Theme.Space.md) {
                Label("Discover add-ons", systemImage: "sparkles.rectangle.stack")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vortxSettingsCard()
        }
        // tvOS: `.plain` left the system focus platter on over this settings-card row. See ChipButtonStyle.
        .vortxCardButton()
    }

    private func install() {
        // Already installed? Offer to UPDATE (re-fetch the manifest) instead of erroring (owner request).
        if let normalized = core.normalizedAddonURL(newAddonURL),
           core.addons.contains(where: { $0.transportUrl == normalized }) {
            showUpdateConfirm = true
            return
        }
        runInstall(replacingExisting: false)
    }

    private func runInstall(replacingExisting: Bool) {
        installing = true
        installMessage = nil
        let url = newAddonURL
        Task { @MainActor in
            let error = await core.installAddon(urlString: url, replacingExisting: replacingExisting)
            installing = false
            installFailed = error != nil
            if let error {
                installMessage = error
            } else {
                installMessage = replacingExisting ? String(localized: "Updated.") : String(localized: "Installed.")
                newAddonURL = ""
            }
        }
    }

    /// The add-on's icon: its `manifest.logo` (so an AIOManager-set custom logo renders), falling back to
    /// the capability SF Symbol when there is no logo or it fails to load.
    @ViewBuilder private func addonIcon(_ addon: CoreDescriptor, isOff: Bool) -> some View {
        let symbol = addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill"
        let tint = isOff ? Theme.Palette.textTertiary
                         : (addon.providesStreams ? Theme.Palette.accent : Theme.Palette.textTertiary)
        AddonLogoIcon(logo: addon.manifest.logo, symbol: symbol, tint: tint, isOff: isOff)
    }

    /// Add-on logo, DOWNSAMPLED via PosterImageLoader (maxPixel 168 = the 56pt @3x on-screen size) instead of
    /// AsyncImage, which decoded each logo at FULL resolution. With a whole account's worth of add-ons rendered
    /// at once (a synced account can carry 25+), that burst of full-res bitmaps ballooned resident memory into
    /// the hundreds of MB / ~1 GB and made the Add-ons screen lag badly (owner-reported "unusable" on Mac).
    /// Falls back to the capability SF Symbol when there is no logo or it fails to load. Mirrors PosterCardiOS's
    /// warm-cache + `.task(id:)` pattern so a revisit never flashes blank.
    private struct AddonLogoIcon: View {
        let logo: String?
        let symbol: String
        let tint: Color
        let isOff: Bool
        @State private var image: VXPosterImage?

        private var warmCache: VXPosterImage? {
            guard let logo, let u = URL(string: logo) else { return nil }
            return PosterImageLoader.cached(u)
        }

        var body: some View {
            Group {
                if let img = image ?? warmCache {
                    imageView(img).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card / 2, style: .continuous))
                        .opacity(isOff ? 0.5 : 1)
                } else {
                    Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(tint)
                }
            }
            .frame(width: 56, height: 56)
            .task(id: logo) {
                guard image == nil, let logo, !logo.isEmpty else { return }
                // 168px = 56pt @3x: only the on-screen size ever sits in memory, never a 1000px+ full-res logo.
                if let img = await PosterImageLoader.load(logo, maxPixel: 168) { image = img }
            }
        }

        private func imageView(_ img: VXPosterImage) -> Image {
            #if canImport(UIKit)
            Image(uiImage: img)
            #else
            Image(nsImage: img)
            #endif
        }
    }

    private func addonRow(_ addon: CoreDescriptor) -> some View {
        let isOff = profiles.isAddonDisabledForActive(base: addon.transportUrl)
        // Layout regression fix: previously icon + text + up-to-4 action chips all shared ONE HStack, so on a
        // narrow phone the fixed-width chips squeezed the text column toward zero width, forcing the name /
        // detail to wrap one glyph per line and clipping at the edges. Split into a top INFO row (icon + text
        // that always claims the full width) and a separate action row below that flows horizontally.
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                addonIcon(addon, isOff: isOff)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(addon.manifest.name).font(Theme.Typography.cardTitle)
                        .foregroundStyle(isOff ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)   // wrap by word, never by glyph
                    Text(isOff ? "Off for this profile" : addon.capabilities)
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(addon.host).font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    let h = health.status[addon.transportUrl] ?? .unknown
                    HStack(spacing: 6) {
                        Circle().fill(h.color).frame(width: 8, height: 8)
                        Text(h.label).font(Theme.Typography.label).foregroundStyle(h.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)   // the text column owns the row width
            }
            addonActions(addon, isOff: isOff)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vortxSettingsCard()
    }

    /// The add-on's action chips, in their own row beneath the info so they never steal width from the name /
    /// detail column. On iPhone the four chips of a configurable add-on (Configure + link + eye + Remove)
    /// overflowed a single horizontal-scroll row and CLIPPED Remove off the right edge (owner-reported "the
    /// add-on page is cut off from the side" - the clipped chip was the one you most need). So on iOS / Mac
    /// they now WRAP (FlowLayout): a narrow phone drops Remove to a second line instead of hiding it, while
    /// iPad / Mac keep them on one line. tvOS is wide and focus-driven, so it keeps the scroll row unchanged.
    @ViewBuilder private func addonActions(_ addon: CoreDescriptor, isOff: Bool) -> some View {
        #if os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { addonActionChips(addon, isOff: isOff) }
        }
        #else
        FlowLayout(spacing: Theme.Space.sm) { addonActionChips(addon, isOff: isOff) }
        #endif
    }

    @ViewBuilder private func addonActionChips(_ addon: CoreDescriptor, isOff: Bool) -> some View {
        // Configurable add-ons (Torrentio, debrid configs, …) expose a web settings page. Available
        // regardless of protected state; protected defaults are not configurable anyway.
        if addon.isConfigurable {
            Button { addonSheet = .configure(addon) } label: { Label("Configure", systemImage: "slider.horizontal.3") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
        }
        if !addon.isProtected {
            // Change the add-on's manifest URL in place (e.g. after reconfiguring it): installs the new
            // URL first, then removes the old, so a bad URL never leaves you with neither.
            Button { addonSheet = .editURL(addon) } label: { Image(systemName: "link") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
            // Per-profile on/off (local overlay). Distinct from Remove, which uninstalls account-wide.
            Button { profiles.toggleAddon(base: addon.transportUrl) } label: {
                Image(systemName: isOff ? "eye.slash" : "eye")
            }
            .buttonStyle(ChipButtonStyle(selected: !isOff))
            .fixedSize()
            Button { core.uninstallAddon(addon) } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                .fixedSize()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.top, Theme.Space.sm)
    }
}

#if !os(tvOS)
/// Drag the installed add-ons into your preferred PRIORITY order (which add-on's catalogs and sources come
/// first). Each drop writes `VortXSyncManager.appliedAddonOrder` and pushes it immediately, so the order
/// syncs to the dashboard and your other devices via doc.addonOrder - the same order the dashboard drag
/// writes. iOS forces edit mode on; macOS reorders by native row drag. iOS / Mac only (tvOS lacks the drag).
struct AddonReorderView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @ObservedObject private var orderObserver = AddonOrderObserver.shared   // re-seed on a remote reorder
    @State private var ordered: [CoreDescriptor] = []

    var body: some View {
        List {
            ForEach(ordered) { addon in
                HStack(spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(addon.manifest.name)
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(addon.host)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear.vortxGlassListRow(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)))
                .listRowSeparator(.hidden)
            }
            .onMove(perform: move)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Reorder Add-ons")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
        .macBackAffordance()
        .onAppear { reload() }
        .onChange(of: core.addons.count) { _ in reload() }        // an install/remove elsewhere re-seeds the list
        .onChange(of: orderObserver.revision) { _ in reload() }   // a remote reorder (or our own) re-seeds; idempotent for a local drag
    }

    /// Re-seed from the live add-on set in the currently-applied order. Preserves the user's order and folds
    /// in any add-on installed since (appended at the end by orderedByApplied).
    private func reload() {
        ordered = VortXSyncManager.orderedByApplied(core.addons, url: { $0.transportUrl })
    }

    private func move(from source: IndexSet, to destination: Int) {
        ordered.move(fromOffsets: source, toOffset: destination)
        VortXSyncManager.shared.applyInAppAddonOrder(ordered.map { $0.transportUrl })
    }
}
#endif

/// Configure a configurable add-on. On iPhone, iPad, and Mac it opens the add-on's web configuration
/// page in the browser; on Apple TV (which has no browser) it shows that page as a QR to finish on a
/// phone, or points to the web dashboard. After configuring, the add-on hands back a NEW manifest URL,
/// which the user pastes into Add an add-on to install their configured copy (the Stremio configure flow).
private struct ConfigureAddonView: View {
    let addon: CoreDescriptor
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: Theme.Space.xs) {
                Text("Configure").font(.title2).fontWeight(.bold)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(addon.manifest.name).font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if let url = addon.configureURL {
                #if os(tvOS)
                if let qr = Self.qrImage(url.absoluteString) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none).resizable()
                        .frame(width: 300, height: 300)
                        .padding(Theme.Space.md)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                Text("Scan with your phone to open this add-on's settings, then paste the configured add-on link back into Add an add-on. You can also configure it on the web dashboard at vortx.tv.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 640)
                #else
                Button { openURL(url) } label: {
                    Label("Open configuration page", systemImage: "safari")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(PrimaryActionStyle())
                Text("Configure the add-on in your browser, then copy the configured add-on link it gives you and paste it into Add an add-on to install your version.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                #endif
            }
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .tint(Theme.Palette.textPrimary)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(Theme.Space.xl)
        #if os(macOS)
        .frame(width: 460)
        .background(Theme.Palette.canvas)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #endif
    }

    #if os(tvOS)
    private static func qrImage(_ string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    #endif
}

/// Which per-add-on sheet is open (Configure or Change-URL). One sheet binding avoids SwiftUI's
/// multiple-`.sheet` conflict.
private enum AddonSheet: Identifiable {
    case configure(CoreDescriptor)
    case editURL(CoreDescriptor)
    var id: String {
        switch self {
        case .configure(let a): return "cfg-" + a.transportUrl
        case .editURL(let a): return "url-" + a.transportUrl
        }
    }
}

/// Change an installed add-on's manifest URL in place, e.g. after reconfiguring it (a configurable add-on
/// hands back a NEW URL with your options baked in). Installs the new URL FIRST, then removes the old, so
/// a failed install never leaves you with neither add-on.
private struct EditAddonURLView: View {
    let addon: CoreDescriptor
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var working = false
    @State private var message: String?

    init(addon: CoreDescriptor) {
        self.addon = addon
        _url = State(initialValue: addon.transportUrl)
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            VStack(spacing: Theme.Space.xs) {
                Text("Change add-on URL").font(.title2).fontWeight(.bold)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(addon.manifest.name).font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text("Replace this add-on's manifest URL, for example after reconfiguring it. The new URL is installed first, then the old one removed.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            TextField("https://…/manifest.json", text: $url)
                .font(.system(size: 16, design: .monospaced))
                .disableAutocorrection(true)
                .frame(maxWidth: 560)
            if let message {
                Text(message).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Theme.Space.md) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(Theme.Palette.textPrimary)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Button(working ? "Updating…" : "Update") { update() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working || url.trimmingCharacters(in: .whitespaces).isEmpty || url == addon.transportUrl)
            }
        }
        .padding(Theme.Space.xl)
        #if os(macOS)
        .frame(width: 520)
        .background(Theme.Palette.canvas)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #endif
    }

    private func update() {
        working = true
        message = nil
        let newURL = url.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if let error = await CoreBridge.shared.installAddon(urlString: newURL) {
                message = error; working = false; return
            }
            // Change-URL is a REPLACE, not a removal: drop the old URL but do NOT tombstone it, so the
            // same URL stays re-addable on every device (a removal tombstone would wrongly suppress it).
            CoreBridge.shared.uninstallAddon(addon, tombstone: false)
            working = false
            dismiss()
        }
    }
}
