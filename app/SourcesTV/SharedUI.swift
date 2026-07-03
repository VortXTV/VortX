import SwiftUI
import UIKit

/// Shared, system-aligned building blocks: the poster artwork, the focusable poster card used by every
/// rail and grid, and the empty / not-signed-in state. See Theme.swift for the tokens these use.

/// Standard poster width across the app. Posters are 2:3, so height is `width * 1.5`.
let kPosterWidth: CGFloat = 200

/// Standard LANDSCAPE catalog-card width on tvOS (16:9, so height = width * 9 / 16 ~= 219pt, shorter than
/// the 300pt poster height, so each rail reads as a cinematic stripe while shrinking vertically).
let kLandscapeCardWidth: CGFloat = 390

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

// MARK: - Focused hero (the browse pages' living backdrop)

/// What the browse pages show behind the rails for the title under focus.
struct FocusedHero: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let type: String
    let title: String
    let backdrop: String?     // background art, falling back to the poster
    let metaLine: String      // prebuilt "2026 · ★ 7.6 · Movie" style line
    let overview: String?
    var genreLine: String?    // "Drama · Fantasy · Adventure" (optional so older caches decode)
    var logo: String?         // clearlogo URL (add-on meta.logo or metahub); optional so older caches decode
}

/// The standard Stremio background art for an IMDB-identified title: real 16:9 backdrop art at
/// screen resolution, instead of a portrait poster stretched across the TV.
private func metahubBackground(for id: String) -> String? {
    guard id.hasPrefix("tt") else { return nil }
    return "https://images.metahub.space/background/big/\(id)/img"
}

/// The standard Stremio clearlogo (transparent PNG) for an IMDB-identified title, mirroring the iOS hero
/// seed. Only `tt` ids have metahub art; other id schemes fall back to the add-on `meta.logo` via enrichment.
private func metahubLogo(for id: String) -> String? {
    guard id.hasPrefix("tt") else { return nil }
    return "https://images.metahub.space/logo/medium/\(id)/img"
}

extension CoreMeta {
    var focusedHero: FocusedHero {
        var parts: [String] = []
        if let releaseInfo, !releaseInfo.isEmpty { parts.append(releaseInfo) }
        if let imdbRating, !imdbRating.isEmpty { parts.append("★ \(imdbRating)") }
        parts.append(type.capitalized)
        let genreLine = (genres?.isEmpty == false) ? genres!.prefix(3).joined(separator: " · ") : nil
        return FocusedHero(id: id, type: type, title: name,
                           backdrop: background ?? metahubBackground(for: id) ?? poster,
                           metaLine: parts.joined(separator: "  ·  "), overview: description,
                           genreLine: genreLine, logo: logo ?? metahubLogo(for: id))
    }
}

extension CoreCWItem {
    /// Library entries carry no backdrop or synopsis; real backdrop art comes from metahub and the
    /// synopsis/rating arrive via the model's Cinemeta enrichment a beat later.
    var focusedHero: FocusedHero {
        let pct = Int((progress * 100).rounded())
        let line = pct > 0 ? "\(type.capitalized)  ·  \(pct)% watched" : type.capitalized
        return FocusedHero(id: id, type: type, title: name,
                           backdrop: metahubBackground(for: id) ?? poster,
                           metaLine: line, overview: nil, genreLine: nil, logo: metahubLogo(for: id))
    }
}

/// Per-page model for the focused hero. Focus changes are debounced so flicking along a rail
/// settles before the backdrop crossfades, and the rails themselves never rebuild (no `.id`),
/// so tvOS focus is never dropped. Heroes without a synopsis (library entries) are enriched from
/// Cinemeta in the background, once per title per session.
@MainActor final class FocusedItemModel: ObservableObject {
    @Published private(set) var hero: FocusedHero?
    /// The text block shows only while focus is in the page's TOP row; deeper rows keep just the
    /// backdrop art, so the details can never collide with content that scrolled up.
    @Published private(set) var detailsVisible = true
    private var pending: Task<Void, Never>?
    private static var enrichmentCache: [String: FocusedHero] = [:]   // session-wide, across pages

