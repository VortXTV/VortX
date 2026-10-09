import SwiftUI

/// Window-owned presentation: a catalog row must not trap a sheet inside its scroll viewport.
@MainActor
final class CinemaQuickViewPresenter: ObservableObject {
    struct Presentation {
        let id = UUID()
        let item: RailItem
        let onWatch: () -> Void
        let onDetails: () -> Void
    }
    @Published private(set) var presentation: Presentation?

    func present(_ item: RailItem, onWatch: @escaping () -> Void, onDetails: @escaping () -> Void) {
        presentation = Presentation(item: item, onWatch: onWatch, onDetails: onDetails)
    }

    func close() { presentation = nil }
}

private struct CinemaQuickViewPresenterKey: EnvironmentKey {
    static let defaultValue: CinemaQuickViewPresenter? = nil
}
private struct CinemaCardViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
    var cinemaQuickViewPresenter: CinemaQuickViewPresenter? {
        get { self[CinemaQuickViewPresenterKey.self] }
        set { self[CinemaQuickViewPresenterKey.self] = newValue }
    }
    var cinemaCardViewportWidth: CGFloat {
        get { self[CinemaCardViewportWidthKey.self] }
        set { self[CinemaCardViewportWidthKey.self] = newValue }
    }
}

struct CinemaQuickViewOverlay: View {
    @ObservedObject var presenter: CinemaQuickViewPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let presentation = presenter.presentation {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.close() }
                        .accessibilityHidden(true)
                    CinemaQuickView(item: presentation.item, onWatch: presentation.onWatch,
                                    onDetails: presentation.onDetails, onClose: { presenter.close() })
                        .id(presentation.id)
                        .frame(width: max(1, min(820, geometry.size.width - 32)),
                               height: max(1, min(760, geometry.size.height - 32)))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .vortxGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                        .accessibilityAddTraits(.isModal)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                #if os(macOS)
                .onExitCommand { presenter.close() }
                #endif
            }
            .transition(reduceMotion ? .identity : .opacity)
            .zIndex(100)
        }
    }
}

/// The title preview uses catalog data first and an isolated, identity-checked synopsis lookup when needed.
struct CinemaQuickView: View {
    let item: RailItem
    let onWatch: () -> Void
    let onDetails: () -> Void
    var onClose: (() -> Void)? = nil
    @State private var sheetDetent: PresentationDetent = .large
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWatchlisted = false
    @State private var watchlistStatus: String?
    @State private var watchlistFailure: String?
    @State private var loadedSynopsis: String?
    @StateObject private var watchlistAction = ProfileMutationPresentation()

    private var watchlistType: String? { LibraryWatchedMutationPolicy.normalizedCatalogType(item.type) }
    private var supportsWatchlist: Bool {
        watchlistType != nil && LibraryWatchedMutationPolicy.isCanonicalCatalogID(item.id)
    }
    private var synopsis: String? {
        let provided = item.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return provided?.isEmpty == false ? provided : loadedSynopsis
    }

