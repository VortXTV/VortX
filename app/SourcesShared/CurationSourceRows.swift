import SwiftUI
import Combine

/// Existing, already resolved VortX rows can be presented without starting a second group fetch.
struct CurationResolvedRows {
    var curated: [String: [MetaPreview]] = [:]
    var interests: [MetaPreview] = []
    var history: [MetaPreview] = []
}

@MainActor struct CurationReadTicket {
    let lifetime: CurationReadLifetime
    let generation: UUID
    let legacy: [SmartCollection]
    let importFingerprints: [String: String]
    let artworkLifetime: CurationArtworkLifetime
    init(lifetime: CurationReadLifetime, generation: UUID, legacy: [SmartCollection], importFingerprints: [String: String]) {
        self.lifetime = lifetime; self.generation = generation; self.legacy = legacy
        self.importFingerprints = importFingerprints; artworkLifetime = lifetime.artworkLifetime
    }
    var isCurrent: Bool {
        lifetime.accepts(generation) && ForYouStore.shared.ready
            && ForYouStore.shared.profileID == lifetime.profileID
            && ProfileStore.shared.active?.isKids != true
    }
}

/// One per open collection page. Imported data remains in the actual import view-model/store;
/// this adapter only resolves stable semantic locators back to its existing authorized request.
@MainActor final class CurationSourceController: ObservableObject {
    let imports: XperienceCollectionsViewModel
    let ticket: CurationReadTicket
    private(set) var resolved: CurationResolvedRows
    private var subscriptions = Set<AnyCancellable>()

    init(ticket: CurationReadTicket, resolved: CurationResolvedRows = .init(),
         imports: XperienceCollectionsViewModel? = nil) {
        let imports = imports ?? XperienceCollectionsViewModel()
        self.ticket = ticket; self.resolved = resolved; self.imports = imports
        imports.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        ticket.lifetime.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if !ticket.isCurrent { self.resolved = .init() }
            self.objectWillChange.send()
        }
            .store(in: &subscriptions)
        imports.store.revisionEvents.sink { [weak self] _ in
            guard let self else { return }
            self.ticket.lifetime.revalidate()
            self.imports.retireIfStale()
            if !self.ticket.isCurrent { self.resolved = .init(); self.objectWillChange.send() }
        }
            .store(in: &subscriptions)
    }
    func start() {
        guard ticket.isCurrent, ticket.lifetime.bindImports(ticket.importFingerprints) else { return }
        imports.reload()
        ticket.lifetime.revalidate()
    }
    func stop() { imports.stop() }
    static func retireReadLifetime(_ lifetime: UUID) {
        Task { await CurationSourceRequestPool.shared.retire(lifetime: lifetime) }
    }

    func load(_ source: CurationSource) async throws -> [MetaPreview] {
        guard ticket.isCurrent else { throw CurationFailure.staleContext }
        let importGeneration = imports.generation
        let signature: String
        switch source.kind {
        case .legacyRules(let id): signature = String(describing: ticket.legacy.first(where: { $0.id == id })?.rules)
        case .curated(let id): signature = String(describing: resolved.curated[id])
        case .interests: signature = String(describing: resolved.interests)
        case .history: signature = String(describing: resolved.history)
        default: signature = ""
        }
        let key = "\(ticket.generation.uuidString)|\(importGeneration.uuidString)|\(ForYouQuery.day(Date()))|\(TMDBClient.deviceRegion)|\(source.kind)|\(signature)"
        let loaded = try await CurationSourceRequestPool.shared.load(key: key, lifetime: ticket.artworkLifetime) { [self] in
            guard ticket.isCurrent else { throw CurationFailure.staleContext }
            let items: [MetaPreview]
            switch source.kind {
            case .legacyRules(let collectionID):
                guard let original = ticket.legacy.first(where: { $0.id == collectionID }),
                      ForYouStore.shared.collections.contains(original) else { throw CurationFailure.staleCollection }
                items = await ForYouRowsModel.titles(for: original.rules, limit: 20)
                guard ticket.isCurrent, ForYouStore.shared.collections.contains(original) else {
                    throw CurationFailure.staleCollection
                }
            case .xperience(let importID, let collectionID, let folderID, let sourceID):
                guard imports.accepts(importGeneration),
                      let namespace = imports.namespaces.first(where: { $0.namespace.uuidString.lowercased() == importID }),
                      ticket.importFingerprints[importID] == namespace.document.fingerprint,
                      let collection = namespace.document.collections.first(where: { $0.id == collectionID }),
                      let folder = collection.folders.first(where: { $0.id == folderID }) else {
                    throw CurationFailure.staleContext
                }
                let matches = folder.sources.enumerated().filter { XperienceAddonBinding.key(for: $0.element) == sourceID }
                guard matches.count == 1, let match = matches.first else { throw CurationFailure.unavailable }
                let request = try imports.catalogRequest(namespace: namespace.field, collectionID: collectionID,
                                                         folderID: folderID, index: match.offset)
                let page = try await XperienceCatalogClient.load(source: request.source, candidate: request.candidate)
                guard ticket.isCurrent, imports.accepts(importGeneration), imports.accepts(request.generation) else {
                    throw CurationFailure.staleContext
                }
                items = Array(page.prefix(20)).map(Self.preview)
            case .addonCatalog(let manifestID, let type, let catalogID, let genre):
                let raw: VortxJSON = .object(["provider": .string("addon"), "addonId": .string(manifestID),
                    "type": .string(type), "catalogId": .string(catalogID), "genre": genre.map(VortxJSON.string) ?? .null])
                let addon = XperienceCollections.Source(raw: raw, provider: "addon", addonID: manifestID,
                                                       type: type, catalogID: catalogID, genre: genre)
                let request = try imports.catalogRequest(unambiguousInstalledSource: addon)
                let page = try await XperienceCatalogClient.load(source: request.source, candidate: request.candidate)
                guard ticket.isCurrent, imports.accepts(importGeneration), imports.accepts(request.generation) else {
                    throw CurationFailure.staleContext
                }
                items = Array(page.prefix(20)).map(Self.preview)
            case .curated(let collectionID):
                if let row = resolved.curated[collectionID] {
                    items = Array(row.prefix(20))
                } else if let catalog = CurationStarterCollections.catalogSource(collectionID) {
                    let page = await catalog.load(1)
                    guard !page.items.isEmpty || page.cause == nil else { throw CurationFailure.unavailable }
                    items = Array(page.items.prefix(20))
                } else if let row = await CuratedCollectionsModel.collectionTitles(for: collectionID) {
                    items = Array(row.prefix(20))
                } else { throw CurationFailure.unavailable }
            case .interests:
                guard !resolved.interests.isEmpty else { throw CurationFailure.unavailable }
                items = Array(resolved.interests.prefix(20))
            case .history:
                guard !resolved.history.isEmpty else { throw CurationFailure.unavailable }
                items = Array(resolved.history.prefix(20))
            case .unsupported:
                throw CurationFailure.unavailable
            }
            try Task.checkCancellation()
            guard ticket.isCurrent else { throw CurationFailure.staleContext }
            return CurationLoadedTitles(items)
        }
        guard ticket.isCurrent else { throw CurationFailure.staleContext }
        switch source.kind {
        case .legacyRules(let id):
            guard let original = ticket.legacy.first(where: { $0.id == id }),
                  ForYouStore.shared.collections.contains(original) else { throw CurationFailure.staleCollection }
        case .xperience, .addonCatalog:
            guard imports.accepts(importGeneration) else { throw CurationFailure.staleContext }
        default: break
        }
        return loaded.items
    }

    private static func preview(_ item: CoreMeta) -> MetaPreview {
        MetaPreview(id: item.id, type: item.type, name: item.name, poster: item.poster,
                    posterShape: item.posterShape, popularity: nil)
    }
}