    func focus(_ hero: FocusedHero, showsDetails: Bool = true) {
        if hero == self.hero {
            if detailsVisible != showsDetails { detailsVisible = showsDetails }
            return
        }
        pending?.cancel()
        let resolved = Self.resolve(hero)
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.hero = resolved
            self?.detailsVisible = showsDetails
            self?.enrichIfNeeded(resolved)
        }
    }

    /// First render: show something immediately instead of an empty canvas.
    func seedIfEmpty(_ hero: FocusedHero?) {
        guard self.hero == nil, let hero else { return }
        self.hero = Self.resolve(hero)
        detailsVisible = true
        enrichIfNeeded(self.hero ?? hero)
    }

    /// The cached (detail-page-grade) hero when we have one, keeping the live progress tail
    /// ("62% watched") from the incoming library hero.
    private static func resolve(_ hero: FocusedHero) -> FocusedHero {
        loadCacheIfNeeded()
        guard let cached = enrichmentCache[hero.id] else { return hero }
        let watchedTail = hero.metaLine.components(separatedBy: "  ·  ").first { $0.hasSuffix("% watched") }
        let line = watchedTail.map { "\(cached.metaLine)  ·  \($0)" } ?? cached.metaLine
        return FocusedHero(id: hero.id, type: hero.type, title: hero.title,
                           backdrop: cached.backdrop ?? hero.backdrop,
                           metaLine: line, overview: cached.overview ?? hero.overview,
                           genreLine: cached.genreLine ?? hero.genreLine,
                           logo: cached.logo ?? hero.logo)
    }

    /// Capture what the detail page knows (the engine resolves EVERY id scheme, tmdb: included), so
    /// any title you have opened shows its real backdrop, rating, and synopsis in the hero forever.
    static func noteMeta(id: String, type: String, title: String, backdrop: String?,
                         releaseInfo: String?, imdbRating: String?, runtime: String?,
                         overview: String?, genres: [String]?) {
        loadCacheIfNeeded()
        var parts: [String] = []
        if let releaseInfo, !releaseInfo.isEmpty { parts.append(releaseInfo) }
        if let imdbRating, !imdbRating.isEmpty { parts.append("★ \(imdbRating)") }
        if let runtime, !runtime.isEmpty { parts.append(runtime) }
        parts.append(type.capitalized)
        let genreLine = (genres?.isEmpty == false) ? genres!.prefix(3).joined(separator: " · ") : nil
        let hero = FocusedHero(id: id, type: type, title: title, backdrop: backdrop,
                               metaLine: parts.joined(separator: "  ·  "), overview: overview,
                               genreLine: genreLine, logo: metahubLogo(for: id))
        guard enrichmentCache[id] != hero else { return }
        enrichmentCache[id] = hero
        saveCache()
    }

    // MARK: persistence (survives relaunch, so heroes stay rich without re-opening titles)

    private static var cacheLoaded = false
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hero-cache.json")
    }

    private static func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: FocusedHero].self, from: data) {
            enrichmentCache = decoded
        }
    }

    private static func saveCache() {
        if let data = try? JSONEncoder().encode(enrichmentCache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// Base URLs of installed add-ons that serve metas. The enrichment walks these the way the
    /// engine would, so every id scheme works (tt via Cinemeta, tmdb:/tvdb: via their add-ons).
    private static var metaSourceBases: [String] = []

    /// Call whenever the installed add-ons change. Accepts raw transport URLs (.../manifest.json).
    static func configureMetaSources(transportUrls: [String]) {
        metaSourceBases = transportUrls.map { url in
            url.hasSuffix("manifest.json") ? String(url.dropLast("manifest.json".count)) : url
        }
    }

    /// Pre-fetch details for rail items (Continue Watching especially) so the hero is already rich
    /// the moment a card takes focus.
    func warm(_ heroes: [FocusedHero]) {
        Self.loadCacheIfNeeded()
        for hero in heroes.prefix(15) { enrichIfNeeded(hero, apply: false) }
    }

    /// Fill in synopsis / rating / year / genres (and better art) for heroes that came from sparse
    /// library data. Tries Cinemeta for IMDB ids, then every meta-serving add-on the user has
    /// installed. Cached to disk; applied live only if the title is still focused.
    private func enrichIfNeeded(_ hero: FocusedHero, apply: Bool = true) {
        Self.loadCacheIfNeeded()
        guard hero.overview == nil, Self.enrichmentCache[hero.id] == nil else { return }
        let candidates = Self.metaURLs(for: hero)
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            for url in candidates {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                request.cachePolicy = .returnCacheDataElseLoad
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let decoded = try? JSONDecoder().decode(AddonMetaResponse.self, from: data),
                      let meta = decoded.meta,
                      meta.description != nil || meta.background != nil else { continue }
                var parts: [String] = []
                if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
                if let rating = meta.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
                if let runtime = meta.runtime, !runtime.isEmpty { parts.append(runtime) }
                // Keep the type, but drop any progress tail: it is stale by the next read, and
                // resolve() re-attaches the live one.
                let stableTail = hero.metaLine.components(separatedBy: "  ·  ")
                    .filter { !$0.hasSuffix("% watched") }.joined(separator: "  ·  ")
                if !stableTail.isEmpty { parts.append(stableTail) }
                let genreLine = (meta.genres?.isEmpty == false)
                    ? meta.genres!.prefix(3).joined(separator: " · ") : nil
                let enriched = FocusedHero(id: hero.id, type: hero.type, title: hero.title,
                                           backdrop: meta.background ?? hero.backdrop,
                                           metaLine: parts.joined(separator: "  ·  "),
                                           overview: meta.description, genreLine: genreLine,
                                           logo: meta.logo ?? hero.logo)
                await MainActor.run {
                    Self.enrichmentCache[hero.id] = enriched
                    Self.saveCache()
                    guard apply, let self, self.hero?.id == hero.id else { return }
                    self.hero = Self.resolve(hero)   // re-resolve so the live progress tail merges in
                }
                return
            }
        }
    }

    private static func metaURLs(for hero: FocusedHero) -> [URL] {
        var bases = metaSourceBases
        if hero.id.hasPrefix("tt") { bases.insert("https://v3-cinemeta.strem.io/", at: 0) }
        return bases.compactMap { URL(string: "\($0)meta/\(hero.type)/\(hero.id).json") }
    }
}

