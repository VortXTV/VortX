import SwiftUI

/// One add-on in the official community collection. Decodes only the fields the store shows; the manifest
/// carries far more (resources, catalogs, version), which Codable ignores. `id` is the transport URL so the
/// list is stable and the health store (keyed by transport URL) and the installed-set both line up.
struct StoreAddon: Decodable, Identifiable {
    let transportUrl: String
    let manifest: Manifest
    var id: String { transportUrl }

    struct Manifest: Decodable {
        let id: String?
        let name: String
        let description: String?
        let logo: String?
        let types: [String]?
    }

    var name: String { manifest.name }
    var summary: String { manifest.description ?? "" }
    var types: [String] { manifest.types ?? [] }
}

/// Loads the OFFICIAL Stremio community add-on collection (the same list the official clients show) so the
/// in-app store does not depend on scraping a third-party site. Fetched once, cached in memory, and fails
/// soft to an empty list (the store then just shows nothing rather than an error wall).
@MainActor
final class CommunityAddonStore: ObservableObject {
    static let shared = CommunityAddonStore()
    @Published private(set) var addons: [StoreAddon] = []
    @Published private(set) var loading = false
    @Published private(set) var loadFailed = false
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    private init() {}

    /// The official, public community collection endpoint (same host the app already uses for auth).
    private static let url = URL(string: "https://api.strem.io/addonscollection.json")!

    func load(force: Bool = false) {
        guard force || (!loaded && !loading) else { return }
        loadTask?.cancel()   // a forced reload supersedes any in-flight fetch (no two racing writers)
        loading = true
        loadFailed = false
        loadTask = Task {
            let fetched = await Self.fetch()
            if Task.isCancelled { return }
            loading = false
            if fetched.isEmpty { loadFailed = true } else { addons = fetched; loaded = true }
        }
    }

    nonisolated private static func fetch() async -> [StoreAddon] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        // Some CDNs in front of the collection reject non-browser User-Agents (same lesson as the health probe).
        req.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let list = try? JSONDecoder().decode([StoreAddon].self, from: data) else { return [] }
        // Drop entries with no usable manifest URL.
        return list.filter { URL(string: $0.transportUrl) != nil }
    }
}

/// Discover add-ons: a browsable, searchable store over the official community collection, each entry
/// carrying a LIVE health badge (cross-referenced through the same `AddonHealthStore` the installed list
/// uses) and a one-tap Install that goes through the engine, so the new add-on syncs to the account and the
/// official apps exactly like a pasted manifest URL. Already-installed add-ons show as Installed.
struct AddonStoreView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @ObservedObject private var catalog = CommunityAddonStore.shared
    @ObservedObject private var health = AddonHealthStore.shared
    @State private var query = ""
    @State private var installing: Set<String> = []

    private var installed: Set<String> { Set(core.addons.map(\.transportUrl)) }

    /// Normalize a manifest URL exactly as `CoreBridge.installAddon` does before storing it (trim, then
    /// append `/manifest.json` if missing), so an already-installed add-on is recognized as Installed even
    /// when the collection lists an un-suffixed transport URL.
    private func normalizedManifestURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed) else { return trimmed }
        if !url.absoluteString.lowercased().hasSuffix("manifest.json") {
            url = url.appendingPathComponent("manifest.json")
        }
        return url.absoluteString
    }

    private var filtered: [StoreAddon] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog.addons }
        return catalog.addons.filter {
            $0.name.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || $0.types.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Discover add-ons").screenTitleStyle()
                hint("Browse the community add-on collection and install with one tap. Each shows whether it is reachable right now. Installed add-ons sync to your account and the official apps.")
                searchField
                if catalog.loading && catalog.addons.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, Theme.Space.xl)
                } else if catalog.loadFailed && catalog.addons.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        hint("Couldn't load the add-on catalog. Check your connection and try again.")
                        Button("Try again") { catalog.load(force: true) }
                            .buttonStyle(ChipButtonStyle(selected: false))
                            .fixedSize()
                    }
                } else if !catalog.addons.isEmpty && filtered.isEmpty {
                    hint("No add-ons match \"\(query)\".")
                }
                ForEach(filtered) { storeRow($0) }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task { catalog.load() }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search add-ons", text: $query)
                .disableAutocorrection(true)
                .frame(maxWidth: 560)
        }
        .padding(Theme.Space.md)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func storeRow(_ addon: StoreAddon) -> some View {
        let isInstalled = installed.contains(normalizedManifestURL(addon.transportUrl))
        let isInstalling = installing.contains(addon.transportUrl)
        let h = health.status[addon.transportUrl] ?? .unknown
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            AsyncImage(url: addon.manifest.logo.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 28)).foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                // Pin the name to its intrinsic one-line width so it can never be compressed to a ~1pt
                // vertical sliver (the "T / O / R / R / E / N / T / I / O" squeeze) when the chips row
                // and trailing button demand the row width on a narrow iPhone.
                Text(addon.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                if !addon.summary.isEmpty {
                    Text(addon.summary)
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
                if !addon.types.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(addon.types.prefix(4), id: \.self) { type in
                            Text(type.capitalized)
                                .font(Theme.Typography.label)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.Palette.surface2, in: Capsule())
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize()   // each chip keeps its intrinsic size, never pressuring the name
                        }
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(h.color).frame(width: 8, height: 8)
                    Text(h.label).font(Theme.Typography.label).foregroundStyle(h.color)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            installControl(addon, isInstalled: isInstalled, isInstalling: isInstalling)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // Lazy per-row probe: only visible rows hit the network, so a 200-entry catalog never bursts.
        .task { health.probeOne(addon.transportUrl) }
    }

    @ViewBuilder
    private func installControl(_ addon: StoreAddon, isInstalled: Bool, isInstalling: Bool) -> some View {
        if isInstalled {
            #if os(tvOS)
            // tvOS scrolls a ScrollView via the FOCUS ENGINE: the list only scrolls when focus can step to
            // a focusable row below the fold. The default add-ons that head the collection are all
            // "Installed", and a plain Label is NOT focusable, so the early rows offered no focus target
            // and the whole store was stuck at the top (the reported "can't scroll" bug). A no-op Button
            // styled as the installed state gives each installed row a focusable control (with visible focus
            // feedback) so focus travels through every row and pulls the scroll. Never `.disabled` (that
            // would make it unfocusable again). iOS/Mac scroll by touch/trackpad and keep the plain label.
            Button { } label: {
                Label("Installed", systemImage: "checkmark").font(Theme.Typography.label)
            }
            .buttonStyle(ChipButtonStyle(selected: true))
            .fixedSize()
            #else
            Label("Installed", systemImage: "checkmark")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.ok)
                .fixedSize()
            #endif
        } else {
            Button(isInstalling ? "Installing…" : "Install") { installStore(addon) }
                .buttonStyle(PrimaryActionStyle())
                .disabled(isInstalling)
                .fixedSize()
        }
    }

    private func installStore(_ addon: StoreAddon) {
        guard !installing.contains(addon.transportUrl) else { return }
        installing.insert(addon.transportUrl)
        Task { @MainActor in
            _ = await core.installAddon(urlString: addon.transportUrl)
            installing.remove(addon.transportUrl)
            // core.addons republishes from the engine after install, flipping this row to Installed.
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