/// Result data is immutable after construction; it never contains configured transport URLs.
struct CurationLoadedTitles: Sendable {
    let items: [MetaPreview]
    init(_ items: [MetaPreview]) { self.items = items }
}

/// Single-flight by original read lifetime and semantic source. A vanished last subscriber cancels
/// its request. At most two source operations run globally; only successful nonempty rows are cached.
actor CurationSourceRequestPool {
    static let shared = CurationSourceRequestPool()
    private struct Job { let task: Task<CurationLoadedTitles, Error>; var subscribers: Set<UUID> }
    private struct Waiter { let id: UUID; let lifetime: UUID; let continuation: CheckedContinuation<Void, Error> }
    private struct Cached { let titles: CurationLoadedTitles; let expiry: Date }
    private var jobs: [String: Job] = [:]
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private var active = 0
    private var waiters: [Waiter] = []

    func load(key: String, lifetime: CurationArtworkLifetime,
              operation: @escaping @MainActor @Sendable () async throws -> CurationLoadedTitles) async throws -> CurationLoadedTitles {
        try Task.checkCancellation()
        guard lifetime.isActive else { throw CancellationError() }
        evictExpired()
        if let cached = cache[key] { return cached.titles }
        let subscriber = UUID()
        let task: Task<CurationLoadedTitles, Error>
        if var existing = jobs[key] {
            existing.subscribers.insert(subscriber); jobs[key] = existing; task = existing.task
        } else {
            task = Task {
                try await self.acquire(UUID(), lifetime: lifetime.id)
                defer { self.release() }
                try Task.checkCancellation()
                guard lifetime.isActive else { throw CancellationError() }
                let result = try await operation()
                try Task.checkCancellation()
                guard lifetime.isActive else { throw CancellationError() }
                return result
            }
            jobs[key] = Job(task: task, subscribers: [subscriber])
        }
        defer { detach(key: key, subscriber: subscriber) }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.detach(key: key, subscriber: subscriber) }
        }
        try Task.checkCancellation()
        guard lifetime.isActive, jobs[key]?.subscribers.contains(subscriber) == true else { throw CancellationError() }
        if !result.items.isEmpty {
            if cache[key] == nil { order.append(key) }
            cache[key] = Cached(titles: result, expiry: Date().addingTimeInterval(120))
            while order.count > 24 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return result
    }
    func retire(lifetime: UUID) {
        let prefix = lifetime.uuidString + "|"
        for key in jobs.keys.filter({ $0.hasPrefix(prefix) }) {
            jobs.removeValue(forKey: key)?.task.cancel()
        }
        for key in cache.keys.filter({ $0.hasPrefix(prefix) }) { cache.removeValue(forKey: key) }
        order.removeAll { $0.hasPrefix(prefix) }
        for waiter in waiters.filter({ $0.lifetime == lifetime }) { cancel(waiter.id) }
    }
    struct State: Sendable { let jobs: Int; let queued: Int; let cached: Int }
    func state(lifetime: UUID) -> State {
        let prefix = lifetime.uuidString + "|"
        return .init(jobs: jobs.keys.filter { $0.hasPrefix(prefix) }.count,
                     queued: waiters.filter { $0.lifetime == lifetime }.count,
                     cached: cache.keys.filter { $0.hasPrefix(prefix) }.count)
    }
    private func detach(key: String, subscriber: UUID) {
        guard var job = jobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); jobs.removeValue(forKey: key) }
        else { jobs[key] = job }
    }
    private func acquire(_ id: UUID, lifetime: UUID) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        guard waiters.count < 32 else { throw CurationFailure.unavailable }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append(.init(id: id, lifetime: lifetime, continuation: $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().continuation.resume() }
    }
    private func evictExpired() {
        let now = Date()
        order.removeAll { key in
            guard cache[key].map({ $0.expiry <= now }) ?? true else { return false }
            cache.removeValue(forKey: key); return true
        }
    }
}

