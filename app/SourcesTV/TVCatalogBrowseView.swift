import SwiftUI

/// Capture at See All activation, rather than recomputing a destination after a profile/account change.
/// The installed transport is retained only as request identity; it is never rendered or logged.
struct TVCatalogBrowseTarget: Hashable {
    let routeID = UUID()
    let title: String
    let request: TVCatalogRequestIdentity
    let owner: PlaybackMutationTarget
    let profileID: UUID?
    let accountBoundaryGeneration: UInt64

    @MainActor
    func isCurrent(core: CoreBridge, accountBoundaryGeneration: UInt64, invalidated: Bool) -> Bool {
        !invalidated && profileID == ProfileStore.shared.activeID
            && self.accountBoundaryGeneration == accountBoundaryGeneration
            && owner.stillOwnsCurrentContext(core: core)
    }
}

fileprivate struct TVCatalogBrowseResolved {
    let row: CoreBoardRow
    let candidate: TVCatalogBrowseCandidate
    let supportsPaging: Bool
}

extension CoreBridge {
    /// This is a read-only view of the existing native board. It creates no resource owner or fetch.
    @MainActor
    func captureTVCatalogBrowse(row: CoreBoardRow, accountBoundaryGeneration: UInt64) -> TVCatalogBrowseTarget? {
        let owner = PlaybackMutationTarget.capture(core: self)
        guard owner.stillOwnsCurrentContext(core: self),
              let board = decode(TVCatalogBrowseBoard.self, field: "board") else { return nil }
        let matches = board.candidates.filter { $0.request.rowID == row.id && $0.request.type == row.type }
        guard matches.count == 1, let candidate = matches.first,
              candidate.engineIndex == row.engineIndex, candidate.itemCount == row.items.count else { return nil }
        return .init(title: row.title, request: candidate.request, owner: owner,
                     profileID: ProfileStore.shared.activeID, accountBoundaryGeneration: accountBoundaryGeneration)
    }

    @MainActor
    fileprivate func resolveTVCatalogBrowse(_ target: TVCatalogBrowseTarget, accountBoundaryGeneration: UInt64,
                                          invalidated: Bool) -> TVCatalogBrowseResolved? {
        let current = target.isCurrent(core: self, accountBoundaryGeneration: accountBoundaryGeneration,
                                       invalidated: invalidated)
        guard current, let board = decode(TVCatalogBrowseBoard.self, field: "board"),
              let candidate = TVCatalogBrowsePolicy.resolve(target: target.request, candidates: board.candidates,
                                                           ownerCurrent: current, visibleRowIDs: Set(boardRows.map(\.id))),
              let row = boardRows.first(where: { $0.id == target.request.rowID && $0.type == target.request.type }),
              row.engineIndex == candidate.engineIndex, row.items.count == candidate.itemCount else { return nil }
        let supportsPaging = decode(TVCatalogBrowseRegistry.self, field: "ctx")?.supportsPaging(target.request) == true
        return .init(row: row, candidate: candidate, supportsPaging: supportsPaging)
    }

    @MainActor
    func pageTVCatalogBrowse(_ target: TVCatalogBrowseTarget, accountBoundaryGeneration: UInt64, invalidated: Bool = false) {
        guard let live = resolveTVCatalogBrowse(target, accountBoundaryGeneration: accountBoundaryGeneration,
                                              invalidated: invalidated) else { return }
        TVCatalogBrowsePolicy.page(target: target.request, candidates: [live.candidate], ownerCurrent: true,
                                   visibleRowIDs: [live.row.id], supportsPaging: live.supportsPaging,
                                   load: { self.loadBoardRowNextPage(engineIndex: $0) })
    }
}

/// Read-only heavy-field access has the same background-thread contract as CoreBridge's existing
/// board assembly. This narrowly held reader never dispatches, starts an owner, or publishes state.
private struct TVCatalogBrowseDecoded: Sendable {
    let candidates: [TVCatalogBrowseCandidate]
    let supportsPaging: Bool
}

private final class TVCatalogBrowseReader: @unchecked Sendable {
    let core: CoreBridge
    init(core: CoreBridge) { self.core = core }

    func read(_ request: TVCatalogRequestIdentity) -> TVCatalogBrowseDecoded? {
        guard !Task.isCancelled, let raw = core.stateData("board"),
              let board = try? JSONDecoder().decode(TVCatalogBrowseBoard.self, from: raw) else { return nil }
        guard !Task.isCancelled else { return nil }
        let registry = core.stateData("ctx").flatMap { try? JSONDecoder().decode(TVCatalogBrowseRegistry.self, from: $0) }
        return .init(candidates: board.candidates, supportsPaging: registry?.supportsPaging(request) == true)
    }
}

/// Cache the current projection at real board publication boundaries, not SwiftUI render/focus ticks.
/// JSON serialization/decoding runs off main; the captured owner and generation fence its publication.
@MainActor private final class TVCatalogBrowseProjection: ObservableObject {
    @Published private(set) var live: TVCatalogBrowseResolved?
    @Published private(set) var isRefreshing = false
    private var task: Task<Void, Never>?
    private var decodeTask: Task<TVCatalogBrowseDecoded?, Never>?
    private var generation = 0

