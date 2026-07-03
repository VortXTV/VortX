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
            if effectiveType != "series" { loadMovieStreamsIfNeeded() }
            loadCredits()
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
        // AGGREGATE across EVERY loaded source (all add-ons), scanning BOTH `name` AND `description` per stream:
        // add-ons split the release name and the audio/sub language tags across the two fields, so `name ??
        // description` under-labelled a lazy add-on. Taking both widens the union of tokens (MULTI, DUAL,
        // KOR+ENG, audio/sub tags) we can see for this title.
        let names: [String] = core.streamGroups()
            .flatMap { $0.streams }
            .flatMap { [$0.name, $0.description] }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let key = "\(contentKey)#\(names.count)"
        guard key != langChipsKey else { return }
        langChipsKey = key

        // Split into AUDIO vs SUBTITLE claims per stream context: a bare release-name language word is an audio
        // claim (verified below); a code from a subtitle-marked string (vostfr, "ESubs", ...) is a subtitle
        // claim (kept). This split is what lets the verify drop a FALSE audio claim without dropping real subs.
        let observed = LanguageIndexClient.audioSubCodes(fromNames: names)
        let imdb = ratingsImdbID
        Task { @MainActor in
            // Community index + TMDB spoken_languages fetched in PARALLEL: the two verification sources. Both
            // fail soft to nil (no signal), so a missing source never falsely contradicts an audio claim.
            async let availabilityTask = LanguageIndexClient.fetch(contentKey: contentKey)
            async let spokenTask = TMDBClient.spokenLanguages(imdbID: imdb, type: type)
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
        }
        Task.detached {
            await LanguageIndexClient.contribute(contentKey: contentKey,
                                                 audioLangs: observed.audio,
                                                 subLangs: observed.sub,
                                                 provenance: "name")
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
                                    .background(Theme.Palette.surface2, in: Capsule())
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

    /// Fetch MDBList ratings for this title (no-op without a key / imdb id). Fail-soft: leaves the row
    /// hidden on any miss. Skipped for live channels, which carry no ratings.
    private func loadRatings() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, mdbRatings == nil else { return }
        Task {
            let r = await MDBListClient.ratings(imdbID: imdb, type: type)
            await MainActor.run { mdbRatings = r }
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
        let hasStreams = core.metaDetails?.streams.contains { $0.request.path.id == streamId } ?? false
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
                                AsyncImage(url: URL(string: provider.logoURL ?? "")) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.Palette.surface1)
                                }
                                .frame(width: 56, height: 56)
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
                                             initialSeason: primary?.video.season)
                            .id("detailContent")
                        castSection
                        whereToWatchSection
                        moreLikeThisSection
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
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
                                Text(d)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(4).lineSpacing(2)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }
                        }
                        // Flexible gap pushes the action band down to the bottom of the first screen.
                        Spacer(minLength: Theme.Space.lg)
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            languageChips
                            HStack(spacing: Theme.Space.sm) { trailerChip(m) }
                            CoreStreamList(title: m.name,
                                           meta: PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
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
        if autoplayTrailers, !reduceMotion, !LiveTypes.contains(type),
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
                Task { @MainActor in
                    // DEVICE-DIRECT FIRST: resolve the YouTube stream on the user's own IP (InnerTube from
                    // the app; a residential IP gets the full streamingData, incl. adaptive 1080p+). A direct
                    // (non-YouTube) trailer stream still short-circuits everything (no resolver needed).
                    if directTrailerURL(m) == nil,
                       let yt = await preferredTrailerYouTubeID(m),
                       let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
                        NSLog("[yt-direct] tvOS trailer button: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
                        // FIX I applies here too: isTrailer keeps a dead link off the engine's content streams.
                        presenter.request = PlaybackRequest(url: resolved.videoURL, title: "\(m.name) Trailer",
                                                            isTrailer: true, audioSidecarURL: resolved.audioURL)
                        return
                    }
                    guard let url = await resolveFullTrailerURL(m) else { return }
                    NSLog("[yt-direct] tvOS trailer button: fallback-worker")
                    // FIX I: tag this as a trailer so a dead /yt route shows "Trailer unavailable" instead
                    // of failing over to the engine's content streams (which would play the actual/random movie).
                    presenter.request = PlaybackRequest(url: url, title: "\(m.name) Trailer", isTrailer: true)
                }
            } label: {
                Label("Trailer", systemImage: "film")
            }
            .buttonStyle(ChipButtonStyle())
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

    /// Compact MDBList ratings row ("IMDb 8.5  ·  RT 92%  ·  TMDB 78%"), shown only when the user has set
    /// an MDBList key AND ratings came back. Renders nothing otherwise (no error UI). Same typography as
    /// metaRow so it reads as a second fact line under the title.
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
    @State private var showBulkMenu = false
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe so accent ticks recolor on theme change
    @EnvironmentObject private var profiles: ProfileStore   // per-profile progress + live updates

    @State private var season: Int = 1
    // Cached so a re-render (watch-state updates arrive often) does not re-filter and
    // re-sort the episode list every time. seasons depends only on the immutable
    // `videos`; episodes additionally on `season`.
    @State private var seasons: [Int] = []
    @State private var episodes: [CoreVideo] = []

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
                ForEach(episodes) { v in episodeRow(v) }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
        }
        .onAppear {
            recomputeSeasons()
            let preferred = initialSeason ?? firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
            if seasons.contains(preferred) { season = preferred }
            else if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
            recomputeEpisodes()
        }
        .onChange(of: season) { recomputeEpisodes() }
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
                    if let overview = v.overview, !overview.isEmpty {
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
        let blurArt = SpoilerBlurSetting.isEnabled && !isWatched   // hide future-episode imagery until you have watched it
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

    var body: some View {
        ZStack {
            FullBleedBackdrop(url: video.thumbnail ?? meta.background ?? meta.poster)
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
                        if let overview = video.overview, !overview.isEmpty {
                            Text(overview)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4).lineSpacing(2)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    CoreStreamList(title: "\(meta.name) · S\(season)·E\(video.episode ?? 0)",
                                   meta: PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                                                      name: meta.name, poster: meta.poster,
                                                      season: video.season, episode: video.episode),
                                   episodes: episodes,
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
        .onAppear { core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id) }
    }

    /// Season/episode, air date, then the show-level facts (runtime, rating, genres) for context.
    private var episodeMetaRow: some View {
        HStack(spacing: Theme.Space.md) {
            Text("S\(season) · E\(video.episode ?? 0)")
            if let released = video.released, released.count >= 10 { Text(String(released.prefix(10))) }
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
        let t = video.title ?? ""
        return t.isEmpty ? "Episode \(video.episode ?? 0)" : t
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
struct CoreStreamList: View {
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [CoreVideo] = []               // the season's episodes (series only), for the player's Prev/Next/Episodes
    /// The title's imdb id (tt...) for the TorBox search-as-a-source lookup, when known. nil = no search
    /// contribution (also the no-imdb-id case, e.g. a live channel). The feature is further gated on a
    /// TorBox key inside `TorBoxSearchSource.refresh`.
    var imdbId: String? = nil
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @State private var sourceFilter: String? = nil
    @State private var showAllSources = false   // the full ranked list is revealed on demand (Watch-Now first)
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
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
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
    @EnvironmentObject private var account: StremioAccount   // sign-in gate for the source-index SERVE read
    // Offline-download state (#30, tvOS): the device-local index drives the Download chip's three
    // affordances (Download / Downloading / Downloaded) the same way iOS does. Device-local only; nothing
    // here syncs or touches the account library.
    @ObservedObject private var downloads = DownloadStore.shared
    /// Once the user has confirmed (and dismissed) the storage-eviction warning the first time, never show
    /// it again. Per device (a plain @AppStorage bool), not synced.
    @AppStorage("stremiox.downloadEvictionAck") private var downloadEvictionAck = false
    /// Drives the first-download confirmation dialog; carries the resolve closure to run on confirm.
    @State private var pendingDownload: (() -> Void)?

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

    var body: some View {
        let groups = StreamRanking.rankedGroups(displayGroups(core.streamGroups()), pin: sourcePin,
                                                debridCachedHashes: debridCache.cachedHashes)   // best source first within each add-on
        let streamCount = groups.reduce(0) { $0 + $1.streams.count }
        let visible = groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
        let addons = core.streamLoadProgress()                       // (loaded, total) stream add-ons
        let loadingAddons = addons.total == 0 || addons.loaded < addons.total
        // Per-series quality memory: bias Watch Now toward the quality signature of
        // whatever this title played last (per profile), so a series you watch in a
        // specific quality keeps opening in it. Cached/instant still outranks it.
        let remembered = meta.flatMap { LastStreamStore.entry(for: $0.libraryId, profileID: ProfileStore.shared.activeID)?.qualityText }
        let best = StreamRanking.best(groups, continuity: remembered, pin: sourcePin,
                                      debridCachedHashes: debridCache.cachedHashes)

        // Watch-Now stays greyed until (nearly) every add-on has answered, so one press plays the
        // best of ALL sources, not the best of whoever answered first. A hung add-on can't hold the
        // button hostage: the timeout opens the gate anyway.
        let watchReady = !loadingAddons || settleTimedOut

        return VStack(alignment: .leading, spacing: Theme.Space.md) {
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
                    .contextMenu { resolutionMenu(groups) }
                    .focused($watchFocused)   // FIX H: target of the page's default focus

                    // The visible quality dropdown, two levels: resolution tier first (4K / 1080p /
                    // 720p / Others), then the flavors inside it (Dolby Vision · Remux, HDR · Atmos, …).
                    Button { showQualityPicker = true } label: {
                        Label("Quality", systemImage: "chevron.up.chevron.down")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .confirmationDialog("Pick a quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
                        ForEach(StreamRanking.tiers(groups), id: \.self) { tier in
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
                    // LazyVStack so only on-screen rows are built: a popular title can return 2000+ sources,
                    // and a plain VStack instantiated them all at once, OOM-crashing the Apple TV mid-load.
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(visible) { group in
                            ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                                streamRow(group.addon, stream)
                            }
                        }
                    }
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
        // Debrid cache awareness: as add-ons answer (the load count climbs), check which raw torrents the
        // user's debrid account has cached. `refresh` de-dups by the hash set, so this only hits a provider
        // when the torrents change; with no debrid key it returns an empty set and nothing renders or re-ranks.
        .onChange(of: core.streamLoadProgress().loaded) { _ in
            // Unfiltered: cache awareness needs the raw torrents / usenet nzbs the Direct-links-only filter
            // would drop, plus the TorBox search sources, so those rows badge too. Orthogonal to the filter.
            debridCache.refresh(from: torboxSearch.merged(into: core.streamGroups()))
            refreshSourceIndex()   // SERVE + HOARD the community source index as more sources answer
        }
        // TorBox search-as-a-source: fetch the extra usenet/torrent sources (gated on a TorBox key + de-duped
        // by imdb id inside refresh). Live channels pass nil, so this no-ops for them.
        .onAppear { torboxSearch.refresh(imdbId: imdbId); refreshSourceIndex() }
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
        }
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

    /// Resolution dropdown for the Watch button (long-press): the best source at each available quality.
    @ViewBuilder private func resolutionMenu(_ groups: [CoreStreamSourceGroup]) -> some View {
        ForEach(StreamRanking.resolutionOptions(groups), id: \.label) { opt in
            Button { play(opt.stream) } label: { Label("Watch in \(opt.label)", systemImage: "play.fill") }
        }
    }

    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        // Merge the TorBox search sources first (no-op with no TorBox key / no results), then the community
        // source-index sources (no-op unless the Singularity toggle is on + signed in), then apply the
        // Direct-links-only filter so a search/community source is filtered on the same rule as an add-on's.
        let withSearch = sourceIndex.merged(into: torboxSearch.merged(into: groups))
        guard directLinksOnly else { return withSearch }
        return withSearch.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The pool `content_id` for this list: the title's imdb id, plus `:S:E` when the `PlaybackMeta` carries
    /// a season + episode (a series episode list). nil when no imdb id is known (e.g. a live channel).
    private var sourceContentID: String? {
        SourceIndexClient.contentID(imdbId: imdbId, season: meta?.season, episode: meta?.episode)
    }

    /// Community source index (tvOS): SERVE refresh + HOARD contribution for this title/episode. Fully gated
    /// + fail-soft inside `SourceIndexClient` (consent / fleet flag / Singularity toggle / login). De-duped
    /// per content id; safe to call as sources stream in.
    private func refreshSourceIndex() {
        guard let contentID = sourceContentID else { return }
        sourceIndex.refresh(contentID: contentID, isSignedIn: account.isSignedIn)
        let groups = torboxSearch.merged(into: core.streamGroups())
        guard !groups.isEmpty else { return }
        Task.detached { await SourceIndexClient.hoard(contentID: contentID, groups: groups) }
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
        Task { await playResolving(stream) }
    }

    /// AUTO-PICK play (the "Watch Now" button + resolution long-press): race the top few CACHED sources in
    /// parallel so we reach a genuinely-cached link fast instead of committing to `best` alone, which — when
    /// `best` is a false-cached row (an add-on ⚡ that this account does not actually hold) — serially times
    /// out before the user reaches a real one. `groups` is already StreamRanking-ordered (continuity / binge /
    /// pin applied), so flattening it preserves that order as the candidate order. FAIL-SOFT: if the parallel
    /// race yields nothing (no confirmed-cached row, or every leg failed) it falls straight through to today's
    /// single-resolve `play(best)`, so the no-key / no-cache path is unchanged. A MANUAL row tap still calls
    /// `play(_:)` directly (`streamRow`), resolving exactly the row the user chose.
    private func playBest(_ best: CoreStream, in groups: [CoreStreamSourceGroup]) {
        Task { await playBestResolving(best, in: groups) }
    }

    @MainActor private func playBestResolving(_ best: CoreStream, in groups: [CoreStreamSourceGroup]) async {
        // Candidate order = the already-ranked list order (continuity/binge/pin preserved), best first.
        let candidates = groups.flatMap(\.streams)
        if let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs) {
            // A parallel-cached winner is a remote direct link: present it exactly as the single-resolve
            // debrid branch does (engine wired for state, torrent:false, no /create, no closeTorrent).
            core.loadEnginePlayer(for: win.stream)
            presenter.request = PlaybackRequest(url: win.ref.url, title: title, meta: meta, episodes: episodes,
                                                sourceHint: StreamRanking.signature(win.stream), torrent: false,
                                                bingeGroup: win.stream.behaviorHints?.bingeGroup,
                                                headers: win.stream.requestHeaders)
            return
        }
        // No parallel-cached winner: today's single-resolve path on the ranked best, unchanged.
        await playResolving(best)
    }

    @MainActor private func playResolving(_ stream: CoreStream) async {
        if let direct = await DebridCoordinator.shared.resolvedPlaybackURL(for: stream) {
            core.loadEnginePlayer(for: stream)
            presenter.request = PlaybackRequest(url: direct, title: title, meta: meta, episodes: episodes,
                                                sourceHint: StreamRanking.signature(stream), torrent: false,
                                                bingeGroup: stream.behaviorHints?.bingeGroup,
                                                headers: stream.requestHeaders)
            return
        }
        // Today's path, unchanged.
        guard let url = stream.playableURL else { return }
        core.loadEnginePlayer(for: stream)
        prepareTorrent(stream)
        presenter.request = PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes,
                                            sourceHint: StreamRanking.signature(stream), torrent: stream.isTorrent,
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            headers: stream.requestHeaders)
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
            Button { play(stream) } label: { streamLabel(addon, stream, enabled: true, pinned: isPinned(addon, stream), debridCached: isDebridCached(stream)) }
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
                             debridCached: Bool = false) -> some View {
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
                    badge(addon.uppercased())
                    if stream.isTorrent { badge("TORRENT") }
                    // Cache chip: instant from the user's debrid account (coordinator-confirmed raw torrent)
                    // OR the add-on already advertises the source as cached. Accent tint sets it apart from
                    // the neutral add-on/torrent badges; only shown when cached.
                    if cached { badge("⚡ CACHED", accent: true) }
                }
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
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(enabled ? 1 : 0.55)
    }

    private func badge(_ text: String, accent: Bool = false) -> some View {
        Text(text).font(Theme.Typography.eyebrow).tracking(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(accent ? Theme.Palette.accent.opacity(0.22) : Theme.Palette.surface3, in: Capsule())
            .foregroundStyle(accent ? Theme.Palette.accent : Theme.Palette.textSecondary)
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
                if let id = core.metaDetails?.meta?.id { core.removeFromLibrary(id: id) }
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

/// H16 one tvOS cast entry: a circular TMDB headshot (initials disc fallback), the actor name, and the
/// character beneath. Wrapped in a focusable, borderless Button so the tvOS focus engine can land on the
/// rail and travel through it (a bare non-focusable card would block downward scrolling, the same class as
/// issue #77's non-playable source rows). Focus lifts + brightens the photo, matching the other rails.
private struct CastMemberCard: View {
    let member: TMDBClient.CastMember
    @FocusState private var focused: Bool

    var body: some View {
        Button {} label: {
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
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityElement(children: .combine)
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
