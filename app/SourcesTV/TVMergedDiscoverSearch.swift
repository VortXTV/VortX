import SwiftUI

extension View {
    /// Merged Discover needs a full-height search/browse viewport. The established hero strip is
    /// retained exactly when the preference is off.
    @ViewBuilder func tvDiscoverSearchLayout(merged: Bool) -> some View {
        if merged { self.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { self.heroBottomStrip() }
    }
}

/// Discover's inline search consumer uses the same engine/history APIs as the standalone Search
/// screen. It owns only this mounted query and never discovers streams or changes a resume route.
struct TVMergedDiscoverSearch: View {
    @Binding var query: String
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager
    @EnvironmentObject private var theme: ThemeManager
    @State private var history: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var debouncePending = false
    @State private var submittedQuery = ""
    @State private var admittedResults: [CoreMeta] = []
    @State private var resultOwnerProfile: UUID?
    @State private var resultOwnerAccountBoundary: UInt64?
    @FocusState private var inputFocused: Bool

    private var hasQuery: Bool { TVDiscoverSearchPolicy.hasQuery(query) }
    private var signedIn: Bool { account.isSignedIn || vortxSync.isSignedIn }
    private var waiting: Bool { hasQuery && (debouncePending || core.searchIsLoading) }
    private var currentResults: [CoreMeta] {
        // Retain the engine's query ownership, and don't paint the preceding query during debounce.
        submittedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) && !debouncePending
            ? admittedResults : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textSecondary)
                TextField("Movies or series", text: $query)
                    .focused($inputFocused).submitLabel(.search)
                    .onSubmit { submit() }
                    .disabled(!signedIn)
                if !query.isEmpty {
                    Button { query = ""; inputFocused = true } label: { Label("Clear", systemImage: "xmark.circle") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(Theme.Space.md)
            .vortxGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous),
                        fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
            .focusSection()
            if !signedIn {
                CoreEmptyState.signedOut
            } else if hasQuery {
                results
            } else if !history.isEmpty {
                recentSearches
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .onAppear {
            core.loadSearchSuggestions()
            history = SearchHistoryStore.load(profileID: profiles.activeID)
            if hasQuery, debouncePending || submittedQuery != query.trimmingCharacters(in: .whitespacesAndNewlines) {
                schedule(query)
            }
        }
        .onChange(of: query) { _, value in schedule(value) }
        .onReceive(core.$searchResults) { results in
            guard TVDiscoverSearchPolicy.acceptsResults(query: query, submittedQuery: submittedQuery,
                debouncePending: debouncePending, capturedProfile: resultOwnerProfile,
                currentProfile: profiles.activeID, capturedAccountBoundary: resultOwnerAccountBoundary,
                currentAccountBoundary: account.credentialBoundaryGeneration) else { return }
            // The engine publishes fast matches before every add-on has finished. Display those
            // real partial results, with a loading signal while the remaining catalogs settle.
            admittedResults = results
        }
        .onChange(of: profiles.activeID) { _, _ in resetForOwner() }
        .onChange(of: account.credentialBoundaryGeneration) { _, _ in resetForOwner() }
        .onDisappear { searchTask?.cancel() }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Recent Searches").sectionTitleStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(history, id: \.self) { term in
                        Button { query = term } label: { Label(term, systemImage: "clock") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    Button {
                        SearchHistoryStore.clear(profileID: profiles.activeID)
                        history = []
                    } label: { Label("Clear recent", systemImage: "trash") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
                .padding(.vertical, Theme.Space.sm)
            }
            .focusSection()
        }
    }

    @ViewBuilder private var results: some View {
        if currentResults.isEmpty {
            HStack(spacing: Theme.Space.sm) {
                if waiting { ProgressView().tint(theme.accent) }
                Text(waiting ? "Searching…" : "No matches for \"\(query)\".")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Space.lg)
        } else {
            if waiting {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().tint(theme.accent)
                    Text("Searching more add-ons…").font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            ForEach(["movie", "series", "other"], id: \.self) { type in
                let items = currentResults.filter { type == "other" ? !["movie", "series"].contains($0.type) : $0.type == type }
                if !items.isEmpty {
                    Text(type == "movie" ? "Movies" : type == "series" ? "Series" : "Other").sectionTitleStyle()
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVGridMetrics.landscapeCellWidth),
                        spacing: Theme.Space.lg), count: TVGridMetrics.landscapeColumns),
                        alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(items) { item in
                            TVCatalogSelectionCard(presentation: .meta(item), width: TVGridMetrics.landscapeCellWidth,
                                                   onSelect: { saveQuery() })
                        }
                    }
                    .padding(.vertical, Theme.Space.md).focusSection()
                }
            }
        }
    }

    private func schedule(_ value: String) {
        searchTask?.cancel()
        admittedResults = []
        debouncePending = TVDiscoverSearchPolicy.hasQuery(value)
        guard debouncePending else {
            submittedQuery = ""; core.search("")
            return
        }
        // Capture both owner boundaries before the delay, so old queued searches cannot target a
        // replacement profile/account even if its rendered state has not caught up yet.
        let profileID = profiles.activeID
        let accountBoundary = account.credentialBoundaryGeneration
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, profileID == profiles.activeID,
                  accountBoundary == account.credentialBoundaryGeneration, signedIn else { return }
            core.suggestSearch(value)
            submittedQuery = value.trimmingCharacters(in: .whitespacesAndNewlines)
            resultOwnerProfile = profileID
            resultOwnerAccountBoundary = accountBoundary
            debouncePending = false
            core.search(value)
        }
    }

    private func submit() {
        searchTask?.cancel()
        guard signedIn else { return }
        admittedResults = []
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        resultOwnerProfile = profiles.activeID
        resultOwnerAccountBoundary = account.credentialBoundaryGeneration
        core.suggestSearch(query)
        core.search(query)
        debouncePending = false
    }

    private func saveQuery() {
        guard hasQuery else { return }
        SearchHistoryStore.add(query.trimmingCharacters(in: .whitespacesAndNewlines), profileID: profiles.activeID)
        history = SearchHistoryStore.load(profileID: profiles.activeID)
    }

    private func resetForOwner() {
        searchTask?.cancel(); query = ""; submittedQuery = ""; debouncePending = false
        admittedResults = []; resultOwnerProfile = nil; resultOwnerAccountBoundary = nil
        history = SearchHistoryStore.load(profileID: profiles.activeID)
    }
}
