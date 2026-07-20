import SwiftUI

/// Client-side type segmentation for the Library (Movies / TV / Anime). The engine's own type filter
/// only knows movie vs. series and cannot surface Anime, so the type row is derived here from each saved
/// title's meta type — a pure presentation grouping that leaves the engine's SORT chips and every
/// per-item action (open / remove / watched) untouched.
private enum LibrarySegment: String, CaseIterable, Identifiable {
    case all, movies, tv, anime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .movies: return String(localized: "Movies")
        case .tv: return String(localized: "TV")
        case .anime: return String(localized: "Anime")
        }
    }

    /// The bucket a saved title falls into. Library entries carry no genre field, so Anime is detected
    /// from an explicit "anime" meta type or an anime-catalog id scheme (Kitsu / AniList / MAL / AniDB);
    /// everything else splits on movie vs. the rest (series / channel / tv fold into TV).
    static func bucket(id: String, type: String) -> LibrarySegment {
        if type == "anime" { return .anime }
        let lower = id.lowercased()
        if ["kitsu:", "anilist:", "mal:", "anidb:"].contains(where: lower.hasPrefix) { return .anime }
        return type == "movie" ? .movies : .tv
    }
}

/// Client-side SMART filters for the Library: saved "smart lists" (Unwatched / In Progress / Watched /
/// Short) evaluated as predicates over each saved title, auto-updating as the library and its watch state
/// change. They read ONLY fields a library entry already carries (the read-only watched signal, engine
/// watch `progress`, and the engine's stored media runtime), so nothing here touches the account or the
/// engine's own type/sort filters. Multi-select and AND-combined, so combinations read as one smart list
/// ("Unwatched" + "Short" = unwatched short films). A field the entry does not carry (e.g. runtime for a
/// title never played) simply does not match, it never crashes.
private enum LibrarySmartFilter: String, CaseIterable, Identifiable {
    case unwatched, inProgress, watched, short
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unwatched:  return String(localized: "Unwatched")
        case .inProgress: return String(localized: "In Progress")
        case .watched:    return String(localized: "Watched")
        case .short:      return String(localized: "Short")
        }
    }

    /// Runtime strictly under this many milliseconds counts as "Short" (100 minutes).
    private static let shortRuntimeMs: Double = 100 * 60 * 1000
    /// The actively-resumable band: played into, but below the engine's own 0.9 finished ceiling.
    private static let inProgressCeil = 0.9

    /// Whether a saved title matches this filter. `watched` is the platform's read-only watched signal;
    /// `progress` is 0…1 watch progress; `durationMs` is the engine's stored media duration (0 when the
    /// title was never played, so its runtime is unknown, so "Short" cannot match it and the title is
    /// simply left out rather than crashing).
    func matches(watched: Bool, progress: Double, durationMs: Double) -> Bool {
        switch self {
        case .unwatched:  return !watched
        case .watched:    return watched
        case .inProgress: return progress > 0 && progress < Self.inProgressCeil
        case .short:      return durationMs > 0 && durationMs < Self.shortRuntimeMs
        }
    }
}

