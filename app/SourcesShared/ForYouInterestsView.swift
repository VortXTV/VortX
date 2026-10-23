import SwiftUI

/// The interests picker: genres, scenes, eras and followed people for the active profile.
///
/// One view for every Apple surface: TV presents it full screen the first time a profile reaches Home,
/// iPhone, iPad and Mac as a sheet. Chips are the app's `ChipButtonStyle` capsules, so they focus,
/// select and scale exactly like every other chip. `firstRun` offers Done / Skip for now; both record a
/// decision so no device asks again. Editing (from Tune) offers Save / Cancel instead.
struct ForYouInterestsView: View {
    /// The store-owned session captured with this picker; only it may save the draft.
    let session: ForYouInterestsEditSession
    let firstRun: Bool
    let onFinish: () -> Void

    @EnvironmentObject private var theme: ThemeManager
    @State private var draft: ForYouInterests
    @State private var saving = false
    @State private var errorMessage: String?

    init(session: ForYouInterestsEditSession, firstRun: Bool, onFinish: @escaping () -> Void) {
        self.session = session
        self.firstRun = firstRun
        self.onFinish = onFinish
        _draft = State(initialValue: session.initial ?? ForYouInterests())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("What do you like to watch?").screenTitleStyle()
                    Text("Pick a few. For You also learns from what you watch.")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }
                section("Genres") {
                    ForEach(ForYouGenre.picker) { genre in
                        chip(genre.label, selected: draft.genres.contains(genre.rawValue)) { toggle(&draft.genres, genre.rawValue) }
                    }
                }
                section("Also into") {
                    ForEach(ForYouExtra.allCases) { extra in
                        chip(extra.label, selected: draft.extras.contains(extra.rawValue)) { toggle(&draft.extras, extra.rawValue) }
                    }
                }
                section("From any era, or mostly") {
                    ForEach(ForYouEra.allCases) { era in
                        chip(era.label, selected: draft.eras.contains(era.rawValue)) { toggle(&draft.eras, era.rawValue) }
                    }
                }
                peopleSection
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                HStack(spacing: Theme.Space.sm) {
                    Button(firstRun ? LocalizedStringKey("Done") : LocalizedStringKey("Save")) { save(decided: draft) }
                        .buttonStyle(ChipButtonStyle(selected: true))
                    Button(firstRun ? LocalizedStringKey("Skip for now") : LocalizedStringKey("Cancel")) {
                        if firstRun { save(decided: ForYouInterests(decided: true)) } else { onFinish() }
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    if saving { ProgressView() }
                }
                .disabled(saving)
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: Theme.Space.readableColumn + 200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // A profile, sign-in or credential change retires the session: close rather than keep another
        // profile's draft on screen.
        .onReceive(ForYouStore.shared.$interestsEditID) { id in if id != session.id { onFinish() } }
        .onDisappear { ForYouStore.shared.retireInterestsEdit(session) }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("People you follow").eyebrowStyle()
            ForYouPeoplePicker(people: $draft.people)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
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

    private func save(decided interests: ForYouInterests) {
        var value = interests
        value.decided = true
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await ForYouStore.shared.saveInterests(value, session: session)
                onFinish()
            } catch CurationFailure.staleContext {
                onFinish()   // the profile changed underneath; the draft belongs to no one now
            } catch {
                errorMessage = String(localized: "Couldn't save your interests. Check your connection and try again.")
            }
        }
    }
}

/// Search TMDB for people and keep a short list of them. Shared by the interests picker and the smart
/// collection builder; typing is debounced so a name issues one search, not one per keystroke.
struct ForYouPeoplePicker: View {
    @Binding var people: [ForYouPerson]
    var maxPeople = 10

    @State private var query = ""
    @State private var results: [TMDBClient.PersonResult] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !people.isEmpty {
                FlowLayout(spacing: Theme.Space.sm) {
                    ForEach(people) { person in
                        Button { people.removeAll { $0.id == person.id } } label: {
                            Label(person.name, systemImage: "xmark")
                        }
                        .buttonStyle(ChipButtonStyle(selected: true))
                        .accessibilityHint(Text("Removes \(person.name)"))
                    }
                }
            }
            if people.count < maxPeople {
                TextField("Add a person", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Space.sm)
                    .vortxSettingsCard()
                    .frame(maxWidth: 640, alignment: .leading)
                    .onChange(of: query) { value in search(value) }
            }
            if !results.isEmpty {
                FlowLayout(spacing: Theme.Space.sm) {
                    ForEach(results) { person in
                        Button { follow(person) } label: { Label(person.name, systemImage: "plus") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func follow(_ person: TMDBClient.PersonResult) {
        guard !people.contains(where: { $0.id == person.id }), people.count < maxPeople else { return }
        people.append(ForYouPerson(id: person.id, name: person.name, department: person.department))
        query = ""
        results = []
    }

    private func search(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let found = await TMDBClient.searchPeople(query: trimmed, limit: 8)
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            results = found.filter { result in !people.contains { $0.id == result.id } }
        }
    }
}
