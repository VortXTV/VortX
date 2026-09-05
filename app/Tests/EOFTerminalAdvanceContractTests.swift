// EOFTerminalAdvanceContractTests: a standalone, runnable proof of the DECISION LOGIC in the diag-22
// EOF freeze-instead-of-advance fix. S7E1 froze ~15 min at end-of-file because of a TWO-layer mechanism:
//
//   LAYER 1 - the advance was swallowed. At EOF the terminal route resolved to `.outgoingCommittedWhileResolving`
//   -> `.persistOutgoingCompletionOnly`, whose contract is "record the completion but do NOT advance or exit
//   while the requested target resolves." With TorBox dead (torbox=0) the next target NEVER resolved, so the
//   handler returned and the session sat forever. FIX: that route (and the sibling `.markSupersededTerminal`)
//   must now ARM a bounded deadline at the call site instead of trusting an unbounded external resolve.
//
//   LAYER 2 - nothing recovered, and it looked like buffering. mpv reports paused-for-cache=true on the final
//   frame, which the app maps to `buffering=true`, and the stall watchdog stood down while buffering. So a
//   player frozen at pos==duration was misread as a legitimate rebuffer and waited on forever. FIX: an
//   at-EOF frozen frame (pos ~= duration, EOF delivered) is recoverable REGARDLESS of buffering; a genuine
//   mid-stream rebuffer (currentTime < duration) is NOT and stays owned by the normal buffering path.
//
// This file drives the REAL pure helpers behind both layers (`EpisodePlaybackIdentity.terminalEventRoute`,
// `.terminalEventAction`, `.terminalActionRequiresBoundedDeadline`, and `TerminalPlaybackWatchdogPolicy.
// eofFreezeIsRecoverable` - all in the real CoreModels.swift), so the proof is of production code, not a
// mirror. Like app/Tests/BingeSourceMemoryRaceContractTests.swift, VortX's Apple app has no Xcode unit-test
// bundle (verification is build + on-device, per the repo guide), so this is a self-contained executable that
// compiles the real production sources plus small stubs for the peripheral types CoreModels.swift names but
// this proof never calls. Run:
//
//   xcrun swiftc -o /tmp/eof-terminal-test \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/SourcesShared/CatalogRowResolution.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/SourcesShared/AppleCWSeasonRolloverPolicy.swift \
//     app/SourcesShared/DebridPlaybackAvailability.swift \
//     app/SourcesShared/UsenetStreamValidation.swift \
//     app/SourcesShared/CoreModels.swift \
//     app/Tests/EOFTerminalAdvanceContractTests.swift && /tmp/eof-terminal-test
//
// The load-bearing proofs are the OLD-vs-NEW divergences:
//   LAYER 1 - the ROUTE/ACTION mapping is UNCHANGED (persist-completion still means persist-completion), yet
//             the NEW `terminalActionRequiresBoundedDeadline` flips exactly the two hanging actions to "arm a
//             deadline" - so the fix adds a bound WITHOUT altering the route contract it defends.
//   LAYER 2 - for the at-EOF frozen frame the OLD watchdog stood down (buffering==true), while the NEW
//             classifier calls it recoverable; for a mid-stream rebuffer BOTH keep waiting, so normal
//             behavior is preserved.

import Foundation

// MARK: - Minimal CoreModels peripheral stubs (the subset the compiled CoreModels.swift names; this proof
// never calls any of them). Mirrors BingeSourceMemoryRaceContractTests' stub block, trimmed to CoreModels.

enum DebridService: String { case torBox }
struct DebridEpisode { let season: Int; let episode: Int }

enum LastStreamStore {
    struct Entry {
        let videoId: String
        let url: String
        let type: String
        let debridService: String?
        let infoHash: String?
        let linkSavedAt: Date?
        let debridTorrentId: Int?
        let debridFileId: Int?
        let fileIdx: Int?
        let season: Int?
        let episode: Int?
    }
}

enum StubError: Error { case unavailable }

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?,
                   episode: DebridEpisode? = nil, requiresSemanticSelection: Bool) async throws -> URL {
        throw StubError.unavailable
    }
}

enum VortXSyncManager { static let appliedAddonOrder: [String] = [] }
enum AddonTombstones { static func normalize(_ value: String) -> String { value } }

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum UsenetProviderStore { static let isConfigured = false }

