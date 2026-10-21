import SwiftUI

/// Match the addon media types used by the other Apple search surfaces. Keep unknown types in Other;
/// a collection returned by an addon remains its real metadata target, separate from a hub browse target.
private enum TVSearchResultGroup: String, CaseIterable {
    case movies, series, collections, other

    init(type: String) {
        switch type {
        case "movie": self = .movies
        case "series": self = .series
        case "collection", "collections": self = .collections
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .movies: return String(localized: "Movies")
        case .series: return String(localized: "Series")
        case .collections: return String(localized: "Collections")
        case .other: return String(localized: "Other")
        }
    }
}

// SearchHistoryStore moved to SourcesShared/SearchHistoryStore.swift so the iOS/Mac search screen
// can reuse it (#90 ported to touch + Mac). Same per-profile, sync-backed store.

/// The search field's text, split so the view carrying `.searchable` does not redraw while the user types.
///
/// tvOS 27 Continuity Keyboard: when the view that owns `.searchable` re-renders, SwiftUI re-sends the field
/// text to the iPhone's remote text session, which resets it. Every redraw driven by a keystroke therefore
/// erased the letter just typed, so the iPhone and the TV fought over the text (letters flashing on and off).
/// Verified on an Apple TV 4K (tvOS 27.0): a bare `.searchable` whose host reads the query flickers, while the
/// same field with a host that never redraws on typing, or a UIKit `UISearchController`, works.
///
/// So typing only updates `fieldText` (not published, read by the binding) and `live.text` (published, observed by
/// the content and suggestion views). The host observes `programmaticRevision` alone, which changes only when the
/// app itself replaces the text (a Recent Searches chip), so the field picks that change up.
@MainActor
private final class TVSearchFieldModel: ObservableObject {
    final class LiveQuery: ObservableObject {
        @Published var text = ""
    }

    @Published private(set) var programmaticRevision = 0
    private(set) var fieldText = ""
    let live = LiveQuery()
    /// Bumped on Search/Return so the content runs an immediate search without the host observing anything.
    let submitted = LiveSubmit()

    final class LiveSubmit: ObservableObject {
        @Published private(set) var count = 0
        func fire() { count += 1 }
    }

    func userTyped(_ value: String) {
        guard value != fieldText else { return }
        fieldText = value
        live.text = value
    }

    func replace(with value: String) {
        fieldText = value
        live.text = value
        programmaticRevision += 1
    }
}

