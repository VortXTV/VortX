import SwiftUI

/// Search across every installed addon, on the engine (CatalogsWithExtra with a search extra).
struct SearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if account.isSignedIn { results } else { CoreEmptyState.signedOut }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
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
        if core.searchResults.isEmpty {
            Text(emptyText)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.xl)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(resultSections, id: \.title) { section in
                    resultRow(title: section.title, items: section.items)
                }
            }
        }
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
                .padding(.vertical, Theme.Space.sm)
            }
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
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Start typing to search across everything your add-ons cover."
            : "No matches for \"\(query)\"."
    }

    private var suggestionTitles: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()

        let coreSuggestions = core.searchSuggestions.map(\.name)
            .filter { title in
                guard title.caseInsensitiveCompare(trimmed) != .orderedSame else { return false }
                return seen.insert(title).inserted
            }

        let localTitles = core.searchResults.map(\.name)
            + core.continueWatching.map(\.name)
            + core.boardRows.flatMap { $0.items.map(\.name) }
        let localMatches = localTitles.filter { title in
            guard title.caseInsensitiveCompare(trimmed) != .orderedSame else { return false }
            guard title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                return false
            }
            return seen.insert(title).inserted
        }

        return Array((coreSuggestions + localMatches).prefix(10))
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(value)
            searchNow(value)
        }
    }

    private func searchNow(_ value: String) {
        core.search(value)
    }
}