enum StremioServer {
    static let usenetNodeBase: String? = nil
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

final class CommunityStreamGateway {
    static let shared = CommunityStreamGateway()
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? { upstream }
}

// MARK: - Assertion harness (mirrors the binge contract test)

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

// MARK: - Route fixtures (real PlayerLoadToken identities driving the real terminalEventRoute)

private typealias Identity = EpisodePlaybackIdentity
private typealias Route = EpisodePlaybackIdentity.TerminalEventRoute
private typealias Action = EpisodePlaybackIdentity.TerminalEventAction

/// The exact route a committed episode hits at true EOF while a next episode is mid-resolve: the outgoing
/// committed file is still the active load, a switch is in progress, and its pending target has not issued.
private func outgoingCommittedWhileResolvingRoute() -> Route {
    let live = PlayerLoadToken()          // the outgoing committed file, still the active/committed load
    return Identity.terminalEventRoute(
        callbackToken: live, activeToken: live, committedToken: live,
        pendingToken: PlayerLoadToken(), pendingIssued: false,   // the next target exists but has NOT issued
        switchingEpisode: true
    )
}

/// A superseded physical load hitting EOF while a newer advance owns the active session.
private func supersededTerminalRoute() -> Route {
    let live = PlayerLoadToken()
    return Identity.terminalEventRoute(
        callbackToken: live, activeToken: live, committedToken: PlayerLoadToken(),
        pendingToken: PlayerLoadToken(), pendingIssued: false,
        supersededToken: live, supersededIssued: true,
        switchingEpisode: false
    )
}

/// The ordinary committed EOF (no switch in progress): the finale / normal end that advances-or-exits itself.
private func committedRoute() -> Route {
    let live = PlayerLoadToken()
    return Identity.terminalEventRoute(
        callbackToken: live, activeToken: live, committedToken: live,
        pendingToken: nil, pendingIssued: false,
        switchingEpisode: false
    )
}

// MARK: - LAYER 2 old-vs-new model

/// The pre-fix stall-watchdog stand-down: it waited (stood down, never counted the freeze) whenever the media
/// reported buffering. This is the exact `!buffering` clause that blinded it at the EOF boundary.
private func oldWatchdogStoodDown(buffering: Bool) -> Bool { buffering }

@main
enum EOFTerminalAdvanceContractTests {
    static func main() {
        // =====================================================================================================
        // LAYER 1 - the advance is no longer swallowed: the hanging routes now require a bounded deadline.
        // =====================================================================================================

        // 1a - ROUTE/ACTION contract is UNCHANGED (the fix defends this contract, it does not rewrite it).
        let outgoingRoute = outgoingCommittedWhileResolvingRoute()
        expect(outgoingRoute == .outgoingCommittedWhileResolving,
               "layer1 route: a committed EOF mid-episode-switch is still .outgoingCommittedWhileResolving")
        expect(Identity.terminalEventAction(route: outgoingRoute, kind: .eof) == .persistOutgoingCompletionOnly,
               "layer1 action: that route at EOF still maps to .persistOutgoingCompletionOnly (unchanged)")
        expect(supersededTerminalRoute() == .superseded,
               "layer1 route: a superseded physical load at EOF is still .superseded")
        expect(Identity.terminalEventAction(route: .superseded, kind: .eof) == .markSupersededTerminal,
               "layer1 action: .superseded at EOF still maps to .markSupersededTerminal (unchanged)")
        expect(committedRoute() == .committed,
               "layer1 route: an ordinary committed EOF is still .committed -> it advances-or-exits itself")

        // 1b - the NEW decision: exactly the two hanging actions now demand a bounded deadline at the call site.
        expect(Identity.terminalActionRequiresBoundedDeadline(.persistOutgoingCompletionOnly),
               "layer1 arm: .persistOutgoingCompletionOnly MUST arm a bounded deadline (the diag-22 hang)")
        expect(Identity.terminalActionRequiresBoundedDeadline(.markSupersededTerminal),
               "layer1 arm: .markSupersededTerminal MUST arm a bounded deadline (same swallow shape)")

        // 1c - the follow-through actions must NOT arm (they own their own advance / failure / live session).
        expect(Identity.terminalActionRequiresBoundedDeadline(.handleCommitted) == false,
               "layer1 no-arm: .handleCommitted advances itself, no deadline")
        expect(Identity.terminalActionRequiresBoundedDeadline(.handlePending) == false,
               "layer1 no-arm: .handlePending fails the load itself, no deadline")
        expect(Identity.terminalActionRequiresBoundedDeadline(.ignoreOutgoingError) == false,
               "layer1 no-arm: .ignoreOutgoingError is a stale/superseded error, no deadline")
        expect(Identity.terminalActionRequiresBoundedDeadline(.ignoreStale) == false,
               "layer1 no-arm: .ignoreStale belongs to a different live session, no deadline")

        // 1d - EOF-vs-error divergence on the SAME outgoing-committed route: only the EOF (a completion) arms.
        let outgoingErrorAction = Identity.terminalEventAction(route: .outgoingCommittedWhileResolving, kind: .error)
        expect(outgoingErrorAction == .ignoreOutgoingError,
               "layer1 kind: the outgoing-committed route on an ERROR is .ignoreOutgoingError, not a completion")
        expect(Identity.terminalActionRequiresBoundedDeadline(.persistOutgoingCompletionOnly)
                   != Identity.terminalActionRequiresBoundedDeadline(outgoingErrorAction),
               "layer1 divergence: the EOF completion arms a deadline; the same route's error does not")

        // =====================================================================================================
        // LAYER 2 - the watchdog is no longer blinded by buffering at the EOF boundary.
        // =====================================================================================================

        let dur = 2712.0            // a real episode runtime; the play head is parked here on the final frame

        // 2a - the diag-22 frozen final frame: pos ~= duration, EOF delivered. Recoverable regardless of the
        //      paused-for-cache "buffering" that hung it.
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur, duration: dur, hasStartedPlaying: true, loadFailed: false),
               "layer2 EOF: a frame frozen at pos == duration after EOF is recoverable (advance-or-exit)")