/// The Stremio add-on protocol's meta response, the fields the hero uses. Same shape for
/// Cinemeta and every catalog add-on.
private struct AddonMetaResponse: Decodable {
    struct Meta: Decodable {
        let description: String?
        let imdbRating: String?
        let releaseInfo: String?
        let background: String?
        let runtime: String?
        let genres: [String]?
        let logo: String?
    }
    let meta: Meta?
}

/// Invisible focus probe placed inside a focusable button's label: `isFocused` from the
/// environment reflects the button's focus (the documented tvOS pattern), and the callback
/// fires on gain only.
struct FocusReporter: View {
    @Environment(\.isFocused) private var isFocused
    let onFocus: () -> Void
    var body: some View {
        Color.clear.onChange(of: isFocused) { if isFocused { onFocus() } }
    }
}

extension View {
    /// Cages a browse page's scrolling content in a bottom strip. The focus engine centers focused
    /// rows inside THIS viewport, so they are geometrically incapable of riding up over the hero;
    /// rows leaving the strip fade out at its top edge instead of clipping hard.
    func heroBottomStrip(height: CGFloat = 470) -> some View {
        mask(VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 50)
            Color.black
        })
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The browse pages' background layer: the focused title's artwork at full bleed with a detail
/// block (title, meta line, synopsis) on the upper-left band. Content scrolls over it.
struct BrowseHeroBackdrop: View {
    @ObservedObject var model: FocusedItemModel
    var detailsTop: CGFloat = 90   // Home: just under the tab bar; grid pages: below their chips
    /// When set, the block's BOTTOM is pinned this far above the container's bottom edge instead of
    /// using `detailsTop`. The rails strip anchors to the same edge, so the two can never collide
    /// even as the tab bar shows or hides and shifts the top safe area.
    var detailsBottom: CGFloat? = nil
    @EnvironmentObject private var theme: ThemeManager
    /// The focused title's clean TMDB clearlogo (textless PNG), resolved by id like the landscape cards.
    /// nil until it resolves (or when TMDB has none / no key) - the title then falls back to styled text.
    @State private var heroLogo: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.Palette.canvas.ignoresSafeArea()
            if let hero = model.hero {
                FullBleedBackdrop(url: hero.backdrop)
                    .id(hero.id)
                    .transition(.opacity)
                if model.detailsVisible {
                    positioned(detailsBlock(hero)
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(.leading, Theme.Space.screenEdge))
                        .id("details-\(hero.id)")
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.hero?.id)
        .animation(.easeOut(duration: 0.25), value: model.detailsVisible)
        // Resolve the focused title's clearlogo by id (TMDB, same source as the landscape cards) so the
        // hero shows the logo in place of the serif title text, matching the iOS/Mac hero. Re-runs per hero.
        .task(id: model.hero?.id) { await loadHeroLogo() }
        // No ignoresSafeArea here: the image layer handles its own full-bleed, and keeping this
        // container inside the safe area lets the tab bar reclaim focus when you press up at the top.
    }

