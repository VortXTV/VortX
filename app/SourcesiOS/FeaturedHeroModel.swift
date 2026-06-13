import SwiftUI

/// The interactive featured hero's per-screen model — the touch/Mac analogue of the tvOS
/// `FocusedItemModel`, adapted for a focus-less platform. Where tvOS tracks the *focused* card,
/// touch has two layered behaviours instead:
///
///   1. **Auto-rotate** (ambient, Netflix/Disney+ style): a small randomized pool of featured
///      candidates (the top items of the screen) cross-fades every `heroRotateInterval`.
///   2. **Click-to-feature** (override): tapping a poster pins it as the featured hero and PAUSES
///      rotation; tapping the already-featured poster (or the hero's Play button) opens its detail.
///
/// Each featured item is enriched with logo + trailer + synopsis through a SELF-CONTAINED meta
/// fetch (Cinemeta + installed meta add-ons), replicating the tvOS enrichment but kept entirely
/// inside SourcesiOS so the tvOS target is untouched. Enrichment is cached by id so re-showing a
/// title (rotation looping, or returning to the screen) is instant.
@MainActor
final class FeaturedHeroModel: ObservableObject {
    /// The item currently filling the hero (seed-grade until enrichment lands, then upgraded in place).
    @Published private(set) var hero: FeaturedHeroItem?
    /// True once the user has pinned a pick; rotation stays paused until the screen reseeds.
    @Published private(set) var isUserFeatured = false

    /// Auto-advance cadence. The user asked for "every 3 seconds or something"; we lean slightly above
    /// 3s so a reader can take in the title + synopsis before the cross-fade.
    static let heroRotateInterval: Duration = .seconds(3.5)
    /// Cross-fade duration for the backdrop + overlay swap.
    static let heroCrossfade: Double = 0.45
    /// How many candidates the rotating pool holds at most.
    static let heroPoolCap = 5

    /// Dwell before the muted trailer autoplay fades in once the hero settles on a title that has a
    /// trailer. Long enough that fast rotating/tapping through items never starts a stale player
    /// (the dwell timer is cancelled the instant the featured item changes), short enough to feel
    /// like Netflix's ambient preview.
    static let trailerAutoplayDwell: Duration = .seconds(1.3)
    /// If the embed hasn't reported that it began loading within this window after it mounts, treat
    /// it as a failure and silently drop the autoplay layer back to the still backdrop.
    static let trailerAutoplayLoadTimeout: Duration = .seconds(6)
    /// Cross-fade for the autoplay layer fading in over the still backdrop.
    static let trailerAutoplayFade: Double = 0.6

    /// The randomized rotation pool (seed-grade items; each is enriched lazily when shown).
    private var pool: [FeaturedHeroItem] = []
    private var rotationIndex = 0
    private var rotationTask: Task<Void, Never>?

    /// Whether motion (auto-rotate + cross-fade) is allowed. Driven by the view's
    /// `accessibilityReduceMotion`; when false, the hero shows a single static featured item.
    private var motionEnabled = true

    /// Session-wide enrichment cache (logo + trailer + synopsis + better art), keyed by id, shared
    /// across all three screens' models so a title enriched on Home is instant on Discover.
    private static var enrichmentCache: [String: FeaturedHeroItem] = [:]

    /// Base URLs of installed meta-serving add-ons, walked for enrichment the way the engine would
    /// (Cinemeta first for `tt` ids, then every installed meta add-on for tmdb:/tvdb:/kitsu: ids).
    private static var metaSourceBases: [String] = []

    /// Configure the meta-enrichment sources from the installed add-ons. Accepts raw transport URLs
    /// (".../manifest.json"); only add-ons that actually serve `meta` are kept.
    static func configureMetaSources(_ addons: [CoreDescriptor]) {
        metaSourceBases = addons
            .filter { $0.providesMeta }
            .map { url -> String in
                let t = url.transportUrl
                return t.hasSuffix("manifest.json") ? String(t.dropLast("manifest.json".count)) : t
            }
    }

    // MARK: Seeding + rotation

