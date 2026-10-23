import Combine
import Foundation

/// One process-local, bounded cache for public definitions shared by existing Home and Library.
/// No profile document, import, credential, artwork bytes or content catalog is persisted here.
@MainActor final class CurationDefaultsModel: ObservableObject {
    static let shared = CurationDefaultsModel()
    @Published private var collections: [CurationCollection] = []
    private static let freshFor: TimeInterval = 3_600
    private static let maximumStaleAge: TimeInterval = 86_400
    private static let retryAfter: TimeInterval = 300

    typealias Loader = @Sendable (CurationDefaultsRequestScope) async throws -> CurationDefaultsFeed
    typealias ScopeProvider = @MainActor () -> CurationDefaultsRequestScope?
    typealias Fallback = @MainActor () -> [CurationCollection]
    private struct Cached {
        let scope: CurationDefaultsRequestScope
        let feed: CurationDefaultsFeed
        let at: Date
    }
    private struct Flight {
        let id: UUID
        let scope: CurationDefaultsRequestScope
        let task: Task<Void, Never>
    }
    private var cached: Cached?
    private var publishedScope: CurationDefaultsRequestScope?
    private var flight: Flight?
    private var lastAttempt: (scope: CurationDefaultsRequestScope, at: Date)?
    private let loader: Loader
    private let scopeProvider: ScopeProvider
    private let fallback: Fallback
    private let now: @Sendable () -> Date

    init(loader: @escaping Loader = { try await CurationDefaultsClient.load($0) },
         scopeProvider: @escaping ScopeProvider = { CurationDefaultsModel.liveScope() },
         fallback: @escaping Fallback = { CurationStarterCollections.collections },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader; self.scopeProvider = scopeProvider; self.fallback = fallback; self.now = now
    }

    /// Public IDs remain public IDs. These rows are not passed through profile-companion persistence.
    func currentCollections() -> [CurationCollection] {
        guard let current = scopeProvider(), publishedScope == current,
              let cached, cached.scope == current,
              Self.age(now(), since: cached.at, within: Self.maximumStaleAge) else { return fallback() }
        return cached.feed.collections
    }

    /// Visible-surface trigger only. Home and Library join one flight; there is no timer or poller.
    func loadIfNeeded() async {
        // A cancelled joiner cannot retire a healthy shared request or change its retry/cache state.
        guard !Task.isCancelled else { return }
        guard let scope = scopeProvider() else { stop(); return }
        if let flight, flight.scope == scope { await flight.task.value; return }
        if publishedScope != scope {
            flight?.task.cancel(); flight = nil; cached = nil; lastAttempt = nil
            publishedScope = scope; collections = fallback()
        }
        let time = now()
        if let cached, cached.scope == scope, Self.age(time, since: cached.at, within: Self.freshFor) {
            collections = cached.feed.collections
            return
        }
        if let lastAttempt, lastAttempt.scope == scope,
           Self.age(time, since: lastAttempt.at, within: Self.retryAfter) { return }
        lastAttempt = (scope, time)
        let id = UUID(), loader = self.loader
        let task = Task { [weak self] in
            do {
                let feed = try await loader(scope)
                try Task.checkCancellation()
                self?.complete(id: id, scope: scope, result: .success(feed))
            } catch {
                self?.complete(id: id, scope: scope, result: .failure(error))
            }
        }
        flight = .init(id: id, scope: scope, task: task)
        await task.value
    }

    /// Explicit process/account teardown only. A disappearing Home or Library must not cancel its peer.
    func stop() {
        flight?.task.cancel(); flight = nil; cached = nil; lastAttempt = nil; publishedScope = nil
        collections = fallback()
    }

    private func complete(id: UUID, scope: CurationDefaultsRequestScope,
                          result: Result<CurationDefaultsFeed, Error>) {
        guard flight?.id == id, flight?.scope == scope else { return }
        flight = nil
        guard scopeProvider() == scope else {
            cached = nil; publishedScope = nil; collections = fallback()
            return
        }
        publishedScope = scope
        switch result {
        case .success(let feed):
            cached = .init(scope: scope, feed: feed, at: now())
            collections = feed.collections
        case .failure(let error):
            // Unsupported deployment and failed authorization return local defaults, not stale authority.
            if let failure = error as? CurationDefaultsFailure,
               case .http(let code) = failure, [401, 403, 404].contains(code) {
                cached = nil; collections = fallback(); return
            }
            if let cached, cached.scope == scope,
               Self.age(now(), since: cached.at, within: Self.maximumStaleAge) {
                collections = cached.feed.collections
            } else {
                cached = nil; collections = fallback()
            }
        }
    }

    private static func age(_ time: Date, since earlier: Date, within limit: TimeInterval) -> Bool {
        let age = time.timeIntervalSince(earlier)
        return age >= 0 && age < limit
    }

    private static func liveScope() -> CurationDefaultsRequestScope? {
        guard let endpoint = CurationDefaultsClient.endpoint(catalogs: RemoteConfig.snapshot.catalogsEndpoint) else { return nil }
        return .init(endpoint: endpoint, lifecycle: SourceIndexLifecycleClock.snapshot(),
                     isSignedIn: VortXSyncManager.shared.isSignedIn)
    }
}
