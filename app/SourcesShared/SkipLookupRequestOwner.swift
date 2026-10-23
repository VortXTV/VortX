import Foundation

struct SkipLookupRequestOwner<Load: Hashable & Sendable>: Equatable, Sendable {
    let metaId: String
    let season: Int?
    let episode: Int?
    let durationSeconds: Double
    let durationMilliseconds: Int
    let sourceGeneration: Int
    let loadToken: Load

    static func usableMilliseconds(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0,
              let milliseconds = Int(exactly: (seconds * 1000).rounded(.towardZero)),
              milliseconds > 0 else { return nil }
        return milliseconds
    }

    init?(metaId: String, season: Int?, episode: Int?, durationSeconds: Double,
          sourceGeneration: Int, loadToken: Load?) {
        guard !metaId.isEmpty, let milliseconds = Self.usableMilliseconds(durationSeconds),
              let loadToken else { return nil }
        self.metaId = metaId
        self.season = season
        self.episode = episode
        self.durationSeconds = durationSeconds
        durationMilliseconds = milliseconds
        self.sourceGeneration = sourceGeneration
        self.loadToken = loadToken
    }

    func canPublish(current: Self?, isCancelled: Bool) -> Bool { !isCancelled && self == current }

    func shouldStart(replacing current: Self?, previousTaskIsCancelled: Bool) -> Bool {
        self != current || previousTaskIsCancelled
    }

    var skipDBHintCacheKey: String {
        let bucket = Int(durationSeconds / 10) * 10
        return "skipdb:\(metaId):\(season ?? 0):\(episode ?? 0):\(bucket)"
    }
}
