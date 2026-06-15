import SwiftUI

/// Search across every installed addon, on the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @State private var showOpenLink = false
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        Group {
            if account.isSignedIn { results } else { CoreEmptyState.signedOut }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Button { showOpenLink = true } label: {
                    Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .sheet(isPresented: $showOpenLink) { OpenLinkView() }
                resultGrid
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)
        }
        .searchable(text: $query, prompt: "Movies or series")
        .searchSuggestions {
            ForEach(suggestionTitles, id: \.self) { title in
                Text(title).searchCompletion(title)
            }
        }
        .onSubmit(of: .search) {
            searchTask?.cancel()
            core.suggestSearch(query)
            searchNow(query)
        }
        .onAppear { core.loadSearchSuggestions() }
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder private var resultGrid: some View {
        if !hasSearchQuery || core.searchResults.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(resultSections, id: \.title) { section in
                    resultRow(title: section.title, items: section.items)
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

    private func resultRow(title: String, items: [CoreMeta]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   menu: .catalog)
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

    private var resultSections: [(title: String, items: [CoreMeta])] {
        let movies = core.searchResults.filter { $0.type == "movie" }
        let series = core.searchResults.filter { $0.type == "series" }
        let other = core.searchResults.filter { $0.type != "series" && $0.type != "movie" }
        return [
            ("Movies", movies),
            ("Series", series),
            ("Other", other),
        ].filter { !$0.items.isEmpty }
    }

    private var emptyText: String {
        if isWaitingForCurrentQuery { return "Searching..." }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Start typing to search across everything your add-ons cover."
            : "No matches for \"\(query)\"."
    }

    private var isWaitingForCurrentQuery: Bool {
        hasSearchQuery && (searchDebouncePending || core.searchIsLoading)
    }

    private var hasSearchQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var suggestionTitles: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        // Returns true (and records the title) only if it contains the query as a substring
        // and hasn't been seen before. Exact matches are excluded (the user typed it already).
        func keep(_ title: String) -> Bool {
            title.caseInsensitiveCompare(trimmed) != .orderedSame
                && title.range(of: trimmed, options: opts) != nil
                && seen.insert(title).inserted
        }

        // Continue watching first: small, personal, high signal.
        let watching = core.continueWatching.map(\.name).filter { keep($0) }

        // Engine suggestion catalog — interleaved by type when available. In practice this may
        // be empty if the addon set doesn't provide a suggestion catalog, in which case
        // searchResults below becomes the effective source.
        func interleaved<T>(from items: [T], typeAt: KeyPath<T, String>, nameAt: KeyPath<T, String>) -> [String] {
            let filtered = items.filter { keep($0[keyPath: nameAt]) }
            let movies = filtered.filter { $0[keyPath: typeAt] == "movie" }
            let series = filtered.filter { $0[keyPath: typeAt] == "series" }
            let other  = filtered.filter { $0[keyPath: typeAt] != "movie" && $0[keyPath: typeAt] != "series" }
            var mixed: [String] = []
            for i in 0..<max(movies.count, series.count) {
                if i < movies.count { mixed.append(movies[i][keyPath: nameAt]) }
                if i < series.count { mixed.append(series[i][keyPath: nameAt]) }
            }
            return mixed + other.map { $0[keyPath: nameAt] }
        }

        let engineMixed = interleaved(from: core.searchSuggestions, typeAt: \.type, nameAt: \.name)
        // searchResults carry full type info — apply the same interleaving so series from the
        // current results aren't pushed behind all movies (the root cause of GoT appearing late).
        let resultsMixed = interleaved(from: core.searchResults, typeAt: \.type, nameAt: \.name)
        let board = core.boardRows.flatMap { $0.items }.filter { keep($0.name) }.map(\.name)

        return Array((watching + engineMixed + resultsMixed + board).prefix(10))
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
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
}