    func refresh(target: TVCatalogBrowseTarget, core: CoreBridge, account: StremioAccount, invalidated: Bool) {
        cancel()
        guard target.isCurrent(core: core, accountBoundaryGeneration: account.credentialBoundaryGeneration,
                               invalidated: invalidated) else { live = nil; return }
        let capturedGeneration = generation
        let reader = TVCatalogBrowseReader(core: core)
        let request = target.request
        isRefreshing = true
        let worker = Task.detached(priority: .userInitiated) { reader.read(request) }
        decodeTask = worker
        task = Task { [weak self, weak core, weak account] in
            let decoded = await worker.value
            guard let self, let core, let account, !Task.isCancelled, self.generation == capturedGeneration else { return }
            self.isRefreshing = false
            guard target.isCurrent(core: core, accountBoundaryGeneration: account.credentialBoundaryGeneration,
                                   invalidated: invalidated), let decoded,
                  let candidate = TVCatalogBrowsePolicy.resolve(target: request, candidates: decoded.candidates,
                      ownerCurrent: true, visibleRowIDs: Set(core.boardRows.map(\.id))),
                  let row = core.boardRows.first(where: { $0.id == request.rowID && $0.type == request.type }),
                  row.engineIndex == candidate.engineIndex, row.items.count == candidate.itemCount else {
                self.live = nil; return
            }
            self.live = .init(row: row, candidate: candidate, supportsPaging: decoded.supportsPaging)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        decodeTask?.cancel(); decodeTask = nil
        isRefreshing = false
    }
}

/// The full grid observes the same board row as Home. All native in-flight, exhaustion, add-on order,
/// and page append rules remain owned by CoreBridge's existing per-row page action.
struct TVCatalogBrowseView: View {
    let target: TVCatalogBrowseTarget
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var watchedIndex = WatchedIndex.shared
    @State private var invalidated = false
    @StateObject private var projection = TVCatalogBrowseProjection()
    @FocusState private var backFocused: Bool

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(TVGridMetrics.landscapeCellWidth), spacing: Theme.Space.lg),
              count: TVGridMetrics.landscapeColumns)
    }

    var body: some View {
        let rowStillVisible = core.boardRows.contains { $0.id == target.request.rowID && $0.type == target.request.type }
        let live = target.isCurrent(core: core, accountBoundaryGeneration: account.credentialBoundaryGeneration,
                                    invalidated: invalidated) && rowStillVisible ? projection.live : nil
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.md) {
                    Button { dismiss() } label: { Label("Back to Home", systemImage: "chevron.left") }
                        .buttonStyle(ChipButtonStyle(selected: false)).focused($backFocused)
                    Text(target.title).screenTitleStyle()
                }
                .focusSection()
                if let live {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(live.row.items) { item in
                            TVCatalogSelectionCard(presentation: .meta(item), width: TVGridMetrics.landscapeCellWidth,
                                                   isWatched: watchedIndex.ids.contains(item.id))
                                .onAppear {
                                    if item.id == live.row.items.last?.id { page() }
                                }
                        }
                    }
                    .padding(.vertical, Theme.Space.md)
                    .focusSection()
                    if live.candidate.state == .loading {
                        HStack(spacing: Theme.Space.sm) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text("Loading more titles…").font(Theme.Typography.label)
                        }
                    } else if live.candidate.state == .error {
                        Text("More titles are unavailable right now.").font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else if live.supportsPaging && live.candidate.lastPageCount > 0 {
                        Button(action: page) { Label("Load more", systemImage: "arrow.down") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                } else if projection.isRefreshing {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().tint(Theme.Palette.accent)
                        Text("Loading catalog…").font(Theme.Typography.body)
                    }
                    .frame(minHeight: 360)
                } else {
                    CoreEmptyState(systemImage: "film.stack", title: "Catalog unavailable",
                                   message: "This catalog is no longer available in the current profile.")
                        .frame(minHeight: 360)
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tvCatalogQuickViewRoutes()
        .navigationBarBackButtonHidden(true)
        .onAppear { backFocused = true; refresh() }
        .onReceive(core.$boardRows) { _ in refresh() }
        .onReceive(core.$addons) { _ in refresh() }
        .onChange(of: profiles.activeID) { _, _ in invalidated = true }
        .onChange(of: account.credentialBoundaryGeneration) { _, _ in invalidated = true }
        .onDisappear { projection.cancel() }
        .onExitCommand { dismiss() }
    }

    private func page() {
        core.pageTVCatalogBrowse(target, accountBoundaryGeneration: account.credentialBoundaryGeneration,
                                invalidated: invalidated)
    }

    private func refresh() {
        projection.refresh(target: target, core: core, account: account, invalidated: invalidated)
    }
}
