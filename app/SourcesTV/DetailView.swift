import SwiftUI

/// Meta detail, driven by the **stremio-core** engine (CoreBridge): a cinematic hero + overview, then
/// streams (movie) or a season selector with episode thumbnails (series). Streams come from the
/// engine's `meta_details`, the same complete, per-addon list the official app shows.
struct DetailView: View {
    let type: String
    let id: String
    var client: AddonClient = AddonClient()   // kept for call-site compatibility (Search)
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var presenter: PlayerPresenter   // root-replacement player presentation (Trailer)
    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized detail title/logo override

    // #44 in-hero trailer gating, the SAME keys iOS uses: the "Autoplay trailers" setting + reduce-motion.
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var similarItems: [MetaPreview] = []
    /// Franchise/collection this movie belongs to (TMDB belongs_to_collection -> parts, in release order),
    /// rendered as the "Part of the … Collection" rail JUST ABOVE More Like This. Nil for a standalone film /
    /// series / any miss, which hides the row. `collectionKey` de-dupes the fetch per imdb id.
    @State private var collection: TMDBClient.CollectionResult?
    @State private var collectionKey: String?
    @State private var mdbRatings: MDBListRatings?
    @State private var watchAvail: TMDBClient.WatchAvailability?
    @State private var financials: TMDBClient.Financials?
    @State private var releaseDates: TMDBClient.ReleaseDates?   // theatrical + digital, TMDB-fetched (movies only)

    /// H16 cast rail: full cast with photo + actor + character (TMDB credits via the keyless edge), placed
    /// JUST ABOVE More Like This. The meta's plain name list (`m.cast`) is the fallback so the rail never
    /// blanks without TMDB. `creditsKey` de-dupes the fetch per imdb id (mirrors iOSDetailView bug-10 work).
    @State private var castMembers: [TMDBClient.CastMember] = []
    @State private var creditsKey: String?
    @AppStorage("vortx.detail.showFinancials") private var showFinancials = true   // budget + box office on movie detail (movies only, needs a TMDB key)

    /// "Also available in" language chips (P1, community-subtitle system): the union of the languages PARSED
    /// from this title's loaded stream names and the crowd-sourced language index. Codes only; gated on
    /// `features.languageIndex`, rendered only when non-empty. `langChipsKey` de-dupes the compute.
    @State private var langChips: [(code: String, label: String)] = []
    @State private var langChipsKey = ""
    @State private var langChipsDebounce: Task<Void, Never>? = nil
    private static let langChipsDebounceMs = 400   // settle window before the off-main name/regex parse, mirrors coalesceMs intent
    /// yt-direct: the ambient hero trailer's ATTEMPTED device-direct resolve, keyed by meta id so a stale
    /// resolve never paints over another title. `url == nil` = attempted, no direct stream (mount the /yt
    /// worker URL). The layer waits for the attempt so the clip never remounts mid-play on a late resolve.
    @State private var heroDirectTrailer: (metaID: String, url: URL?)?

    var body: some View {
        Group {
            if let meta = core.metaDetails?.meta {
                // Live (tv / channel / events) gets its own stripped-down page BEFORE the movie
                // fallback (today live falls through to moviePage): backdrop + name + a red LIVE
                // badge + the channel source list, with NO VOD chrome: no trailer chip, no movie
                // synopsis framing, no skip/chapter UI. The source list keeps PlaybackMeta(type: type)
                // so the player's live-tuned path engages (see TVPlayerView.initialLiveMode).
                if LiveTypes.contains(type) {
                    livePage(meta)
                // A series OR a COLLECTION/franchise meta (a non-series carrying >1 entries as videos[], e.g.
                // TVDB collections via AIOmetadata) renders the episodic list; a normal movie (0-1 video) falls
                // through to moviePage. Without the collection case it showed as one un-streamable entry (#102).
                } else if let videos = meta.videos, !videos.isEmpty,
                          (effectiveType == "series" || (videos.count > 1 && meta.behaviorHints?.hasScheduledVideos != true)) {
                    seriesPage(meta, videos: videos)
                } else {
                    moviePage(meta)
                }
            } else if !LiveTypes.contains(type), type != "series", id.hasPrefix("tt"),
                      let placeholder = CoreMetaItem.placeholder(id: id, type: type, name: "") {
                // Cinemeta meta is nil for this tt (a new/unreleased title: tt at TMDB, not yet in Cinemeta).
                // The page is meta-driven, so without this it sat on a spinner forever AND the streams guard
                // never passed -> "No sources found". Render moviePage from a metahub-by-tt placeholder so the
                // hero paints and the sources list shows; the relaxed streams guard fires on the tt directly.
                // When the real meta later arrives, onChange swaps to it.
                moviePage(placeholder)
            } else {
                // Focusable so Back pops this view instead of exiting the app while it loads.
                ScrollView {
                    BigSpinner().padding(120).focusable()
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // NO ignoresSafeArea on the content: tvOS's safe-area insets exist to keep UI out of
        // TV overscan, and pushing the whole page into them clipped the top of the detail page
        // on TVs that crop (field report). The backdrops self-bleed (FullBleedBackdrop ignores
        // the safe area itself), so only text and controls moved back inside the safe zone.
        .onAppear {
            // Movies / live are a single video. Their stream request must carry the IMDB id, not the raw
            // catalog id: a TMDB/Kitsu catalog gives a tmdb:/kitsu: meta id, and imdb-keyed add-ons
            // (idPrefixes ["tt"]) are dropped from the plan for a non-imdb id (only AIOStreams-style broad
            // add-ons answer). The imdb id is in the meta's behaviorHints.defaultVideoId, known only after
            // the meta loads, so load meta FIRST then dispatch streams on meta-ready (loadMovieStreamsIfNeeded).
            // Series load streams per-episode (CoreEpisodeStreams), so a series detail loads meta only.
            if effectiveType == "series" {
                core.loadMeta(type: effectiveType, id: id)
            } else if core.metaDetails?.meta?.id == id {
                loadMovieStreamsIfNeeded()
            } else {
                core.loadMeta(type: effectiveType, id: id)
                // An imdb tt whose Cinemeta meta may never arrive (new/unreleased) would never reach the
                // onChange(meta?.id) that dispatches streams: fire the tt-keyed streams now so the sources
                // list populates regardless of the meta race. No-op'd by hasStreams once they land.
                loadMovieStreamsIfNeeded()
            }
            captureHero()
            loadCredits()
            loadCollection()
            if let m = core.metaDetails?.meta, m.id == id {
                loadSimilar(m); loadRatings(); loadWatchProviders(); loadFinancials(); loadReleaseDates()
            } else {
                // Meta not resident (and it may NEVER arrive for a title Cinemeta doesn't know): fill
                // "More Like This" from the tt-keyed TMDB recommendations now (#29). If meta does land,
                // the onChange below re-runs the richer meta-seeded loadSimilar, which overwrites this.
                loadSimilarFallback()
            }
            refreshLanguageChips()
        }
        .onDisappear {
            langChipsDebounce?.cancel()
            // Scrolling the series episode list auto-hides the tab bar at the UIKit level. When the
            // user presses Back the NavigationStack pops but the bar can stay hidden at its scroll-
            // suppressed position. Heal it the same way the player-close path does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { TabBarHealer.heal("detail-popped") }
        }
        // Re-dispatch streams under the AUTHORITATIVE meta.type once it arrives (Collections-hub fix): if the
        // hub's TMDB guess was wrong, meta.type corrects it and the request re-fires under the type add-ons use.
        .onChange(of: core.metaDetails?.meta?.type) { loadMovieStreamsIfNeeded() }
        .onChange(of: core.metaDetails?.meta?.id) {
            captureHero()
            langChips = []; langChipsKey = ""   // new title: reset the language chips before recomputing
            castMembers = []; creditsKey = nil  // new title: reset the cast rail before refetching (H16)
            collection = nil; collectionKey = nil   // new title: drop the old franchise rail before refetching
            if effectiveType != "series" { loadMovieStreamsIfNeeded() }
            loadCredits()
            loadCollection()
            if let m = core.metaDetails?.meta, m.id == id { loadSimilar(m); loadRatings(); loadWatchProviders(); loadFinancials(); loadReleaseDates() }
            refreshLanguageChips()
        }
        .onChange(of: core.streamLoadProgress().loaded) { _ in
            refreshLanguageChips()   // recompute the "Also available in" chips as more sources answer
        }
    }

    /// The IMDb id to fetch MDBList ratings for: prefer the meta's imdb `defaultVideoId` (tt...) when the
    /// catalog id is non-imdb (tmdb:/kitsu:), else the catalog id when it is itself an imdb id.
    private var ratingsImdbID: String? {
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
        return id.hasPrefix("tt") ? id : nil
    }

    /// The pool `content_key` for this title (P1). Movies/series key on the imdb id (no season/episode here,
    /// since the detail lists all sources across episodes). nil when no imdb id is known -> the feature no-ops.
    private var languageContentKey: String? {
        SubtitleReleaseFingerprint.contentKey(imdbId: ratingsImdbID)
    }

    /// P1: compute the "Also available in" chips from (a) languages PARSED from the loaded stream names and
    /// (b) the crowd-sourced language index, then fire-and-forget a name-provenance contribution. Gated on
    /// `features.languageIndex` inside the clients; de-duped per title + loaded-stream-count so it re-runs as
    /// sources arrive. Fail-soft: any miss leaves the row hidden.
    private func refreshLanguageChips() {
        // Gate the whole compute (incl. the TMDB spoken_languages verify fetch) on the master feature flag, so
        // it is a hard no-op when off rather than relying only on the per-client internal no-ops.
        guard LanguageIndexClient.isEnabled, let contentKey = languageContentKey else { return }
        // Cheap main-thread dedup: an integer stream count, NO per-stream string/regex work. The O(N) name
        // flatten + the ~10^5-regex audioSubCodes parse both move off the main thread below, so this gate can
        // no longer stall the render even when it fires per loaded tick.
        let snapshot = core.streamGroups()                     // value-type COW snapshot, O(1)
        let streamCount = snapshot.reduce(0) { $0 + $1.streams.count }
        let key = "\(contentKey)#\(streamCount)"
        guard key != langChipsKey else { return }
        langChipsKey = key
        let imdb = ratingsImdbID
        let mediaType = type
        langChipsDebounce?.cancel()                            // supersede any in-flight settle
        langChipsDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.langChipsDebounceMs))
            guard !Task.isCancelled, languageContentKey == contentKey else { return }   // title switched during settle
            // AGGREGATE across EVERY loaded source (all add-ons), scanning BOTH `name` AND `description` per
            // stream, then split into AUDIO vs SUBTITLE claims. The heavy flatten + regex parse runs OFF the
            // main thread; audioSubCodes is pure/static so it is safe to call from the detached task.
            let observed = await Task.detached(priority: .utility) { () -> (audio: [String], sub: [String]) in
                let names = snapshot.flatMap { $0.streams }
                    .flatMap { [$0.name, $0.description] }
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return LanguageIndexClient.audioSubCodes(fromNames: names)
            }.value
            guard languageContentKey == contentKey else { return }
            // Community index + TMDB spoken_languages fetched in PARALLEL: the two verification sources. Both
            // fail soft to nil (no signal), so a missing source never falsely contradicts an audio claim.
            async let availabilityTask = LanguageIndexClient.fetch(contentKey: contentKey)
            async let spokenTask = TMDBClient.spokenLanguages(imdbID: imdb, type: mediaType)
            let availability = await availabilityTask
            let tmdbSpoken = await spokenTask
            guard languageContentKey == contentKey else { return }   // title switched mid-fetch
            // VERIFY: drop a name-only AUDIO language contradicted by BOTH TMDB and the community (the false-
            // claim fix, e.g. a Korean-only file whose release name says "English"). Subtitle + corroborated
            // codes are kept; nothing is dropped when a verification source is missing.
            langChips = LanguageIndexClient.verifiedAvailabilityChips(observedAudio: observed.audio,
                                                                      observedSub: observed.sub,
                                                                      availability: availability,
                                                                      tmdbSpoken: tmdbSpoken)
            Task.detached {
                await LanguageIndexClient.contribute(contentKey: contentKey,
                                                     audioLangs: observed.audio,
                                                     subLangs: observed.sub,
                                                     provenance: "name")
            }
        }
    }