    private var facts: [String] {
        [item.releaseInfo, item.imdbRating.map { "★ \($0)" }, item.type.capitalized]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .vortxGlassDisc()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
                .accessibilityIdentifier("cinema-quick-view-close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    wideLayout
                    compactLayout
                }
                .padding(Theme.Space.md)
            }
        }
        .presentationDetents([.medium, .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .background(Theme.Palette.canvas.opacity(0.82))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick view for \(item.name)")
        .onAppear(perform: refreshWatchlist)
        .task(id: item.type + ":" + item.id) { await loadMissingSynopsis() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
            refreshWatchlist()
        }
        .onDisappear { watchlistAction.cancel() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            artwork
                .frame(width: 260, height: 390)
                .clipped()
            copy
        }
        .frame(minWidth: 540, alignment: .leading)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            artwork.frame(maxWidth: .infinity).frame(height: 230).clipped()
            copy
        }
    }

    private var artwork: some View {
        ZStack {
            CachedPosterImage(url: item.background ?? item.poster)
                .scaledToFill()
                .overlay(Color.black.opacity(0.32))
            if let poster = item.poster, !poster.isEmpty {
                CachedPosterImage(url: poster)
                    .scaledToFill()
                    .frame(width: 132, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(item.type.capitalized)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.accent)
                .textCase(.uppercase)
            Text(item.name)
                .font(Theme.Typography.hero)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !facts.isEmpty {
                FlowLayout(spacing: Theme.Space.xs) {
                    ForEach(facts, id: \.self) { fact in
                        Text(fact)
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.horizontal, Theme.Space.sm)
                            .frame(minHeight: 30)
                            .vortxGlassChip(selected: false)
                    }
                }
            }
            if let description = synopsis, !description.isEmpty {
                Text(description)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    close()
                    onWatch()
                } label: {
                    Label("Watch Now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .vortxGlassProminent(in: Capsule())
                .accessibilityHint("Opens this title's playback options")

                Button {
                    toggleWatchlist()
                } label: {
                    Label(watchlistAction.isRunning ? "Saving…" : (isWatchlisted ? "In Watchlist" : "Add to Watchlist"),
                          systemImage: isWatchlisted ? "bookmark.fill" : "bookmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
                .disabled(!supportsWatchlist || watchlistAction.isRunning)
                .accessibilityHint(isWatchlisted ? "Removes this title from your watchlist" : "Saves this title to your watchlist")
            }
            if !supportsWatchlist {
                Text("This add-on's title cannot be saved to Watchlist yet.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if let watchlistStatus {
                Text(watchlistStatus)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(watchlistStatus.hasPrefix("Added") ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            if let error = watchlistAction.errorMessage {
                Text(error).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button {
                close()
                onDetails()
            } label: {
                Label("Details", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)
            .accessibilityHint("Opens the full title page")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: item.id)
    }

    private func refreshWatchlist() {
        #if !CINEMA_UI_SMOKE_RENDERER
        isWatchlisted = LibraryAutoAdd.isWatchlisted(item.id, type: watchlistType)
        #endif
    }

    @MainActor
    private func loadMissingSynopsis() async {
        #if !CINEMA_UI_SMOKE_RENDERER
        guard item.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
        let core = CoreBridge.shared
        let target = PlaybackMutationTarget.capture(core: core)
        let profileID = ProfileStore.shared.activeID
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        guard let pathID = item.id.addingPercentEncoding(withAllowedCharacters: allowed),
              let pathType = item.type.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        let bases = core.addons.filter { descriptor in
            (descriptor.manifest.resources ?? []).contains { resource in
                resource.name == "meta"
                    && resource.types?.contains(item.type) != false
                    && ((resource.idPrefixes ?? descriptor.manifest.idPrefixes ?? []).isEmpty
                        || (resource.idPrefixes ?? descriptor.manifest.idPrefixes ?? []).contains { item.id.hasPrefix($0) })
            }
        }.map(\.baseUrl)
        var seen = Set<String>()
        let urls = bases.compactMap { base -> URL? in
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            guard seen.insert(trimmed).inserted,
                  let url = URL(string: "\(trimmed)/meta/\(pathType)/\(pathID).json"),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        let synopsis = await CinemaPreviewSynopsis.load(urls: urls, id: item.id, type: item.type)
        guard !Task.isCancelled, ProfileStore.shared.activeID == profileID,
              target.stillOwnsCurrentContext(core: core) else { return }
        loadedSynopsis = synopsis
        #endif
    }

    private func toggleWatchlist() {
        guard supportsWatchlist else { return }
        #if CINEMA_UI_SMOKE_RENDERER
        preconditionFailure("Cinema UI renderer must not mutate a watchlist")
        #else
        let core = CoreBridge.shared
        guard let type = watchlistType else { return }
        watchlistStatus = nil
        watchlistFailure = nil
        #if VORTX_NATIVE_DATA_ENGINE
        // Capture the viewer at the tap. A normal in-flight sync can make the playback target
        // temporarily unavailable; it must not turn a watchlist action into a silent no-op.
        let admission = core.captureNativeWatchlistActionAdmission()
        let requestedMembership = !isWatchlisted
        watchlistAction.start(operation: {
            guard let target = await core.prepareNativeWatchlistActionTarget(admission) else { return false }
            do {
                let entry = VortxNativeWatchlist.Entry(id: item.id, type: type, name: item.name,
                    poster: item.poster, addedAt: Date().timeIntervalSince1970)
                let membership = try await core.setNativeWatchlist(entry, present: requestedMembership, target: target)
                guard core.nativeWatchlistTargetIsCurrent(target) else { return false }
                isWatchlisted = membership
                return true
            } catch {
                if let failure = error as? VortxNativeWatchlist.Failure { watchlistFailure = failure.localizedDescription }
                return false
            }
        }, failureMessage: {
            watchlistFailure ?? "Couldn't save to Watchlist. Please try again."
        }, onSuccess: {
            watchlistStatus = isWatchlisted ? "Added to Watchlist" : "Removed from Watchlist"
        })
        #else
        let target = PlaybackMutationTarget.capture(core: core)
        let profileID = ProfileStore.shared.activeID
        let isCurrent = {
            ProfileStore.shared.activeID == profileID && target.stillOwnsCurrentContext(core: core)
        }
        watchlistAction.start(operation: {
            guard isCurrent() else { return false }
            do {
                _ = try await LibraryAutoAdd.toggleWatchlistAcknowledged(
                    id: item.id, type: type, name: item.name, poster: item.poster, target: target)
                return isCurrent()
            } catch { return false }
        }, failureMessage: {
            isCurrent() ? "Couldn't update Watchlist. Please try again." : "Profile changed. Please try again."
        }, onSuccess: {
            guard isCurrent() else { return }
            refreshWatchlist()
            watchlistStatus = isWatchlisted ? "Added to Watchlist" : "Removed from Watchlist"
        })
        #endif
        #endif
    }
}

/// The same per-profile want-to-watch ledger as the detail and quick-view bookmark buttons. The main
/// Library grid remains the account/local saved library; this destination makes the bookmark intent visible.
struct CinemaWatchlist: View {
    let onOpen: (RailItem) -> Void
    let onWatch: (RailItem) -> Void
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @State private var entries: [LibraryAutoAdd.WatchlistEntry] = []

    private var items: [RailItem] {
        let catalog = core.boardRows.flatMap(\.items)
        return entries.map { entry in
            let preview = catalog.first { $0.id == entry.id && $0.type == entry.type }
            return RailItem(id: entry.id, type: entry.type, name: entry.name ?? preview?.name ?? entry.id,
                            poster: entry.poster ?? preview?.poster, progress: 0,
                            background: preview?.background, description: preview?.description,
                            releaseInfo: preview?.releaseInfo, imdbRating: preview?.imdbRating,
                            genres: preview?.genres)
        }
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableViewCompat(title: "Watchlist", systemImage: "bookmark",
                                             message: "Titles you bookmark to watch later appear here.")
                    .frame(minHeight: 360)
            } else {
                PosterGrid(items: items, onTap: onOpen, onWatch: onWatch, menu: .catalog)
                    .padding(.vertical, Theme.Space.md)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()
        .onAppear { entries = LibraryAutoAdd.watchlist() }
        .onChange(of: profiles.activeID) { _ in entries = LibraryAutoAdd.watchlist() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
            entries = LibraryAutoAdd.watchlist()
        }
    }
}

/// A big, glass-backed entry card for Library destinations. The caller owns navigation; this type is only
/// presentation, so Downloads and future profile/library routes keep their existing values and actions.
struct CinemaLibraryEntryCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 52, height: 52)
                .vortxGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), shadow: .flat)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let badge { Text(badge).font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.accent) }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Home's compact doorway into the existing Discover navigation stack. It is intentionally presentation
/// only: callers retain the real `HubTarget` value so pagination, category pills, and filter behavior live
/// in their established browse owner.
struct CinemaBrowseEntry: View {
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "safari.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 52, height: 52)
                .vortxGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), shadow: .flat)
            VStack(alignment: .leading, spacing: 3) {
                Text("Discover").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Browse genres, services, and catalog filters")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
    }
}

/// A value route for an installed add-on catalog. It intentionally stores only stable board identity;
/// `CinemaBoardCatalogBrowse` observes the current bridge row so a horizontal shelf and its full grid share
/// the same live page stream instead of making a second provider-wide catalog request.
struct CinemaBoardCatalogTarget: Hashable {
    let rowID: String
    let title: String
    let engineIndex: Int
}

/// The full-grid counterpart to a Home add-on shelf. Paging delegates to the existing per-row engine action,
/// preserving source selection and avoiding duplicate/fan-out catalog fetches.
struct CinemaBoardCatalogBrowse: View {
    let target: CinemaBoardCatalogTarget
    @Binding var path: NavigationPath
    @EnvironmentObject private var core: CoreBridge

    private var row: CoreBoardRow? {
        core.boardRows.first(where: { $0.id == target.rowID })
    }

    private var items: [RailItem] {
        (row?.items ?? []).map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0,
                     background: $0.background, description: $0.description,
                     releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating, genres: $0.genres)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                if items.isEmpty {
                    ContentUnavailableViewCompat(title: target.title, systemImage: "film.stack",
                                                 message: "This catalog has no available titles right now.")
                        .frame(minHeight: 360)
                } else {
                    PosterGrid(items: items, onTap: openDetails, onWatch: watch,
                               menu: .catalog, showWatchedBadges: true,
                               onReachEnd: { core.loadBoardRowNextPage(engineIndex: target.engineIndex) })
                }
            }
            .padding(.vertical, Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()
    }

    private func openDetails(_ item: RailItem) {
        path.append(FeaturedHeroItem.from(rail: item))
    }

    private func watch(_ item: RailItem) {
        path.append(CinemaDetailTarget(item: FeaturedHeroItem.from(rail: item), autoPlay: true))
    }
}

/// Search is deliberately a result surface rather than another poster rail: its cards keep the actual
/// wide artwork, title, available facts, and synopsis together under the image at a readable scale.
struct CinemaSearchResults: View {
    let items: [RailItem]
    let onOpen: (RailItem) -> Void
    var onWatch: ((RailItem) -> Void)? = nil
    @AppStorage("vortx.quickViewEnabled") private var quickViewEnabled = true
    @State private var quickViewItem: RailItem?
    @Environment(\.cinemaQuickViewPresenter) private var quickViewPresenter

    var body: some View {
        LazyVStack(spacing: Theme.Space.md) {
            ForEach(items) { item in
                Button {
                    if quickViewEnabled, let quickViewPresenter {
                        quickViewPresenter.present(item, onWatch: { (onWatch ?? onOpen)(item) },
                                                   onDetails: { onOpen(item) })
                    } else if quickViewEnabled { quickViewItem = item } else { onOpen(item) }
                } label: {
                    CinemaSearchResultCard(item: item)
                }
                .buttonStyle(CardFocusStyle(scale: 1.015))
                .accessibilityLabel(item.name)
                .accessibilityHint(quickViewEnabled ? "Opens quick view" : "Opens details")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .sheet(item: $quickViewItem) { item in
            CinemaQuickView(item: item, onWatch: {
                if let onWatch { onWatch(item) } else { onOpen(item) }
            }, onDetails: { onOpen(item) })
        }
    }
}

private struct CinemaSearchResultCard: View {
    let item: RailItem

    private var facts: [String] {
        [item.releaseInfo, item.imdbRating.map { "★ \($0)" }, item.type.capitalized]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                artwork.frame(width: 260, height: 146).clipped()
                copy
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                artwork.frame(maxWidth: .infinity).frame(height: 190).clipped()
                copy
            }
        }
        .padding(Theme.Space.sm)
        .vortxCinemaCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
    }

    private var artwork: some View {
        CachedPosterImage(url: item.background ?? item.poster)
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.42)], startPoint: .center, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            if let description = item.description, !description.isEmpty {
                Text(description).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