    @ViewBuilder private func positioned<Content: View>(_ content: Content) -> some View {
        if let detailsBottom {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, detailsBottom)
        } else {
            content.padding(.top, detailsTop)
        }
    }

    /// Editorial rhythm: a tight title-meta pairing, then air before the synopsis, so the block
    /// reads as one composed unit instead of evenly stacked lines.
    private func detailsBlock(_ hero: FocusedHero) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heroLogo {
                // The clearlogo IS the title in image form; expose the name to VoiceOver, not the art.
                Image(uiImage: heroLogo).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 540, maxHeight: 180, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    .accessibilityLabel(hero.title)
            } else {
                Text(hero.title)
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            }
            Text(hero.metaLine)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, 14)
            if let genres = hero.genreLine {
                Text(genres)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, 6)
            }
            if let overview = hero.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3).lineSpacing(5)
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(.top, 18)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    /// Resolve + load the focused hero's clearlogo. Resets immediately on every hero change so the title
    /// text shows at once, then swaps to the logo when it resolves (nil = TMDB has none / no key = text stays).
    private func loadHeroLogo() async {
        heroLogo = nil
        guard let hero = model.hero else { return }
        // fanart.tv clearlogo first (when enabled), else the ERDB-aware add-on/metahub logo. Both fail-soft.
        let resolved = await Fanart.logo(id: hero.id, type: hero.type)
            ?? PosterArtwork.logo(id: hero.id, fallback: hero.logo ?? metahubLogo(for: hero.id))
        guard let lg = resolved, let img = await fetchHeroImage(lg) else { return }
        heroLogo = img
    }

    private func fetchHeroImage(_ raw: String) async -> UIImage? {
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        if let cached = posterMemoryCache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad   // art is immutable: prefer the shared disk cache
        guard let (data, _) = try? await URLSession.shared.data(for: req), !Task.isCancelled,
              let img = UIImage(data: data) else { return nil }
        posterMemoryCache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// Cinematic LANDSCAPE artwork for a catalog card: a 16:9 cell filled with the title's CLEAN TMDB backdrop
/// (textless, no rating overlay), resolved by id via `LandscapeBackdropCache`. With no TMDB backdrop (no key
/// set, or none on TMDB) it does NOT crop a 2:3 poster into an ugly slab: it fills with a heavily blurred +
/// darkened copy of the poster and lays the poster fit/centered on top, so the 16:9 frame always looks
/// intentional. The add-on `meta.background` is deliberately NOT used (it is frequently a 2:3 poster URL, the
/// source of the cropped art that got the first landscape attempt reverted). Same cached loader as `PosterArt`.
struct LandscapeArt: View {
    let id: String?
    let type: String
    let title: String
    let poster: String?
    var width: CGFloat = kLandscapeCardWidth
    @State private var image: UIImage?
    @State private var logo: UIImage?
    @State private var usedBackdrop = false
    @State private var failed = false

    private var height: CGFloat { (width * 9 / 16).rounded() }

    var body: some View {
        Group {
            if let image {
                if usedBackdrop {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .overlay { titleLayer }
                } else {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 26).opacity(0.55)
                        .overlay(Color.black.opacity(0.35))
                        .overlay(Image(uiImage: image).resizable().aspectRatio(contentMode: .fit))
                }
            } else if failed {
                Theme.Palette.surface2.overlay(
                    Image(systemName: "film").font(.system(size: 40)).foregroundStyle(Theme.Palette.textTertiary)
                )
            } else {
                Theme.Palette.surface2.overlay(ProgressView().tint(Theme.Palette.textTertiary))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task(id: id ?? poster ?? "") { await load() }
    }

    /// The title ON the cinematic backdrop: the title's clean TMDB clearlogo when one resolves, else the
    /// title as styled text, both over a bottom scrim so they read on any backdrop.
    @ViewBuilder private var titleLayer: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            if let logo {
                Image(uiImage: logo).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width * 0.6, maxHeight: height * 0.42, alignment: .bottomLeading)
                    .padding(Theme.Space.md)
            } else {
                Text(title)
                    .font(.system(size: 22, weight: .bold)).lineLimit(2)
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    .padding(Theme.Space.md)
            }
        }
    }

    private func load() async {
        image = nil; logo = nil; usedBackdrop = false; failed = false
        // Clean TMDB textless 16:9 backdrop (cached by id). Only a real backdrop fills the cell.
        if let id, let bd = await LandscapeBackdropCache.backdrop(id: id, type: type), let img = await fetch(bd) {
            image = img; usedBackdrop = true
            // Title overlay: prefer the clearlogo (PNG); titleLayer falls back to text when nil.
            if let lg = await LandscapeBackdropCache.logo(id: id, type: type) { logo = await fetch(lg) }
            return
        }
        // No TMDB backdrop: composite the poster (blurred fill behind a fit copy), never an ugly 2:3 crop.
        if let img = await fetch(poster) { image = img; usedBackdrop = false; return }
        failed = true
    }

    private func fetch(_ raw: String?) async -> UIImage? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        if let cached = posterMemoryCache.object(forKey: url as NSURL) { return cached }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad   // art is immutable: prefer the shared disk cache
        guard let (data, _) = try? await URLSession.shared.data(for: req), !Task.isCancelled,
              let img = UIImage(data: data) else { return nil }
        posterMemoryCache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// The focusable poster + title used in every rail and grid. Navigates to the detail page; crafted