    /// "Also available in" chips row (P1). Rendered only when the language merge produced something. A
    /// wrapping run of chips showing the FULL localized language NAMES (English · Français …, H11 - port of
    /// the iOS #8 fix; the label is already Locale-resolved by LanguageIndexClient), styled with Theme surface
    /// tokens. Names are wider than the old 2-letter codes, so fewer per row. No add-on wording: these are
    /// just the languages this title is available in.
    @ViewBuilder private var languageChips: some View {
        if !langChips.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Also available in")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
                let perRow = 4
                let rowStarts = Array(stride(from: 0, to: langChips.count, by: perRow))
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(rowStarts, id: \.self) { start in
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(langChips[start..<min(start + perRow, langChips.count)], id: \.code) { chip in
                                Text(chip.label)
                                    .font(Theme.Typography.label.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    // Glass the static "Also available in" language pill: a non-selected
                                    // glass chip so it reads as raised VortX chrome, not a flat surface fill.
                                    .vortxGlassChip(selected: false)
                                    .accessibilityLabel(chip.label)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    /// H16: fetch the full cast (who-played-who + headshots) from the keyless TMDB credits edge, keyed per
    /// imdb id so meta arriving after the tt-only first load doesn't refetch. Works with meta=nil (a
    /// hub-seeded tt not yet in Cinemeta). Fail-soft: a miss leaves the meta-cast fallback rail.
    private func loadCredits() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, creditsKey != imdb else { return }
        creditsKey = imdb
        Task {
            guard let result = await TMDBClient.credits(imdbID: imdb, type: effectiveType) else { return }
            await MainActor.run {
                guard creditsKey == imdb else { return }   // title switched mid-fetch
                if !result.cast.isEmpty { castMembers = result.cast }
            }
        }
    }

    /// Fetch this movie's franchise/collection (TMDB belongs_to_collection -> parts, release order) from the
    /// keyless edge, keyed per imdb id so meta arriving after the tt-only first load doesn't refetch (works
    /// with meta=nil for a hub-seeded tt). Movies only. Fail-soft: a standalone film / miss leaves the row hidden.
    private func loadCollection() {
        guard effectiveType != "series", let imdb = ratingsImdbID, collectionKey != imdb else { return }
        collectionKey = imdb
        Task {
            let result = await TMDBClient.movieCollection(imdbID: imdb, type: effectiveType)
            await MainActor.run {
                guard collectionKey == imdb else { return }   // title switched mid-fetch
                collection = result
            }
        }
    }

    /// Fetch MDBList ratings for this title (no-op without a key / imdb id). Fail-soft: leaves the row
    /// hidden on any miss. Skipped for live channels, which carry no ratings.
    private func loadRatings() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, mdbRatings == nil else { return }
        Task {
            // VortX's keyless ratings service first (IMDb / RT / Metacritic / TMDB, no user key needed), then
            // reach for the user's own MDBList key ONLY to fill what VortX did not return. Mirrors iOS so both
            // surfaces show the same ratings row for every user, keyed or not (tvOS previously showed nothing
            // unless an MDBList key was set).
            let vx = await VortXRatingsClient.ratings(imdbID: imdb, type: type)
            let needsMore = vx == nil || vx?.rottenTomatoes == nil || vx?.metacritic == nil
            let mdb = needsMore ? await MDBListClient.ratings(imdbID: imdb, type: type) : nil
            let merged = MDBListRatings(
                imdb: vx?.imdb ?? mdb?.imdb,
                rottenTomatoes: vx?.rottenTomatoes ?? mdb?.rottenTomatoes,
                metacritic: vx?.metacritic ?? mdb?.metacritic,
                tmdb: vx?.tmdb ?? mdb?.tmdb
            )
            await MainActor.run { mdbRatings = merged.hasAny ? merged : nil }
        }
    }

    /// Fetch the movie budget + box office (no-op for series / no key / no imdb id). Fail-soft; the row hides on a miss.
    private func loadFinancials() {
        guard showFinancials, type != "series", let imdb = ratingsImdbID, financials == nil else { return }
        Task {
            let f = await TMDBClient.details(imdbID: imdb, type: type)
            await MainActor.run { financials = f }
        }
    }

    /// Fetch theatrical + digital release dates (no-op for series / no key / no imdb id). Fail-soft; the row hides on a miss.
    private func loadReleaseDates() {
        guard type != "series", let imdb = ratingsImdbID, releaseDates == nil else { return }
        Task {
            let d = await TMDBClient.releaseDates(imdbID: imdb, type: type)
            await MainActor.run { releaseDates = d }
        }
    }

    /// The id to dispatch a movie/live stream request with: the meta's imdb `defaultVideoId` (tt...) when
    /// the catalog id is non-imdb (tmdb:/kitsu:), else the catalog id. Falls back to the catalog id before
    /// the meta loads. Matches official Stremio (and the engine's guess_stream), which key movie streams on
    /// default_video_id so imdb add-ons match.
    private var movieStreamId: String {
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, !dv.isEmpty, dv != id { return dv }
        return id
    }

    /// The AUTHORITATIVE type for the stream request + series/movie render: the loaded meta's type once
    /// resident, else the incoming `type`. The Collections/Trending HUB passes a TMDB movie/tv GUESS as `type`
    /// (TMDBClient), which for TV-movies / mini-series / anime disagrees with the type stream add-ons index the
    /// title under -> a type-scoped request matched no add-on ("No sources found" from the hub, while the same
    /// title worked from an add-on catalog carrying the engine's authoritative type). Keying off meta.type
    /// fixes both directions; falling back to `type` keeps behavior unchanged until meta loads.
    private var effectiveType: String {
        if core.metaDetails?.meta?.id == id, let t = core.metaDetails?.meta?.type, !t.isEmpty { return t }
        return type
    }

    /// Dispatch the movie/live stream request with the imdb-preferring id, unless those streams are already
    /// resident. No-op for series and until this title's meta loaded. The hasStreams guard keys on the
    /// EFFECTIVE id so no re-dispatch loop forms once the imdb-keyed streams arrive.
    private func loadMovieStreamsIfNeeded() {
        guard effectiveType != "series" else { return }
        // Relaxed guard (build 137): the old `meta?.id == id` gate blocked streams whenever Cinemeta meta
        // was nil (a new/unreleased tt not yet in Cinemeta -> "No sources found"). Fire either when this
        // title's meta is resident (the imdb-defaultVideoId path) OR, with meta still absent, directly on
        // the catalog id when it is itself an imdb tt (the hub-card case). Non-imdb ids without meta still
        // wait (their stream id only resolves from the meta). hasStreams keys on the effective id, so no
        // re-dispatch loop forms once the streams arrive.
        let metaResident = core.metaDetails?.meta?.id == id
        guard metaResident || id.hasPrefix("tt") else { return }
        let streamId = movieStreamId
        // Either surface counts as resident: meta-embedded streams (metaStreams, #122) are keyed by the
        // same stream path id, and their presence means the engine already selected this id.
        let hasStreams = core.metaDetails?.allStreamGroups.contains { $0.request.path.id == streamId } ?? false
        guard !hasStreams else { return }
        if effectiveType != type { NSLog("[detail] stream type corrected: hub-guess=%@ -> meta=%@ id=%@", type, effectiveType, id) }
        core.loadMeta(type: effectiveType, id: id, streamType: effectiveType, streamId: streamId)
    }

    /// H16 tvOS cast rail: a focusable horizontal rail of every cast member (photo circle + actor + character),
    /// placed JUST ABOVE More Like This. TMDB credits when they resolved, else the meta's plain cast names
    /// (no photos/roles) so the rail never blanks without TMDB. Negative synthetic ids keep the fallback
    /// Identifiable without colliding with real TMDB person ids. Same focus pattern as the other rails.
    private var railCastMembers: [TMDBClient.CastMember] {
        if !castMembers.isEmpty { return castMembers }
        let names = core.metaDetails?.meta?.cast ?? []
        return names.enumerated().map {
            TMDBClient.CastMember(id: -1 - $0.offset, name: $0.element, character: nil, profileURL: nil)
        }
    }

    @ViewBuilder private var castSection: some View {
        if !LiveTypes.contains(type), !railCastMembers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                RailHeader(title: "Cast")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                        ForEach(railCastMembers.prefix(30)) { member in
                            CastMemberCard(member: member)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.vertical, Theme.Space.lg)
                }
            }
        }
    }

    /// The "Part of the … Collection" rail: every entry in this movie's TMDB collection in release order,
    /// each a PosterCard that opens its detail, mirroring the More-Like-This rail exactly. Shown only when
    /// the collection has more than one entry (a one-item "collection" is not a franchise).
    @ViewBuilder private var collectionSection: some View {
        if let collection, collection.parts.count > 1 {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                RailHeader(eyebrow: "Collection", title: TMDBClient.collectionRowTitle(collection.name))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                        ForEach(collection.parts) { item in
                            PosterCard(title: item.name, poster: item.poster,
                                       type: item.type, id: item.id)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.vertical, Theme.Space.lg)
                }
            }
        }
    }

    @ViewBuilder private var moreLikeThisSection: some View {
        if !similarItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                RailHeader(title: "More Like This")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                        ForEach(similarItems.prefix(20)) { item in
                            PosterCard(title: item.name, poster: item.poster,
                                       type: item.type, id: item.id)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.vertical, Theme.Space.lg)
                }
            }
        }
    }

    private func loadSimilar(_ meta: CoreMetaItem) {
        guard !LiveTypes.contains(type) else { return }
        // No genres to seed the add-on similarity walk with: fall back to the meta-independent TMDB
        // recommendations path so the rail still fills (#29).
        guard !meta.genres.isEmpty else { loadSimilarFallback(); return }
        Task {
            let items = await AddonClient.similar(type: type, excludingId: id, genres: meta.genres, title: meta.name)
            var merged = items
            // When a TMDB key is set, prepend TMDB recommendations (deduped) for richer "more like this".
            if ApiKeys.tmdbKey() != nil, id.hasPrefix("tt") {
                let existing = Set(items.map(\.id))
                let recs = await AddonClient.tmdbSimilar(type: type, imdbID: id).filter { $0.id != id && !existing.contains($0.id) }
                merged = recs + items
            }
            // Never clobber an already-filled rail (the #29 fallback) with an empty meta-seeded result.
            await MainActor.run { if !merged.isEmpty { similarItems = merged } }
        }
    }

    /// #29: meta-independent "More Like This". A title Cinemeta doesn't know (a hub/custom-category card)
    /// never loads a meta, so the meta-gated `loadSimilar` never ran and the rail stayed empty while Play
    /// worked (streams fire directly on the tt id). TMDB recommendations key on the tt id alone, so fetch
    /// them directly. Fail-soft, and it only fills while the rail is still empty, so a later richer
    /// meta-seeded result is never clobbered.
    private func loadSimilarFallback() {
        guard !LiveTypes.contains(type), similarItems.isEmpty, id.hasPrefix("tt"), ApiKeys.tmdbKey() != nil else { return }
        Task {
            let recs = await AddonClient.tmdbSimilar(type: effectiveType, imdbID: id).filter { $0.id != id }
            guard !recs.isEmpty else { return }
            await MainActor.run { if similarItems.isEmpty { similarItems = recs } }
        }
    }

    @ViewBuilder private var whereToWatchSection: some View {
        if let avail = watchAvail, !avail.providers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                RailHeader(title: "Where to Watch")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.md) {
                        ForEach(avail.providers) { provider in
                            VStack(spacing: 6) {
                                // TMDB watch-provider marks are dark / brand-hued app icons that read as
                                // "very dark" drawn straight on the app's dark chrome (#95). Sit each mark on
                                // the shared warm near-white plate (the same treatment the Streaming Services
                                // tiles and RemoteLogo use) with a small inset, so a dark logo stays legible
                                // and whole instead of blending into the background.
                                AsyncImage(url: URL(string: provider.logoURL ?? "")) { img in
                                    img.resizable().scaledToFit().padding(56 * BundledLogo.plateInsetFraction)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.Palette.surface1)
                                }
                                .frame(width: 56, height: 56)
                                .background(BundledLogo.plateFill)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                                Text(provider.name)
                                    .font(Theme.Typography.label)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .lineLimit(1).frame(width: 80)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.vertical, Theme.Space.sm)
                }
            }
        }
    }

    /// Legal streaming availability for the title in the viewer's region (TMDB watch/providers). Only
    /// runs with a TMDB key + an IMDb id; a nil result simply hides the section.
    private func loadWatchProviders() {
        guard !LiveTypes.contains(type), id.hasPrefix("tt") else { return }
        Task {
            let avail = await TMDBClient.watchProviders(imdbID: id, type: type)
            await MainActor.run { watchAvail = avail }
        }
    }

    /// Feed the browse pages' hero cache with what this page knows. The engine resolved this meta
    /// through the add-on system, so it works for every id scheme (tt, tmdb:, tvdb:, anything).
    private func captureHero() {
        guard let m = core.metaDetails?.meta, m.id == id else { return }
        FocusedItemModel.noteMeta(id: m.id, type: type, title: m.name,
                                  backdrop: m.background ?? m.poster,
                                  releaseInfo: m.releaseInfo, imdbRating: m.imdbRating,
                                  runtime: m.runtime, overview: m.description, genres: m.genres)
    }

    /// Series keep the hero + episode-list layout (the page below the hero is full of content).
    private func seriesPage(_ meta: CoreMetaItem, videos: [CoreVideo]) -> some View {
        let watched = profiles.activeUsesEngineHistory
            ? (core.metaDetails?.watchedIds ?? [])
            : profiles.watchedVideoIds(forMeta: meta.id)
        let primary = seriesPrimaryEpisode(videos, watched: watched, metaID: meta.id)
        let primaryProgress = primary.map { episodeProgress($0.video, metaID: meta.id) } ?? 0
        // FIX (build 137): the series/season hero was chopped at the top + not full-bleed because the
        // backdrop lived INSIDE hero(), i.e. inside the VStack inside the ScrollView, so its
        // .ignoresSafeArea() could not escape the top nav-bar safe-area inset. Hoist FullBleedBackdrop +
        // heroTrailerLayer to a page-root ZStack sibling (matching moviePage/livePage/CoreEpisodeStreams),
        // so they sit at the screen edge and bleed under the nav bar + to the bottom overscan. hero() then
        // drops its own (now duplicated) backdrop + trailer layer (see hero()).
        return ScrollViewReader { proxy in
            ZStack {
                // Carry the .fit/.fill branch EXACTLY: .fill when a real landscape background exists (the
                // common case, full-bleed, never pillarboxed); .fit only when a series falls back to its
                // portrait poster (no landscape background), to avoid cropping the tall art.
                FullBleedBackdrop(url: meta.background ?? meta.poster,
                                  contentMode: (meta.type == "series" && meta.background == nil) ? .fit : .fill)
                heroTrailerLayer(meta).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        hero(meta, primaryEpisode: primary?.video, primaryIsResume: primary?.isResume == true,
                             primaryProgress: primaryProgress,
                             scrollToContent: { withAnimation { proxy.scrollTo("detailContent", anchor: .top) } })
                        CoreSeasonedEpisodes(meta: meta, videos: videos,
                                             watched: watched,
                                             initialSeason: resumeSeasonHint(videos, metaID: meta.id) ?? primary?.video.season)
                            .id("detailContent")
                        castSection
                        whereToWatchSection
                        collectionSection
                        moreLikeThisSection
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        }
        // Show-level watched rollup (issue #143): a series reads as watched once every AIRED, regular-season
        // episode is watched, so unaired episodes and Season 0 specials never hold a finished show back, and a
        // series whose episodes were MARKED (not played) still flips the poster badge even though the engine's
        // library `times_watched` stays 0. Read-only: fed into WatchedIndex, never a write. Recomputed when the
        // watched set changes (a mark) or the episode list streams in.
        .onAppear {
            WatchedIndex.shared.noteSeriesWatched(meta.id,
                isFullyWatched: SeriesWatched.isFullyWatched(videos: videos, watched: watched))
        }
        .onChange(of: watched) {
            WatchedIndex.shared.noteSeriesWatched(meta.id,
                isFullyWatched: SeriesWatched.isFullyWatched(videos: videos, watched: watched))
        }
        .onChange(of: videos.count) {
            WatchedIndex.shared.noteSeriesWatched(meta.id,
                isFullyWatched: SeriesWatched.isFullyWatched(videos: videos, watched: watched))
        }
    }

    /// Movies get the full-bleed cinematic page. H12+H15 ANCHORED LAYOUT (owner 16:50): the FIRST SCREEN is
    /// a self-contained page sized to a full viewport height (`firstScreenHeight`, ~one tvOS canvas): the
    /// title/logo + meta + description block sits UP near the top, and the action band (language chips,
    /// trailer chip, and the Watch/Sources CoreStreamList) is pinned to the BOTTOM of that first screen by a
    /// flexible Spacer, so it is always fully visible on open with nothing cut off. Initial focus lands on
    /// Watch (CoreStreamList's own .defaultFocus). Everything below the fold (cast H16, Where to Watch, More
    /// Like This) sits in a SECOND section that only scrolls into view when the user deliberately navigates
    /// DOWN past the action band. This is the standard first-party tvOS detail pattern; it fixes the cut-off
    /// Watch button (H12) and removes the upward focus trap (H15) because the first screen's focus chain is
    /// fixed. The focus engine itself is untouched: only layout containers and a Spacer were added.
    ///
    /// 5a/6a (build 171): the bottom-anchor only holds while the first-screen content fits one viewport; a
    /// long synopsis grew the block past `firstScreenHeight`, collapsed the flexible Spacer, and pushed the
    /// Watch band DOWN (owner: "the button moves") AND scrolled the band into a region tvOS could not project
    /// focus back UP from, re-trapping the path to the tab bar (the H15 regression). The description is now
    /// clamped to a FIXED reserved line count, so its length can no longer change where the band lands: the
    /// Watch button holds one position across titles and the first-screen focus chain (Watch -> tab bar
    /// upward) stays fixed. Still non-focusable, so the focus engine is untouched.
    private func moviePage(_ m: CoreMetaItem) -> some View {
        ZStack {
            FullBleedBackdrop(url: m.background ?? m.poster)
            // #44: the muted, looping trailer fades in OVER the still backdrop (full-bleed, behind the
            // scrolling content). Non-focusable + no hit-testing, so the focus engine is untouched.
            heroTrailerLayer(m).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    // FIRST SCREEN: title block up top, action band anchored at the bottom.
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        Spacer().frame(height: 200)   // logo/description move UP (was 380)
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            titleOrLogo(m)
                            metaRow(m)
                            ratingsRow()
                            financialsRow()
                            releaseDatesRow()
                            if let d = m.description, !d.isEmpty {
                                // 5a/6a (build 171): reserve space for a FIXED 3 lines (was an elastic 4)
                                // so a short synopsis occupies the SAME height as a long one. The block above
                                // the action band is now length-independent, so the bottom-anchored Watch
                                // button holds one position across every title and the first screen can no
                                // longer overflow into a scrolled state that traps the upward focus path.
                                // Non-focusable, so Watch keeps default focus and the up-path is untouched.
                                Text(d)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(3, reservesSpace: true).lineSpacing(2)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }
                        }
                        // Flexible gap pushes the action band down to the bottom of the first screen.
                        Spacer(minLength: Theme.Space.lg)
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            languageChips
                            HStack(spacing: Theme.Space.sm) { trailerChip(m) }
                            CoreStreamList(title: m.name,
                                           meta: PlaybackMeta(libraryId: m.id, videoId: m.id,
                                                              type: m.type.isEmpty ? effectiveType : m.type,
                                                              name: m.name, poster: m.poster,
                                                              season: nil, episode: nil),
                                           imdbId: ratingsImdbID)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.bottom, Theme.Space.lg)
                    .frame(minHeight: Self.firstScreenHeight, alignment: .top)   // first screen ~= one viewport tall (version-safe; no tvOS-17 containerRelativeFrame)
                    // SECOND SECTION (below the fold): scrolls in only on deliberate down-nav.
                    castSection
                    whereToWatchSection
                    collectionSection
                    moreLikeThisSection
                }
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    /// The title block: an ERDB rating-baked logo (or the add-on's clearart logo) by id when available,
    /// otherwise the serif hero title text. Mirrors iOS `iOSDetailView.titleOrLogo`.
    @ViewBuilder private func titleOrLogo(_ m: CoreMetaItem) -> some View {
        // fanart.tv clearlogo first (when enabled), else the ERDB-aware add-on/metahub logo, else serif text.
        ResolvedTitleLogo(id: m.behaviorHints?.defaultVideoId ?? m.id, type: m.type,
                          fallbackLogo: l10n.logo(for: id) ?? m.logo,
                          maxWidth: 640, maxHeight: 200, shadowOpacity: 0.5, shadowRadius: 12,
                          accessibilityName: l10n.title(for: id) ?? m.name) {
            heroTitleText(m)
        }
    }

    private func heroTitleText(_ m: CoreMetaItem) -> some View {
        Text(l10n.title(for: id) ?? m.name)
            .font(Theme.Typography.hero).tracking(-1.5)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2).minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// Live channel page: the same full-bleed cinematic backdrop as a movie, but stripped of VOD chrome,
    /// no trailer chip, no movie-style synopsis paragraph, no skip/chapter UI. A red "LIVE" badge sits
    /// beside the title, then a now/next EPG strip (when the channel carries a schedule), and the
    /// channel's full source list lets the user pick a stream. The stream list carries the channel's
    /// live `type` in its `PlaybackMeta`, which the player reads via `LiveTypes` to engage live tuning
    /// and NO-OP resume/progress.
    private func livePage(_ m: CoreMetaItem) -> some View {
        ZStack {
            FullBleedBackdrop(url: m.background ?? m.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Spacer().frame(height: 380)
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                            Text(m.name)
                                .font(Theme.Typography.hero).tracking(-1.5)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.6)
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            liveBadge
                        }
                        metaRow(m)
                    }
                    epgStrip(m)
                    CoreStreamList(title: m.name,
                                   meta: PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
                                                      name: m.name, poster: m.poster,
                                                      season: nil, episode: nil),
                                   imdbId: ratingsImdbID)
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    /// Now/Next EPG strip for a live channel (tvOS twin of the iOS one; reuses the SAME `EPGSchedule`
    /// type, no duplicated selection logic). The schedule already rides in the meta JSON
    /// (`behaviorHints.hasScheduledVideos` + dated `videos[]`): no XMLTV/networking on the client.
    /// When `EPGSchedule` resolves, show a NOW row (title + "until <next start>") and a NEXT row
    /// (title + start time); otherwise fall back to the channel description. Display-only and
    /// non-focusable, so the focus order (title → source list) is unchanged. Times use the device
    /// LOCALE (short time), turning the UTC `released` into a local clock reading.
    @ViewBuilder private func epgStrip(_ m: CoreMetaItem) -> some View {
        if let schedule = EPGSchedule(meta: m) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if let now = schedule.now {
                    epgRow(eyebrow: "NOW",
                           title: now.episodeTitle,
                           detail: schedule.next?.releasedDate.map { "until \(Self.epgTime.string(from: $0))" })
                }
                if let next = schedule.next {
                    epgRow(eyebrow: "NEXT",
                           title: next.episodeTitle,
                           detail: next.releasedDate.map { Self.epgTime.string(from: $0) })
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
        } else if let d = m.description, !d.isEmpty {
            Text(d)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    /// One EPG row: an eyebrow tag (NOW / NEXT), the program title, and an optional time detail.
    private func epgRow(eyebrow: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(eyebrow)
                .font(Theme.Typography.eyebrow).tracking(1.5)
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Height of the anchored first screen of the movie detail (H12/H15). The tvOS SwiftUI canvas is
    /// 1080pt tall; after the top nav bar and the bottom overscan the usable band is ~900pt. Sizing the
    /// first section to this keeps the title block up top and the action band on the first screen without
    /// the tvOS-17-only `containerRelativeFrame`. A `minHeight` (not a fixed `frame`) so a very tall action
    /// band on a title with many chips grows rather than clips.
    private static let firstScreenHeight: CGFloat = 900

    /// Device-locale short-time formatter (UTC `released` → local clock reading). `static let` to
    /// avoid per-row allocation; locale/time-zone default to the device's current settings.
    private static let epgTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// The red "LIVE" pill that marks a live channel (the live counterpart to the VOD trailer / Watch
    /// affordances this page drops).
    private var liveBadge: some View {
        Text("LIVE")
            .font(Theme.Typography.eyebrow).tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.Palette.danger, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    /// Full-bleed backdrop with a canvas-blended gradient and the title / metadata / synopsis on the
    /// lower band. The serif title is the editorial signature.
    private func hero(_ m: CoreMetaItem, primaryEpisode: CoreVideo? = nil, primaryIsResume: Bool = false,
                      primaryProgress: Double = 0,
                      scrollToContent: @escaping () -> Void) -> some View {
        // FIX (build 137): the backdrop + trailer layer are now hoisted to the seriesPage page-root ZStack
        // (so they bleed under the nav bar at the top + to the bottom overscan, like moviePage). hero() is
        // now a plain in-flow VStack: a leading Spacer pushes the title/actions block onto the lower band
        // where the FullBleedBackdrop's own bottom scrim keeps it readable. Mirrors moviePage exactly.
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Spacer().frame(height: 380)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(m.name)
                    .font(Theme.Typography.hero).tracking(-1.5)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                metaRow(m)
                ratingsRow()
                financialsRow()
                releaseDatesRow()
                if let d = m.description, !d.isEmpty {
                    Text(d)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3).lineSpacing(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                // On-screen focusable anchor: grabs initial focus on push (so Back pops instead of
                // exiting), and jumps to the episodes / sources below.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.sm) {
                        if let primaryEpisode {
                            VStack(spacing: Theme.Space.xs) {
                                NavigationLink {
                                    CoreEpisodeStreams(meta: m, video: primaryEpisode,
                                                       season: primaryEpisode.season ?? 0,
                                                       episodes: sortedEpisodes(m.videos ?? []))   // ALL seasons ordered → auto-advance crosses the season boundary
                                } label: {
                                    Label(primaryEpisodeLabel(primaryEpisode, isResume: primaryIsResume,
                                                              resumeSeconds: primaryIsResume ? primaryEpisodeResumeSeconds(primaryEpisode, metaID: m.id) : nil),
                                          systemImage: "play.fill")
                                }
                                .buttonStyle(PrimaryActionStyle())
                                if primaryIsResume, primaryProgress > 0.01 {
                                    ProgressStripe(value: primaryProgress)
                                        .padding(.horizontal, Theme.Space.sm)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        if primaryEpisode == nil {
                            Button(action: scrollToContent) {
                                Label(type == "series" ? "Episodes" : "Watch",
                                      systemImage: type == "series" ? "list.bullet" : "play.fill")
                            }
                            .buttonStyle(PrimaryActionStyle())
                        } else {
                            Button(action: scrollToContent) {
                                Label("Episodes", systemImage: "list.bullet")
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                        LibraryChip()
                        WatchlistChip()
                        trailerChip(m)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.bottom, Theme.Space.lg)
        }
        // In-flow hero: the leading Spacer(380) reserves the top band for the hoisted full-bleed backdrop,
        // and the title/actions block sits on the lower scrimmed band. Greedy on width + leading aligned,
        // matching moviePage; no fixed minHeight (the backdrop now fills the page-root ZStack, not this view).
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// #44 in-hero trailer layer: a muted, looping libmpv trailer ({serverBase}/yt/{id}) painted OVER the
    /// still backdrop on the cinematic detail header, the tvOS twin of the iOS `InHeroTrailerView`. Mounted
    /// only when ALL hold: the "Autoplay trailers" setting is on, motion is allowed, this is a VOD title
    /// (live channels carry no trailers), and `TrailerRequest` resolved a PLAYABLE url. `playableURL` now
    /// yields the SAME native `/yt` full trailer the Trailer button plays (the retired R2 `/clip` snippet is
    /// gone, owner directive); it is nil for a YouTube-only trailer with no resolvable id, so the layer never
    /// mounts there and the still backdrop stays, the same auto-hide the Trailer chip uses. The trailer itself
    /// only reveals once it actually starts decoding and the server is confirmed online (see
    /// `TVInHeroTrailerView`), so a missing / slow / blocked trailer never blanks the band.
    @ViewBuilder private func heroTrailerLayer(_ m: CoreMetaItem) -> some View {
        // `presenter.request == nil`: the player presents OVER this page, which stays mounted (only
        // opacity-hidden + disabled) - so without this gate the hero clip's libmpv instance kept decoding
        // its looping 1080p trailer underneath the whole movie: micro stutter and audio crackle on every
        // stream started from this page. Unmounting tears the clip down the moment the player presents;
        // it remounts fresh when playback closes.
        if autoplayTrailers, !reduceMotion, !LiveTypes.contains(type), presenter.request == nil,
           let url = TrailerRequest.from(meta: m)?.playableURL {
            // Owner directive: play the WHOLE trailer muted + looping (window nil), the same full `/yt` trailer
            // as the Trailer button, not a 10s snippet (that only suited the retired short `/clip` mp4). For a
            // SERIES this `m` is the series meta, so a series-episode hero shows the SERIES trailer.
            // yt-direct: try the DEVICE-DIRECT stream first (resolved on the user's own IP; the hero is muted,
            // so a video-only adaptive pick needs no audio sidecar). The layer mounts only after the attempt
            // lands so a late resolve never remounts a clip mid-play; a miss mounts the /yt worker URL.
            Group {
                if let attempt = heroDirectTrailer, attempt.metaID == m.id {
                    TVInHeroTrailerView(url: attempt.url ?? url, window: nil)
                }
            }
            .task(id: m.id) { await resolveHeroDirectTrailer(m) }
        }
    }

    /// yt-direct: one attempt per meta id at resolving the ambient hero trailer on the user's own IP.
    /// Fail-soft: any miss records `url = nil`, which mounts the existing /yt worker URL unchanged.
    private func resolveHeroDirectTrailer(_ m: CoreMetaItem) async {
        guard heroDirectTrailer?.metaID != m.id else { return }
        var direct: URL? = nil
        // A direct (non-YouTube) trailer stream needs no resolver; only a YouTube trailer is resolvable.
        if directTrailerURL(m) == nil, let yt = m.trailerYouTubeID, !yt.isEmpty {
            let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080)
            direct = resolved?.videoURL
            NSLog("[yt-direct] tvOS detail ambient: %@",
                  resolved.map { $0.isMuxed ? "direct-muxed" : "direct-pair" } ?? "fallback-worker")
        }
        heroDirectTrailer = (m.id, direct)
    }

    /// A direct (non-YouTube) trailer stream the meta carried, if any. Always preferred (needs no resolver).
    private func directTrailerURL(_ m: CoreMetaItem) -> URL? {
        (m.trailerStreams ?? [])
            .compactMap { $0.ytId == nil ? $0.url : nil }
            .compactMap { URL(string: $0) }
            .first
    }

    /// Whether a FULL trailer exists at all (drives the chip's visibility): a direct stream OR a YouTube id.
    /// A YouTube id is resolvable on EVERY build now: the full builds via the in-process `/yt`, the Lite build
    /// via the public `trailer.vortx.tv/yt` remote resolver (needs no local server), so the chip no longer
    /// auto-hides on Lite for YouTube-only titles (Lite now has a working primary full-trailer path).
    private func hasFullTrailer(_ m: CoreMetaItem) -> Bool {
        directTrailerURL(m) != nil || (m.trailerYouTubeID?.isEmpty == false)
    }

    /// H13 / A6 / FINAL-TRAILER-DECISION: resolve the URL the Trailer BUTTON plays, the FULL trailer, NOT the
    /// 10s ambient `/clip` (which is the hero billboard loop only). Mirrors the iOS/Featured paths. Order:
    ///   1. A direct (non-YouTube) trailer stream the meta carried (`directURL`), plays as-is.
    ///   2. A YouTube trailer -> the `/yt/{id}` InnerTube resolver (server.js on the full builds, the public
    ///      `trailer.vortx.tv/yt` remote resolver on Lite, `StremioServer.trailerResolverBase` picks). The id
    ///      is the D11 language-preferred id when TMDB has one (`preferredTrailerPick`, non-English prefs only),
    ///      else the meta's default id; a `lang` hint (`TMDBClient.trailerLanguageBaseCode`, which honors the
    ///      explicit `stremiox.trailerLanguage` picker) carries the client pick so the resolver's own fallback
    ///      chain (user-lang -> en -> original) matches. There is NO R2 full-trailer route.
    /// Async because the D11 localized-id pick is a TMDB round trip; fail-soft throughout (any miss falls to
    /// the meta's default id / direct stream). nil only when neither a direct stream nor a YouTube id exists.
    private func resolveFullTrailerURL(_ m: CoreMetaItem) async -> URL? {
        // A direct (non-YouTube) trailer stream is always preferred and needs no resolver.
        if let direct = directTrailerURL(m) { return direct }
        guard let yt = await preferredTrailerYouTubeID(m) else { return nil }
        var c = URLComponents(string: "\(StremioServer.trailerResolverBase)/yt/\(yt)")
        let lang = TMDBClient.trailerLanguageBaseCode   // honors the stremiox.trailerLanguage picker (D11)
        if !lang.isEmpty { c?.queryItems = [URLQueryItem(name: "lang", value: lang)] }
        return c?.url
    }

    /// The YouTube id the trailer paths should play (split out of `resolveFullTrailerURL` so the
    /// device-direct resolver can try the SAME D11 language-preferred id before falling back to the
    /// worker URL): a genuinely localized id (non-English prefs only) when TMDB has one, else the
    /// meta's default id. nil when the meta carries no YouTube trailer at all.
    private func preferredTrailerYouTubeID(_ m: CoreMetaItem) async -> String? {
        // D11: prefer a genuinely localized YouTube id (non-English prefs only), else the meta's default id.
        var yt = m.trailerYouTubeID.flatMap { $0.isEmpty ? nil : $0 }
        let languages = TMDBClient.preferredTrailerLanguages.filter { $0 != "en" }
        if !languages.isEmpty {
            let pick = await TMDBClient.preferredTrailerPick(metaID: m.id, type: m.type, preferredLanguages: languages)
            if pick.matchedPreferred, let localized = pick.key, !localized.isEmpty { yt = localized }
        }
        return yt.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Trailer chip. Plays the meta's FULL trailer as a one-off through the player (no torrent, no meta,
    /// no progress / auto-next). Shown whenever the meta carries a trailer (direct stream or a YouTube id),
    /// on Lite the YouTube path resolves through the remote `trailer.vortx.tv/yt`, so the chip is no longer
    /// hidden there. The URL (incl. the D11 localized-id pick) is resolved on tap.
    @ViewBuilder private func trailerChip(_ m: CoreMetaItem) -> some View {
        if hasFullTrailer(m) {
            Button {
                Task { @MainActor in await playFullTrailerInApp(m) }
            } label: {
                Label("Trailer", systemImage: "film")
            }
            .buttonStyle(ChipButtonStyle())
            // #95 SECONDARY action (long-press): hand the trailer straight to the YouTube app. The
            // PRIMARY tap stays in-app playback; this is for viewers who prefer the YouTube app (its
            // account language/captions) or whose in-app path is failing. Only offered when the meta
            // actually carries a YouTube id (a direct-only trailer has nothing to open over there).
            .contextMenu {
                if m.trailerYouTubeID?.isEmpty == false {
                    Button {
                        Task { @MainActor in await openTrailerInYouTubeApp(m) }
                    } label: {
                        Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
    }

    /// #95 PRIMARY path (chip tap): play the FULL trailer in-app, exactly the pre-#95 chip behavior,
    /// but every request now carries `trailerYouTubeID` so a dead load can be rescued by the YouTube
    /// app inside TVPlayerView instead of dead-ending on "Trailer unavailable".
    @MainActor private func playFullTrailerInApp(_ m: CoreMetaItem) async {
        // #95: the YouTube id the player hands to the YouTube app if the in-app load dies. The D11
        // language-preferred pick when the YouTube path resolves one; the meta's default id when a
        // direct (non-YouTube) stream short-circuits the resolve below.
        var rescueID = m.trailerYouTubeID.flatMap { $0.isEmpty ? nil : $0 }
        // DEVICE-DIRECT FIRST: resolve the YouTube stream on the user's own IP (InnerTube from
        // the app; a residential IP gets the full streamingData, incl. adaptive 1080p+). A direct
        // (non-YouTube) trailer stream still short-circuits everything (no resolver needed).
        if directTrailerURL(m) == nil, let yt = await preferredTrailerYouTubeID(m) {
            rescueID = yt
            if let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
                NSLog("[yt-direct] tvOS trailer button: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
                // FIX I applies here too: isTrailer keeps a dead link off the engine's content streams.
                presenter.request = PlaybackRequest(url: resolved.videoURL, title: "\(m.name) Trailer",
                                                    isTrailer: true, trailerYouTubeID: yt,
                                                    audioSidecarURL: resolved.audioURL)
                return
            }
        }
        guard let url = await resolveFullTrailerURL(m) else { return }
        NSLog("[yt-direct] tvOS trailer button: fallback-worker")
        // FIX I: tag this as a trailer so a dead /yt route shows "Trailer unavailable" instead
        // of failing over to the engine's content streams (which would play the actual/random movie).
        presenter.request = PlaybackRequest(url: url, title: "\(m.name) Trailer", isTrailer: true,
                                            trailerYouTubeID: rescueID)
    }

    /// #95 SECONDARY action (chip long-press): open the trailer in the YouTube app with the SAME D11
    /// language-preferred id the in-app path plays, so the user's trailer-language preference carries
    /// over. `UIApplication.open` itself reports failure when no YouTube app is installed (no
    /// canOpenURL, no plist allowlist); on that failure this falls back to the normal in-app playback
    /// (whose own dead-end still ends at the "Trailer unavailable" note), so the action never
    /// silently does nothing.
    @MainActor private func openTrailerInYouTubeApp(_ m: CoreMetaItem) async {
        guard let yt = await preferredTrailerYouTubeID(m) else { return }
        YouTubeAppOpener.openTrailer(youTubeID: yt) { opened in
            if opened {
                DiagnosticsLog.log("trailer", "tvOS trailer served by the YouTube app (chip long-press) id=\(yt)")
            } else {
                DiagnosticsLog.log("trailer", "YouTube app unavailable (chip long-press); falling back to in-app playback id=\(yt)")
                Task { @MainActor in await playFullTrailerInApp(m) }
            }
        }
    }

    private func metaRow(_ m: CoreMetaItem) -> some View {
        HStack(spacing: Theme.Space.md) {
            if let imdb = m.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            if let r = m.releaseInfo { Text(r) }
            if let rt = m.runtime { Text(rt) }
            let genres = m.genres
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// Compact cross-provider ratings row ("IMDb 8.5  ·  RT 92%  ·  MC 81  ·  TMDB 78%"), fed by the VortX
    /// ratings service (no user key needed), with the user's MDBList key filling any gap. Shown only when
    /// ratings came back; renders nothing otherwise (no error UI). Non-focusable, same typography as metaRow
    /// so it reads as a second fact line under the title and never disturbs the first-screen focus chain.
    @ViewBuilder private func ratingsRow() -> some View {
        if let text = mdbRatings.flatMap(Self.ratingsText), !text.isEmpty {
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Build the joined ratings string from the decoded model, or nil when nothing is present.
    private static func ratingsText(_ r: MDBListRatings) -> String? {
        var parts: [String] = []
        if let v = r.imdb { parts.append("IMDb \(imdbFmt.string(from: NSNumber(value: v)) ?? String(v))") }
        if let v = r.rottenTomatoes { parts.append("RT \(v)%") }
        if let v = r.metacritic { parts.append("MC \(v)") }
        if let v = r.tmdb { parts.append("TMDB \(v)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Movie budget + box office (+ profit multiple), a third fact line under the ratings. Opt-out via the
    /// "Show budget & box office" setting; movies-only and hidden when TMDB has no figures.
    @ViewBuilder private func financialsRow() -> some View {
        if showFinancials, type != "series", let f = financials {
            let text = Self.financialsText(f)
            if !text.isEmpty {
                Text(text).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    /// "Budget $200M  ·  Box Office $1.4B  ·  Profit 7.0x" - both values (Arvio shows budget only) plus a profit multiple.
    private static func financialsText(_ f: TMDBClient.Financials) -> String {
        var parts: [String] = []
        if let b = TMDBClient.shortMoney(f.budget) { parts.append("Budget \(b)") }
        if let r = TMDBClient.shortMoney(f.revenue) { parts.append("Box Office \(r)") }
        if f.budget > 0, f.revenue > 0 { parts.append(String(format: "Profit %.1fx", Double(f.revenue) / Double(f.budget))) }
        return parts.joined(separator: "  ·  ")
    }

    /// "In theaters Mar 1, 2024  ·  Digital May 21, 2024" - both dates, each shown only when TMDB has it. Movies only.
    @ViewBuilder private func releaseDatesRow() -> some View {
        if type != "series", let d = releaseDates {
            let text = Self.releaseDatesText(d)
            if !text.isEmpty {
                Text(text).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private static func releaseDatesText(_ d: TMDBClient.ReleaseDates) -> String {
        var parts: [String] = []
        if let t = d.theatrical { parts.append("In theaters \(t)") }
        if let g = d.digital { parts.append("Digital \(g)") }
        return parts.joined(separator: "  ·  ")
    }

    /// One-decimal IMDb formatter (8.5, not 8.50). `static let` to avoid per-row allocation.
    private static let imdbFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /// The season of the episode the viewer was LAST on (from the resume videoId), decoupled from the
    /// watched-gate seriesPrimaryEpisode applies. Opening Details from Continue Watching should land on the
    /// season you were last in, even if that episode is now marked watched (seriesPrimaryEpisode would jump to
    /// the next-unwatched season instead). nil when there is no resume position, so the caller falls back to the
    /// primary/next-unwatched season. seriesPrimaryEpisode still drives the Resume/Play button unchanged.
    private func resumeSeasonHint(_ videos: [CoreVideo], metaID: String) -> Int? {
        let videoId: String? = profiles.activeUsesEngineHistory
            ? core.metaDetails?.libraryItem?.state.videoId
            : profiles.watch[metaID]?.videoId
        guard let videoId else { return nil }
        return sortedEpisodes(videos).first { $0.id == videoId }?.season
    }

    private func seriesPrimaryEpisode(_ videos: [CoreVideo], watched: Set<String>, metaID: String) -> (video: CoreVideo, isResume: Bool)? {
        let sorted = sortedEpisodes(videos)
        // Resume position: the engine's library entry is account level, so overlay
        // profiles resolve theirs from the profile overlay instead (the same
        // invariant as the ticks and the progress stripes).
        let resume: (videoId: String?, timeOffset: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[metaID]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        if resume.timeOffset > 0,
           let videoId = resume.videoId,
           let video = sorted.first(where: { $0.id == videoId }),
           !watched.contains(video.id) {
            return (video, true)
        }
        if let next = sorted.first(where: { !watched.contains($0.id) }) {
            return (next, false)
        }
        return sorted.first.map { ($0, false) }
    }

    private func primaryEpisodeLabel(_ video: CoreVideo, isResume: Bool, resumeSeconds: Double? = nil) -> String {
        let prefix = isResume ? String(localized: "Resume") : String(localized: "Play")
        let base: String = {
            guard let season = video.season else { return "\(prefix) \(String(localized: "Episode")) \(video.episodeNumber)" }
            return "\(prefix) S\(season) E\(video.episodeNumber)"
        }()
        // On a resume, append where playback picks up ("Resume S1 E3 · 1:03"), the timestamp the button seeks to.
        if let timecode = resumeSeconds.flatMap(resumeTimecode) { return "\(base)  ·  \(timecode)" }
        return base
    }

    /// The saved resume position (seconds) for the series' primary episode, respecting the per-profile
    /// invariant: engine-history profiles read the engine library item's `timeOffset`; overlay profiles
    /// read their own entry. Read-only. Nil when the parked episode isn't `video` or there is none.
    private func primaryEpisodeResumeSeconds(_ video: CoreVideo, metaID: String) -> Double? {
        let saved: (videoId: String?, timeOffsetMs: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[metaID]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        guard saved.timeOffsetMs > 0, saved.videoId == video.id else { return nil }
        return saved.timeOffsetMs / 1000
    }

    private func seasonEpisodes(videos: [CoreVideo], season: Int) -> [CoreVideo] {
        sortedEpisodes(videos).filter { ($0.season ?? 0) == season }
    }

    private func sortedEpisodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.sorted {
            let leftSeason = $0.season ?? 0
            let rightSeason = $1.season ?? 0
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let leftEpisode = $0.episode ?? 0
            let rightEpisode = $1.episode ?? 0
            if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
            return $0.id < $1.id
        }
    }

    private func episodeProgress(_ video: CoreVideo, metaID: String) -> Double {
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[metaID], entry.videoId == video.id else { return 0 }
            return entry.progress
        }
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == video.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }
}

/// Series episodes grouped by season: a season selector, then the chosen season's episodes with
/// thumbnails. Selecting an episode loads that episode's streams from the engine.
struct CoreSeasonedEpisodes: View {
    let meta: CoreMetaItem
    let videos: [CoreVideo]
    var watched: Set<String> = []
    var initialSeason: Int?
    @AppStorage("vortx.spoilerBlur") private var spoilerBlur = true   // observed so a Settings toggle redraws; effective value via SpoilerBlurSetting (user wins over the RemoteConfig fleet default)
    // Spoiler-safe mode (SourcePreferences.spoilerSafeKey): veil an UNWATCHED episode's art + synopsis until it
    // is revealed. On tvOS the reveal is FOCUS: the focused row (focusedEpisode == v.id) un-blurs + shows its
    // synopsis, peripheral unwatched rows stay veiled. Observed via @AppStorage on the same flat key so a later
    // Settings toggle redraws. Read-only against `watched` (never a watch write).
    @AppStorage("vortx.detail.spoilerSafe") private var spoilerSafe = true
    @State private var showBulkMenu = false
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe so accent ticks recolor on theme change
    @EnvironmentObject private var profiles: ProfileStore   // per-profile progress + live updates

    @EnvironmentObject private var presenter: PlayerPresenter   // observe the player closing (#7 return-to-episode)
    @State private var season: Int = 1
    @State private var didApplyInitial = false   // once the initial-season hint lands (or the user taps a season), stop re-applying it
    @State private var seasonClampPending = false   // the next season change is the programmatic validity clamp, not a real pick, so it must not lock the hint
    @FocusState private var focusedEpisode: String?   // drives focus (and tvOS auto-scroll) to the current episode
    // Cached so a re-render (watch-state updates arrive often) does not re-filter and
    // re-sort the episode list every time. seasons depends only on the immutable
    // `videos`; episodes additionally on `season`.
    @State private var seasons: [Int] = []
    @State private var episodes: [CoreVideo] = []

    /// The engine's CURRENT resume episode id for this series (advances as continuous-play moves through
    /// episodes), read from the same source as resumeSeasonHint: the engine library for the main profile,
    /// the per-profile overlay otherwise. This is where Back should land after continuous play (#7).
    private var resumeVideoId: String? {
        profiles.activeUsesEngineHistory ? core.metaDetails?.libraryItem?.state.videoId : profiles.watch[meta.id]?.videoId
    }
    private var resumeSeason: Int? { resumeVideoId.flatMap { id in videos.first { $0.id == id }?.season } }

    private func recomputeSeasons() { seasons = Array(Set(videos.map { $0.season ?? 0 })).sorted() }
    private func recomputeEpisodes() {
        episodes = videos.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "\(episodes.count) episode\(episodes.count == 1 ? "" : "s")", title: "Episodes")

            // Always render the season chips, even for a single season: they are the
            // only home of the bulk watched menu (long press), so hiding them left
            // single-season shows with no season or series level mark-watched at all.
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text(seasonLabel(s)) }
                                .buttonStyle(ChipButtonStyle(selected: season == s))
                                .contextMenu {
                                    Button { core.markSeasonWatched(s, true) } label: {
                                        Label("Mark \(seasonLabel(s)) Watched", systemImage: "checkmark.circle")
                                    }
                                    Button { core.markSeasonWatched(s, false) } label: {
                                        Label("Mark \(seasonLabel(s)) Unwatched", systemImage: "arrow.uturn.backward")
                                    }
                                    Button { core.markWatched(true) } label: {
                                        Label("Mark Whole Series Watched", systemImage: "checkmark.circle.fill")
                                    }
                                    Button { core.markWatched(false) } label: {
                                        Label("Mark Whole Series Unwatched", systemImage: "circle")
                                    }
                                }
                        }
                        // The discoverable face of the bulk menu (long-pressing a season
                        // chip is the shortcut for the same actions).
                        Button { showBulkMenu = true } label: {
                            Image(systemName: "ellipsis")
                        }
                        .buttonStyle(ChipButtonStyle())
                        .confirmationDialog("Mark watched", isPresented: $showBulkMenu, titleVisibility: .visible) {
                            Button("\(seasonLabel(season)) watched") { core.markSeasonWatched(season, true) }
                            Button("\(seasonLabel(season)) unwatched") { core.markSeasonWatched(season, false) }
                            Button("Whole series watched") { core.markWatched(true) }
                            Button("Whole series unwatched") { core.markWatched(false) }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
                }
            }

            VStack(spacing: Theme.Space.sm) {
                ForEach(episodes) { v in episodeRow(v).focused($focusedEpisode, equals: v.id) }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
        }
        .onAppear { applyPreferredSeason() }
        // #7: when the player closes, continuous-play may have advanced to a LATER episode (even a later
        // season). The detail page stays mounted behind the player, so this panel keeps the season/focus it
        // launched from. On close, jump to the episode the engine now resumes at: switch season if it moved,
        // then focus that row (tvOS auto-scrolls focus into view) so Back returns to the CURRENT episode, not
        // the one originally launched. Async so the row exists after a season switch and the shell is frontmost.
        .onChange(of: presenter.request == nil) {
            guard presenter.request == nil, let id = resumeVideoId, videos.contains(where: { $0.id == id }) else { return }
            if let s = resumeSeason, s != season, seasons.contains(s) { season = s }
            DispatchQueue.main.async { focusedEpisode = id }
        }
        .onChange(of: season) {
            // A manual tap or the programmatic preferred-season apply locks the auto-pick, so a later
            // videos-arrived pass never clobbers the season you chose. The validity CLAMP below is exempt:
            // it is a stopgap while episodes stream in, and locking on it would shut out a not-yet-loaded
            // Continue-Watching hint before it can land.
            if seasonClampPending { seasonClampPending = false }
            else { didApplyInitial = true }
            recomputeEpisodes()
        }
        // A series' `videos` often stream in AFTER this panel first renders, so the season/episode lists built
        // on first appear can be stale or empty, and the initial-season hint (from Continue Watching) may not
        // resolve until they arrive. Re-run the resolver when the videos array grows so the hint still lands.
        .onChange(of: videos.count) { applyPreferredSeason() }
    }

    /// Resolve and apply the preferred season, re-applying the Continue-Watching `initialSeason` hint until it
    /// actually lands on a season present in `seasons` (guarded by `didApplyInitial` so a manual tap is never
    /// overridden when late videos arrive). This is what makes "open Details on the season I was last watching"
    /// survive the common case where a large series' episode list streams in after the panel first appears.
    private func applyPreferredSeason() {
        recomputeSeasons()
        if !didApplyInitial {
            let preferred = initialSeason ?? firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
            if seasons.contains(preferred) {
                season = preferred   // triggers onChange(season) -> didApplyInitial = true
            }
        }
        if !seasons.contains(season) {
            let clamped = seasons.first { $0 > 0 } ?? seasons.first ?? 1
            if clamped != season { seasonClampPending = true; season = clamped }
        }
        recomputeEpisodes()
    }

    private var firstUnwatchedSeason: Int? {
        videos
            .sorted {
                let leftSeason = $0.season ?? 0
                let rightSeason = $1.season ?? 0
                if leftSeason != rightSeason { return leftSeason < rightSeason }
                let leftEpisode = $0.episode ?? 0
                let rightEpisode = $1.episode ?? 0
                if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
                return $0.id < $1.id
            }
            .first { !watched.contains($0.id) }?
            .season
    }

    /// Spoiler-safe veil for one episode on the detail list: mode ON, the episode is NOT watched, and it is
    /// NOT the currently focused row. Read-only against `watched` (never a write), so it honours the
    /// per-profile watch invariant. tvOS reveals by FOCUS, so the focused row is always un-veiled.
    private func spoilerVeiled(_ v: CoreVideo, isWatched: Bool) -> Bool {
        spoilerSafe && !isWatched && focusedEpisode != v.id
    }

    private func episodeRow(_ v: CoreVideo) -> some View {
        let isWatched = watched.contains(v.id)
        let progress = episodeProgress(v)
        return NavigationLink {
            CoreEpisodeStreams(meta: meta, video: v, season: v.season ?? season, episodes: meta.orderedEpisodes)   // ALL seasons → cross-season auto-advance
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                thumbnail(v, isWatched: isWatched, progress: progress)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.Palette.accent)
                        }
                        Text("\(v.episode ?? 0). \(episodeTitle(v))")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(isWatched ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                            .lineLimit(2)
                    }
                    if let released = v.released, released.count >= 10 {
                        Text(String(released.prefix(10))).font(.system(size: 16)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    if spoilerVeiled(v, isWatched: isWatched) {
                        // Synopsis withheld until this row is focused (spoiler-safe mode). Focusing the row
                        // reveals it (below); peripheral rows read as hidden.
                        Label("Focus to reveal", systemImage: "eye.slash")
                            .font(.system(size: 18)).foregroundStyle(Theme.Palette.textTertiary)
                            .accessibilityLabel("Description hidden")
                    } else if let overview = v.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 18)).foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
        }
        .buttonStyle(RowFocusStyle())
        .contextMenu {
            Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                core.markVideoWatched(v, !isWatched)
            }
        }
    }

    private func thumbnail(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        // Effective spoiler-blur: the user's explicit setting wins; else the RemoteConfig fleet default
        // (`features.spoilerBlur`); else baked true, identical to shipping when no remote config is present.
        // `_ = spoilerBlur` keeps the view observing the @AppStorage so a Settings toggle triggers a redraw.
        _ = spoilerBlur
        // Hide future-episode imagery until watched OR revealed. On tvOS the reveal is FOCUS, and only in the
        // new spoiler-safe mode: gating focus-reveal on `spoilerSafe` keeps the legacy thumbnail-blur setting
        // behaving exactly as shipped (blurred regardless of focus) when the new mode is off.
        let revealed = isWatched || (spoilerSafe && focusedEpisode == v.id)
        let blurArt = !revealed && (spoilerSafe || SpoilerBlurSetting.isEnabled)
        return AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface2.overlay(
                Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 300, height: 170)
        .blur(radius: blurArt ? 20 : 0)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay {
            if blurArt {
                Image(systemName: "eye.slash.fill").font(.title3).foregroundStyle(.white.opacity(0.85)).shadow(radius: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.Palette.accent).padding(8).shadow(radius: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if !isWatched, progress > 0.01 {
                ProgressStripe(value: progress).padding(Theme.Space.xs)
            }
        }
        .opacity(isWatched ? 0.55 : 1)
    }

    private func episodeProgress(_ v: CoreVideo) -> Double {
        // Overlay profiles read their own history; the engine's library entry is
        // account level and would show the main profile's position (same invariant
        // as the watched ticks).
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[meta.id], entry.videoId == v.id else { return 0 }
            return entry.progress
        }
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == v.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }

    private func episodeTitle(_ v: CoreVideo) -> String {
        let title = v.title ?? ""
        return title.isEmpty ? "Episode \(v.episode ?? 0)" : title
    }
    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }
}

/// Loads + shows the streams for one episode (engine `meta_details` with the episode as stream path).
struct CoreEpisodeStreams: View {
    let meta: CoreMetaItem
    let video: CoreVideo
    let season: Int
    var episodes: [CoreVideo] = []
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore   // per-profile engine-history gate (activeUsesEngineHistory)
    @EnvironmentObject private var presenter: PlayerPresenter   // observe the player closing (binge-advance refresh)

    // The episode this page currently SHOWS. Seeded from the pushed `video`, but re-pointed on player dismissal
    // when continuous play advanced past it: this page stays mounted behind the player (no onAppear re-fires), so
    // without this it froze on the launch episode forever (symptom 1) and its Watch-Now built a PlaybackMeta for
    // the wrong episode (symptom 3's identity half). Every label, the backdrop, and the PlaybackMeta handed to
    // CoreStreamList derive from `currentVideo`, so the page shows and plays the binge-advanced episode. This is
    // the pushed-page twin of the CoreSeasonedEpisodes #7 return-to-episode signal, which only covered the grid.
    @State private var currentVideo: CoreVideo

    init(meta: CoreMetaItem, video: CoreVideo, season: Int, episodes: [CoreVideo] = []) {
        self.meta = meta
        self.video = video
        self.season = season
        self.episodes = episodes
        _currentVideo = State(initialValue: video)
    }

    /// The engine's CURRENT resume episode id for this series (advances as continuous play moves through
    /// episodes): the account-level engine library for the main profile, the per-profile overlay otherwise.
    /// Same source the grid's #7 signal reads. With fix 2 the engine's `state.videoId` is trustworthy input.
    private var resumeVideoId: String? {
        profiles.activeUsesEngineHistory ? core.metaDetails?.libraryItem?.state.videoId : profiles.watch[meta.id]?.videoId
    }

    /// The season the page shows: follows `currentVideo` so a cross-season binge advance re-labels correctly.
    private var shownSeason: Int { currentVideo.season ?? season }

    var body: some View {
        ZStack {
            FullBleedBackdrop(url: currentVideo.thumbnail ?? meta.background ?? meta.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Spacer().frame(height: 400)   // let the episode still own the top of the screen
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(meta.name.uppercased())
                            .font(Theme.Typography.eyebrow).tracking(1.5)
                            .foregroundStyle(Theme.Palette.accent)
                        Text(episodeTitle)
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        episodeMetaRow
                        if let overview = currentVideo.overview, !overview.isEmpty {
                            Text(overview)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4).lineSpacing(2)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    CoreStreamList(title: "\(meta.name) · S\(shownSeason)·E\(currentVideo.episode ?? 0)",
                                   meta: PlaybackMeta(libraryId: meta.id, videoId: currentVideo.id, type: meta.type,
                                                      name: meta.name, poster: meta.poster,
                                                      season: currentVideo.season, episode: currentVideo.episode),
                                   episodes: episodes,
                                   episodeStreamId: currentVideo.id,   // scope by episodic context (covers collections/franchise too)
                                   imdbId: {
                                       if let dv = meta.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
                                       return meta.id.hasPrefix("tt") ? meta.id : nil
                                   }())
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: currentVideo.id) }
        // Binge-advance refresh: when the player closes, continuous play may have advanced past the episode this
        // page launched from. Follow the engine's resume episode so the page (title, backdrop, meta, and the
        // Watch-Now PlaybackMeta) shows the CURRENT episode, and re-point meta_details at it so a second Watch-Now
        // resolves + plays THAT episode's streams. Guarded on a real move to a known episode, so a no-op close
        // (paused, same episode) leaves the page untouched.
        .onChange(of: presenter.request == nil) {
            guard presenter.request == nil, let id = resumeVideoId, id != currentVideo.id,
                  let moved = episodes.first(where: { $0.id == id }) else { return }
            currentVideo = moved
            core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: moved.id)
        }
    }

    /// Season/episode, air date, then the show-level facts (runtime, rating, genres) for context.
    private var episodeMetaRow: some View {
        HStack(spacing: Theme.Space.md) {
            Text("S\(shownSeason) · E\(currentVideo.episode ?? 0)")
            if let released = currentVideo.released, released.count >= 10 { Text(String(released.prefix(10))) }
            if let rt = meta.runtime { Text(rt) }
            if let imdb = meta.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            let genres = meta.genres
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    private var episodeTitle: String {
        let t = currentVideo.title ?? ""
        return t.isEmpty ? "Episode \(currentVideo.episode ?? 0)" : t
    }
}

/// Full-screen backdrop for the cinematic pages: the artwork fills the entire viewport (no dead black
/// band anywhere), with canvas scrims that keep the lower text block and the leading edge readable
/// while the image stays vivid up top. Content scrolls over it.
struct FullBleedBackdrop: View {
    let url: String?
    // Series often have no landscape `background` and fall back to the PORTRAIT poster: .fill would crop a
    // tall image inside the wide hero band, so the series hero passes .fit. Defaults to .fill (movies + all
    // other call sites have a 16:9 backdrop and want it edge-to-edge), keeping those paths unchanged.
    var contentMode: ContentMode = .fill
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: URL(string: url ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
                    default: Theme.Palette.surface1
                    }
                }
            }
            .clipped()
            .overlay(
                // Light hand: the artwork stays vivid across most of the screen; just enough
                // canvas at the bottom for rows and at the leading edge for the text block.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Theme.Palette.canvas.opacity(0.18), location: 0.50),
                    .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.78),
                    .init(color: Theme.Palette.canvas.opacity(0.88), location: 1.0),
                ], startPoint: .top, endPoint: .bottom))
            .overlay(
                LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                               startPoint: .leading, endPoint: .center))
            .ignoresSafeArea()
    }
}

/// The per-addon stream list from the engine: source filter chips + each addon's streams shown
/// exactly as the addon labelled them (name + full description), with direct/debrid vs torrent.
/// A stable-identity source row: a content id (`CoreStream.id`) plus an occurrence index disambiguates
/// duplicate streams that share the same id, so the ~4/sec republish no longer reassigns every row's identity
/// (which stranded the tvOS focus handle and defeated Lazy diffing). Built bounded to the render window, so the
/// per-row string work stays capped no matter how many thousand sources a title returns.
private struct SourceRow: Identifiable { let id: String; let addon: String; let stream: CoreStream }

struct CoreStreamList: View {
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [CoreVideo] = []               // the season's episodes (series only), for the player's Prev/Next/Episodes
    /// The episode id to scope stream assembly + the readiness gate to (binge-desync fix, symptom 3). Set by the
    /// episodic page (CoreEpisodeStreams) so the list only ever assembles + plays THIS episode's groups, never the
    /// episode the engine's meta_details last resolved. Scoped by episodic CONTEXT, not meta.type, so franchise /
    /// collection pages (a non-series meta routed to seriesPage) are covered too. nil on movie/live pages -> unscoped.
    var episodeStreamId: String? = nil
    /// The title's imdb id (tt...) for the TorBox search-as-a-source lookup, when known. nil = no search
    /// contribution (also the no-imdb-id case, e.g. a live channel). The feature is further gated on a
    /// TorBox key inside `TorBoxSearchSource.refresh`.
    var imdbId: String? = nil
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @State private var sourceFilter: String? = nil
    @State private var sourceRefreshDebounce: Task<Void, Never>? = nil
    private static let sourceRefreshDebounceMs = 400   // trailing settle for the add-on load storm, mirrors coalesceMs intent
    @State private var showAllSources = false   // the full ranked list is revealed on demand (Watch-Now first)
    // Render only the top N ranked rows at a time; a popular title returns 4000+ sources and instantiating
    // every row (even lazily) plus reassigning identity ~4x/sec starved the tvOS focus engine. "Show more"
    // grows the window by a step. Ranking + auto-pick still run over the FULL list; this caps RENDERING only.
    @State private var sourceRenderLimit = Self.sourceWindowInitial
    private static let sourceWindowInitial = 100
    private static let sourceWindowStep = 100
    @State private var showQualityPicker = false   // level 1: pick a resolution tier
    @State private var qualityTier: String? = nil  // level 2: pick a flavor inside that tier
    @State private var settleTimedOut = false      // opens the Watch-Now gate even if an add-on hangs
    @State private var hasSeatedFocus = false      // one-shot: seat focus on Watch Now once, then leave the user alone
    // FIX H (take 3): seat the detail page's initial focus on Watch Now, not the Trailer chip. The movie
    // page lays the trailer chip out ABOVE this list, so without an explicit default the focus engine parks
    // on Trailer. The earlier takes set `.defaultFocus($watchFocused, true)` but ONLY bound $watchFocused to
    // the READY button (`if let best`), which does not exist on first appear while sources are still loading
    // - so defaultFocus had no target and tvOS fell back to the first focusable (the trailer chip). This
    // take binds $watchFocused to the loading AND no-sources buttons too, so the target always exists and
    // focus follows the one primary-action slot as it transitions loading -> ready, plus a one-shot
    // programmatic seat (.task below) as belt-and-suspenders over defaultFocus (only a hint tvOS can drop).
    // It only sets WHERE focus lands; it does not touch the RemoteCatcher model.
    @FocusState private var watchFocused: Bool
    @EnvironmentObject private var presenter: PlayerPresenter   // root-replacement player presentation
    @ObservedObject private var pinStore = SourcePinStore.shared   // pinned source floats to top + row menu/badge (#15)
    // Debrid cache AWARENESS: which raw torrents the user's debrid account has cached, so they badge +
    // rank up. Empty (no badges, ranking unchanged) with no debrid key configured.
    @StateObject private var debridCache = DebridCacheAwareness()
    // TorBox search-as-a-source (gated on a TorBox key): extra usenet + torrent sources from the public
    // TorBox search index, merged into the list. Empty (list unchanged) with no TorBox key.
    @StateObject private var torboxSearch = TorBoxSearchSource()
    // Community source index ("Singularity"): SERVE (merges corroborated pooled sources when the toggle is
    // on + signed in) + HOARD (fire-and-forget descriptor contribution). Fully gated + fail-soft inside
    // `SourceIndexClient`; keyed on this title's content id (imdb, plus :S:E for an episode's PlaybackMeta).
    @StateObject private var sourceIndex = SourceIndexServeSource()
    // Media servers (Plex/Jellyfin/Emby): resolves this title on the user's connected servers and merges the
    // direct-play hits as their own tier. Empty (list unchanged) with no server connected (dormant).
    @StateObject private var mediaServers = MediaServerSource()
    // Stremio account (api.strem.io). NOTE: the source-index SERVE read is gated on the VORTX-SYNC account
    // (VortXSyncManager, the moat-token identity), NOT this one -- see refreshSourceIndex().
    @EnvironmentObject private var account: StremioAccount
    // Offline-download state (#30, tvOS): the device-local index drives the Download chip's three
    // affordances (Download / Downloading / Downloaded) the same way iOS does. Device-local only; nothing
    // here syncs or touches the account library.
    @ObservedObject private var downloads = DownloadStore.shared
    /// Once the user has confirmed (and dismissed) the storage-eviction warning the first time, never show
    /// it again. Per device (a plain @AppStorage bool), not synced.
    @AppStorage("stremiox.downloadEvictionAck") private var downloadEvictionAck = false
    /// Compact rows (#117): show each source as its parsed quality line (resolution · format · size)
    /// instead of the add-on's raw release name/blurb. Device-local; iOS/Mac read the SAME key.
    @AppStorage("vortx.streams.compactLabels") private var compactLabels = false
    /// Drives the first-download confirmation dialog; carries the resolve closure to run on confirm.
    @State private var pendingDownload: (() -> Void)?
    /// Smart Source Selection (Lane A) auto-pick guard. Set once when the auto-pick fires so it never
    /// re-triggers; a viewer who backs out of the player lands on the full source list (the escape hatch).
    @State private var didAutoPick = false

    /// Pin context derived from the title being shown - a movie pin or a show pin, both keyed by the
    /// library (meta) id. A series episode list passes a `type: "series"` PlaybackMeta, so every episode
    /// shares the one show pin.
    private var pinContext: SourcePinContext? { meta.map { SourcePinContext(metaId: $0.libraryId, isSeries: $0.type == "series") } }
    private var sourcePin: ResolvedPin? { pinContext.flatMap { pinStore.effectivePin($0) } }
    /// A live channel has no fixed file to save, so the offline Download chip is hidden for it.
    private var isLive: Bool { meta.map { LiveTypes.contains($0.type) } ?? false }

    /// The saved resume position (seconds) for this title/episode, or nil when there is none. Reads the
    /// SAME per-profile source `play(_:)` seeks to: the engine library item for engine-history profiles
    /// (via `engineResumeSeconds`), the overlay's own entry otherwise (via `ProfileStore.resumeOffset`).
    /// Suppressed for live channels (they no-op resume). Read-only; writes nothing.
    private var resumeSeconds: Double? {
        guard let meta, !isLive else { return nil }
        let secs = core.engineResumeSeconds(for: meta) ?? ProfileStore.shared.resumeOffset(for: meta)
        return secs >= 1 ? secs : nil
    }

    /// Owns the source-list assembly + ranking OFF the SwiftUI render path (see `SourceListModel`):
    /// snapshot -> merge -> tombstone subtraction -> direct-links filter -> rank, coalesced at ~250 ms
    /// and run off-main, publishing once per real change. This body reads only the published output,
    /// so the CoreBridge revision storm during source search costs it nothing (the earlier
    /// DetailRankMemo cached only the rank and still re-assembled + re-signed per body eval).
    @StateObject private var sourceList = SourceListModel()

    var body: some View {
        // While the player is up the tvOS shell stays MOUNTED behind it (RootView renders the player over an
        // opacity(0).disabled() RootTabView, it does not unmount the shell), so this body re-evaluates on every
        // CoreBridge @Published bump. Rebuilding a 1000+ stream ranked list behind the video saturates the main
        // thread and starves the mpv Metal surface of a layout pass (the "video stuck in a small rectangle /
        // 30s stall" symptom). Skip the whole rankedGroups(displayGroups(...)) + best + watchReady work and hold
        // a same-size placeholder; the view stays mounted so its @State (filter / collapse / picker) survives and
        // the list + focus target restore unchanged when the player closes (presenter.request flips back to nil).
        if presenter.request != nil {
            return AnyView(Color.clear.frame(minHeight: 1))
        }
        // Per-series quality memory: bias Watch Now toward the quality signature of
        // whatever this title played last (per profile), so a series you watch in a
        // specific quality keeps opening in it. Cached/instant still outranks it.
        let remembered = meta.flatMap { LastStreamStore.entry(for: $0.libraryId, profileID: ProfileStore.shared.activeID)?.qualityText }
        // Read the ranked list from the SourceListModel's published output. This body still re-evaluates
        // on every CoreBridge @Published bump while the list is open, but each eval is now a couple of
        // published-array reads: the assembly (merges + tombstones + direct-links filter) AND the rank
        // both run off-main inside the model, coalesced to at most ~4 rebuilds/sec. setContext is a few
        // cheap reads behind an equality guard, safe from body.
        // SCOPE TO THIS EPISODE (binge-desync fix, symptom 3's stream half): the episodic page passes the
        // episode's own id (episodeStreamId) so the list only ever assembles + plays THIS episode's stream
        // groups, never whatever episode the engine's meta_details last resolved (a binge-advanced later
        // episode). Mirrors iOS, which already passes `streamId: video.id`. Scoping by the explicit
        // episodic-context id, not meta.type, keeps franchise/collection pages (a non-series meta routed to
        // seriesPage) scoped too. Movies and live pass nil -> unscoped, unchanged.
        sourceList.setContext(metaId: meta?.libraryId ?? "", streamId: episodeStreamId, continuity: remembered, pin: sourcePin)
        let groups = sourceList.groups                               // best source first within each add-on
        let best = sourceList.best
        let streamCount = groups.reduce(0) { $0 + $1.streams.count }
        let visible = groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
        // Window the RENDERED rows: build at most `sourceRenderLimit` stable-id rows from the visible groups,
        // stopping the moment the budget is hit (bounded string work, no matter how many thousand sources land).
        // Ranking + auto-pick (playBest below) still read the FULL `groups`, never these windowed rows, so
        // Watch-Now always picks the GLOBAL best, not the best of the first 100.
        var seen: [String: Int] = [:]
        var rows: [SourceRow] = []
        rows.reserveCapacity(sourceRenderLimit)
        buildRows: for g in visible {
            for s in g.streams {
                let base = s.id
                let n = seen[base, default: 0]; seen[base] = n + 1
                rows.append(SourceRow(id: "\(base)#\(n)", addon: g.addon, stream: s))
                if rows.count >= sourceRenderLimit { break buildRows }
            }
        }
        let shownRows = rows
        let visibleCount = visible.reduce(0) { $0 + $1.streams.count }   // total in the filtered view, for "Show more"
        let hasMore = visibleCount > shownRows.count
        // Scope the readiness gate to THIS episode too (binge-desync fix): the unscoped progress counts every
        // episode's add-ons that ever loaded into meta_details, so a stale page would read "ready" off the
        // binge-advanced episode's counts and one press would resolve against streams that are not this
        // episode's. Scoped, Watch-Now waits on THIS episode's add-ons (worst case it shows "Finding best…").
        let addons = episodeStreamId.map { core.streamLoadProgress(forStreamId: $0) } ?? core.streamLoadProgress()
        let loadingAddons = addons.total == 0 || addons.loaded < addons.total

        // Watch-Now stays greyed until (nearly) every add-on has answered, so one press plays the
        // best of ALL sources, not the best of whoever answered first. A hung add-on can't hold the
        // button hostage: the timeout opens the gate anyway.
        let watchReady = !loadingAddons || settleTimedOut

        return AnyView(VStack(alignment: .leading, spacing: Theme.Space.md) {
            // Singularity renders INLINE ONLY: its merged group flows through the ranked list like any
            // add-on, sortable with the user's sort (owner decision; the pinned duplicate section that
            // floated an unsortable top-6 above the list was removed on both platforms).
            if let best {
                // Watch-Now first: one press plays the best source; long-press picks another resolution;
                // the full ranked list stays tucked behind "All sources".
                HStack(spacing: Theme.Space.md) {
                    // Stays FOCUSABLE while gated (a disabled button is unfocusable on tvOS, which
                    // dumped focus onto the Quality chip); the action is simply inert until the
                    // add-ons settle, then the same focused button springs alive in place.
                    Button { if watchReady { playBest(best, in: groups) } } label: {
                        if watchReady {
                            // watchLabel derives from the EXACT stream this button plays, so it
                            // can never promise a quality it doesn't deliver. A saved resume position
                            // turns the lead-in into "Resume · 1:03" (playback already seeks there).
                            let lead = resumeSeconds.flatMap(resumeTimecode).map { "\(String(localized: "Resume"))  ·  \($0)  ·  " } ?? String(localized: "Watch in ")
                            Label { Text(verbatim: "\(lead)\(StreamRanking.watchLabel(best))") } icon: { Image(systemName: "play.fill") }
                        } else {
                            HStack(spacing: Theme.Space.sm) {
                                ProgressView().tint(Theme.Palette.onAccent)
                                Text(verbatim: String(localized: "Finding best…  \(addons.loaded)/\(addons.total)"))
                            }
                        }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .opacity(watchReady ? 1 : 0.55)
                    .focused($watchFocused)   // FIX H: target of the page's default focus

                    // "Play from start" (backlog E): a secondary chip beside the primary "Resume · 1:03",
                    // shown only when a saved resume position exists. Plays the SAME best source the primary
                    // Watch/Resume would (never re-runs source selection, per the play-from-start invariant),
                    // just from 0:00, and leaves the stored resume point untouched. Mirrors iOS iOSDetailView.
                    if resumeSeconds != nil {
                        // Fires the instant it is shown: it lives inside `if let best` (a candidate already
                        // exists) and only appears for a title that has played before, so a returning press
                        // replays the remembered source from 0 via playBest's exact-source path. It does NOT
                        // share Watch-Now's `watchReady` add-on-settle gate: that gate made the chip a silent
                        // no-op during the multi-second settle window (the "Play from start does nothing"
                        // report), while the primary button at least showed a spinner. No dead press here.
                        Button { playBest(best, in: groups, fromStart: true) } label: {
                            Label("Play from start", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }

                    // The visible quality dropdown, two levels: resolution tier first (4K / 1080p /
                    // 720p / Others), then the flavors inside it (Dolby Vision · Remux, HDR · Atmos, …).
                    Button { showQualityPicker = true } label: {
                        Label("Quality", systemImage: "chevron.up.chevron.down")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .confirmationDialog("Pick a quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
                        ForEach(sourceList.tiers, id: \.self) { tier in
                            Button(tier) {
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 250_000_000)   // let level 1 dismiss first
                                    qualityTier = tier
                                }
                            }
                        }
                    }
                    .background {
                        Color.clear.confirmationDialog(qualityTier ?? "",
                                                       isPresented: Binding(get: { qualityTier != nil },
                                                                            set: { if !$0 { qualityTier = nil } }),
                                                       titleVisibility: .visible) {
                            if let tier = qualityTier {
                                ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                                    Button(option.label) { play(option.stream) }
                                }
                            }
                        }
                    }

                    Button { withAnimation { showAllSources.toggle() } } label: {
                        Label(showAllSources ? "Hide sources" : "All sources · \(streamCount)",
                              systemImage: showAllSources ? "chevron.up" : "list.bullet")
                    }
                    .buttonStyle(ChipButtonStyle(selected: showAllSources))

                    // Offline download of the auto-picked best source (#30). Same three-state feedback as
                    // iOS: Download (idle, only when watchReady) / Downloading / Downloaded. Disabled while
                    // sources still settle so it can't queue a half-ranked pick. Hidden for LIVE channels,
                    // which have no fixed file to save.
                    if !isLive {
                        downloadChip(ready: watchReady) { requestDownload { Task { await downloadBest(best) } } }
                    }

                    LibraryChip()
                    WatchlistChip()
                }
                // #16: why the recommended source was auto-picked - the rank decision the per-row tags don't show.
                if let reason = StreamRanking.pickReason(best) {
                    Text("Picked for \(reason)")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if loadingAddons && addons.total > 0 {
                    Text("Still finding more · \(addons.loaded)/\(addons.total) add-ons")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if showAllSources {
                    if groups.count > 1 { filterBar(groups, total: streamCount) }
                    // LazyVStack so only on-screen rows are built; the window caps how many rows exist at all,
                    // keeping the focus tree small. Rows carry a stable content id (SourceRow), so the ~4/sec
                    // republish no longer reshuffles the focus handle mid-scroll.
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(shownRows) { row in streamRow(row.addon, row.stream) }
                        if hasMore {
                            Button { sourceRenderLimit += Self.sourceWindowStep } label: {
                                Label("Show more · \(visibleCount - shownRows.count) more", systemImage: "chevron.down")
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                    }
                    // The source column is its own focus section, so "Show more" stays reachable and a press
                    // can't dump focus to the tab bar. The Watch-Now default-focus seat sits ABOVE this section,
                    // outside it, so seating is unaffected.
                    .focusSection()
                }
            } else if loadingAddons {
                // Searching: a focusable, primary-styled loading button (focus can't escape to the tab bar
                // while sources arrive). It flips to "Watch in …" the moment the first source lands.
                Button {} label: {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().tint(Theme.Palette.onAccent)
                        Text(addons.total > 0 ? "Finding sources…  \(addons.loaded)/\(addons.total)" : "Finding sources…")
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .focused($watchFocused)   // FIX H take 3: the default-focus target must exist in THIS (loading) state too
            } else {
                // Done, nothing playable: a greyed (disabled-looking) button + an explanation. Focusable so Back works.
                Button {} label: { Label("No sources found", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(PrimaryActionStyle())
                    .opacity(0.55)
                    .focused($watchFocused)   // FIX H take 3: keep the seat valid in the no-sources state as well
                Text("None of your \(addons.total) add-on\(addons.total == 1 ? "" : "s") returned a playable source for this title.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        // Greedy width so the column never shrinks to its widest child. Without this, the Watch-Now state
        // (just two buttons + a status line, no full-width row yet) collapsed to button-width and an
        // enclosing ScrollView centered it, the "black bar with two buttons in the middle" bug.
        .frame(maxWidth: .infinity, alignment: .leading)
        // FIX H: on appear, seat focus on Watch Now (above) rather than letting the focus engine pick the
        // first focusable view, which on the movie page is the Trailer chip laid out higher up.
        .defaultFocus($watchFocused, true)
        .task {
            // Belt-and-suspenders over .defaultFocus (a hint tvOS drops when a sibling like the trailer chip
            // is laid out first): force the seat onto the Watch Now slot once, just after appear. One-shot
            // via hasSeatedFocus so it never yanks focus back after the user has moved it.
            guard !hasSeatedFocus else { return }
            try? await Task.sleep(for: .milliseconds(60))
            hasSeatedFocus = true
            watchFocused = true
        }
        .task {
            try? await Task.sleep(for: .seconds(12))
            settleTimedOut = true
        }
        // Smart Source Selection (Lane A): auto-pick my best source, scoped to a SERIES episode page (meta
        // type "series"), which is only ever reached by pushing CoreEpisodeStreams. The inline movie / live
        // detail list (meta type "movie" / a live type) is deliberately excluded, so opening a movie detail
        // never auto-starts playback. Waits for the SAME settle gate (`resolveSettled`) the manual Watch uses,
        // then routes through the EXISTING `playBest` auto-pick. Fires once; a manual pick (presenter.request
        // set) or backing out cancels/short-circuits it, leaving the full list.
        .task {
            guard SourcePreferences.shared.autoPickBest, meta?.type == "series", !didAutoPick else { return }
            let remembered = meta.flatMap { LastStreamStore.entry(for: $0.libraryId, profileID: ProfileStore.shared.activeID)?.qualityText }
            var firstBestAt: Date?
            var step = 0
            // Honor cancellation: SwiftUI cancels this .task when the page pops, so the loop must BAIL the
            // instant that happens instead of spinning up to 120 main-actor iterations during the pop
            // animation and firing playBest onto a dismissed view (the ac4e3f1 cancel-fire class).
            while !Task.isCancelled, step < 120 {                   // ~30s ceiling (250 ms steps)
                step += 1
                if presenter.request != nil || didAutoPick { return }   // a manual pick / re-entry: stand down
                let progress = core.streamLoadProgress()
                if sourceList.best != nil, firstBestAt == nil { firstBestAt = Date() }
                let elapsed = firstBestAt.map { Date().timeIntervalSince($0) } ?? 0
                let settled = settleTimedOut || StreamRanking.resolveSettled(
                    sourceList.groups, loaded: progress.loaded, total: progress.total,
                    secondsSinceFirstPlayable: elapsed, rememberedQuality: remembered)
                if let best = sourceList.best, settled {
                    // Re-check right before firing: the view may have popped (task cancelled) or a manual pick
                    // landed during this iteration, so never route playBest onto a dismissed page.
                    guard !Task.isCancelled, presenter.request == nil, !didAutoPick else { return }
                    didAutoPick = true
                    playBest(best, in: sourceList.groups)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }   // cancelled during the sleep (page popped): stop, do not fire
            }
        }
        // Debrid cache awareness: as add-ons answer (the load count climbs), check which raw torrents the
        // user's debrid account has cached. `refresh` de-dups by the hash set, so this only hits a provider
        // when the torrents change; with no debrid key it returns an empty set and nothing renders or re-ranks.
        .onChange(of: core.streamLoadProgress().loaded) { _ in scheduleSourceRefresh() }
        // The Singularity pool answers asynchronously (a network fetch), so re-run the debrid cache check when
        // its streams arrive: this is what lets a pooled torrent's infoHash be checked against the user's own
        // debrid account (and a pooled nzb against their TorBox) and then RESOLVE per-user, not just render.
        .onChange(of: sourceIndex.streams.count) { _ in scheduleSourceRefresh() }
        // Reset the render window when the list collapses (so re-expanding starts fresh at the top) or the
        // title changes (a new list should not inherit the previous title's expanded window).
        .onChange(of: showAllSources) { _ in if !showAllSources { sourceRenderLimit = Self.sourceWindowInitial } }
        .onChange(of: meta?.libraryId) { _ in sourceRenderLimit = Self.sourceWindowInitial }
        // TorBox search-as-a-source: fetch the extra usenet/torrent sources (gated on a TorBox key + de-duped
        // by imdb id inside refresh). Live channels pass nil, so this no-ops for them. Also wires the
        // source-list model to this screen's sources (idempotent; nudges a refresh on re-appear).
        .onAppear {
            sourceList.bind(core: core, torbox: torboxSearch, singularity: sourceIndex,
                            mediaServers: mediaServers, debridCache: debridCache)
            torboxSearch.refresh(imdbId: imdbId)
            mediaServers.refresh(imdb: imdbId, title: meta?.name)
            refreshSourceIndex()
        }
        .onDisappear { sourceRefreshDebounce?.cancel() }
        // First-download storage-eviction warning (#30). Apple TV has no user-visible file system and the
        // OS can reclaim app storage under pressure, so a saved download may be removed by the system. Show
        // this once; on confirm we remember the ack and run the queued download, on cancel we drop it.
        .confirmationDialog("Save this download to Apple TV?",
                            isPresented: Binding(get: { pendingDownload != nil },
                                                 set: { if !$0 { pendingDownload = nil } }),
                            titleVisibility: .visible) {
            Button("Download") {
                downloadEvictionAck = true
                let run = pendingDownload
                pendingDownload = nil
                run?()
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: {
            Text("tvOS can reclaim app storage when the device runs low, so a saved download may be removed by the system. Re-download it any time it is gone.")
        })
    }

    // MARK: Offline download (#30)

    /// The offline-download state for this list's video id, derived from `DownloadStore`. Mirrors iOS's
    /// `downloadChipState`: no record -> offer a download, an active record -> "Downloading", a completed
    /// record -> "Downloaded". Returns `.none` when there is no `meta` (e.g. a bare Search call site).
    private enum DownloadChipState { case none, inProgress, done }

    private func downloadChipState() -> DownloadChipState {
        guard let videoId = meta?.videoId,
              let record = downloads.records.first(where: { $0.videoId == videoId && $0.state != .failed }) else { return .none }
        return record.state == .completed ? .done : .inProgress
    }

    /// A focus-driven Download chip with state feedback (#30), the tvOS twin of the iOS `downloadChip`. The
    /// idle state offers a download (enabled only when `ready`); while a record is active it shows a spinner
    /// + "Downloading" and is disabled; once complete it shows a "Downloaded" check and is disabled. The
    /// action runs only from the idle state, so a press can't re-queue an in-flight or finished download.
    @ViewBuilder private func downloadChip(ready: Bool, action: @escaping () -> Void) -> some View {
        let state = downloadChipState()
        Button {
            if state == .none { action() }
        } label: {
            switch state {
            case .done:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
            case .inProgress:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView()
                    Text("Downloading")
                }
            case .none:
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .buttonStyle(ChipButtonStyle())
        .disabled(state != .none || !ready)
    }

    /// Gate a download behind the one-time eviction warning. The first time, stash the resolve closure and
    /// open the confirmation dialog (which runs it on confirm); after the user has acknowledged it once,
    /// run immediately.
    private func requestDownload(_ run: @escaping () -> Void) {
        if downloadEvictionAck { run() } else { pendingDownload = run }
    }

    /// "Download best": the offline twin of Watch Now, downloading the already-ranked best source. Resolves
    /// the URL EXACTLY as `playResolving` does (cached-debrid direct link preferred, else the source's
    /// `playableURL`) and hands the SAME `PlaybackMeta` this list carries to `DownloadManager`. Device-local
    /// only; writes nothing to the account / libraryItem docs. No-op without a `meta` or a playable URL.
    @MainActor private func downloadBest(_ best: CoreStream) async {
        guard let pm = meta else { return }
        let resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: best, episode: downloadEpisode(pm))
        guard let url = resolved ?? best.playableURL else { return }
        DownloadManager.shared.download(stream: best, meta: pm, resolvedURL: url,
                                        sourceName: best.name, qualityText: StreamRanking.signature(best))
    }

    /// The episode context for a debrid resolve, so a series episode resolves to the right file inside a
    /// season pack (matching `iOSDetailView.downloadBestSeries`). Nil for a movie / live.
    private func downloadEpisode(_ pm: PlaybackMeta) -> DebridEpisode? {
        guard pm.type == "series", let s = pm.season, let e = pm.episode else { return nil }
        return DebridEpisode(season: s, episode: e)
    }

    /// The pool `content_id` for this list: the title's imdb id, plus `:S:E` when the `PlaybackMeta` carries
    /// a season + episode (a series episode list). nil when no imdb id is known (e.g. a live channel).
    private var sourceContentID: String? {
        SourceIndexClient.contentID(imdbId: imdbId, season: meta?.season, episode: meta?.episode)
    }

    /// Community source index (tvOS): SERVE refresh + HOARD contribution for this title/episode. Fully gated
    /// + fail-soft inside `SourceIndexClient` (consent / fleet flag / Singularity toggle / login). De-duped
    /// per content id; safe to call as sources stream in.
    ///
    /// SIGN-IN IDENTITY: the SERVE read is gated on the VORTX-SYNC account, not the Stremio account. The moat
    /// token that un-gates `sources.vortx.tv` is minted from the VortX session bearer (`VortXSyncManager`), so
    /// a Stremio-only sign-in mints no token and the worker returns an empty `login_required` list. Gate on the
    /// same identity that mints the token so a signed-in VortX user actually sees pooled sources.
    private func refreshSourceIndex(torboxMerged: [CoreStreamSourceGroup]? = nil) {
        guard let contentID = sourceContentID else { return }
        let vortxSignedIn = VortXSyncManager.shared.isSignedIn
        sourceIndex.refresh(contentID: contentID, isSignedIn: vortxSignedIn)
        // Pool-EXCLUDED hoard set: the caller's torbox-base when it already merged one (avoids a second walk),
        // else self-merge. NEVER the Singularity-pool-inclusive set: hoarding the pool's own results back into
        // itself would be wrong.
        let groups = torboxMerged ?? torboxSearch.merged(into: core.streamGroups())
        guard !groups.isEmpty else { return }
        Task.detached { await SourceIndexClient.hoard(contentID: contentID, groups: groups) }
    }

    /// Trailing-debounced driver for the add-on load storm: the raw `.onChange` fired per add-on completion,
    /// each doing full O(N) merge walks on main. Coalesce to one pass ~400 ms after the burst settles, and
    /// compute the torbox-base ONCE so the debrid (pool-inclusive) and hoard (pool-excluded) sets share it.
    private func scheduleSourceRefresh() {
        sourceRefreshDebounce?.cancel()
        sourceRefreshDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.sourceRefreshDebounceMs))
            guard !Task.isCancelled else { return }
            let torboxBase = torboxSearch.merged(into: core.streamGroups())   // pool-EXCLUDED (hoard set)
            // Pool-INCLUDED: cache awareness needs the raw torrents / usenet nzbs the Direct-links-only filter
            // would drop, plus the TorBox search AND Singularity pool sources, so those rows badge AND resolve
            // through the user's OWN debrid (torrent -> debrid, usenet -> TorBox). Orthogonal to the filter.
            debridCache.refresh(from: sourceIndex.merged(into: torboxBase))
            refreshSourceIndex(torboxMerged: torboxBase)   // reuse the same base; no second merge walk
        }
    }

    /// Play a stream by handing a request to the root, which swaps the whole shell out for the player
    /// (the only reliable tvOS focus isolation, see RootView). Wires the engine + prepares torrents first.
    ///
    /// CACHED DEBRID: for a RAW TORRENT the user's debrid account can serve, play the debrid DIRECT link
    /// instead of starting the local torrent engine. The resolve is bounded and FAIL-SOFT: any
    /// failure/timeout (and the entire no-key path, with zero await) falls through to today's embedded path,
    /// byte-identical. A debrid URL is a remote direct link, so it is presented with `torrent: false` and
    /// skips `prepareTorrent` (no `/create`); the player keys torrent behaviour off the URL shape, so it
    /// treats this as a direct stream automatically (no warm-up, no `closeTorrent`).
    private func play(_ stream: CoreStream) {
        // #95: a tapped TRAILER row (a Streailer/YouTube `ytId` source) is NOT a content stream. Route it to
        // the trailer path (isTrailer:true, meta:nil) so a dead trailer hits TVPlayerView's isTrailer guard
        // ("Trailer unavailable") and STOPS, instead of failing over to the title's content streams and
        // playing the actual movie. Every normal content stream still goes through `playResolving` unchanged.
        if stream.isYouTubeTrailer {
            Task { @MainActor in await playTrailerStream(stream) }
            return
        }
        Task { await playResolving(stream, explicit: true) }   // a tapped source row / quality pick: honor it in the player
    }

    /// #95: play a source-list TRAILER row (an `isYouTubeTrailer` `ytId` stream) the SAME reliable way the
    /// built-in `trailerChip` does: resolve the YouTube id device-direct first (InnerTube on the user's own
    /// IP, adaptive 1080p+ with an audio sidecar), and only on a miss fall back to the worker `/yt/{id}` URL
    /// WITH a `?lang=` hint so the worker returns the user's dub. Tagged `isTrailer: true` (dead link shows
    /// "Trailer unavailable", never hops to content) with NO meta (no Continue-Watching, no auto-next).
    @MainActor private func playTrailerStream(_ stream: CoreStream) async {
        let name = title.isEmpty ? "Trailer" : "\(title) Trailer"
        if let yt = stream.youTubeTrailerID,
           let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
            NSLog("[yt-direct] tvOS trailer row: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
            presenter.request = PlaybackRequest(url: resolved.videoURL, title: name,
                                                isTrailer: true, trailerYouTubeID: yt,
                                                audioSidecarURL: resolved.audioURL)
            return
        }
        // Device-direct missed: the worker URL WITH the language hint (the plain `playableURL` appends none).
        guard let url = stream.youTubeTrailerWorkerURL(languageCode: TMDBClient.trailerLanguageBaseCode)
                ?? stream.playableURL else { return }
        NSLog("[yt-direct] tvOS trailer row: fallback-worker")
        // #95: the id rides along so a dead /yt route is rescued by the YouTube app before the note.
        presenter.request = PlaybackRequest(url: url, title: name, isTrailer: true,
                                            trailerYouTubeID: stream.youTubeTrailerID)
    }

    /// AUTO-PICK play (the "Watch Now" button + resolution long-press): race the top few CACHED sources in
    /// parallel so we reach a genuinely-cached link fast instead of committing to `best` alone, which, when
    /// `best` is a false-cached row (an add-on ⚡ that this account does not actually hold), serially times
    /// out before the user reaches a real one. `groups` is already StreamRanking-ordered (continuity / binge /
    /// pin applied), so flattening it preserves that order as the candidate order. FAIL-SOFT: if the parallel
    /// race yields nothing (no confirmed-cached row, or every leg failed) it falls straight through to today's
    /// single-resolve `play(best)`, so the no-key / no-cache path is unchanged. A MANUAL row tap still calls
    /// `play(_:)` directly (`streamRow`), resolving exactly the row the user chose.
    private func playBest(_ best: CoreStream, in groups: [CoreStreamSourceGroup], fromStart: Bool = false) {
        Task { await playBestResolving(best, in: groups, fromStart: fromStart) }
    }

    @MainActor private func playBestResolving(_ best: CoreStream, in groups: [CoreStreamSourceGroup], fromStart: Bool = false) async {
        // EXACT-SOURCE RESUME (owner requirement): if this title was last played through a specific debrid
        // source, resume THAT source directly - reresolve a fresh link for the same file - instead of
        // re-running source selection across every add-on (the "Tried N sources / this source didn't load"
        // failure). Only when the stored source is genuinely gone do we drop to the auto-pick race below.
        if let m = meta,
           let entry = LastStreamStore.entry(for: m.libraryId, profileID: ProfileStore.shared.activeID),
           entry.debridService != nil, let hash = entry.infoHash, !hash.isEmpty,
           // Movie: always this title. Series: only when the stored episode is the one being played.
           (m.type != "series" || entry.videoId == m.videoId),
           !(PlaybackSettings.torrentsDisabled && entry.torrent == true) {
            let (url, refreshed) = await CWResume.resolvedURL(for: entry)
            if refreshed, let service = entry.debridService.flatMap(DebridService.init(rawValue:)) {
                // A fresh link for the SAME source: play it as an EXPLICIT pick (no silent hop) so the resume
                // honors the user's chosen source, exactly as a manual source-row tap would. Carry the debrid
                // provenance so the play-record re-stores it and the NEXT resume can reresolve again.
                core.loadEnginePlayer(for: best)
                presenter.request = PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes,
                                                    sourceHint: entry.qualityText, torrent: false,
                                                    bingeGroup: entry.bingeGroup, headers: entry.headers,
                                                    debridRef: DebridPlaybackRef(url: url, service: service,
                                                        infoHash: hash, torrentId: entry.debridTorrentId,
                                                        fileId: entry.debridFileId, fileIdx: entry.fileIdx),
                                                    wasExplicitPick: true, wasResume: true, startFromZero: fromStart)
                return
            }
        }
        // Candidate order = the already-ranked list order (continuity/binge/pin preserved), best first.
        let candidates = groups.flatMap(\.streams)
        if let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs, labeledBest: best) {
            // A parallel-cached winner is a remote direct link: present it exactly as the single-resolve
            // debrid branch does (engine wired for state, torrent:false, no /create, no closeTorrent).
            core.loadEnginePlayer(for: win.stream)
            presenter.request = PlaybackRequest(url: win.ref.url, title: title, meta: meta, episodes: episodes,
                                                sourceHint: StreamRanking.signature(win.stream), torrent: false,
                                                bingeGroup: win.stream.behaviorHints?.bingeGroup,
                                                headers: win.stream.requestHeaders, startFromZero: fromStart)
            return
        }
        // No parallel-cached winner: today's single-resolve path on the ranked best, unchanged. This is an
        // AUTO pick (the Watch-Now fallback), so it may hop normally on a start-timeout.
        await playResolving(best, explicit: false, fromStart: fromStart)
    }

    /// `explicit`: true when the user tapped this exact source row / quality (honor it in the player, no
    /// silent hop on a start-timeout); false when it is the auto Watch-Now single-resolve fallback.
    @MainActor private func playResolving(_ stream: CoreStream, explicit: Bool, fromStart: Bool = false) async {
        // INSTANT FIRST-PLAY: cache-gate the manual resolve on the account-confirmed sets so only a genuinely
        // cached pick runs the blocking debrid resolve (~1 round trip to the direct link); a not-confirmed pick
        // returns nil with zero network and falls straight through to the embedded path below, which plays in a
        // snap (its own playableURL + prepareTorrent) exactly like the pre-511c973 instant path.
        if let direct = await DebridCoordinator.shared.resolvedPlaybackURL(
            for: stream, confirmedCachedHashes: debridCache.cachedHashes,
            confirmedUsenetURLs: debridCache.cachedUsenetURLs) {
            core.loadEnginePlayer(for: stream)
            presenter.request = PlaybackRequest(url: direct, title: title, meta: meta, episodes: episodes,
                                                sourceHint: StreamRanking.signature(stream), torrent: false,
                                                bingeGroup: stream.behaviorHints?.bingeGroup,
                                                headers: stream.requestHeaders, wasExplicitPick: explicit,
                                                startFromZero: fromStart)
            return
        }
        // Today's path, unchanged.
        guard let url = stream.playableURL else { return }
        core.loadEnginePlayer(for: stream)
        prepareTorrent(stream)
        presenter.request = PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes,
                                            sourceHint: StreamRanking.signature(stream), torrent: stream.isTorrent,
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            headers: stream.requestHeaders, wasExplicitPick: explicit,
                                            startFromZero: fromStart)
    }

    private func filterBar(_ groups: [CoreStreamSourceGroup], total: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                Button { sourceFilter = nil } label: { Text("All (\(total))") }
                    .buttonStyle(ChipButtonStyle(selected: sourceFilter == nil))
                ForEach(groups) { group in
                    Button { sourceFilter = group.addon } label: { Text("\(group.addon) (\(group.streams.count))") }
                        .buttonStyle(ChipButtonStyle(selected: sourceFilter == group.addon))
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if stream.playableURL != nil {
            Button { play(stream) } label: { streamLabel(addon, stream, enabled: true, pinned: isPinned(addon, stream), debridCached: isDebridCached(stream), lastPlayed: isLastPlayed(stream)) }
                .buttonStyle(RowFocusStyle())
                .contextMenu { pinMenu(addon, stream) }
        } else {
            // Non-playable (Ratings/RPDB, external/youtube): keep it FOCUSABLE via an inert Button so
            // the tvOS focus engine can land here and keep scrolling DOWN past it. A bare non-focusable
            // first row blocked the whole "All sources" list from scrolling (issue #77). The enabled:false
            // label still dims and shows the lock icon, so it reads as non-playable.
            Button {} label: { streamLabel(addon, stream, enabled: false) }
                .buttonStyle(RowFocusStyle())
        }
    }

    /// True when this row is confirmed cached in the user's debrid account (drives the row ⚡). A raw torrent
    /// matches by infoHash; a USENET row matches its nzb link against the usenet-cached set. False for every
    /// stream when both sets are empty (no key / not yet checked), so no chips render.
    private func isDebridCached(_ stream: CoreStream) -> Bool {
        if let nzb = stream.nzbUrl, !nzb.isEmpty {
            return !debridCache.cachedUsenetURLs.isEmpty && debridCache.cachedUsenetURLs.contains(nzb)
        }
        guard !debridCache.cachedHashes.isEmpty, let h = stream.infoHash?.lowercased() else { return false }
        return debridCache.cachedHashes.contains(h)
    }

    /// True when this stream matches the effective pin - drives the row's pin badge.
    private func isPinned(_ addon: String, _ stream: CoreStream) -> Bool {
        guard let pin = sourcePin else { return false }
        return SourcePinStore.matches(stream, addon: addon, pin: pin)
    }

    /// The source this title/episode last PLAYED (per profile), so its row can carry a "Played" mark and the
    /// viewer can see which file they chose on the previous visit (#134: "I have no idea which file I have
    /// selected"). Reads the per-profile, device-local `LastStreamStore` - the SAME store Continue-Watching
    /// direct-resume uses - so it never touches the account library and respects the per-profile-history
    /// invariant (overlay profiles keep their own store keyed on `ProfileStore.activeID`). Scoped to THIS
    /// episode for a series (a different episode's pick must not mislabel this one); nil for live channels
    /// (no meaningful source memory) or when nothing has played yet.
    private var lastPlayedEntry: LastStreamStore.Entry? {
        guard let meta, !isLive else { return nil }
        guard let entry = LastStreamStore.entry(for: meta.libraryId, profileID: ProfileStore.shared.activeID) else { return nil }
        if meta.type == "series", entry.videoId != meta.videoId { return nil }
        return entry
    }

    /// True when this row is the exact source the title/episode last played - drives the row's "Played" mark
    /// and keeps the user's chosen source visible on return instead of the list looking reset to source 0.
    /// Matches by infoHash first (a torrent / native-debrid file is unambiguous), then by the parsed quality
    /// signature (the SAME full release-text value stored as the entry's `qualityText`) so an add-on-resolved
    /// direct link still lights up. Pure reads; writes nothing.
    private func isLastPlayed(_ stream: CoreStream) -> Bool {
        guard let entry = lastPlayedEntry else { return false }
        if let h = stream.infoHash?.lowercased(), !h.isEmpty,
           let eh = entry.infoHash?.lowercased(), !eh.isEmpty {
            return h == eh
        }
        guard let q = entry.qualityText, !q.isEmpty else { return false }
        return StreamRanking.signature(stream) == q
    }

    /// Long-press menu: pin this source for the show/movie or for everything, or unpin. A pin floats its
    /// source to the top of the list + the one-press Watch pick, but failover still hops off it if dead.
    @ViewBuilder private func pinMenu(_ addon: String, _ stream: CoreStream) -> some View {
        if let ctx = pinContext {
            Button {
                pinStore.pin(stream, addon: addon, scope: .entry, context: ctx)
            } label: { Label("Pin for this \(ctx.entryNoun)", systemImage: "pin") }
            Button {
                pinStore.pin(stream, addon: addon, scope: .global, context: ctx)
            } label: { Label("Pin everywhere", systemImage: "pin.circle") }
            if pinStore.entryPin(ctx) != nil {
                Button(role: .destructive) {
                    pinStore.unpin(scope: .entry, context: ctx)
                } label: { Label("Unpin this \(ctx.entryNoun)", systemImage: "pin.slash") }
            }
            if pinStore.global != nil {
                Button(role: .destructive) {
                    pinStore.unpin(scope: .global, context: ctx)
                } label: { Label("Unpin everywhere", systemImage: "pin.slash") }
            }
        }
    }

    private func streamLabel(_ addon: String, _ stream: CoreStream, enabled: Bool, pinned: Bool = false,
                             debridCached: Bool = false, lastPlayed: Bool = false) -> some View {
        // Cached when EITHER the native coordinator confirmed this raw torrent's hash OR the add-on's own
        // text advertises it cached (⚡ / [RD+] / "cached" / …). Owner plays pre-resolved debrid-ADDON links,
        // so the hash check finds nothing; the text-marker path is what lights the badge. `signature` is the
        // public wrapper over the private `qualityText` `isCached` parses internally.
        let cached = debridCached || StreamRanking.isCached(stream, StreamRanking.signature(stream))
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle")
                .font(.system(size: 30))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    // #134: the exact source this title/episode last played, so returning to the page shows
                    // which file the viewer chose instead of the list looking reset to source 0. Accent tint
                    // (like CACHED) so it reads as a status, plus a checkmark glyph for a scan-at-a-glance mark.
                    if lastPlayed { badge("✓ PLAYED", accent: true) }
                    badge(addon.uppercased())
                    if stream.isTorrent { badge("TORRENT") }
                    // Cache chip: instant from the user's debrid account (coordinator-confirmed raw torrent)
                    // OR the add-on already advertises the source as cached. Accent tint sets it apart from
                    // the neutral add-on/torrent badges; only shown when cached.
                    if cached { badge("⚡ CACHED", accent: true) }
                }
                if compactLabels {
                    // Compact rows (#117): one parsed line ("4K · Remux · DV · Atmos · 12.4 GB") from the
                    // SAME StreamRanking parse that powers the Watch affordances, instead of the add-on's
                    // raw release name + multi-line blurb.
                    let info = StreamRanking.sourceDetail(stream)
                    Text(info.size.map { "\(info.tags) · \($0)" } ?? info.tags)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let name = stream.name, !name.isEmpty {
                        Text(name).font(Theme.Typography.cardTitle)
                            .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let desc = stream.description, !desc.isEmpty {
                        Text(desc).font(.system(size: 18)).foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(enabled ? 1 : 0.55)
        .overlay(
            // #134: a persistent accent ring on the last-played row so the chosen source stands out while
            // scanning the list even when unfocused. Matches the row shape (Theme.Radius.card, same as
            // vortxGlassRow); RowFocusStyle draws its own brighter 3px accent ring on top when focused.
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Palette.accent.opacity(0.55), lineWidth: lastPlayed ? 2 : 0)
        )
    }

    @ViewBuilder private func badge(_ text: String, accent: Bool = false) -> some View {
        let label = Text(text).font(Theme.Typography.eyebrow).tracking(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(accent ? Theme.Palette.accent : Theme.Palette.textSecondary)
        if accent {
            // The accent badge (CACHED) carries meaning through its ember tint, so it stays a SOLID accent
            // pill rather than glass (mirrors the iOS iOSStreamLabel badge split).
            label.background(Theme.Palette.accent.opacity(0.22), in: Capsule())
        } else {
            // Neutral badges (add-on name, TORRENT) become badge-alpha glass pills so they read as raised
            // chrome; the flat shadow keeps them inline without floating.
            label.vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat)
        }
    }

    /// Torrents: ask the embedded server to start fetching peers before playback. No-op for url/debrid.
    private func prepareTorrent(_ stream: CoreStream) {
        guard !PlaybackSettings.torrentsDisabled else { return }
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
        // The server's first-create-wins contract means the FIRST /create's source list sticks for
        // the engine's life, and this is the PRIMARY play path, so it must carry the TCP/TLS
        // trackers (UDP/DHT alone is unreliable in the tvOS sandbox), exactly like every other
        // create path. The old `dht:` + addon-udp-only list left a sandboxed swarm unable to form.
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
        let body: [String: Any] = ["torrent": ["infoHash": hash],
                                   "peerSearch": ["sources": sources, "min": 40, "max": 150]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }
}


/// The watch-later button: saves the open title to the library (the same library
/// the Library tab and the engine's sync use), or removes it again. State comes
/// from the engine's own library entry for this title, so it stays truthful
/// across Continue Watching, catalog, and Library entrances.
struct LibraryChip: View {
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        let saved = core.detailInLibrary
        Button {
            if saved {
                core.removeDetailFromLibrary()   // removes from library + mirrors to external watchlists
            } else {
                core.addDetailToLibrary()
            }
        } label: {
            Label(saved ? "In Library" : "Add to Library",
                  systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(ChipButtonStyle(selected: saved))
    }
}

/// Add / remove the open title from the local "want to watch" watchlist (`LibraryAutoAdd`) — a pure app-side
/// bookmark separate from the engine Library, engine-safe ids only (tt / tmdb). Reads the open title from the
/// engine detail meta exactly like `LibraryChip` reads `core.detailInLibrary`, so it needs no call-site
/// plumbing; a synthetic magnet / paste-a-link title (no tt / tmdb id) hides the chip since it can't be
/// watchlisted. The tvOS twin of the touch `iOSWatchlistChip`.
struct WatchlistChip: View {
    @EnvironmentObject private var core: CoreBridge
    @State private var isWatchlisted = false

    var body: some View {
        if let meta = core.metaDetails?.meta, meta.id.hasPrefix("tt") || meta.id.hasPrefix("tmdb") {
            Button {
                isWatchlisted = LibraryAutoAdd.toggleWatchlist(id: meta.id, type: meta.type,
                                                               name: meta.name, poster: meta.poster)
            } label: {
                Label(isWatchlisted ? "In Watchlist" : "Watchlist",
                      systemImage: isWatchlisted ? "star.fill" : "star")
            }
            .buttonStyle(ChipButtonStyle(selected: isWatchlisted))
            .onAppear { isWatchlisted = LibraryAutoAdd.isWatchlisted(meta.id) }
            .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
                isWatchlisted = LibraryAutoAdd.isWatchlisted(meta.id)
            }
        }
    }
}

/// H16 one tvOS cast entry: a circular TMDB headshot (initials disc fallback), the actor name, and the
/// character beneath. Wrapped in a focusable, borderless Button so the tvOS focus engine can land on the
/// rail and travel through it (a bare non-focusable card would block downward scrolling, the same class as
/// issue #77's non-playable source rows). Focus lifts + brightens the photo, matching the other rails.
private struct CastMemberCard: View {
    let member: TMDBClient.CastMember
    @FocusState private var focused: Bool

    var body: some View {
        // A real TMDB person id (> 0) opens the Person page; the meta name-only fallback carries a synthetic
        // NEGATIVE id (railCastMembers) with no TMDB person to look up, so it stays a focusable-but-inert card
        // exactly as before. Both stay focusable so the rail never blocks downward focus travel (see above).
        if member.id > 0 {
            NavigationLink {
                PersonView(personID: member.id, name: member.name, profileURL: member.profileURL)
            } label: { cardBody }
            // `.plain` does NOT shed the tvOS focus platter, so every focused cast member wore a rounded
            // SQUARE white slab behind its CIRCULAR photo, and the name below rendered white-on-white.
            // `cardBody` already draws this card's whole focus treatment (photo lift + ring + name
            // brighten, keyed off `focused`), so take the ring-less, scale-less variant: it stands the
            // system platter down and adds nothing that could double up on what the card already does.
            .vortxSelfFocusButton()
            .focused($focused)
            .accessibilityElement(children: .combine)
        } else {
            Button {} label: { cardBody }
            // Same as the navigable card above: the platter goes, `cardBody` keeps owning the focus look.
            .vortxSelfFocusButton()
            .focused($focused)
            .accessibilityElement(children: .combine)
        }
    }

    private var cardBody: some View {
        VStack(spacing: Theme.Space.sm) {
            photo
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 14 : 0, y: 6)
                .animation(.easeOut(duration: 0.18), value: focused)
            Text(member.name)
                .font(Theme.Typography.label)
                .foregroundStyle(focused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(2).multilineTextAlignment(.center)
            if let role = member.character, !role.isEmpty {
                Text(role)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(width: 180)
    }

    private var photo: some View {
        AsyncImage(url: URL(string: member.profileURL ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Theme.Palette.surface2
                    Text(member.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
                        .font(Theme.Typography.cardTitle.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.Palette.textPrimary.opacity(focused ? 0.3 : 0.08), lineWidth: focused ? 3 : 1))
    }
}