/// Library, driven by the **stremio-core** engine (`LibraryWithFilters`): the user's saved titles with
/// type + sort filters. Auto-refreshes as the library changes (add/remove/mark watched), no reload.
struct LibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected
    @EnvironmentObject private var profiles: ProfileStore   // gate the Library on the active profile's own history
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var downloads = DownloadStore.shared   // offline downloads section (#30)
    @ObservedObject private var watchedIndex = WatchedIndex.shared   // series-completion badge (#143) refreshes reactively
    /// Active client-side type segment (Movies / TV / Anime); `.all` keeps the flat, mixed grid.
    @State private var segment: LibrarySegment = .all
    /// Active client-side smart filters (Unwatched / In Progress / Watched / Short); empty = no filtering.
    /// Multi-select and AND-combined; applied on top of the type segment and the engine's sort.
    @State private var activeFilters: Set<LibrarySmartFilter> = []
    /// Cinematic landscape cards (TMDB key required) are wider, so fewer per row; portrait keeps 6-up.
    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(kLandscapeCardWidth), spacing: Theme.Space.lg), count: 3)
            : Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // The living backdrop: art owns the screen, details pinned above the strip. The
                // title, filters, and grid all live in the bottom strip and tuck under the hero.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Color.clear.frame(height: 0).scrollToTopAnchor()   // re-select Library tab -> scroll here
                        Text("Library").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                        // Offline downloads (#30): a section ABOVE the saved-titles grid, shown only when at
                        // least one download exists. Plays from the local file with pause/resume/delete +
                        // total storage used, and carries the storage-eviction caption. Device-local only.
                        if !downloads.records.isEmpty {
                            TVDownloadsView()
                                .padding(.bottom, Theme.Space.lg)
                        }
                        if profiles.activeUsesEngineHistory {
                            // Owner profile: the account library (engine). The client-side type segment
                            // (Movies / TV / Anime) replaces the engine's type chips; the engine's SORT
                            // chips stay as-is.
                            if let library = core.library {
                                if !library.catalog.isEmpty { segmentBar(library.catalog) }
                                sortChips(library.selectable)
                                if library.catalog.isEmpty {
                                    hint("Your library is empty. Add titles to your library in Stremio and they will show up here.")
                                } else {
                                    smartFilterBar(segmented(library.catalog))
                                    grid(smartFiltered(segmented(library.catalog)))
                                }
                            } else if account.isSignedIn || vortxSync.isSignedIn {
                                BigSpinner()
                                    .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
                            } else {
                                CoreEmptyState.signedOut
                            }
                        } else {
                            // Overlay profile: its own private watch overlay (never the account). No
                            // engine `selectable`, so the engine sort chips are omitted, but the
                            // client-side type segment still groups the grid.
                            let items = profiles.libraryItems
                            if items.isEmpty {
                                hint("This profile's library is empty. Titles it watches show up here.")
                            } else {
                                segmentBar(items)
                                smartFilterBar(segmented(items))
                                grid(smartFiltered(segmented(items)))
                            }
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip()
                // Re-selecting the active Library tab scrolls back to the top.
                .scrollToTopOnBump(TabScrollKeys.library)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Reload while empty: the library syncs from the API asynchronously after sign-in, so the
        // first load can land before ctx.library is populated. Revisiting the tab refills it.
        .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() }; seed() }
        .onChange(of: core.library?.catalog.first?.id) { seed() }
        .onChange(of: profiles.activeID) { seed() }
    }

    private func seed() {
        let first = profiles.activeUsesEngineHistory ? core.library?.catalog.first : profiles.libraryItems.first
        focusModel.seedIfEmpty(first?.focusedHero)
    }

    /// The engine's SORT chips (Recent / Name / Most watched …). The type row is now the client-side
    /// `segmentBar`, so only the sorts are dispatched back through the engine here.
    private func sortChips(_ selectable: CoreLibrarySelectable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(selectable.sorts) { sort in
                    Button { core.selectLibrary(sort.request) } label: { Text(sort.label) }
                        .buttonStyle(ChipButtonStyle(selected: sort.selected))
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
        }
    }

    /// The client-side type segment chips (All / Movies / TV / Anime), rendered with the shared
    /// `ChipButtonStyle` so they carry the same glass + focus treatment as every other filter chip.
    /// Shown only when the library actually spans two or more buckets — a single-type library keeps the
    /// flat grid with no redundant control.
    @ViewBuilder private func segmentBar(_ items: [CoreCWItem]) -> some View {
        let segs = availableSegments(items)
        if !segs.isEmpty {
            let active = effectiveSegment(segs)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(segs) { seg in
                        Button { segment = seg } label: { Text(seg.label) }
                            .buttonStyle(ChipButtonStyle(selected: seg == active))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
        }
    }

    /// `All` plus each bucket that actually holds titles, in a stable Movies / TV / Anime order. Returns
    /// empty (hiding the control) when fewer than two buckets are present.
    private func availableSegments(_ items: [CoreCWItem]) -> [LibrarySegment] {
        var present: Set<LibrarySegment> = []
        for it in items { present.insert(LibrarySegment.bucket(id: it.id, type: it.type)) }
        let ordered = [LibrarySegment.movies, .tv, .anime].filter(present.contains)
        return ordered.count >= 2 ? [.all] + ordered : []
    }

    /// The selected segment clamped to what's on offer, so removing the last title of a kind falls back
    /// to `All` instead of stranding the grid on an empty, now-unavailable segment.
    private func effectiveSegment(_ available: [LibrarySegment]) -> LibrarySegment {
        available.contains(segment) ? segment : .all
    }

    /// Filter the catalog to the active segment (`All` passes everything through unchanged).
    private func segmented(_ items: [CoreCWItem]) -> [CoreCWItem] {
        let seg = effectiveSegment(availableSegments(items))
        guard seg != .all else { return items }
        return items.filter { LibrarySegment.bucket(id: $0.id, type: $0.type) == seg }
    }

    /// The client-side SMART filter chips (Unwatched / In Progress / Watched / Short), rendered with the
    /// shared `ChipButtonStyle` so they carry the same glass + focus treatment as every other filter chip.
    /// Sits below the type segment and the engine's sort row. Only chips that actually SPLIT the current
    /// grid (match some but not all titles) are shown, so there are never dead or no-op controls.
    @ViewBuilder private func smartFilterBar(_ items: [CoreCWItem]) -> some View {
        let applicable = applicableFilters(items)
        if !applicable.isEmpty {
            let active = Set(effectiveFilters(items))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(applicable) { f in
                        Button { toggle(f) } label: { Text(f.label) }
                            .buttonStyle(ChipButtonStyle(selected: active.contains(f)))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
        }
    }

    /// Does a title match this smart filter, reading its already-present fields (the read-only watched
    /// signal, engine watch progress, and the engine's stored media runtime in ms)?
    private func matches(_ f: LibrarySmartFilter, _ item: CoreCWItem) -> Bool {
        f.matches(watched: isWatched(item), progress: item.progress, durationMs: item.state.duration)
    }

    /// Smart filters that meaningfully split the given (type-segmented) list: each matches at least one
    /// title but not all of them. A filter matching every title, or none, would be a no-op, so it is hidden.
    private func applicableFilters(_ items: [CoreCWItem]) -> [LibrarySmartFilter] {
        let total = items.count
        guard total > 0 else { return [] }
        return LibrarySmartFilter.allCases.filter { f in
            let n = items.reduce(0) { $0 + (matches(f, $1) ? 1 : 0) }
            return n > 0 && n < total
        }
    }

    /// The active filters clamped to what still splits the current grid, so switching type segment (or the
    /// library changing under a selection) never strands the grid on a filter that no longer applies.
    private func effectiveFilters(_ items: [CoreCWItem]) -> [LibrarySmartFilter] {
        applicableFilters(items).filter { activeFilters.contains($0) }
    }

    /// Keep only titles matching EVERY active-and-applicable smart filter (AND-combined). No active
    /// filter passes everything through unchanged.
    private func smartFiltered(_ items: [CoreCWItem]) -> [CoreCWItem] {
        let eff = effectiveFilters(items)
        guard !eff.isEmpty else { return items }
        return items.filter { item in eff.allSatisfy { matches($0, item) } }
    }

    /// Toggle a smart filter. Unwatched and Watched are mutually exclusive, so enabling one clears the
    /// other and the combined predicate never asks for the impossible (a permanently empty grid).
    private func toggle(_ f: LibrarySmartFilter) {
        if activeFilters.contains(f) {
            activeFilters.remove(f)
        } else {
            activeFilters.insert(f)
            if f == .watched { activeFilters.remove(.unwatched) }
            if f == .unwatched { activeFilters.remove(.watched) }
        }
    }

    private func grid(_ items: [CoreCWItem]) -> some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
            ForEach(items) { item in
                PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                           progress: item.progress > 0 ? item.progress : nil,
                           isWatched: isWatched(item),
                           width: kPosterWidth, landscapeWidth: kLandscapeCardWidth, menu: .library,
                           onFocus: { focusModel.focus(item.focusedHero) })
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.sm)
    }

    /// Watched badge for a Library tile, honoring the per-profile history invariant:
    /// the owner profile reads the engine's own watched bookkeeping (timesWatched);
    /// overlay profiles read only their private overlay (a whole-title mark records the
    /// metaId itself, episode finishes record episode ids), never the account's state.
    private func isWatched(_ item: CoreCWItem) -> Bool {
        // A series fully watched by its aired, regular-season episodes badges even when the engine's
        // `times_watched` never got bumped (marked, not played) — WatchedIndex holds that derived set,
        // per profile, alongside the engine bucket / overlay signal (issue #143).
        if watchedIndex.ids.contains(item.id) { return true }
        return profiles.activeUsesEngineHistory
            ? item.isWatched
            : !profiles.watchedVideoIds(forMeta: item.id).isEmpty
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.lg)
    }
}