/// focus (scale + ember glow + lift) comes from `CardFocusStyle`. Optional progress stripe for
/// in-progress titles.
struct PosterCard: View {
    let title: String
    let poster: String?
    let type: String
    let id: String
    var progress: Double? = nil
    /// The saved resume position in seconds, shown as a small "1:03" timecode badge on the poster
    /// (alongside the progress stripe) so Continue Watching cards say where playback resumes. Nil on
    /// every non-CW card, so their tiles are unchanged.
    var resumeSeconds: Double? = nil
    var width: CGFloat = kPosterWidth
    /// Explicit LANDSCAPE card width, for callers that lay cards into FIXED grid cells (TVCategoryBrowse's
    /// 4-across grid). Landscape mode ignores `width` (all rails share one cinematic width), so without
    /// this a fixed-cell grid rendered full-size landscape cards inside narrower cells and neighbouring
    /// tiles overlapped (#28). Nil = the rail-standard kLandscapeCardWidth.
    var landscapeWidth: CGFloat? = nil
    var menu: PosterMenu = .none
    var onFocus: (() -> Void)? = nil   // browse pages report focus to drive the hero backdrop
    var directPlay: (() -> Void)? = nil   // Continue Watching: resume the same link straight into the player
    var onDetails: (() -> Void)? = nil    // Continue Watching: open the full detail page from the long-press menu
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized title/poster override

