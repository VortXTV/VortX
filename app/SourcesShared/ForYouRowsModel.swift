import Combine
import Foundation

/// Home's For You rows (from the profile's interests) and pinned smart collection rows.
///
/// Fetching is keyed only by what changes the query (profile, interests or rules, and the day, since
/// "released by today" moves); the raw results are cached, and library ownership plus "hide what I've
/// watched" are applied when publishing. Adding a title to the library therefore re-filters the rows
/// without refetching them. Rows are fetched one at a time and published as each lands, so the first
/// row shows quickly and TMDB never sees a burst from this rail.
@MainActor
final class ForYouRowsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let eyebrow: String
        let title: String
        let items: [MetaPreview]
    }

    @Published private(set) var interestRows: [Row] = []
    @Published private(set) var collectionRows: [Row] = []

    private static let rowLimit = 20
    private var interestKey: String?
    private var collectionKey: String?
    private var collectionDay: String?
    private var interestRaw: [(plan: ForYouRowPlan, items: [MetaPreview])] = []
    private var collectionRaw: [String: [MetaPreview]] = [:]
    private var interestTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?
    private var owned: Set<String> = []
    private var watched: Set<String> = []
    private var pinned: [SmartCollection] = []

    /// `enabled` is false for a kids profile, a device without the profile's saved choices yet, or no
    /// TMDB route: the rows are cleared rather than showing another profile's results.
    func refresh(profileID: UUID?, interests: ForYouInterests?, collections: [SmartCollection],
                 owned: Set<String>, watched: Set<String>, enabled: Bool, now: Date = Date()) {
        self.owned = owned
        self.watched = watched
        guard enabled, let profileID else { clear(); return }
        let day = ForYouQuery.day(now)
        refreshInterests(profileID: profileID, interests: interests, day: day)
        refreshCollections(profileID: profileID, collections: collections.filter(\.home), day: day)
        publish()
    }

    /// A new profile's preferences can publish before Home's refresh observer runs. An
    /// explicit pick accepts only the rows produced for these exact current query inputs.
    func currentInterestItems(profileID: UUID?, interests: ForYouInterests?, now: Date = Date()) -> [MetaPreview] {
        guard let profileID else { return [] }
        let plan = interests.map { ForYouQuery.plan($0) } ?? []
        let key = "\(profileID.uuidString)|\(ForYouQuery.day(now))|" + plan.map { "\($0.id)=\($0.source)" }.joined(separator: ",")
        guard interestKey == key else { return [] }
        return interestRows.flatMap(\.items)
    }

    func clear() {
        interestTask?.cancel(); collectionTask?.cancel()
        interestTask = nil; collectionTask = nil
        interestKey = nil; collectionKey = nil
        collectionDay = nil
        interestRaw = []; collectionRaw = [:]; pinned = []
        if !interestRows.isEmpty { interestRows = [] }
        if !collectionRows.isEmpty { collectionRows = [] }
    }

    /// Titles for one collection's rules (also the builder's live preview).
    nonisolated static func titles(for rules: SmartCollectionRules, limit: Int = 20) async -> [MetaPreview] {
        guard case .discover(let movie, let tv) = ForYouQuery.collectionSource(rules) else { return [] }
        return await TMDBClient.ruleTitles(movieQuery: movie, tvQuery: tv, limit: limit)
    }

    private func refreshInterests(profileID: UUID, interests: ForYouInterests?, day: String) {
        let plan = interests.map { ForYouQuery.plan($0) } ?? []
        let key = "\(profileID.uuidString)|\(day)|" + plan.map { "\($0.id)=\($0.source)" }.joined(separator: ",")
        guard key != interestKey else { return }
        interestTask?.cancel()
        interestKey = key
        interestRaw = []
        guard !plan.isEmpty else { return }
        interestTask = Task { [weak self] in
            for row in plan {
                let items: [MetaPreview]
                switch row.source {
                case .discover(let movie, let tv):
                    items = await TMDBClient.ruleTitles(movieQuery: movie, tvQuery: tv, limit: Self.rowLimit)
                case .person(let id):
                    items = await TMDBClient.personTopTitles(id: id, limit: Self.rowLimit)
                }
                guard !Task.isCancelled, let self, self.interestKey == key else { return }
                self.interestRaw.append((row, items))
                self.publish()
            }
            // An all-empty result is most likely a failed fetch: forget the key so the next refresh retries.
            guard let self, self.interestKey == key, self.interestRaw.allSatisfy({ $0.items.isEmpty }) else { return }
            self.interestKey = nil
        }
    }

    private func refreshCollections(profileID: UUID, collections: [SmartCollection], day: String) {
        pinned = collections
        // Rules include a released-by-today cutoff. Cached titles must age with that query,
        // while same-day renames and pin changes can continue to reuse successful rows.
        if collectionDay != day {
            collectionRaw = [:]
            collectionDay = day
        }
        let key = "\(profileID.uuidString)|\(day)|" + collections.map { "\($0.id)=\(String(describing: $0.rules))" }.joined(separator: ",")
        guard key != collectionKey else { return }
        collectionTask?.cancel()
        collectionKey = key
        let wanted = Set(collections.map(Self.rawKey))
        collectionRaw = collectionRaw.filter { wanted.contains($0.key) }
        let missing = collections.filter { collectionRaw[Self.rawKey($0)] == nil }
        guard !missing.isEmpty else { return }
        collectionTask = Task { [weak self] in
            for collection in missing {
                let items = await Self.titles(for: collection.rules)
                guard !Task.isCancelled, let self, self.collectionKey == key else { return }
                if !items.isEmpty { self.collectionRaw[Self.rawKey(collection)] = items }
                self.publish()
            }
            // Empty results also represent transport failures. Keep successful rows, but let
            // the next refresh retry just the missing collections under the same query key.
            guard !Task.isCancelled, let self, self.collectionKey == key else { return }
            if collections.contains(where: { self.collectionRaw[Self.rawKey($0)] == nil }) {
                self.collectionKey = nil
            }
        }
    }

    /// Raw results depend only on the rules, so renaming or pinning a collection reuses them.
    private static func rawKey(_ collection: SmartCollection) -> String { "\(collection.id)|\(String(describing: collection.rules))" }

    private func publish() {
        let interest = interestRaw.compactMap { entry -> Row? in
            let items = entry.items.filter { !owned.contains($0.id) }
            return items.isEmpty ? nil : Row(id: entry.plan.id, eyebrow: entry.plan.eyebrow, title: entry.plan.title, items: items)
        }
        let collection = pinned.compactMap { pinned -> Row? in
            guard let raw = collectionRaw[Self.rawKey(pinned)] else { return nil }
            let items = pinned.rules.hideWatched ? raw.filter { !watched.contains($0.id) } : raw
            return items.isEmpty ? nil : Row(id: "smartCollection.\(pinned.id)", eyebrow: String(localized: "Your collection"),
                                             title: pinned.name, items: items)
        }
        if interestRows != interest { interestRows = interest }
        if collectionRows != collection { collectionRows = collection }
    }
}

/// Titles for every smart collection on the Library screen (pinned or not), fetched one collection at
/// a time and cached by rules, so renaming or pinning never refetches.
@MainActor
final class SmartCollectionTitlesModel: ObservableObject {
    @Published private(set) var titles: [String: [MetaPreview]] = [:]
    @Published private(set) var loading: Set<String> = []
    private var cache: [String: [MetaPreview]] = [:]
    private var task: Task<Void, Never>?

    func load(_ collections: [SmartCollection]) {
        task?.cancel()
        let keyed = collections.map { (id: $0.id, key: String(describing: $0.rules), rules: $0.rules) }
        var known: [String: [MetaPreview]] = [:]
        for entry in keyed { if let cached = cache[entry.key] { known[entry.id] = cached } }
        titles = known
        let missing = keyed.filter { cache[$0.key] == nil }
        loading = Set(missing.map(\.id))
        guard !missing.isEmpty else { return }
        task = Task { [weak self] in
            for entry in missing {
                let items = await ForYouRowsModel.titles(for: entry.rules)
                guard !Task.isCancelled, let self else { return }
                if !items.isEmpty { self.cache[entry.key] = items }
                self.titles[entry.id] = items
                self.loading.remove(entry.id)
            }
        }
    }
}
