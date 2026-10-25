import SwiftUI

extension SmartCollectionRules {
    /// One line describing the rules, shown under a collection's name.
    var summary: String {
        var parts: [String] = []
        let genres = genreChoices.map(\.label)
        if !genres.isEmpty { parts.append(genres.joined(separator: String(localized: " or "))) }
        if let extra = extraChoices.first { parts.append(extra.label) }
        if !people.isEmpty { parts.append(String(localized: "With \(people.map(\.name).joined(separator: ", "))")) }
        switch (yearFrom, yearTo) {
        case (nil, nil): break
        case (let from?, nil): parts.append(String(localized: "\(String(from)) to now"))
        case (nil, let to?): parts.append(String(localized: "Up to \(String(to))"))
        case (let from?, let to?): parts.append(String(localized: "\(String(from)) to \(String(to))"))
        }
        if let rating = minRating, rating > 0 { parts.append(String(localized: "Rated \(String(format: "%.0f", rating))+")) }
        switch type {
        case .all: break
        case .movie: parts.append(String(localized: "Movies"))
        case .series: parts.append(String(localized: "Shows"))
        }
        if hideWatched { parts.append(String(localized: "Unwatched")) }
        return parts.isEmpty ? String(localized: "Popular titles") : parts.joined(separator: " · ")
    }
}

/// Builds or edits one smart collection with a live preview. Shared by tvOS and iPhone/iPad/Mac: the
/// platform wrapper supplies the preview row (`ExternalWatchlistRow` on TV, `PosterRail` on touch) so
/// the cards are the same ones each platform's Home uses. `watched` drives "Hide what I've watched".
@MainActor struct SmartCollectionEditor<Preview: View>: View {
    let existing: SmartCollection?
    private let legacySession: CurationLegacyEditSession
    private let readTicket: CurationReadTicket?
    private let originalReadGeneration: UUID
    @ObservedObject private var readLifetime: CurationReadLifetime
    @ObservedObject private var forYouStore = ForYouStore.shared
    let watched: Set<String>
    let onFinish: () -> Void
    let preview: (_ items: [MetaPreview], _ loading: Bool) -> Preview

    @EnvironmentObject private var theme: ThemeManager
    @State private var name: String
    @State private var rules: SmartCollectionRules
    @State private var home: Bool
    @State private var items: [MetaPreview] = []
    @State private var loading = false
    @State private var previewTask: Task<Void, Never>?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var appearanceSession: CurationEditSession?

    private static var fromYears: [Int?] { [nil, 1970, 1980, 1990, 2000, 2010, 2020] }
    private static var toYears: [Int?] { [nil, 1979, 1989, 1999, 2009, 2019] }
    private static var ratings: [Double?] { [nil, 6, 7, 8] }

    init(existing: SmartCollection?, legacySession: CurationLegacyEditSession,
         readTicket: CurationReadTicket? = nil, watched: Set<String>, onFinish: @escaping () -> Void,
         @ViewBuilder preview: @escaping (_ items: [MetaPreview], _ loading: Bool) -> Preview) {
        self.existing = existing
        self.legacySession = legacySession
        self.readTicket = readTicket
        let lifetime = readTicket?.lifetime ?? CurationReadLifetime()
        _readLifetime = ObservedObject(wrappedValue: lifetime)
        originalReadGeneration = readTicket?.generation ?? lifetime.generation
        self.watched = watched
        self.onFinish = onFinish
        self.preview = preview
        _name = State(initialValue: existing?.name ?? "")
        _rules = State(initialValue: existing?.rules ?? SmartCollectionRules())
        _home = State(initialValue: existing?.home ?? true)
    }

    private var shown: [MetaPreview] { rules.hideWatched ? items.filter { !watched.contains($0.id) } : items }
    private var editIsCurrent: Bool {
        forYouStore.isCurrentLegacyEdit(legacySession)
            && (readTicket?.isCurrent ?? readLifetime.accepts(originalReadGeneration))
    }

