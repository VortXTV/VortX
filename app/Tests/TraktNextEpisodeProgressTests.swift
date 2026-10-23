import Foundation

// UNRUN. Link the real progress fold, TraktModels and original-byte JSON admission helper.
// This fixture has no provider transport, authentication, persistence or presentation dependency.
@main
enum TraktNextEpisodeProgressTests {
    private typealias Progress = TraktNextEpisodeProgress
    private static let show = TraktShow(ids: TraktIDs(trakt: 10, imdb: "tt100", tmdb: 42), title: "Fixture show")
    private static let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private static let watchedAt = "2026-10-01T09:00:00Z"
    private static let next = #"{"season":2,"number":4,"ids":{"trakt":204},"first_aired":"2026-10-20T10:00:00Z"}"#
    private static let pending = #"[{"number":2,"aired":4,"completed":3,"episodes":[{"number":4,"completed":false}]}]"#
    private static func wire(next: String = "null", seasons: String = "[]", reset: String = "null",
                             hidden: String = "[]", activity: String? = watchedAt) -> Data {
        let rawActivity = activity.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"aired":4,"completed":3,"last_watched_at":\(rawActivity),"reset_at":\(reset),"next_episode":\(next),"seasons":\(seasons),"hidden_seasons":\(hidden)}
        """.utf8)
    }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    private static func rejects(_ failure: Progress.Failure, _ data: Data, show: TraktShow = TraktNextEpisodeProgressTests.show) async {
        do { _ = try await Progress.decode(data, show: show, now: now); preconditionFailure("Expected rejection") }
        catch let actual as Progress.Failure { require(actual == failure, "exact bounded rejection") }
        catch { preconditionFailure("Unexpected error") }
    }
    static func main() async throws {
        let caughtUp = try await Progress.decode(wire(), show: show, now: now)
        require(caughtUp == .caughtUp, "explicit null next marker is a truthful caught-up result")
        // The watch timestamp is identical. A visible budgeted progress read, independent of
        // paused_at equality, can now receive a newly aired authoritative next marker.
        let result = try await Progress.decode(wire(next: next, seasons: pending), show: show, now: now)
        guard case .next(let candidate) = result else { preconditionFailure("Expected supplied next candidate") }
        require(candidate.id == "tt100" && candidate.season == 2 && candidate.episode == 4
            && candidate.showTraktID == 10 && candidate.episodeTraktID == 204, "actual show identity and supplied episode coordinates retained")
        require(candidate.aliases == ["tmdb:tv:42", "tmdb:42"] && candidate.lastWatchedAt == watchedAt,
                "typed identity union and original watch timestamp survive without fake pause/progress")
        let unknownActivity = try await Progress.decode(wire(next: next, seasons: pending, activity: nil), show: show, now: now)
        guard case .next(let noActivity) = unknownActivity else { preconditionFailure("Expected next candidate") }
        require(noActivity.lastWatchedAt == nil, "missing watch activity is never stamped with discovery time")
        let absentEpisode = try await Progress.decode(wire(next: next), show: show, now: now)
        require(absentEpisode == .unavailable(.incompleteEpisodeEvidence), "missing episode row is unknown, not unwatched")
        let completedEpisode = pending.replacingOccurrences(of: "false", with: "true")
        let completed = try await Progress.decode(wire(next: next, seasons: completedEpisode), show: show, now: now)
        require(completed == .unavailable(.incompleteEpisodeEvidence), "a completed row cannot become a candidate even if next metadata contradicts it")
        let rewatch = try await Progress.decode(wire(next: next, seasons: pending,
            reset: #""2026-10-02T09:00:00Z""#), show: show, now: now)
        require(rewatch == .unavailable(.rewatchPolicyRequired), "rewatch reset requires its own policy rather than guessing from lifetime rows")
        await rejects(.invalidResponse, wire(next: next, seasons: pending, hidden: #"[{"number":2}]"#))
        await rejects(.invalidResponse, wire(next: next.replacingOccurrences(of: "T10:", with: "T13:"), seasons: pending))
        await rejects(.invalidResponse, wire(next: next.replacingOccurrences(of: #""season":2"#, with: #""season":0"#), seasons: pending))
        await rejects(.invalidResponse, wire(next: next.replacingOccurrences(of: #""trakt":204"#, with: #""trakt":true"#), seasons: pending))
        let duplicateSeason = #"[{"number":2,"aired":4,"completed":3,"episodes":[]},{"number":2,"aired":4,"completed":3,"episodes":[]}]"#
        await rejects(.invalidResponse, wire(next: next, seasons: duplicateSeason))
        let duplicateEpisode = #"[{"number":2,"aired":4,"completed":3,"episodes":[{"number":4,"completed":false},{"number":4,"completed":true}]}]"#
        await rejects(.invalidResponse, wire(next: next, seasons: duplicateEpisode))
        let duplicateUnknown = Data((String(String(decoding: wire(), as: UTF8.self).dropLast()) + #", "unknown":1,"\u0075nknown":2}"#).utf8)
        await rejects(.invalidResponse, duplicateUnknown)
        let missingNext = Data(String(decoding: wire(), as: UTF8.self).replacingOccurrences(of: #""next_episode":null,"#, with: "").utf8)
        await rejects(.invalidResponse, missingNext)
        let duplicateNext = Data((String(String(decoding: wire(), as: UTF8.self).dropLast()) + #", "next_episode":null}"#).utf8)
        await rejects(.invalidResponse, duplicateNext)
        await rejects(.invalidResponse, Data("[]".utf8))
        await rejects(.responseTooLarge, Data(repeating: 32, count: Progress.maximumResponseBytes + 1))
        await rejects(.invalidShow, wire(next: next, seasons: pending),
            show: TraktShow(ids: TraktIDs(trakt: 0, imdb: "tt100"), title: "Invalid"))
        let tmdb = try await Progress.decode(wire(next: next, seasons: pending),
            show: TraktShow(ids: TraktIDs(trakt: 10, tmdb: 42), title: "TMDB show"), now: now)
        guard case .next(let typed) = tmdb else { preconditionFailure("Expected TMDB candidate") }
        require(typed.id == "tmdb:tv:42" && typed.season == 2 && typed.episode == 4, "typed TV fallback never crosses movie identity or guesses an opaque video ID")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await Progress.decode(wire(next: next, seasons: pending), show: show, now: now); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancellationPreserved = await cancelled.value
        require(cancellationPreserved, "pre-cancelled decode retains cancellation without touching a provider")
        print("Trakt next-episode progress component checks passed")
    }
}