        // 2b - THE fix, as an old-vs-new divergence on the identical buffering==true input.
        let bufferingAtEOF = true
        let newRecoverableAtEOF = TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
            atEOF: true, currentTime: dur, duration: dur, hasStartedPlaying: true, loadFailed: false)
        expect(oldWatchdogStoodDown(buffering: bufferingAtEOF) == true,
               "layer2 old: the pre-fix watchdog stood down at EOF because buffering was true (hung ~15 min)")
        expect(newRecoverableAtEOF == true,
               "layer2 new: the fixed classifier recovers the same frame despite buffering")
        expect(oldWatchdogStoodDown(buffering: bufferingAtEOF) != !newRecoverableAtEOF,
               "layer2 divergence: exactly where the old watchdog waited forever, the new one recovers")

        // 2c - a genuine mid-stream rebuffer (play head short of the duration) is NOT this case: both the new
        //      classifier AND the old watchdog keep waiting, so normal buffering behavior is preserved.
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: false, currentTime: dur / 2, duration: dur, hasStartedPlaying: true, loadFailed: false) == false,
               "layer2 mid-stream: a rebuffer at currentTime < duration is NOT an EOF freeze -> normal path")
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur / 2, duration: dur, hasStartedPlaying: true, loadFailed: false) == false,
               "layer2 position: even with the flag set, a play head far short of duration does not count")

        // 2d - the pos ~= duration tolerance boundary (last ~1.5s of the file still counts as the final frame).
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur - 1.0, duration: dur, hasStartedPlaying: true, loadFailed: false),
               "layer2 tolerance: 1.0s before the end (within tolerance) still counts as the final frame")
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur - 30, duration: dur, hasStartedPlaying: true, loadFailed: false) == false,
               "layer2 tolerance: 30s before the end is not the final frame")

        // 2e - guards: never recover a session that never started, one already failed, or with no known duration.
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur, duration: dur, hasStartedPlaying: false, loadFailed: false) == false,
               "layer2 guard: a session that never produced a first frame is not an EOF freeze")
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: dur, duration: dur, hasStartedPlaying: true, loadFailed: true) == false,
               "layer2 guard: an already-failed load is owned by the failure path, not this")
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: true, currentTime: 0, duration: 0, hasStartedPlaying: true, loadFailed: false) == false,
               "layer2 guard: with no known duration there is no terminal position to detect")
        expect(TerminalPlaybackWatchdogPolicy.eofFreezeIsRecoverable(
                   atEOF: false, currentTime: dur, duration: dur, hasStartedPlaying: true, loadFailed: false) == false,
               "layer2 guard: without the EOF flag a play head at duration is not yet a terminal freeze")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
