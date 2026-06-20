import SwiftUI

/// The ambient billboard hero's per-screen model — the touch/Mac analogue of the tvOS
/// `FocusedItemModel`, adapted for a focus-less platform. Where tvOS tracks the *focused* card, touch
/// has no pointer to follow, so the hero is a SELF-DRIVEN ambient billboard (Netflix/Disney+ style):
///
///   - A small randomized pool of candidates (the top items of the screen) cross-fades every
///     `heroRotateInterval`, as a still backdrop with the Play + detail overlay.
///   - The hero is fully DECOUPLED from the catalog grid/rails: it does NOT auto-select, focus, or
///     ring any poster, and tapping a poster opens that title's detail through normal navigation —
///     it never "features" the tapped title in the hero.
///   - Rotation STOPS the moment the user interacts (scroll / hover / select) and resumes only after
///     a spell of inactivity (`heroResumeAfter`). Reduce Motion disables rotation entirely.
///
/// Each featured item is enriched with logo + trailer + synopsis through a SELF-CONTAINED meta
/// fetch (Cinemeta + installed meta add-ons), replicating the tvOS enrichment but kept entirely
/// inside SourcesiOS so the tvOS target is untouched. Continue-Watching seeds carry no catalog meta,
/// so this enrichment is what gives a CW hero its title/rating/year/genres/synopsis. Enrichment is
/// cached by id so re-showing a title (rotation looping, or returning to the screen) is instant.
@MainActor
final class FeaturedHeroModel: ObservableObject {
    /// The item currently filling the hero (seed-grade until enrichment lands, then upgraded in place).
    @Published private(set) var hero: FeaturedHeroItem?

    /// Ambient auto-advance cadence. ~7s so a reader can take in the title + synopsis before the
    /// cross-fade (issue #53; was 3.5s, which churned too fast).
    static let heroRotateInterval: Duration = .seconds(7)
    /// Cross-fade duration for the backdrop + overlay swap.
    static let heroCrossfade: Double = 0.45
    /// How many candidates the rotating pool holds at most.
    static let heroPoolCap = 5
    /// After the user interacts (scroll / hover / select), rotation pauses and only resumes once this
    /// much time has passed with no further interaction — so the billboard never yanks the page out
    /// from under someone who is reading or browsing.
    static let heroResumeAfter: Duration = .seconds(12)

    /// The randomized rotation pool (seed-grade items; each is enriched lazily when shown).
    private var pool: [FeaturedHeroItem] = []
    private var rotationIndex = 0
    private var rotationTask: Task<Void, Never>?

    /// Set while the user is actively interacting with the screen: the rotation loop holds the current
    /// item instead of advancing. A pending resume task clears it after `heroResumeAfter` of quiet.
    private var interactionHeld = false
    /// The debounced "resume rotation after inactivity" task; restarted on every interaction.
    private var resumeTask: Task<Void, Never>?

    /// Whether motion (auto-rotate + cross-fade) is allowed. Driven by the view's
    /// `accessibilityReduceMotion`; when false, the hero shows a single static featured item.
    private var motionEnabled = true

    /// Session-wide enrichment cache (logo + trailer + synopsis + better art), keyed by id, shared
    /// across all three screens' models so a title enriched on Home is instant on Discover.
    private static var enrichmentCache: [String: FeaturedHeroItem] = [:]

    /// Base URLs of installed meta-serving add-ons, walked for enrichment the way the engine would
    /// (Cinemeta first for `tt` ids, then every installed meta add-on for tmdb:/tvdb:/kitsu: ids).
    private static var metaSourceBases: [String] = []