    var body: some View {
        ScrollView {
            if editIsCurrent {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text(existing == nil ? LocalizedStringKey("New smart collection") : LocalizedStringKey("Edit smart collection"))
                    .screenTitleStyle()
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.cardTitle)
                    .padding(Theme.Space.sm)
                    .vortxSettingsCard()
                    .frame(maxWidth: 640, alignment: .leading)
                group("Genre is any of") {
                    ForEach(ForYouGenre.allCases) { genre in
                        chip(genre.label, selected: rules.genres.contains(genre.rawValue)) { toggle(&rules.genres, genre.rawValue) }
                    }
                }
                group("Scene") {
                    ForEach(ForYouExtra.allCases) { extra in
                        chip(extra.label, selected: rules.extras.first == extra.rawValue) {
                            rules.extras = rules.extras.first == extra.rawValue ? [] : [extra.rawValue]
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("With").eyebrowStyle()
                    ForYouPeoplePicker(people: $rules.people, maxPeople: 5)
                    if !rules.people.isEmpty && rules.type != .movie {
                        Text("People rules find movies; TMDB cannot search shows by person.")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                group("Year from") {
                    ForEach(Self.fromYears, id: \.self) { year in
                        chip(year.map { String($0) } ?? String(localized: "Any"), selected: rules.yearFrom == year) { rules.yearFrom = year }
                    }
                }
                group("Year to") {
                    ForEach(Self.toYears, id: \.self) { year in
                        chip(year.map { String($0) } ?? String(localized: "Now"), selected: rules.yearTo == year) { rules.yearTo = year }
                    }
                }
                group("Rating at least") {
                    ForEach(Self.ratings, id: \.self) { rating in
                        chip(rating.map { String(format: "%.0f+", $0) } ?? String(localized: "Any"), selected: rules.minRating == rating) {
                            rules.minRating = rating
                        }
                    }
                }
                group("Type") {
                    chip(String(localized: "Movies and shows"), selected: rules.type == .all) { rules.type = .all }
                    chip(String(localized: "Movies"), selected: rules.type == .movie) { rules.type = .movie }
                    chip(String(localized: "Shows"), selected: rules.type == .series) { rules.type = .series }
                }
                group("Sort by") {
                    chip(String(localized: "Popular"), selected: rules.sort == .popular) { rules.sort = .popular }
                    chip(String(localized: "Highest rated"), selected: rules.sort == .rating) { rules.sort = .rating }
                    chip(String(localized: "Newest"), selected: rules.sort == .newest) { rules.sort = .newest }
                }
                FlowLayout(spacing: Theme.Space.sm) {
                    chip(String(localized: "Hide what I've watched"), selected: rules.hideWatched) { rules.hideWatched.toggle() }
                    chip(String(localized: "Show on Home"), selected: home) { home.toggle() }
                }
                if let existing {
                    Button("Appearance and folders") {
                        do { appearanceSession = try forYouStore.captureRichEdit(existing) }
                        catch { errorMessage = String(localized: "This collection changed. Close and reopen its editor.") }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(saving)
                    XperienceCurationExportControls(existing: existing)
                        .disabled(saving)
                } else {
                    Text("Save this collection to choose its folders, artwork and layout.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(previewCaption).eyebrowStyle()
                    preview(shown, loading)
                }
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                HStack(spacing: Theme.Space.sm) {
                    Button("Save") { save() }.buttonStyle(ChipButtonStyle(selected: true))
                    Button("Cancel") { onFinish() }.buttonStyle(ChipButtonStyle(selected: false))
                    if existing != nil {
                        Button("Delete") { confirmDelete = true }
                            .buttonStyle(ChipButtonStyle(selected: false, accentText: Theme.Palette.danger))
                    }
                    if saving { ProgressView() }
                }
                .disabled(saving)
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("This collection or profile changed. Open a fresh editor to continue.")
                    Button("Close", action: onFinish).buttonStyle(ChipButtonStyle())
                }
                .padding(Theme.Space.screenInset)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .confirmationDialog("Delete this collection?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { schedulePreview(immediately: true) }
        .onValueChange(of: rules) { _ in schedulePreview(immediately: false) }
        .onDisappear { previewTask?.cancel() }
        .onValueChange(of: readLifetime.generation) { _ in previewTask?.cancel(); items = []; loading = false }
        #if os(tvOS)
        .fullScreenCover(isPresented: appearancePresented) { appearanceEditor }
        #else
        .sheet(isPresented: appearancePresented) { appearanceEditor }
        #endif
    }

    private var appearancePresented: Binding<Bool> {
        Binding(get: { appearanceSession != nil }, set: { presented in
            if !presented, let session = appearanceSession {
                forYouStore.retireRichEdit(session)
                appearanceSession = nil
            }
        })
    }

    @ViewBuilder private var appearanceEditor: some View {
        if let session = appearanceSession {
            CurationAppearanceEditor(session: session) {
                forYouStore.retireRichEdit(session)
                appearanceSession = nil
            }
            .environmentObject(theme)
        }
    }

    private var previewCaption: String {
        if loading { return String(localized: "Finding titles") }
        let count = shown.count
        return count == 0 ? String(localized: "No titles match yet") : String(localized: "\(count) titles match")
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).eyebrowStyle()
            FlowLayout(spacing: Theme.Space.sm) { content() }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label) }
            .buttonStyle(ChipButtonStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ list: inout [String], _ key: String) {
        if let index = list.firstIndex(of: key) { list.remove(at: index) } else { list.append(key) }
    }

    /// Debounced: picking several chips in a row runs one query.
    private func schedulePreview(immediately: Bool) {
        previewTask?.cancel()
        guard editIsCurrent else { items = []; loading = false; return }
        let snapshot = rules
        loading = true
        previewTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled else { return }
            let found = await ForYouRowsModel.titles(for: snapshot)
            guard !Task.isCancelled, snapshot == rules, editIsCurrent else { return }
            items = found
            loading = false
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = String(localized: "Name your collection first."); return }
        if let from = rules.yearFrom, let to = rules.yearTo, from > to {
            errorMessage = String(localized: "The start year is after the end year."); return
        }
        var collection = legacySession.collection
        collection.name = String(trimmed.prefix(80))
        collection.rules = rules
        collection.home = home
        persist { try await forYouStore.saveLegacy(collection, session: legacySession) }
    }

    private func delete() {
        guard existing != nil else { return }
        persist { try await forYouStore.deleteLegacy(legacySession) }
    }

    private func persist(_ operation: @escaping () async throws -> Void) {
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            guard editIsCurrent else {
                errorMessage = String(localized: "This collection or profile changed. Open a fresh editor to continue.")
                return
            }
            do { try await operation(); onFinish() }
            catch { errorMessage = String(localized: "Couldn't save. Check your connection and try again.") }
        }
    }
}
