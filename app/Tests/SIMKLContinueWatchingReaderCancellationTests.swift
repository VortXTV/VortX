import Foundation

// Link the real SIMKLContinueWatching source, ContinueWatchingPreferences,
// SIMKLSessionID and SIMKLError. Only transport responses and ordering are fixtures.
@main
enum SIMKLContinueWatchingReaderCancellationTests {
    private static let session = SIMKLSessionID(rawValue: "inert-reader-cancellation-A")
    private static let initialStamp = "2026-10-20T09:00:00Z"
    private static let nextStamp = "2026-10-20T10:00:00Z"
    private static let finalStamp = "2026-10-20T11:00:00Z"
    private static let originalActivity = "2026-10-01T09:00:00Z"
    private static let paths = ["/sync/activities", "/sync/all-items/movies",
                                "/sync/all-items/shows", "/sync/all-items/anime", "/sync/playback"]
    private static let firstPause = #"[{"progress":42.5,"paused_at":"2026-10-02T09:00:00Z","episode":{"season":1,"number":1},"show":{"title":"Fixture show","ids":{"simkl":10,"imdb":"tt100"}}}]"#
    private static let secondPause = #"[{"progress":50,"paused_at":"2026-10-03T09:00:00Z","episode":{"season":1,"number":2},"show":{"title":"Fixture show","ids":{"simkl":10,"imdb":"tt100"}}}]"#

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    private struct Request: Sendable {
        let path: String
        let query: [String: String]
    }
    private actor Transport: SIMKLContinueWatchingTransport {
        enum Failure: Error { case fixture }
        nonisolated let currentSession: SIMKLSessionID
        private var stamp = initialStamp
        private var watchingStamp = initialStamp
        private var nextEpisode: String? = "S01E02"
        private var playback = "[]"
        private var failurePath: String?
        private var holdPath: String?
        private var paths: [Request] = []
        private var isHeld = false
        private var holdEntered: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        init(_ session: SIMKLSessionID) { currentSession = session }
        func configure(stamp: String, watchingStamp: String? = nil, next: String?, playback: String = "[]",
                       failure: String? = nil, hold: String? = nil) {
            precondition(held == nil && holdEntered == nil)
            self.stamp = stamp; self.watchingStamp = watchingStamp ?? stamp
            nextEpisode = next; self.playback = playback; failurePath = failure; holdPath = hold
            paths = []; isHeld = false
        }
        func requests() -> [Request] { paths }
        func waitUntilHeld() async {
            if isHeld { return }
            await withCheckedContinuation { continuation in
                precondition(holdEntered == nil)
                holdEntered = continuation
            }
        }
        func releaseHeld() {
            guard let continuation = held else { preconditionFailure("No held fixture leg") }
            held = nil; holdPath = nil; isHeld = false
            continuation.resume()
        }
        nonisolated func continueWatchingSessionIsCurrent(_ session: SIMKLSessionID) -> Bool {
            session == currentSession
        }
        func continueWatchingRead(path: String, query: [String: String], session: SIMKLSessionID) async throws -> Data {
            paths.append(Request(path: path, query: query))
            guard session == currentSession else { throw Failure.fixture }
            if path == holdPath {
                // Deliberately noncooperating: return valid bytes after the caller is cancelled.
                // Continuation admission, not a sleep, establishes the precise await boundary.
                await withCheckedContinuation { continuation in
                    precondition(held == nil)
                    held = continuation; isHeld = true
                    holdEntered?.resume(); holdEntered = nil
                }
            }
            if path == failurePath { throw Failure.fixture }
            switch path {
            case "/sync/activities":
                return Data("{\"all\":\"\(stamp)\",\"tv_shows\":{\"all\":\"\(stamp)\",\"watching\":\"\(watchingStamp)\"}}".utf8)
            case "/sync/all-items/shows":
                let marker = nextEpisode.map { "\"\($0)\"" } ?? "null"
                return Data(("{\"shows\":[{\"status\":\"watching\",\"last_watched_at\":\"\(originalActivity)\",\"next_to_watch\":\(marker),"
                    + "\"show\":{\"title\":\"Fixture show\",\"ids\":{\"simkl\":10,\"imdb\":\"tt100\"}}}]}" ).utf8)
            case "/sync/all-items/movies", "/sync/all-items/anime": return Data()
            case "/sync/playback": return Data(playback.utf8)
            default: throw Failure.fixture
            }
        }
    }