/// Each lazy folder owns one selected source task. Other sources remain visible as choices and do
/// not fetch until selected. Changing the selection or leaving the folder cancels its subscription.
@MainActor struct CurationFolderSourceRows<Content: View>: View {
    let folder: CurationFolder
    @ObservedObject var controller: CurationSourceController
    @ObservedObject private var watched = WatchedIndex.shared
    let content: (_ items: [MetaPreview], _ suppliedArtwork: Bool) -> Content
    @State private var selectedSourceID: String?
    @State private var items: [MetaPreview] = []
    @State private var loading = false
    @State private var unavailable = false
    @State private var requestID = UUID()
    @State private var retry = 0

    private var source: CurationSource? {
        folder.sources.first { $0.id == selectedSourceID } ?? folder.sources.first
    }
    private var taskIdentity: String {
        "\(controller.ticket.generation)|\(controller.ticket.lifetime.generation)|\(controller.imports.generation)|\(source?.id ?? "none")|\(String(describing: source?.kind))|\(retry)"
    }
    private var shown: [MetaPreview] {
        guard let source, case .legacyRules(let id) = source.kind,
              controller.ticket.legacy.first(where: { $0.id == id })?.rules.hideWatched == true else { return items }
        return items.filter { !watched.ids.contains($0.id) }
    }
    private var suppliedArtwork: Bool {
        guard let source else { return false }
        switch source.kind {
        case .xperience, .addonCatalog: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if folder.sources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(Array(folder.sources.enumerated()), id: \.element.id) { index, entry in
                            Button(sourceLabel(entry, index: index)) { selectedSourceID = entry.id }
                                .buttonStyle(ChipButtonStyle(selected: source?.id == entry.id))
                                .accessibilityAddTraits(source?.id == entry.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
            if loading { ProgressView().accessibilityLabel("Loading collection source") }
            if unavailable {
                Text("This source is unavailable. Check its rules or installed add-on binding.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Button("Retry") { retry += 1 }.buttonStyle(ChipButtonStyle())
            } else if !loading && shown.isEmpty {
                Text("No titles match this source yet.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            } else if !shown.isEmpty {
                content(shown, suppliedArtwork)
            }
        }
        .task(id: taskIdentity) { await load() }
        .onDisappear { requestID = UUID(); items = []; loading = false }
    }

    @MainActor private func load() async {
        let ticket = UUID(); requestID = ticket
        items = []; unavailable = false; loading = true
        defer { if requestID == ticket { loading = false } }
        guard let source else { return }
        do {
            let found = try await controller.load(source)
            guard !Task.isCancelled, requestID == ticket, controller.ticket.isCurrent else { return }
            items = found
        } catch {
            guard !Task.isCancelled, requestID == ticket else { return }
            unavailable = true
        }
    }

    private func sourceLabel(_ source: CurationSource, index: Int) -> String {
        switch source.kind {
        case .legacyRules: return String(localized: "Rules")
        case .curated(let id) where id.hasSuffix(".movies"): return String(localized: "Movies")
        case .curated(let id) where id.hasSuffix(".shows"): return String(localized: "Shows")
        case .interests: return String(localized: "For you")
        case .history: return String(localized: "Watch history")
        default: return String(localized: "Source \(index + 1)")
        }
    }
}
