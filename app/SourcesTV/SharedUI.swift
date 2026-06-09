import SwiftUI
import UIKit

/// Shared, system-aligned building blocks: the poster artwork, the focusable poster card used by every
/// rail and grid, and the empty / not-signed-in state. See Theme.swift for the tokens these use.

/// Standard poster width across the app. Posters are 2:3, so height is `width * 1.5`.
let kPosterWidth: CGFloat = 200

/// In-memory poster cache, on top of the shared URLCache (disk). Decoded images, evicted under memory
/// pressure. Keyed by URL so a poster shown in several rails decodes once.
private let posterMemoryCache: NSCache<NSURL, UIImage> = {
    let c = NSCache<NSURL, UIImage>(); c.countLimit = 400; return c
}()

/// Poster artwork with a warm placeholder and the system card radius. Not focusable on its own;
/// `PosterCard` wraps it in the focusable button.
///
/// Loads via `.task` + a memory/disk cache rather than `AsyncImage`. `AsyncImage` keeps no cache and
/// cancels in-flight requests during the appear transition without retrying, which left the
/// first (above-the-fold) rails blank on device; a `.task`-driven load re-runs on the next appear and
/// hits the cache instantly.
struct PosterArt: View {
    let poster: String?
    var width: CGFloat = kPosterWidth
    @State private var image: UIImage?
    @State private var failed = false
    init(_ poster: String?, width: CGFloat = kPosterWidth) { self.poster = poster; self.width = width }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                Theme.Palette.surface2.overlay(
                    Image(systemName: "film").font(.system(size: 40)).foregroundStyle(Theme.Palette.textTertiary)
                )
            } else {
                Theme.Palette.surface2.overlay(ProgressView().tint(Theme.Palette.textTertiary))
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task(id: poster) { await load() }
    }

    private func load() async {
        guard let raw = poster, let url = URL(string: raw) else { failed = true; return }   // no poster → film placeholder
        if let cached = posterMemoryCache.object(forKey: url as NSURL) { image = cached; return }   // instant, no flash
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad   // posters are immutable: prefer the shared disk cache
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            if let img = UIImage(data: data) {
                posterMemoryCache.setObject(img, forKey: url as NSURL)
                image = img
            } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }   // a cancel (scrolled away) is not a failure; the next appear retries
        }
    }
}

/// Which long-press (context) menu a `PosterCard` shows. `.continueWatching` offers a dismiss; `.catalog`
/// offers add-to-library plus mark watched / unwatched; `.library` swaps add for remove-from-library;
/// `.none` attaches no menu at all.
enum PosterMenu { case none, continueWatching, catalog, library }

/// The focusable poster + title used in every rail and grid. Navigates to the detail page; crafted
/// focus (scale + ember glow + lift) comes from `CardFocusStyle`. Optional progress stripe for
/// in-progress titles.
struct PosterCard: View {
    let title: String
    let poster: String?
    let type: String
    let id: String
    var progress: Double? = nil
    var width: CGFloat = kPosterWidth
    var menu: PosterMenu = .none

    var body: some View {
        if menu == .none {
            cardLink
        } else {
            cardLink.contextMenu { menuItems }
        }
    }

    private var cardLink: some View {
        NavigationLink {
            DetailView(type: type, id: id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                PosterArt(poster, width: width)
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0.01 {
                            ProgressStripe(value: progress).padding(Theme.Space.xs)
                        }
                    }
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(CardFocusStyle())
    }

    /// Long-press actions, fired straight at the engine (`CoreBridge.shared`). Continue Watching and the
    /// catalogs both refresh on their own when the engine re-emits the affected fields.
    @ViewBuilder private var menuItems: some View {
        switch menu {
        case .none:
            EmptyView()
        case .continueWatching:
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        case .catalog:
            Button {
                CoreBridge.shared.addToLibrary(metaId: id)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
        case .library:
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

/// A thin resume-progress bar that sits at the bottom of a poster.
struct ProgressStripe: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55))
                Capsule().fill(Theme.Palette.accent).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// A centered empty / not-signed-in / error state: an icon, a title, and a short line.
/// Used instead of an endless spinner when there is genuinely nothing to show.
struct CoreEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.screenEdge)
    }

    /// The standard "you are not signed in" state, shown on the main tabs.
    static var signedOut: CoreEmptyState {
        CoreEmptyState(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "Sign in to get started",
            message: "Open the Settings tab and sign in to your Stremio account to load your library, catalogs, and add-ons."
        )
    }
}
