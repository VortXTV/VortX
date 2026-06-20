import SwiftUI

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

    nonisolated private static func check(_ transportUrl: String) async -> AddonHealth {
        guard let url = URL(string: transportUrl) else { return .down }
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
}

/// Add-ons installed on your account, read live from the engine. Install one by its manifest URL,
/// or remove a non-default add-on here. Changes sync to your account and to the official apps.
struct AddonsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var health = AddonHealthStore.shared
    @State private var newAddonURL = ""
    @State private var installing = false
    @State private var installMessage: String?
    @State private var installFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Add-ons").screenTitleStyle()
                    if !account.isSignedIn {
                        hint("Sign in to manage your add-ons. They sync across your devices and the official apps.")
                    } else {
                        installSection
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
                                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            hint("Tap the eye to turn an add-on off for \(profiles.active?.name ?? "this profile") only. It stays installed on your account and stays on for your other profiles.")
                            HStack {
                                Spacer()
                                Button { health.probe(core.addons.map(\.transportUrl), force: true) } label: {
                                    Label("Re-check status", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .fixedSize()
                            }
                            ForEach(core.addons) { addon in addonRow(addon) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .task(id: core.addons.count) { health.probe(core.addons.map(\.transportUrl)) }
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
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func install() {
        installing = true
        installMessage = nil
        let url = newAddonURL
        Task { @MainActor in
            let error = await core.installAddon(urlString: url)
            installing = false
            installFailed = error != nil
            if let error {
                installMessage = error
            } else {
                installMessage = "Installed."
                newAddonURL = ""
            }
        }
    }

    private func addonRow(_ addon: CoreDescriptor) -> some View {
        let isOff = profiles.isAddonDisabledForActive(base: addon.transportUrl)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: addon.providesStreams ? "play.rectangle.on.rectangle.fill" : "puzzlepiece.extension.fill")
                .font(.system(size: 36))
                .foregroundStyle(isOff ? Theme.Palette.textTertiary
                                       : (addon.providesStreams ? Theme.Palette.accent : Theme.Palette.textTertiary))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(addon.manifest.name).font(Theme.Typography.cardTitle)
                    .foregroundStyle(isOff ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                Text(isOff ? "Off for this profile" : addon.capabilities)
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Text(addon.host).font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                let h = health.status[addon.transportUrl] ?? .unknown
                HStack(spacing: 6) {
                    Circle().fill(h.color).frame(width: 8, height: 8)
                    Text(h.label).font(Theme.Typography.label).foregroundStyle(h.color)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if !addon.isProtected {
                // Per-profile on/off (local overlay). Distinct from Remove, which uninstalls account-wide.
                Button { profiles.toggleAddon(base: addon.transportUrl) } label: {
                    Image(systemName: isOff ? "eye.slash" : "eye")
                }
                .buttonStyle(ChipButtonStyle(selected: !isOff))
                .fixedSize()
                Button { core.uninstallAddon(addon) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    .fixedSize()   // keep the Remove chip at its intrinsic width so a narrow phone row can't squeeze the label to one glyph per line
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.top, Theme.Space.sm)
    }
}
