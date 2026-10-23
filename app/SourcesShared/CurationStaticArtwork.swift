import SwiftUI
import CoreGraphics

/// The read owner revokes this lock-backed token before publishing context loss. A queued image
/// request retains the original token, so winning a permit cannot revive retired view authority.
final class CurationArtworkLifetime: @unchecked Sendable, Hashable {
    let id: UUID
    private let lock = NSLock()
    private var active: Bool
    init(id: UUID = UUID(), active: Bool = true) { self.id = id; self.active = active }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func revoke() { lock.lock(); active = false; lock.unlock() }
    static func == (lhs: CurationArtworkLifetime, rhs: CurationArtworkLifetime) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// In-memory static artwork only. The view owns its task; leaving a tile cancels its queued or
/// active request. No folder appearance starts a catalog request or an animated-media pipeline.
struct CurationStaticArtwork: View {
    let url: String?
    let resourceID: String
    let lifetime: CurationArtworkLifetime
    var thumbnailDimension = 512
    var contentMode: ContentMode = .fill

    static func retire(lifetime: UUID) {
        Task { await CurationArtworkPool.shared.retire(lifetime: lifetime) }
    }

    @State private var image: CurationArtworkImage?
    @State private var requestID = UUID()

    private struct Request: Hashable {
        let url: String?
        let resourceID: String
        let lifetime: CurationArtworkLifetime
        let dimension: Int
    }

    private var request: Request {
        Request(url: url, resourceID: resourceID, lifetime: lifetime,
                dimension: min(768, max(64, thumbnailDimension)))
    }

    var body: some View {
        ZStack {
            Color.clear
            if lifetime.isActive, let image {
                Image(decorative: image.image, scale: 1, orientation: .up)
                    .resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: request) { await load(request) }
        .onDisappear {
            requestID = UUID()
            image = nil
        }
    }

    @MainActor private func load(_ request: Request) async {
        let ticket = UUID()
        requestID = ticket
        image = nil
        guard let url = request.url, !url.isEmpty else { return }
        do {
            let result = try await CurationArtworkPool.shared.load(
                url: url, resourceID: request.resourceID, lifetime: request.lifetime,
                thumbnailDimension: request.dimension)
            guard !Task.isCancelled, requestID == ticket, request.lifetime.isActive else { return }
            image = result
        } catch {
            // The local VortX surface and accessible text remain usable when artwork is unavailable.
        }
    }
}

/// CGImage is immutable after ImageIO has created it. This box never exposes mutable decoder state.
final class CurationArtworkImage: @unchecked Sendable {
    let image: CGImage
    let cost: Int
    init(_ image: CGImage) {
        self.image = image
        cost = image.bytesPerRow * image.height
    }
}

/// A small process-wide gate prevents a viewport full of folders from creating a request/decode burst.
/// The cache is partitioned by the owning profile/source lifetime and never persists supplied URLs.
actor CurationArtworkPool {
    static let shared = CurationArtworkPool()
    private static let maximumActive = 2
    private static let maximumQueued = 32
    private static let maximumEntries = 24
    private static let maximumCost = 16 * 1_024 * 1_024
    private static let ttl: TimeInterval = 300

    private struct Key: Hashable {
        let url: String
        let resourceID: String
        let lifetime: UUID
        let dimension: Int
    }
    private struct Cached {
        let image: CurationArtworkImage
        let expiry: Date
    }
    private struct Waiter {
        let id: UUID
        let lifetime: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private enum Failure: Error { case queueFull }
    private var active = 0
    private var waiters: [Waiter] = []
    private var workers: [UUID: (lifetime: UUID, task: Task<CurationArtworkImage, Error>)] = [:]
    private var cache: [Key: Cached] = [:]
    private var recency: [Key] = []
    private var cacheCost = 0
    typealias Loader = @Sendable (String, Int, CurationArtworkLifetime) async throws -> CurationArtworkImage
    private let loader: Loader

    init(loader: @escaping Loader = { url, dimension, lifetime in
        let data = try await XperienceArtworkClient.load(url)
        try Task.checkCancellation()
        guard lifetime.isActive else { throw CancellationError() }
        return CurationArtworkImage(try XperienceArtworkClient.decode(data, thumbnailDimension: dimension))
    }) { self.loader = loader }

    func load(url: String, resourceID: String, lifetime: CurationArtworkLifetime,
              thumbnailDimension: Int) async throws -> CurationArtworkImage {
        try Task.checkCancellation()
        guard lifetime.isActive else { throw CancellationError() }
        let key = Key(url: url, resourceID: resourceID, lifetime: lifetime.id,
                      dimension: thumbnailDimension)
        evictExpired()
        if let hit = cached(key) { return hit }
        try await acquire(UUID(), lifetime: lifetime.id)
        // Install release before checking cancellation: a resumed waiter owns a permit even if its
        // cancellation and the previous request's release happened together.
        defer { release() }
        try Task.checkCancellation()
        guard lifetime.isActive else { throw CancellationError() }
        if let hit = cached(key) { return hit }
        let load = loader
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard lifetime.isActive else { throw CancellationError() }
            let image = try await load(url, thumbnailDimension, lifetime)
            try Task.checkCancellation()
            guard lifetime.isActive else { throw CancellationError() }
            return image
        }
        let workerID = UUID()
        workers[workerID] = (lifetime.id, worker)
        defer { workers.removeValue(forKey: workerID) }
        let image = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard !worker.isCancelled, lifetime.isActive else { throw CancellationError() }
        insert(image, for: key)
        return image
    }

    func retire(lifetime: UUID) {
        for worker in workers.values where worker.lifetime == lifetime { worker.task.cancel() }
        for waiter in waiters.filter({ $0.lifetime == lifetime }) { cancelWaiter(waiter.id) }
        for key in recency.filter({ $0.lifetime == lifetime }) { remove(key) }
    }
    struct State: Sendable { let workers: Int; let queued: Int; let cached: Int; let bytes: Int }
    func state(lifetime: UUID) -> State {
        let retained = cache.filter { $0.key.lifetime == lifetime }
        return .init(workers: workers.values.filter { $0.lifetime == lifetime }.count,
                     queued: waiters.filter { $0.lifetime == lifetime }.count,
                     cached: retained.count, bytes: retained.values.reduce(0) { $0 + $1.image.cost })
    }

    private func acquire(_ id: UUID, lifetime: UUID) async throws {
        try Task.checkCancellation()
        if active < Self.maximumActive { active += 1; return }
        guard waiters.count < Self.maximumQueued else { throw Failure.queueFull }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, lifetime: lifetime, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            active -= 1
        }
    }

    private func cached(_ key: Key) -> CurationArtworkImage? {
        guard let entry = cache[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    private func insert(_ image: CurationArtworkImage, for key: Key) {
        guard image.cost <= Self.maximumCost else { return }
        remove(key)
        while recency.count >= Self.maximumEntries || cacheCost + image.cost > Self.maximumCost {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
        cache[key] = Cached(image: image, expiry: Date().addingTimeInterval(Self.ttl))
        recency.append(key)
        cacheCost += image.cost
    }

    private func evictExpired() {
        let now = Date()
        for key in recency.filter({ cache[$0].map { $0.expiry <= now } ?? true }) { remove(key) }
    }

    private func remove(_ key: Key) {
        if let old = cache.removeValue(forKey: key) { cacheCost -= old.image.cost }
        recency.removeAll { $0 == key }
    }
}