/// Search across every installed addon, on the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected

    var body: some View {
        Group {
            // TVSearchHost takes no inputs, so redraws of this gate (account or sync state) do not reach it.
            if account.isSignedIn || vortxSync.isSignedIn { TVSearchHost() } else { CoreEmptyState.signedOut }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}

/// Owns `.searchable` and nothing else that changes while typing. See `TVSearchFieldModel`.
private struct TVSearchHost: View {
    @StateObject private var field = TVSearchFieldModel()

    var body: some View {
        let _ = field.programmaticRevision   // the only redraw trigger: app-initiated text changes
        ScrollView {
            TVSearchContent(field: field, live: field.live, submitted: field.submitted)
        }
        .searchable(text: Binding(get: { field.fieldText }, set: { field.userTyped($0) }),
                    prompt: "Movies, series or collections")
        .searchSuggestions {
            TVSearchSuggestions(live: field.live)
        }
        .onSubmit(of: .search) { field.submitted.fire() }
    }
}

/// Suggestions observe the engine and the live query themselves, keeping both out of the host.
private struct TVSearchSuggestions: View {
    @VisibleCore private var core
    @ObservedObject var live: TVSearchFieldModel.LiveQuery

    var body: some View {
        ForEach(core.searchSuggestionTitles(for: live.text), id: \.self) { title in
            Text(title).searchCompletion(title)
        }
    }
}

/// Everything below the search field: history, link chips, results, people. Free to redraw on every keystroke.
private struct TVSearchContent: View {
    let field: TVSearchFieldModel
    @ObservedObject var live: TVSearchFieldModel.LiveQuery
    @ObservedObject var submitted: TVSearchFieldModel.LiveSubmit
    @VisibleCore private var core   // observed only while this tab is on screen (EngineObservation.swift)
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @State private var showOpenLink = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @State private var history: [String] = []
    /// Actors and crew whose name matches the query, opened onto their Person page.
    @State private var people: [TMDBClient.PersonResult] = []
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    private var query: String { live.text }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if !history.isEmpty && !isTyping {
                historySection
            }
            if !isTyping {
                HStack(spacing: Theme.Space.sm) {
                    Button { showOpenLink = true } label: {
                        Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .sheet(isPresented: $showOpenLink) { OpenLinkView() }

                    #if !VORTX_NO_EMBEDDED_SERVER
                    NavigationLink { DebridLibraryView() } label: {
                        Label("Debrid Cloud", systemImage: "cloud")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    #endif
                }
                .focusSection()
            }
            resultGrid
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xl)
        .onChange(of: submitted.count) { _, _ in
            searchTask?.cancel()
            searchDebouncePending = false
            core.suggestSearch(query)
            searchNow(query)
        }
        .onAppear {
            collectionsHub.load()
            core.loadSearchSuggestions()
            history = SearchHistoryStore.load(profileID: profiles.activeID)
        }
        .onChange(of: live.text) { _, value in scheduleSearch(value) }
        // People lookups follow the typing, debounced; a newer query cancels the older one.
        .task(id: query.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { people = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await TMDBClient.searchPeople(query: trimmed)
            guard !Task.isCancelled else { return }
            people = found
        }
        .onChange(of: profiles.activeID) { _, id in
            history = SearchHistoryStore.load(profileID: id)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Recent Searches").sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(history, id: \.self) { term in
                        Button {
                            field.replace(with: term)
                        } label: {
                            Label(term, systemImage: "clock")
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    Button {
                        SearchHistoryStore.clear(profileID: profiles.activeID)
                        history = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.sm)
            }
            .padding(.horizontal, -Theme.Space.screenEdge)
        }
    }

    @ViewBuilder private var resultGrid: some View {
        let collections = matchingCollections
        let sections = resultSections(collections: collections)
        if !hasSearchQuery || (sections.isEmpty && people.isEmpty) {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(sections, id: \.group) { section in
                    resultRow(group: section.group, items: section.items,
                              collections: section.group == .collections ? collections : [])
                }
                if !people.isEmpty { peopleRow }
                if core.searchResults.isEmpty && isWaitingForCurrentQuery {
                    emptyState
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Space.sm) {
            if isWaitingForCurrentQuery {
                ProgressView()
                    .tint(Theme.Palette.accent)
            }
            Text(emptyText)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.Palette.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.xl)
    }

    /// "People": the cast card the detail page uses, so a focused headshot lifts and opens the same Person page.
    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("People").sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(people) { person in
                        CastMemberCard(member: .init(id: person.id, name: person.name,
                                                     character: person.department, profileURL: person.profileURL))
                            .simultaneousGesture(TapGesture().onEnded { _ in saveToHistory(query) })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)
            }
            .padding(.horizontal, -Theme.Space.screenEdge)
        }
        .focusSection()
    }

    private func resultRow(group: TVSearchResultGroup, items: [CoreMeta], collections: [HubTarget]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(group.title).sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(collections, id: \.self) { target in
                        NavigationLink { TVCategoryBrowse(target: target) } label: {
                            collectionTile(target)
                        }
                        .buttonStyle(CardFocusStyle())
                        .simultaneousGesture(TapGesture().onEnded { _ in saveToHistory(query) })
                        .accessibilityLabel(Text(LocalizedStringKey(target.title)))
                        .accessibilityHint("Opens this collection")
                    }
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   menu: .catalog)
                            .simultaneousGesture(TapGesture().onEnded { _ in saveToHistory(query) })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)
            }
            // Cancel the parent VStack's screenEdge padding so the ScrollView reaches the screen
            // edge and its clip region starts there rather than at the first card's left edge.
            .padding(.horizontal, -Theme.Space.screenEdge)
        }
    }

    private func resultSections(collections: [HubTarget]) -> [(group: TVSearchResultGroup, items: [CoreMeta])] {
        let grouped = Dictionary(grouping: core.searchResults, by: { TVSearchResultGroup(type: $0.type) })
        return TVSearchResultGroup.allCases.compactMap { group in
            let items = grouped[group] ?? []
            guard !items.isEmpty || (group == .collections && !collections.isEmpty) else { return nil }
            return (group: group, items: items)
        }
    }

    /// Filter the existing shared inventory locally. Typing never loads a category's content or starts
    /// a second search; the only network work is the hub's ordinary cadence-cached load on appearance.
    private var matchingCollections: [HubTarget] {
        guard hasSearchQuery, CollectionsHubModel.isAvailable else { return [] }
        var targets: [HubTarget] = []
        if !catalogPrefs.isCategoryHidden(HubCategoryKey.discoverSection) {
            targets += collectionsHub.discover.filter { !catalogPrefs.isCategoryHidden(HubCategoryKey.discover($0)) }.map(HubTarget.discover)
        }
        if !catalogPrefs.isCategoryHidden(HubCategoryKey.streamingSection) {
            targets += collectionsHub.providers.map { .service(id: $0.providerID, name: $0.name) }
        }
        if !catalogPrefs.isCategoryHidden(HubCategoryKey.genresSection) {
            targets += collectionsHub.genres.filter { !catalogPrefs.isCategoryHidden(HubCategoryKey.genre($0)) }.map(HubTarget.genre)
        }
        if !catalogPrefs.isCategoryHidden(HubCategoryKey.decadesSection) {
            targets += collectionsHub.decades.filter { !catalogPrefs.isCategoryHidden(HubCategoryKey.decade($0)) }.map(HubTarget.decade)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return targets.filter {
            $0.title.localizedStandardContains(trimmed)
                || String(localized: LocalizedStringResource(stringLiteral: $0.title)).localizedStandardContains(trimmed)
        }
    }

    @ViewBuilder private func collectionTile(_ target: HubTarget) -> some View {
        switch target {
        case .discover(let list):
            DiscoverCardTile(list: list, backdrop: collectionsHub.discoverBackdrops[list])
        case .service(let id, _):
            if let provider = collectionsHub.providers.first(where: { $0.providerID == id }) {
                TVServiceTile(provider: provider)
            }
        case .genre(let genre):
            TVGenreTile(genre: genre, backdrop: collectionsHub.genreBackdrops[genre.title])
        case .decade(let decade):
            TVDecadeTile(decade: decade, cover: collectionsHub.decadeCovers[decade.title])
        }
    }

    private var emptyText: String {
        if isWaitingForCurrentQuery { return "Searching..." }
        return hasSearchQuery ? "No matches for \"\(query)\"."
            : "Start typing to search across everything your add-ons cover."
    }

    private var isTyping: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isWaitingForCurrentQuery: Bool {
        hasSearchQuery && (searchDebouncePending || core.searchIsLoading)
    }

    private var hasSearchQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var suggestionTitles: [String] { core.searchSuggestionTitles(for: query) }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        core.prepareSearch(value)
        core.suggestSearch(value)
        searchDebouncePending = value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(value)
            searchNow(value)
            searchDebouncePending = false
        }
    }

    private func searchNow(_ value: String) {
        core.search(value)
    }

    private func saveToHistory(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        SearchHistoryStore.add(trimmed, profileID: profiles.activeID)
        history = SearchHistoryStore.load(profileID: profiles.activeID)
    }
}
