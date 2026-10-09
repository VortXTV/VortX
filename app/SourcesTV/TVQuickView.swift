import SwiftUI
import UIKit

/// The card's own immutable profile/account capture. Preview data never reads the shared meta slot.
struct TVQuickViewTarget: Identifiable, Hashable {
    let id = UUID()
    let presentation: TVCinemaCardPresentation
    let profileID: UUID?
    let accountBoundaryGeneration: UInt64
    let mutationTarget: PlaybackMutationTarget
    var autoPlay = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func isCurrent(core: CoreBridge, profiles: ProfileStore, account: StremioAccount) -> Bool {
        profileID != nil && profileID == profiles.activeID && !profiles.needsPicker
            && accountBoundaryGeneration == account.credentialBoundaryGeneration
            && mutationTarget.stillOwnsCurrentContext(core: core)
    }
}

/// Frozen from the existing series primary Play/Resume selection, including its exact offset.
struct TVQuickViewEpisodeTarget: Identifiable, Hashable {
    let id = UUID()
    let meta: CoreMetaItem
    let video: CoreVideo
    let episodes: [CoreVideo]
    let resumeSeconds: Double?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
private final class TVQuickViewRoutes: ObservableObject {
    @Published var preview: TVQuickViewTarget?
    @Published var destination: TVQuickViewTarget?
    var pendingDestination: TVQuickViewTarget?
}

/// Attach to a non-lazy screen ancestor, inside its NavigationStack. A lazy card cell cannot own
/// a navigationDestination registration: its lifetime ends as it scrolls out of the viewport.
private struct TVQuickViewRouteModifier: ViewModifier {
    @StateObject private var routes = TVQuickViewRoutes()
    @AppStorage("vortx.quickViewEnabled") private var quickViewEnabled = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var presenter: PlayerPresenter

    func body(content: Content) -> some View {
        content.environmentObject(routes)
            .fullScreenCover(item: $routes.preview, onDismiss: finishDismissal) { target in
                TVQuickView(target: target) { autoPlay in
                    guard target.isCurrent(core: core, profiles: profiles, account: account),
                          presenter.request == nil else { return }
                    var route = target
                    route.autoPlay = autoPlay
                    routes.pendingDestination = route
                    routes.preview = nil
                }
                .presentationBackground(.clear)
            }
            .navigationDestination(item: $routes.destination) { target in
                if target.isCurrent(core: core, profiles: profiles, account: account) {
                    DetailView(type: target.presentation.type, id: target.presentation.id,
                               autoPlayOnAppear: target.autoPlay)
                } else {
                    CoreEmptyState(systemImage: "person.crop.circle", title: "Profile changed",
                                   message: "Open this title again in the current profile.")
                }
            }
            .onChange(of: profiles.activeID) { _, _ in retirePreview() }
            .onChange(of: account.credentialBoundaryGeneration) { _, _ in retirePreview() }
            .onChange(of: profiles.needsPicker) { _, required in if required { retirePreview() } }
            .onChange(of: quickViewEnabled) { _, enabled in if !enabled { retirePreview() } }
    }

    private func finishDismissal() {
        guard let target = routes.pendingDestination else { return }
        routes.pendingDestination = nil
        guard target.isCurrent(core: core, profiles: profiles, account: account), presenter.request == nil else { return }
        routes.destination = target
    }

    private func retirePreview() {
        routes.pendingDestination = nil
        routes.preview = nil
    }
}

extension View {
    func tvCatalogQuickViewRoutes() -> some View { modifier(TVQuickViewRouteModifier()) }
}

/// The existing card control still owns focus and its catalog context menu. Disabled QuickView
/// passes nil to directPlay, preserving PosterCard's original direct NavigationLink.
struct TVCatalogSelectionCard: View {
    let presentation: TVCinemaCardPresentation
    var width: CGFloat = kLandscapeCardWidth
    var posterWidth: CGFloat? = nil
    var cinematic = true
    var isWatched = false
    var onFocus: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    @AppStorage("vortx.quickViewEnabled") private var quickViewEnabled = true
    @EnvironmentObject private var routes: TVQuickViewRoutes
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var presenter: PlayerPresenter

    var body: some View {
        let action: (() -> Void)? = TVQuickViewPolicy.presents(enabled: quickViewEnabled, catalog: true)
            ? { openPreview() } : nil
        Group {
            if cinematic {
                TVCinemaCard(presentation: presentation, width: width, isWatched: isWatched,
                             menu: .catalog, onFocus: onFocus, directPlay: action)
            } else {
                PosterCard(title: presentation.title, poster: presentation.poster,
                           type: presentation.type, id: presentation.id, isWatched: isWatched,
                           width: posterWidth, landscapeWidth: width, menu: .catalog,
                           onFocus: onFocus, directPlay: action)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { _ in onSelect?() })
    }

    private func openPreview() {
        let target = TVQuickViewTarget(presentation: presentation, profileID: profiles.activeID,
            accountBoundaryGeneration: account.credentialBoundaryGeneration,
            mutationTarget: PlaybackMutationTarget.capture(core: core))
        guard target.isCurrent(core: core, profiles: profiles, account: account), presenter.request == nil else { return }
        routes.preview = target
    }
}

/// Focus lives in a native full-screen presentation. Supplied artwork/facts fill a rounded glass
/// panel; unavailable metadata stays absent, and previewing never discovers sources or trailers.
struct TVQuickView: View {
    let target: TVQuickViewTarget
    let onOpen: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var watchlistAction = ProfileMutationPresentation()
    @State private var isWatchlisted = false
    @State private var watchlistStatus: String?
    @FocusState private var watchFocused: Bool