    /// Ids with an enrichment fetch in flight, so the eager pool pre-fetch and the per-show fetch don't
    /// double-request the same title (apply-race / wasted round-trips). MainActor-isolated.
    private var enriching: Set<String> = []

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
            hero = nil
            return
        }

        let newIds = capped.map(\.id)
        if newIds == pool.map(\.id) && hero != nil {
            // Same screen content, so don't churn the pool or yank the backdrop. BUT a prior stop() (a tab
            // switch / disappear) cancels rotationTask, and this early-return used to leave it dead, so the
            // hero froze on one item when the screen reappeared with unchanged content (the "iOS hero stuck,
            // not rotating like Mac" report). Re-arm the timer if it isn't running.
            if rotationTask == nil { startRotation() }
            return
        }

        pool = capped.shuffled()
        rotationIndex = 0
        // Fresh content: drop any interaction hold carried over from the previous pool so it can't
        // suppress the new rotation.
        resumeTask?.cancel(); resumeTask = nil
        interactionHeld = false
        show(pool[rotationIndex], animated: false)
        startRotation()
        // Eagerly enrich the WHOLE pool now, not just the visible item. Continue-Watching seeds carry
        // only a name + poster, so a CW hero (e.g. Game of Thrones) showed bare — its enrichment used to
        // start only when it rotated in and often lost the apply-race against the ~7s rotation. Pre-fetching
        // every pool item means each is already cached (rating/year/genres/synopsis/logo) by the time it
        // appears, so the meta row is there on first show. The cache + in-flight guards de-dup the work.
        for item in pool { enrichIfNeeded(item) }
    }

    /// Kick off (or restart) the auto-advance loop. No-op when motion is disabled or the pool has a
    /// single item.
    private func startRotation() {
        rotationTask?.cancel()
        guard motionEnabled, pool.count > 1 else { return }
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heroRotateInterval)
                guard !Task.isCancelled else { return }
                await self?.advanceIfNotHeld()
            }
        }
    }

    /// One rotation tick: advance unless the user is currently interacting. While held we keep the
    /// timer alive (so the cadence resumes immediately once the inactivity window elapses) but leave
    /// the hero put.
    private func advanceIfNotHeld() {
        guard !interactionHeld else { return }
        advance()
    }

    private func advance() {
        guard motionEnabled, pool.count > 1 else { return }
        rotationIndex = (rotationIndex + 1) % pool.count
        show(pool[rotationIndex], animated: true)
    }

    /// Stop the timer when the screen disappears (re-armed on the next `seed`).
    func stop() {
        rotationTask?.cancel()
        rotationTask = nil
        // Drop any pending resume so a re-seed/disappear can't leave the loop pinned.
        resumeTask?.cancel(); resumeTask = nil
        interactionHeld = false
    }

    /// Feature a SPECIFIC item in the hero (macOS keyboard browse: the focused poster drives the hero, the
    /// touch analogue of the tvOS focused-card hero). Holds the ambient rotation while the user navigates so
    /// the billboard doesn't yank to a different title mid-browse; `noteInteraction()` (called when focus
    /// leaves the cards) re-arms the resume timer. Enriches the item so its meta row fills in like rotation.
    func feature(_ item: FeaturedHeroItem) {
        interactionHeld = true
        resumeTask?.cancel(); resumeTask = nil
        show(item, animated: true)
    }

    // MARK: User interaction (pause rotation; resume after inactivity)

    /// The user touched the screen (scroll / hover / select). Pause the ambient rotation immediately
    /// and (re)start the inactivity timer; rotation resumes only once `heroResumeAfter` passes with no
    /// further interaction. No-op when motion is disabled. Decoupled from selection: this never pins,
    /// rings, or opens any poster — it only quiets the billboard while the user is busy (issue #53).
    func noteInteraction() {
        guard motionEnabled else { return }
        interactionHeld = true
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.heroResumeAfter)
            guard !Task.isCancelled else { return }
            await self?.releaseInteractionHold()
        }
    }

    /// Inactivity elapsed: release the hold so the rotation loop resumes advancing at its cadence.
    private func releaseInteractionHold() {
        interactionHeld = false
        resumeTask?.cancel(); resumeTask = nil
    }

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
    /// a seed-grade item by fetching its meta from Cinemeta + the installed meta add-ons. This is what
    /// gives Continue-Watching heroes — which carry only a name + poster — a real meta row and synopsis
    /// (issue #54). Cached to the session cache; applied live only if the title is still the one on
    /// screen. Self-contained (no dependency on the tvOS `FocusedItemModel`), so tvOS is untouched.
    private func enrichIfNeeded(_ item: FeaturedHeroItem) {
        guard Self.enrichmentCache[item.id] == nil, !enriching.contains(item.id) else { return }
        let candidates = Self.metaURLs(for: item)
        guard !candidates.isEmpty else {
            NSLog("[Hero] no meta candidates for \(item.name) (id=\(item.id), type=\(item.type)) — id scheme not covered by Cinemeta or any installed meta add-on")
            return
        }
        enriching.insert(item.id)
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
                NSLog("[Hero] enriched \(item.name): rating=\(enriched.imdbRating ?? "-") year=\(enriched.releaseInfo ?? "-") runtime=\(enriched.runtime ?? "-") genres=\(enriched.genres.count) via \(url.host ?? "?")")
                await MainActor.run {
                    Self.enrichmentCache[item.id] = enriched
                    self?.enriching.remove(item.id)
                    guard let self, self.hero?.id == item.id else { return }
                    // No animation here: this is an in-place content upgrade of the SAME hero, not a
                    // swap, so cross-fading would flicker the already-visible backdrop.
                    self.hero = enriched
                }
                return
            }
            // No candidate resolved (every fetch failed / timed out / returned an empty meta) — free the
            // id to retry later, and log it so a persistently-bare hero is diagnosable on-device.
            NSLog("[Hero] enrich FAILED for \(item.name) (id=\(item.id)) — all \(candidates.count) candidate fetch(es) failed/empty")
            await MainActor.run { self?.enriching.remove(item.id) }
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

    /// Stremio's standard logo art (transparent PNG) for an IMDB-identified title, so the hero can show
    /// the show's LOGO as its title immediately, without waiting on (or depending on) the async meta
    /// enrichment. Enrichment still upgrades it to the add-on's own logo when one resolves; if metahub
    /// has no logo for the id the AsyncImage fails and `titleOrLogo` falls back to the styled serif name.
    /// Nil for non-IMDB ids (tmdb:/tvdb:/kitsu:), which only metahub-by-IMDB can't cover.
    static func metahubLogo(forId id: String) -> String? {
        guard id.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/logo/medium/\(id)/img"
    }

    /// Seed from a catalog meta (carries its own `background` + preview fields when the add-on filled
    /// them; falls back to metahub-by-IMDB / poster otherwise).
    static func from(meta: CoreMeta) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: meta.id, type: meta.type, name: meta.name, poster: meta.poster,
            backdrop: meta.background ?? metahubBackground(forId: meta.id) ?? meta.poster,
            logo: metahubLogo(forId: meta.id), description: meta.description, releaseInfo: meta.releaseInfo,
            runtime: nil, imdbRating: meta.imdbRating, genres: meta.genres ?? [],
            trailerYouTubeID: nil)
    }

    /// Seed from a Continue Watching / library entry, which carries only a poster: real 16:9 art comes
    /// from metahub for IMDB ids, falling back to the poster (mirrors tvOS `CoreCWItem.focusedHero`).
    /// The title/rating/year/genres/synopsis are filled in by the model's background enrichment (#54).
    static func from(cw: CoreCWItem) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: cw.id, type: cw.type, name: cw.name, poster: cw.poster,
            backdrop: metahubBackground(forId: cw.id) ?? cw.poster,
            logo: metahubLogo(forId: cw.id), description: nil, releaseInfo: nil,
            runtime: nil, imdbRating: nil, genres: [],
            trailerYouTubeID: nil)
    }

    /// Build from the lightweight `RailItem` carried through the rails/grid (so the hero can seed
    /// richly from catalog preview fields). `RailItem` now carries the catalog preview fields.
    static func from(rail: RailItem) -> FeaturedHeroItem {
        FeaturedHeroItem(
            id: rail.id, type: rail.type, name: rail.name, poster: rail.poster,
            backdrop: rail.background ?? metahubBackground(forId: rail.id) ?? rail.poster,
            logo: metahubLogo(forId: rail.id), description: rail.description, releaseInfo: rail.releaseInfo,
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
