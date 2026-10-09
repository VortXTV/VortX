import Foundation

struct CoreStream: Sendable {
    let name: String
    let url: String?
    let isUsenet: Bool
    func playableURL(isEpisode: Bool) -> URL? { url.flatMap(URL.init(string:)) }
}
struct DebridEpisode: Sendable { let season: Int; let episode: Int }
struct DebridPlaybackRef: Sendable { let url: URL }

@MainActor final class DebridCoordinator {
    static let shared = DebridCoordinator()
    var calls: [String] = []
    var resolved: [String: URL] = [:]
    var onResolve: (() -> Void)?
    var delay: Duration = .zero
    var delays: [String: Duration] = [:]
    func resolvedPlaybackRef(for stream: CoreStream, episode: DebridEpisode?,
        confirmedCachedHashes: Set<String>?, waitForLocalUsenetNode: Bool,
        usenetResolveTimeout: Duration) async -> DebridPlaybackRef? {
        calls.append(stream.name)
        onResolve?()
        let delay = delays[stream.name] ?? delay
        if delay > .zero { try? await Task.sleep(for: delay) }
        return resolved[stream.name].map(DebridPlaybackRef.init(url:))
    }
}

@main enum RankedEpisodeResolutionTests {
    @MainActor static func main() async {
        let bad = CoreStream(name: "chosen-nzb", url: "https://example.invalid/file.nzb", isUsenet: true)
        let good = CoreStream(name: "alternate-video", url: "https://example.invalid/video.mkv", isUsenet: false)
        let backend = DebridCoordinator.shared
        let result = await iOSResolveRankedEpisodeCandidate([bad, good], episode: .init(season: 1, episode: 2))
        precondition(result?.index == 1 && result?.stream.name == good.name)
        precondition(result?.url == URL(string: good.url!))
        precondition(backend.calls == [bad.name, good.name], "initial resolution failure must try the next candidate")
        backend.calls = []
        backend.resolved[bad.name] = URL(string: "https://example.invalid/resolved.mkv")!
        let preferred = await iOSResolveRankedEpisodeCandidate([bad, good], episode: .init(season: 1, episode: 2))
        precondition(preferred?.index == 0 && backend.calls == [bad.name], "playable chosen release wins without resolving alternates")
        backend.calls = []
        backend.delay = .seconds(2)
        let started = ProcessInfo.processInfo.systemUptime
        let timedOut = await iOSResolveRankedEpisodeCandidate([bad], episode: .init(season: 1, episode: 2),
                                                              deadline: started + 0.05)
        precondition(timedOut == nil && ProcessInfo.processInfo.systemUptime - started < 1, "whole local+cloud resolution must obey owner deadline")
        backend.delay = .zero
        backend.resolved = [:]
        backend.calls = []
        backend.delays[bad.name] = .seconds(35)
        let fallbackStart = ProcessInfo.processInfo.systemUptime
        let boundedFallback = await iOSResolveRankedEpisodeCandidate([bad, good], episode: .init(season: 1, episode: 2),
            deadline: fallbackStart + 0.4)
        precondition(boundedFallback?.index == 1 && ProcessInfo.processInfo.systemUptime - fallbackStart < 0.4,
                     "cooperative35s NNTP fault cannot consume the alternate's reserved budget")
        backend.delays = [:]
        let inheritedBudget = EpisodeResolutionBudget(episodeID: "episode2", origin: .automatic,
                                                       now: ProcessInfo.processInfo.systemUptime - 40)
        let lateCandidate = await EpisodeResolutionBudget.$current.withValue(inheritedBudget) {
            await iOSResolveRankedEpisodeCandidate([good], episode: .init(season: 1, episode: 2))
        }
        precondition(lateCandidate?.stream.name == good.name,
                     "late candidate at40s is admitted inside the same request, not canceled by old30s timer")
        backend.calls = []
        let expired = await iOSResolveRankedEpisodeCandidate([bad, good], episode: nil,
                                                            deadline: ProcessInfo.processInfo.systemUptime - 1)
        precondition(expired == nil && backend.calls.isEmpty)
        var current = true
        backend.onResolve = { current = false }
        let replaced = await iOSResolveRankedEpisodeCandidate([bad, good], episode: .init(season: 1, episode: 2),
                                                             stillCurrent: { current })
        precondition(replaced == nil, "replacement during resolve must not enqueue/play its stale result")
        backend.onResolve = nil
        let cancelled = Task { await iOSResolveRankedEpisodeCandidate([bad, good], episode: nil) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        print("PASS production candidate resolver: chosen release, NZB-failure fallback, exact URL, expiry, owner replacement, cancellation; no network/media")
    }
}