    private static func healthyFlightSurvivesCancelledCompetitors() async {
        let reader = SIMKLContinueWatchingReader(), transport = Transport(session)
        await transport.configure(stamp: initialStamp, next: "S01E02")
        let seed = await reader.refresh(session: session, transport: transport)
        require(seed.hasSnapshot && !seed.failed && seed.items.first?.videoID == "tt100:1:2", "seed complete prior snapshot")
        await transport.configure(stamp: nextStamp, next: "S01E03", hold: "/sync/all-items/shows")
        let healthy = Task { await reader.refresh(session: session, transport: transport) }
        await transport.waitUntilHeld()
        let before = await transport.requests()

        let sameSession = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.refresh(session: session, transport: transport)
        }
        let same = await sameSession.value
        require(same.hasSnapshot && !same.failed && same.items == seed.items, "pre-cancelled same-session caller reads only the current cache")
        let differentSession = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.refresh(session: SIMKLSessionID(rawValue: "inert-reader-cancellation-B"), transport: transport)
        }
        let different = await differentSession.value
        require(!different.hasSnapshot && !different.failed && different.items.isEmpty, "pre-cancelled different session neither exposes nor resets current cache")
        let retiredTransport = Transport(SIMKLSessionID(rawValue: "inert-retired-provider-session"))
        let retiredSession = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.refresh(session: session, transport: retiredTransport)
        }
        let retired = await retiredSession.value
        let retiredRequests = await retiredTransport.requests()
        require(!retired.hasSnapshot && retired.items.isEmpty && retiredRequests.isEmpty, "a matching reader cache is unavailable when its transport session retired")
        let after = await transport.requests()
        require(after.count == before.count, "all pre-cancelled competitors issue zero requests")
        await transport.releaseHeld()
        let accepted = await healthy.value
        let acceptedRequests = await transport.requests()
        require(accepted.hasSnapshot && !accepted.failed && accepted.items.first?.videoID == "tt100:1:3", "cancelled competitors do not retire the suspended healthy generation")
        require(acceptedRequests.map(\.path) == paths && acceptedRequests[2].query["date_from"] == initialStamp, "healthy changed-activity flight completes sequential delta legs using exact old cursor")

        await transport.configure(stamp: nextStamp, next: "S01E04")
        let unchanged = await reader.refresh(session: session, transport: transport)
        let requests = await transport.requests()
        require(unchanged.items == accepted.items && requests.map(\.path) == ["/sync/activities", "/sync/playback"], "healthy commit advanced activity cursor; unchanged all never triggers a periodic list reread")
    }

    private static func finalPlaybackLegIsAtomic() async {
        let reader = SIMKLContinueWatchingReader(), transport = Transport(session)
        await transport.configure(stamp: initialStamp, next: "S01E02", playback: firstPause)
        let seed = await reader.refresh(session: session, transport: transport)
        require(seed.items.first?.videoID == "tt100:1:1" && seed.items.first?.progress == 0.425
            && seed.items.first?.activity == "2026-10-02T09:00:00Z", "real paused episode, percentage and timestamp take precedence")
        await transport.configure(stamp: nextStamp, next: "S01E03", failure: "/sync/playback")
        let failed = await reader.refresh(session: session, transport: transport)
        let failedRequests = await transport.requests()
        require(failed.hasSnapshot && failed.failed && failed.items == seed.items && failedRequests.map(\.path) == paths, "final playback failure after all successful list legs retains only the prior complete snapshot")
        await transport.configure(stamp: nextStamp, next: "S01E03")
        let retry = await reader.refresh(session: session, transport: transport)
        let retryRequests = await transport.requests()
        require(retryRequests.map(\.path) == paths && retryRequests[2].query["date_from"] == initialStamp, "failed playback does not advance the saved activities cursor")
        require(retry.hasSnapshot && !retry.failed && retry.items.first?.videoID == "tt100:1:3"
            && retry.items.first?.progress == nil && retry.items.first?.activity == originalActivity, "truthful empty paused set restores the supplied next marker without fake activity or progress")

        await transport.configure(stamp: finalStamp, next: "S01E04", playback: secondPause, hold: "/sync/playback")
        let cancelledFlight = Task { await reader.refresh(session: session, transport: transport) }
        await transport.waitUntilHeld()
        let heldRequests = await transport.requests()
        require(heldRequests.map(\.path) == paths, "cancellation witness reaches final playback after lists succeeded")
        cancelledFlight.cancel()
        await transport.releaseHeld()
        let cancelled = await cancelledFlight.value
        require(cancelled.hasSnapshot && !cancelled.failed && cancelled.items == retry.items, "noncooperating final playback cannot publish a cancelled flight or failure status")
        await transport.configure(stamp: finalStamp, next: "S01E04", playback: secondPause)
        let accepted = await reader.refresh(session: session, transport: transport)
        let acceptedRequests = await transport.requests()
        require(acceptedRequests.map(\.path) == paths && acceptedRequests[2].query["date_from"] == nextStamp, "cancelled final playback leaves the old activity cursor due for exact delta retry")
        require(accepted.hasSnapshot && !accepted.failed && accepted.items.first?.videoID == "tt100:1:2"
            && accepted.items.first?.progress == 0.5 && accepted.items.first?.activity == "2026-10-03T09:00:00Z", "successful retry preserves genuine paused progress and lastWatched rather than next-marker precedence")

        let emptyReader = SIMKLContinueWatchingReader()
        await transport.configure(stamp: initialStamp, next: "S01E02", failure: "/sync/playback")
        let noCompleteSnapshot = await emptyReader.refresh(session: session, transport: transport)
        require(!noCompleteSnapshot.hasSnapshot && noCompleteSnapshot.failed && noCompleteSnapshot.items.isEmpty, "successful initial lists alone are not a complete snapshot after final playback failure")
        await transport.configure(stamp: initialStamp, next: "S01E02")
        let initialRetry = await emptyReader.refresh(session: session, transport: transport)
        let initialRetryRequests = await transport.requests()
        require(initialRetry.hasSnapshot && !initialRetry.failed && initialRetryRequests.map(\.path) == paths
            && initialRetryRequests[2].query["date_from"] == nil, "failed initial playback retains no cursor and requires the ordinary initial full pull")
    }

    private static func everyNoncooperatingLegObservesCancellation() async {
        for (index, path) in paths.enumerated() {
            let reader = SIMKLContinueWatchingReader(), transport = Transport(session)
            await transport.configure(stamp: initialStamp, next: "S01E02", playback: firstPause, hold: path)
            let flight = Task { await reader.refresh(session: session, transport: transport) }
            await transport.waitUntilHeld()
            flight.cancel()
            await transport.releaseHeld()
            let cancelled = await flight.value
            let requests = await transport.requests()
            require(!cancelled.hasSnapshot && !cancelled.failed && cancelled.items.isEmpty, "cancellation at each noncooperating await cannot create a first snapshot")
            require(requests.map(\.path) == Array(paths.prefix(index + 1)), "reader starts no later leg after a cancelled await returns valid bytes")
            await transport.configure(stamp: initialStamp, next: "S01E02")
            let retry = await reader.refresh(session: session, transport: transport)
            let retryRequests = await transport.requests()
            require(retry.hasSnapshot && !retry.failed && retryRequests.map(\.path) == paths
                && retryRequests[2].query["date_from"] == nil, "cancelled first attempt leaves no admitted activity cursor")
        }
    }

    private static func newlyAiredActivityUsesExistingDelta() async {
        let reader = SIMKLContinueWatchingReader(), transport = Transport(session)
        await transport.configure(stamp: initialStamp, next: nil)
        let caughtUp = await reader.refresh(session: session, transport: transport)
        require(caughtUp.hasSnapshot && caughtUp.items.isEmpty, "supplied null next marker is caught up, not evidence for a fabricated episode")
        // Official Sync guide: a newly aired episode bumps watching and therefore all, then
        // the ordinary date_from delta supplies the new authoritative next_to_watch marker.
        await transport.configure(stamp: nextStamp, watchingStamp: nextStamp, next: "S01E03")
        let newlyAired = await reader.refresh(session: session, transport: transport)
        let deltaRequests = await transport.requests()
        require(deltaRequests.map(\.path) == paths && deltaRequests[2].query["date_from"] == initialStamp,
                "new-air activity follows existing sequential delta reads, not a new endpoint or periodic full read")
        require(newlyAired.hasSnapshot && newlyAired.items.first?.videoID == "tt100:1:3"
            && newlyAired.items.first?.activity == originalActivity && newlyAired.items.first?.progress == nil,
                "supplied new-air next marker reappears without history replay, paused progress or timestamp synthesis")
        await transport.configure(stamp: nextStamp, next: "S01E04")
        let unchanged = await reader.refresh(session: session, transport: transport)
        let unchangedRequests = await transport.requests()
        require(unchangedRequests.map(\.path) == ["/sync/activities", "/sync/playback"] && unchanged.items == newlyAired.items,
                "unchanged activities never cause a list reread, regardless of hypothetical catalog bytes")
    }

    static func main() async {
        await healthyFlightSurvivesCancelledCompetitors()
        await finalPlaybackLegIsAtomic()
        await everyNoncooperatingLegObservesCancellation()
        await newlyAiredActivityUsesExistingDelta()
        print("SIMKL reader cancellation and new-air delta component checks passed")
    }
}
