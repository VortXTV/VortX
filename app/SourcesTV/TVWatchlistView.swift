import SwiftUI

// A refresh owns both the viewer epoch and its request. A -> B -> A must retire the first A's
// response even when the final account/profile ids happen to match again.
struct TVWatchlistPresentationFence<Owner: Equatable> {
    let owner: Owner
    let profileID: UUID?
    let generation: UUID

    func allows(owner: Owner, profileID: UUID?, generation: UUID, nativeReady: Bool) -> Bool {
        self.owner == owner && self.profileID == profileID && self.generation == generation && nativeReady
    }
}

/// The same app watch-later ledger as the TV detail chip. Saved Library titles and Continue Watching
/// are independent collections; neither supplies rows or a successful empty result to this destination.
struct TVWatchlistView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @State private var entries: [LibraryAutoAdd.WatchlistEntry] = []
    @State private var displayedFence: TVWatchlistPresentationFence<CredentialScopeRegistry.Capture>?
    @State private var generation = UUID()
    @State private var reloadTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var isVisible = false
    @State private var selectedDetail: DetailTarget?
    @State private var detailOwner: CredentialScopeRegistry.Capture?
    @State private var detailProfileID: UUID?
    @State private var displayedNativeTarget: CoreBridge.NativeNavigationTarget?
    @State private var detailNativeTarget: CoreBridge.NativeNavigationTarget?

    private struct DetailTarget: Hashable {
        let id: String
        let type: String
    }

    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(kLandscapeCardWidth), spacing: Theme.Space.lg), count: 3)
            : Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)
    }

    private var nativeReady: Bool {
        guard let displayedNativeTarget else { return false }
        return core.nativeNavigationTargetIsCurrent(displayedNativeTarget)
    }

    private var canDisplay: Bool {
        displayedFence?.allows(owner: CredentialScopeRegistry.shared.capture(), profileID: profiles.activeID,
                               generation: generation, nativeReady: nativeReady) == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Watchlist").screenTitleStyle()
                Button { dismiss() } label: {
                    Label("Back to Library", systemImage: "chevron.left")
                }
                .buttonStyle(ChipButtonStyle(selected: false))

                if canDisplay {
                    if entries.isEmpty {
                        Text("Titles you save to Watchlist from their details appear here.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.top, Theme.Space.lg)
                    } else {
                        LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                            // The host ledger keys membership by type/id, including titles sharing an id.
                            ForEach(entries, id: \.tvWatchlistIdentity) { entry in
                                watchlistCard(entry)
                            }
                        }
                        .padding(.top, Theme.Space.sm)
                    }
                } else {
                    HStack(spacing: Theme.Space.md) {
                        if isLoading { ProgressView().tint(Theme.Palette.accent) }
                        Text(isLoading ? "Loading Watchlist…" : "Watchlist isn't ready yet. Please try again.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Button("Retry") { reload() }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .disabled(isLoading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationDestination(item: $selectedDetail) { detail in
            DetailView(type: detail.type, id: detail.id)
        }
        .onAppear { isVisible = true; reload() }
        .onDisappear { isVisible = false; cancelReload() }
        .onChange(of: profiles.activeID) { _ in boundaryChanged() }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            boundaryChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
            retireNavigationIfNeeded()
            if isVisible { reload() }
        }
        .onChange(of: core.revision) { _ in
            retireNavigationIfNeeded()
            // A mount or same-profile account rebind can retire admission without changing activeID.
            if isVisible && !canDisplay && reloadTask == nil { reload() }
        }
    }

    private func cancelReload() {
        reloadTask?.cancel()
        reloadTask = nil
        generation = UUID()
    }

    private func boundaryChanged() {
        selectedDetail = nil
        displayedFence = nil
        entries = []
        cancelReload()
        if isVisible { reload() }
    }

    private func reload() {
        cancelReload()
        isLoading = true
        let fence = TVWatchlistPresentationFence(owner: CredentialScopeRegistry.shared.capture(),
                                                profileID: profiles.activeID, generation: generation)
        // Capture the viewer before scheduling preparation. Cached profiles do not admit a native read.
        let admission = core.captureNativeWatchlistActionAdmission()
        reloadTask = Task { @MainActor in
            defer {
                if generation == fence.generation { reloadTask = nil; isLoading = false }
            }
            guard let prepared = await core.prepareNativeWatchlistActionTarget(admission),
                  core.nativeWatchlistTargetIsCurrent(prepared),
                  let navigation = core.captureNativeNavigationTarget(),
                  core.nativeNavigationTargetIsCurrent(navigation) else { return }
            let loaded: [LibraryAutoAdd.WatchlistEntry]
            do {
                loaded = try core.nativeWatchlist().map {
                    .init(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, addedAt: $0.addedAt)
                }
            } catch { return }
            guard core.nativeWatchlistTargetIsCurrent(prepared),
                  core.nativeNavigationTargetIsCurrent(navigation) else { return }
            guard !Task.isCancelled, isVisible,
                  fence.allows(owner: CredentialScopeRegistry.shared.capture(), profileID: profiles.activeID,
                               generation: generation, nativeReady: true) else { return }
            displayedNativeTarget = navigation
            entries = loaded
            displayedFence = fence
        }
    }

    private func watchlistCard(_ entry: LibraryAutoAdd.WatchlistEntry) -> some View {
        // Capture the rendered row's receipt. A queued gesture on profile A's card must not be
        // upgraded to profile B's current receipt, even if both profiles saved the same title.
        let fence = displayedFence
        let navigation = displayedNativeTarget
        return PosterCard(title: entry.name ?? entry.id, poster: entry.poster,
                          type: entry.type, id: entry.id, width: kPosterWidth,
                          landscapeWidth: kLandscapeCardWidth, menu: .none,
                          onDetails: {
            guard let navigation, core.nativeNavigationTargetIsCurrent(navigation) else { return }
            detailNativeTarget = navigation
            openDetails(entry, fence: fence)
        })
    }

    private func openDetails(_ entry: LibraryAutoAdd.WatchlistEntry,
                             fence: TVWatchlistPresentationFence<CredentialScopeRegistry.Capture>?) {
        guard let fence, canDisplay,
              fence.allows(owner: CredentialScopeRegistry.shared.capture(), profileID: profiles.activeID,
                           generation: generation, nativeReady: nativeReady),
              entries.contains(where: { $0.tvWatchlistIdentity == entry.tvWatchlistIdentity }) else { return }
        detailOwner = fence.owner
        detailProfileID = fence.profileID
        selectedDetail = .init(id: entry.id, type: entry.type)
    }

    private func retireNavigationIfNeeded() {
        guard selectedDetail != nil else { return }
        guard let detailOwner, CredentialScopeRegistry.shared.isCurrent(detailOwner),
              detailProfileID == profiles.activeID else { selectedDetail = nil; return }
        guard let detailNativeTarget, core.nativeNavigationTargetIsCurrent(detailNativeTarget) else {
            selectedDetail = nil; return
        }
    }
}

private extension LibraryAutoAdd.WatchlistEntry {
    var tvWatchlistIdentity: String { type + ":" + id }
}