    private var item: TVCinemaCardPresentation { target.presentation }
    private var current: Bool { target.isCurrent(core: core, profiles: profiles, account: account) }
    private var supportsWatchlist: Bool {
        ["movie", "series"].contains(item.type) && LibraryWatchedMutationPolicy.isCanonicalCatalogID(item.id)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                artwork
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack(alignment: .top) {
                        Text(item.title).font(Theme.Typography.hero).lineLimit(3)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer(minLength: Theme.Space.md)
                        Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    facts
                    if !item.bodyText.isEmpty {
                        ScrollView {
                            Text(item.bodyText).font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                    HStack(spacing: Theme.Space.md) {
                        Button { if current { onOpen(true) } } label: {
                            Label("Watch Now", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryActionStyle()).focused($watchFocused)
                        Button(action: toggleWatchlist) {
                            Label(isWatchlisted ? "In Watchlist" : "Add to Watchlist",
                                  systemImage: isWatchlisted ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(ChipButtonStyle(selected: isWatchlisted))
                        .disabled(!current || !supportsWatchlist || watchlistAction.isRunning)
                    }
                    .focusSection()
                    Button { if current { onOpen(false) } } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    if let status = watchlistAction.errorMessage ?? watchlistStatus {
                        Text(status).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(width: 760, alignment: .leading)
            }
            .padding(Theme.Space.xl)
            .vortxGlass(in: RoundedRectangle(cornerRadius: 36, style: .continuous),
                        fillAlpha: 0.70, shadow: .flat)
            .padding(Theme.Space.screenEdge)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick view for \(item.title)")
        .defaultFocus($watchFocused, true)
        .onAppear { watchFocused = true; refreshWatchlist() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in refreshWatchlist() }
        .onDisappear { watchlistAction.cancel() }
        .onExitCommand { dismiss() }
    }

    private var artwork: some View {
        VStack(spacing: Theme.Space.md) {
            TVQuickViewArtwork(background: item.background, poster: item.poster)
            if let poster = item.poster, !poster.isEmpty {
                PosterArt(poster, width: 160, radius: 20)
            }
        }
        .accessibilityHidden(true)
    }

    private var facts: some View {
        item.facts.enumerated().reduce(Text("")) { result, entry in
            let separator = entry.offset == 0 ? Text("") : Text("  ·  ")
            switch entry.element {
            case .text(let value): return result + separator + Text(value)
            case .rating(let value): return result + separator + Text(Image(systemName: "star.fill")) + Text(" \(value)")
            }
        }
        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
    }

    private func refreshWatchlist() {
        guard current else { return }
        isWatchlisted = LibraryAutoAdd.isWatchlisted(item.id, type: item.type)
    }

    private func toggleWatchlist() {
        guard current, supportsWatchlist else { return }
        let mutationTarget = PlaybackMutationTarget.capture(core: core)
        let isCurrent = { current && mutationTarget.stillOwnsCurrentContext(core: core) }
        watchlistStatus = nil
        watchlistAction.start(operation: {
            guard isCurrent() else { return false }
            do {
                _ = try await LibraryAutoAdd.toggleWatchlistAcknowledged(
                    id: item.id, type: item.type, name: item.title, poster: item.poster, target: mutationTarget)
                return isCurrent()
            } catch { return false }
        }, failureMessage: {
            isCurrent() ? "Couldn't update Watchlist. Please try again." : "Profile changed. Please try again."
        }, onSuccess: {
            guard isCurrent() else { return }
            refreshWatchlist()
            watchlistStatus = isWatchlisted ? "Added to Watchlist" : "Removed from Watchlist"
        })
    }
}

private struct TVQuickViewArtwork: View {
    let background: String?
    let poster: String?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if TVCinemaArtworkPolicy.fillsFrame(pixelWidth: Double(image.size.width), pixelHeight: Double(image.size.height)) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 26).opacity(0.55)
                        .overlay(Color.black.opacity(0.35))
                        .overlay(Image(uiImage: image).resizable().aspectRatio(contentMode: .fit))
                }
            } else {
                Theme.Palette.surface2.overlay {
                    if failed { Image(systemName: "film").font(.system(size: 40)) }
                    else { ProgressView().tint(Theme.Palette.textTertiary) }
                }
            }
        }
        .frame(width: 420, height: 236).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .task(id: [background ?? "", poster ?? ""]) {
            image = nil; failed = false
            for raw in [background, poster].compactMap({ $0 }) where !raw.isEmpty {
                if let loaded = await PosterImageLoader.load(raw, maxPixel: 1280) {
                    guard !Task.isCancelled else { return }
                    image = loaded; return
                }
                guard !Task.isCancelled else { return }
            }
            failed = true
        }
    }
}