    /// (Re)seed the rotation pool from a screen's top items, randomize order, and start auto-rotating.
    /// Idempotent for the same pool: if the candidate ids are unchanged we keep the current hero and
    /// timer running, so a routine engine re-emit (revision bump) never resets the rotation or yanks
    /// the backdrop out from under the viewer.
    func seed(_ candidates: [FeaturedHeroItem], reduceMotion: Bool) {
        motionEnabled = !reduceMotion
        let capped = Array(candidates.prefix(Self.heroPoolCap))
        // An empty pool means the screen has no content (e.g. after sign-out clears the rows). Clear
        // the hero and halt rotation so a stale featured title — with a working Play button — can't
        // linger. Home renders the hero unconditionally, so without this it would keep cycling
        // stale data; Discover/Library already gate on content but benefit from the cleanup too.
        guard !capped.isEmpty else {
            stop()
            pool = []
            rotationIndex = 0
            isUserFeatured = false
            hero = nil
            return
        }

        let newIds = capped.map(\.id)
        if newIds == pool.map(\.id) && hero != nil { return }   // same screen content → don't churn

        pool = capped.shuffled()
        rotationIndex = 0
        isUserFeatured = false
        show(pool[rotationIndex], animated: false)
        startRotation()
    }

    /// Kick off (or restart) the auto-advance loop. No-op when motion is disabled, the pool has a
    /// single item, or the user has pinned a pick.
    private func startRotation() {
        rotationTask?.cancel()
        guard motionEnabled, pool.count > 1, !isUserFeatured else { return }
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heroRotateInterval)
                guard !Task.isCancelled else { return }
                await self?.advance()
            }
        }
    }

    private func advance() {
        guard motionEnabled, pool.count > 1, !isUserFeatured else { return }
        rotationIndex = (rotationIndex + 1) % pool.count
        show(pool[rotationIndex], animated: true)
    }

    /// Stop the timer when the screen disappears (re-armed on the next `seed`).
    func stop() {
        rotationTask?.cancel()
        rotationTask = nil
    }

    // MARK: Click-to-feature

    /// User tapped a poster: pin it as the featured hero and PAUSE rotation. Returns `true` when this
    /// is a *new* pick (caller stays on the screen); `false` when the tapped item is ALREADY featured
    /// (the caller should open detail — the second-tap / Play-button "open" path).
    @discardableResult
    func feature(_ item: FeaturedHeroItem) -> Bool {
        if let hero, hero.id == item.id {
            return false   // already featured → caller opens detail
        }
        isUserFeatured = true
        stop()
        show(item, animated: motionEnabled)
        return true
    }

    /// Whether the given id is the one currently filling the hero (drives the poster "featured" ring).
    func isFeatured(_ id: String) -> Bool { hero?.id == id }

    // MARK: Showing + enrichment

    /// Swap the hero to `item`, upgrading to the cached enriched version when available, and kick off
    /// a background enrichment fetch when it isn't.
    private func show(_ item: FeaturedHeroItem, animated: Bool) {
        let resolved = Self.enrichmentCache[item.id] ?? item
        if animated && motionEnabled {
            withAnimation(.easeOut(duration: Self.heroCrossfade)) { hero = resolved }
        } else {
            hero = resolved
        }
        enrichIfNeeded(item)
    }

    /// Fill in logo / trailer / synopsis / rating / year / runtime / genres (and better 16:9 art) for
    /// a seed-grade item by fetching its meta from Cinemeta + the installed meta add-ons. Cached to
    /// the session cache; applied live only if the title is still the one on screen. Self-contained
    /// (no dependency on the tvOS `FocusedItemModel`), so tvOS is untouched.
    private func enrichIfNeeded(_ item: FeaturedHeroItem) {
        guard Self.enrichmentCache[item.id] == nil else { return }
        let candidates = Self.metaURLs(for: item)
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
                      meta.description != nil || meta.background != nil || meta.logo != nil else { continue }
                let enriched = item.enriched(with: meta)
                await MainActor.run {
                    Self.enrichmentCache[item.id] = enriched
                    guard let self, self.hero?.id == item.id else { return }
                    // No animation here: this is an in-place content upgrade of the SAME hero, not a
                    // swap, so cross-fading would flicker the already-visible backdrop.
                    self.hero = enriched
                }
                return
            }
        }
    }

    /// Meta endpoints to try, in priority order: Cinemeta for IMDB ids, then every installed meta
    /// add-on (covers tmdb:/tvdb:/kitsu: id schemes).
    private static func metaURLs(for item: FeaturedHeroItem) -> [URL] {
        var bases = metaSourceBases
        if item.id.hasPrefix("tt") { bases.insert("https://v3-cinemeta.strem.io/", at: 0) }
        // De-dupe while preserving order (Cinemeta may also be in the installed list).
        var seen = Set<String>()
        return bases
            .filter { seen.insert($0).inserted }
            .compactMap { URL(string: "\($0)meta/\(item.type)/\(item.id).json") }
    }
}

// MARK: - The hero's data model