    /// The title to show: the pooled localized title in the user's language when available, else the caller's.
    private var displayTitle: String { l10n.title(for: id) ?? title }
    /// The poster to show: the pooled localized (language-matched) poster when available, else the caller's.
    private var displayPoster: String? { l10n.poster(for: id) ?? poster }

    /// Cinematic 16:9 landscape pill vs legacy 2:3 portrait poster, per the Appearance setting. Gated on
    /// a TMDB key: without one every backdrop falls back to the blurred-poster composite, so keyless
    /// users keep the clean portrait grid until they add a key (Settings > API keys).
    private var landscape: Bool { catalogPrefs.landscapeCards && apiKeys.hasTMDB }
    /// Landscape cards use one cinematic width (or the caller's explicit grid-cell width); portrait
    /// cards honor the caller's `width`.
    private var cardWidth: CGFloat { landscape ? (landscapeWidth ?? kLandscapeCardWidth) : width }

    var body: some View {
        if menu == .none {
            cardLink
        } else {
            cardLink.contextMenu { menuItems }
        }
    }

    @ViewBuilder private var cardLink: some View {
        if let directPlay {
            Button(action: directPlay) { cardLabel }
                .buttonStyle(CardFocusStyle())
        } else {
            NavigationLink { DetailView(type: type, id: id) } label: { cardLabel }
                .buttonStyle(CardFocusStyle())
        }
    }

    private var cardLabel: some View {
        legacyCardLabel
    }

    private var legacyCardLabel: some View {
        Group {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Group {
                    if landscape {
                        LandscapeArt(id: id, type: type, title: displayTitle, poster: PosterArtwork.poster(id: id, fallback: displayPoster), width: cardWidth)
                    } else {
                        PosterArt(PosterArtwork.poster(id: id, fallback: displayPoster), width: cardWidth)
                    }
                }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0.01 {
                            ProgressStripe(value: progress).padding(Theme.Space.xs)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let resumeSeconds, let timecode = resumeTimecode(resumeSeconds) {
                            Text(timecode)
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(Theme.Space.sm)
                                .accessibilityLabel("Resumes at \(timecode)")
                        }
                    }
                Text(displayTitle)
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: cardWidth, alignment: .leading)
            }
            // Read the card as one element so VoiceOver says the title and the resume
            // timecode together, not a stray "1:03" after the title.
            .accessibilityElement(children: .combine)
            .background { if let onFocus { FocusReporter(onFocus: onFocus) } }
            // Pin the focus/long-press interaction region to the card's RESTING rect. Without this,
            // tvOS builds the context-menu preview from the focused card's scaled-up, shadow-offset
            // frame (see CardFocusStyle), which bleeds into the next rail and makes a long-press snap
            // focus to the row below instead of holding the card in place.
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// Long-press actions, fired straight at the engine (`CoreBridge.shared`). Continue Watching and the
    /// catalogs both refresh on their own when the engine re-emits the affected fields.
    @ViewBuilder private var menuItems: some View {
        switch menu {
        case .none:
            EmptyView()
        case .continueWatching:
            if let onDetails {
                Button(action: onDetails) {
                    Label("Details", systemImage: "info.circle")
                }
            }
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
    @EnvironmentObject private var theme: ThemeManager

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
    var showsSignInButton = false
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @State private var showingLogin = false

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
            if showsSignInButton {
                Button {
                    showingLogin = true
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, Theme.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.screenEdge)
        .fullScreenCover(isPresented: $showingLogin) {
            LoginView(account: account)
        }
    }

    /// The standard "you are not signed in" state, shown on the main tabs.
    static var signedOut: CoreEmptyState {
        CoreEmptyState(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "Sign in to get started",
            message: "Sign in to your Stremio account to load your library, catalogs, and add-ons.",
            showsSignInButton: true
        )
    }
}

/// The standard large accent spinner. controlSize(.large) does not exist in
/// older tvOS SDKs (the CI runner's Xcode fails on it), so the size comes from
/// a scale instead, which renders the same everywhere.
struct BigSpinner: View {
    var body: some View {
        ProgressView().scaleEffect(1.5).tint(Theme.Palette.accent)
    }
}
