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
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.close() }
                        .accessibilityHidden(true)
                    let frame = CinemaRailLayout.quickViewFrame(viewport: geometry.size)
                    let shape = RoundedRectangle(cornerRadius: geometry.size.width < 600 ? 0 : 24,
                                                 style: .continuous)
                    CinemaQuickView(item: presentation.item, onWatch: presentation.onWatch,
                                    onDetails: presentation.onDetails, onClose: { presenter.close() })
                        .id(presentation.id)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(shape)
                        .vortxGlass(in: shape, fillAlpha: 0.12, tone: .scrim, materialOpacity: 0.42)
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @EnvironmentObject private var theme: ThemeManager
    @State private var isWatchlisted = false
    @State private var watchlistStatus: String?
    @State private var watchlistFailure: String?
    @State private var loadedSynopsis: String?
    @State private var loadedSynopsisKey: RatingRequestKey?
    @State private var loadedRatings: MDBListRatings?
    @State private var loadedRatingsKey: RatingRequestKey?
    @State private var loadedArtworkKey: RatingRequestKey?
    @State private var loadedBackdrop: String?
    @State private var loadedLogo: String?
    @State private var loadedCreditsKey: RatingRequestKey?
    @State private var castMembers: [TMDBClient.CastMember] = []
    @StateObject private var watchlistAction = ProfileMutationPresentation()

    private var watchlistType: String? { LibraryWatchedMutationPolicy.normalizedCatalogType(item.type) }
    private var supportsWatchlist: Bool {
        watchlistType != nil && LibraryWatchedMutationPolicy.isCanonicalCatalogID(item.id)
    }
    private var synopsis: String? {
        let provided = item.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return provided?.isEmpty == false ? provided : (loadedSynopsisKey == ratingRequest ? loadedSynopsis : nil)
    }

    private var facts: [String] {
        [item.releaseInfo, previewIMDb.map { "★ \($0)" }, item.type.capitalized]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var ratingRequest: RatingRequestKey { .init(id: item.id, type: item.type) }
    private var previewIMDb: String? {
        RatingPresentationPolicy.merged(loadedRatingsKey == ratingRequest ? loadedRatings : nil,
                                       fallbackIMDb: item.imdbRating)?.imdb.map { String(format: "%.1f", $0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = CinemaRailLayout.quickViewContentInset(width: geometry.size.width)
            let wide = geometry.size.width >= 700
            ZStack(alignment: .top) {
                backdrop(size: geometry.size, wide: wide)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        Color.clear
                            .frame(height: min(wide ? 130 : 150, geometry.size.height * 0.2))
                            .accessibilityHidden(true)
                        titleAndFacts(wide: wide)
                        if let description = synopsis, !description.isEmpty {
                            Text(description)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(wide ? 4 : 6)
                                .frame(maxWidth: 680, alignment: .leading)
                        }
                        actionBar
                        status
                        if !visibleCast.isEmpty { castRail }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    header
                        .padding(.horizontal, inset)
                        .padding(.top, Theme.Space.md)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick view for \(item.name)")
        .onAppear(perform: refreshWatchlist)
        .task(id: item.type + ":" + item.id) { await loadMissingSynopsis() }
        .task(id: ratingRequest) { await loadPreviewArtwork() }
        .task(id: ratingRequest) { await loadPreviewCredits() }
        .task(id: ratingRequest) {
            #if !CINEMA_UI_SMOKE_RENDERER
            let requested = ratingRequest
            loadedRatingsKey = requested; loadedRatings = nil
            let value = await CardRatingStore.shared.ratings(id: requested.id, type: requested.type)
            guard !Task.isCancelled, loadedRatingsKey == requested else { return }
            loadedRatings = value
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
            refreshWatchlist()
        }
        .onDisappear { watchlistAction.cancel() }
    }

    private var requiresContrast: Bool { reduceTransparency || accessibilityContrast == .increased }
    private var visibleCast: [TMDBClient.CastMember] {
        loadedCreditsKey == ratingRequest ? castMembers : []
    }
    private var artworkURL: String? {
        (loadedArtworkKey == ratingRequest ? loadedBackdrop : nil) ?? item.background ?? item.poster
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func openDetails() {
        close()
        onDetails()
    }

    /// A real route to the established detail/source owner, never a pretend inline Streams tab.
    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Quick view")
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                .textCase(.uppercase)
            Spacer(minLength: Theme.Space.md)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .vortxGlassDisc()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close preview")
            .accessibilityIdentifier("cinema-quick-view-close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, Theme.Space.sm)
        .background {
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -40)
                .padding(.top, -24)
                .allowsHitTesting(false)
        }
    }

    private func backdrop(size: CGSize, wide: Bool) -> some View {
        ZStack {
            Theme.Palette.canvas
            CachedPosterImage(url: artworkURL)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(wide ? 0.94 : 0.72), location: 0),
                .init(color: .black.opacity(wide ? 0.82 : 0.72), location: 0.60),
                .init(color: .black.opacity(wide ? 0.30 : 0.72), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(requiresContrast ? 0.96 : 0.88)],
                           startPoint: .center, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func titleAndFacts(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            #if CINEMA_UI_SMOKE_RENDERER
            titleText
                .frame(maxWidth: wide ? 460 : 320, minHeight: 84, alignment: .bottomLeading)
            #else
            ResolvedTitleLogo(id: LibraryWatchedMutationPolicy.isCanonicalCatalogID(item.id) ? item.id : nil, type: item.type,
                              fallbackLogo: loadedArtworkKey == ratingRequest ? loadedLogo : nil,
                              maxWidth: wide ? 460 : 320, maxHeight: 84,
                              accessibilityName: item.name) { titleText }
                .frame(minHeight: 84, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
            #endif
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let genres = item.genres, !genres.isEmpty {
                FlowLayout(spacing: Theme.Space.xs) {
                    ForEach(Array(genres.prefix(4)), id: \.self) { genre in
                        Text(genre)
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                            .padding(.horizontal, Theme.Space.sm)
                            .padding(.vertical, 5)
                            .background(Theme.Palette.textPrimary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var titleText: some View {
        Text(item.name)
            .font(Theme.Typography.hero)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) { watchButton; streamsButton; watchlistButton }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) { watchButton; watchlistButton }
                streamsButton
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private var watchButton: some View {
        Button {
            close()
            onWatch()
        } label: {
            Label("Watch Now", systemImage: "play.fill")
                .font(Theme.Typography.label.weight(.semibold))
                .padding(.horizontal, Theme.Space.lg)
                .frame(minWidth: 148, minHeight: 46)
        }
        .buttonStyle(.plain)
        .vortxGlassTintedSurface(in: Capsule(), fillAlpha: 0.22, tintAlpha: 0.12,
                                highlight: 0.16, tone: .scrim, contained: true, forceOpaque: requiresContrast)
        .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.72), lineWidth: 1))
        .accessibilityHint("Opens this title's playback options")
    }

    private var streamsButton: some View {
        Button(action: openDetails) {
            Text("View streams")
                .font(Theme.Typography.label.weight(.semibold))
                .padding(.horizontal, Theme.Space.lg)
                .frame(minWidth: 148, minHeight: 46)
        }
        .buttonStyle(.plain)
        .vortxGlassTintedSurface(in: Capsule(), fillAlpha: 0.16, tintAlpha: 0.03,
                                highlight: 0.12, tone: .scrim, contained: true, forceOpaque: requiresContrast)
        .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.48), lineWidth: 1))
        .accessibilityHint("Opens the full title page and its source list")
    }

    private var watchlistButton: some View {
        Button(action: toggleWatchlist) {
            Group {
                if watchlistAction.isRunning {
                    ProgressView().controlSize(.small).tint(Theme.Palette.textPrimary)
                } else {
                    Image(systemName: isWatchlisted ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .vortxGlassTintedSurface(in: Circle(), fillAlpha: 0.16, tintAlpha: 0.03,
                                tone: .scrim, contained: true, forceOpaque: requiresContrast)
        .disabled(!supportsWatchlist || watchlistAction.isRunning)
        .accessibilityLabel(watchlistAction.isRunning ? "Saving watchlist" : (isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist"))
    }

    @ViewBuilder private var status: some View {
        if !supportsWatchlist {
            Text("This add-on's title cannot be saved to Watchlist yet.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        if let watchlistStatus {
            Text(watchlistStatus).font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        if let error = watchlistAction.errorMessage {
            Text(error).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private var castRail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Cast").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text("Preview")
                    .font(Theme.Typography.eyebrow).foregroundStyle(Theme.Palette.textPrimary.opacity(0.82))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                    ForEach(visibleCast) { member in
                        VStack(spacing: Theme.Space.xs) {
                            CachedPosterImage(url: member.profileURL)
                                .frame(width: 72, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .accessibilityHidden(true)
                            Text(member.name).font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textPrimary).lineLimit(2)
                            if let character = member.character {
                                Text(character).font(Theme.Typography.eyebrow)
                                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.82)).lineLimit(2)
                            }
                        }
                        .frame(width: 86, alignment: .top)
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Theme.Space.md)
        // A flat local wash protects captions when this rail scrolls over the bright side of the art.
        // It adds no second material blur; accessibility contrast retains an opaque warm scrim.
        .background(VortXGlass.fill(requiresContrast ? 1 : 0.72, tone: .scrim),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func refreshWatchlist() {
        #if !CINEMA_UI_SMOKE_RENDERER
        isWatchlisted = LibraryAutoAdd.isWatchlisted(item.id, type: watchlistType)
        #endif
    }

    @MainActor
    private func loadMissingSynopsis() async {
        #if !CINEMA_UI_SMOKE_RENDERER
        let requested = ratingRequest
        loadedSynopsisKey = requested; loadedSynopsis = nil
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
        guard !Task.isCancelled, loadedSynopsisKey == requested, ProfileStore.shared.activeID == profileID,
              target.stillOwnsCurrentContext(core: core) else { return }
        if let synopsis { loadedSynopsis = synopsis }
        #endif
    }

    /// Optional enrichment reuses the existing coalescing artwork cache and never delays catalog first paint.
    @MainActor
    private func loadPreviewArtwork() async {
        #if !CINEMA_UI_SMOKE_RENDERER
        let requested = ratingRequest
        loadedArtworkKey = requested; loadedBackdrop = nil; loadedLogo = nil
        guard ["movie", "series"].contains(requested.type),
              LibraryWatchedMutationPolicy.isCanonicalCatalogID(requested.id) else { return }
        let core = CoreBridge.shared
        let target = PlaybackMutationTarget.capture(core: core)
        let profileID = ProfileStore.shared.activeID
        let backdrop = await LandscapeBackdropCache.backdrop(id: requested.id, type: requested.type)
        guard !Task.isCancelled, loadedArtworkKey == requested,
              ProfileStore.shared.activeID == profileID, target.stillOwnsCurrentContext(core: core) else { return }
        loadedBackdrop = backdrop
        let logo = await LandscapeBackdropCache.logo(id: requested.id, type: requested.type)
        guard !Task.isCancelled, loadedArtworkKey == requested,
              ProfileStore.shared.activeID == profileID, target.stillOwnsCurrentContext(core: core) else { return }
        loadedLogo = logo
        #endif
    }

    /// Full detail already uses this public credits path. Keep the preview isolated from its live metadata slot.
    @MainActor
    private func loadPreviewCredits() async {
        #if !CINEMA_UI_SMOKE_RENDERER
        let requested = ratingRequest
        loadedCreditsKey = requested; castMembers = []
        guard ["movie", "series"].contains(requested.type), requested.id.hasPrefix("tt"),
              LibraryWatchedMutationPolicy.isCanonicalCatalogID(requested.id) else { return }
        let core = CoreBridge.shared
        let target = PlaybackMutationTarget.capture(core: core)
        let profileID = ProfileStore.shared.activeID
        let result = await TMDBClient.credits(imdbID: requested.id, type: requested.type)
        guard !Task.isCancelled, loadedCreditsKey == requested,
              ProfileStore.shared.activeID == profileID, target.stillOwnsCurrentContext(core: core) else { return }
        castMembers = Array((result?.cast ?? []).prefix(12))
        if synopsis == nil { loadedSynopsisKey = requested; loadedSynopsis = result?.overview }
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
        .onValueChange(of: profiles.activeID) { _ in entries = LibraryAutoAdd.watchlist() }
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
    @State private var loadedRatings: MDBListRatings?
    @State private var loadedRatingsKey: RatingRequestKey?
    private var ratingRequest: RatingRequestKey { .init(id: item.id, type: item.type) }
    private var previewIMDb: String? {
        RatingPresentationPolicy.merged(loadedRatingsKey == ratingRequest ? loadedRatings : nil,
                                       fallbackIMDb: item.imdbRating)?.imdb.map { String(format: "%.1f", $0) }
    }

    private var facts: [String] {
        [item.releaseInfo, previewIMDb.map { "★ \($0)" }, item.type.capitalized]
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
        .task(id: ratingRequest) {
            #if !CINEMA_UI_SMOKE_RENDERER
            let requested = ratingRequest
            loadedRatingsKey = requested; loadedRatings = nil
            let value = await CardRatingStore.shared.ratings(id: requested.id, type: requested.type)
            guard !Task.isCancelled, loadedRatingsKey == requested else { return }
            loadedRatings = value
            #endif
        }
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