/// One featured title for the touch/Mac hero. Built seed-grade from the sparse catalog/library data a
/// screen already has, then upgraded in place once enrichment resolves logo + trailer + synopsis.
/// `Hashable` so it can drive a `NavigationStack(path:)` route to the detail page.
struct FeaturedHeroItem: Identifiable, Equatable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let backdrop: String?       // 16:9 art (catalog `background`, else metahub by IMDB id, else poster)
    let logo: String?           // add-on logo, present only after enrichment
    let description: String?
    let releaseInfo: String?    // year
    let runtime: String?
    let imdbRating: String?
    let genres: [String]
    /// The first trailer's YouTube id, surfaced by enrichment. Nil until (and unless) a fetched meta
    /// carries a trailer; drives the hero's Trailer chip.
    let trailerYouTubeID: String?

    /// Standard Stremio 16:9 background art for an IMDB-identified title (mirrors the tvOS helper).
    static func metahubBackground(forId id: String) -> String? {
        guard id.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/background/big/\(id)/img"
    }

    /// Seed from a catalog meta (carries its own `background` + preview fields when the add-on filled
    /// them; falls back to metahub-by-IMDB / poster otherwise).
    static func from(meta: CoreMeta) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: meta.id, type: meta.type, name: meta.name, poster: meta.poster,
            backdrop: meta.background ?? metahubBackground(forId: meta.id) ?? meta.poster,
            logo: nil, description: meta.description, releaseInfo: meta.releaseInfo,
            runtime: nil, imdbRating: meta.imdbRating, genres: meta.genres ?? [],
            trailerYouTubeID: nil)
    }

    /// Seed from a Continue Watching / library entry, which carries only a poster: real 16:9 art comes
    /// from metahub for IMDB ids, falling back to the poster (mirrors tvOS `CoreCWItem.focusedHero`).
    static func from(cw: CoreCWItem) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: cw.id, type: cw.type, name: cw.name, poster: cw.poster,
            backdrop: metahubBackground(forId: cw.id) ?? cw.poster,
            logo: nil, description: nil, releaseInfo: nil,
            runtime: nil, imdbRating: nil, genres: [],
            trailerYouTubeID: nil)
    }

    /// Build from the lightweight `RailItem` carried through the rails/grid (so a tapped card can pin
    /// the hero immediately, before any fetch). `RailItem` now carries the catalog preview fields.
    static func from(rail: RailItem) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: rail.id, type: rail.type, name: rail.name, poster: rail.poster,
            backdrop: rail.background ?? metahubBackground(forId: rail.id) ?? rail.poster,
            logo: nil, description: rail.description, releaseInfo: rail.releaseInfo,
            runtime: nil, imdbRating: rail.imdbRating, genres: rail.genres ?? [],
            trailerYouTubeID: nil)
    }

    /// Return a copy upgraded with a fetched add-on meta response (keeps existing seed values when the
    /// response omits a field).
    func enriched(with meta: AddonMetaResponse.Meta) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: id, type: type, name: name, poster: poster,
            backdrop: meta.background ?? backdrop,
            logo: meta.logo ?? logo,
            description: meta.description ?? description,
            releaseInfo: meta.releaseInfo ?? releaseInfo,
            runtime: meta.runtime ?? runtime,
            imdbRating: meta.imdbRating ?? imdbRating,
            genres: (meta.genres?.isEmpty == false) ? meta.genres! : genres,
            trailerYouTubeID: meta.trailerYouTubeID ?? trailerYouTubeID)
    }
}

// MARK: - The Stremio add-on meta response

/// The add-on protocol's meta response — the fields the hero uses. Self-contained copy (the tvOS one
/// in SharedUI.swift is tvOS-only + private), extended with `logo` + `trailerStreams` so the touch
/// hero can surface the editorial logo and the Trailer chip. Same JSON shape for Cinemeta and every
/// catalog add-on.
struct AddonMetaResponse: Decodable {
    struct Meta: Decodable {
        let description: String?
        let imdbRating: String?
        let releaseInfo: String?
        let background: String?
        let runtime: String?
        let genres: [String]?
        let logo: String?
        let trailerStreams: [TrailerStream]?

        /// First trailer's YouTube id, if the meta carries one (`trailerStreams[].ytId`).
        var trailerYouTubeID: String? {
            (trailerStreams ?? []).compactMap(\.ytId).first { !$0.isEmpty }
        }
    }

    /// A single trailer stream entry; we only read its YouTube id.
    struct TrailerStream: Decodable {
        let ytId: String?
    }

    let meta: Meta?
}
