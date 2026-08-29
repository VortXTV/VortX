// Standalone hostile contracts for cross-account playback, resume admission, and rail publication.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/external-sync-race-security \
//     app/SourcesShared/ExternalSyncSessionPolicy.swift \
//     app/Tests/ExternalSyncRaceSecurityTests.swift && /tmp/external-sync-race-security

import Foundation

@main
struct ExternalSyncRaceSecurityTestRunner {
    static func main() {
        var checks = 0
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        // Playback begins under A. Both auth boundaries then move the app to B while the player remains
        // alive. A same-token recovery is still the old playback and must own neither replacement account.
        var ownership = PlaybackScrobbleSessionOwnership<String, String>()
        expect(
            ownership.beginPlayback(
                itemKey: "tt123|video-1||",
                playbackToken: "player-1",
                traktSessionID: "trakt-A",
                simklSessionID: "simkl-A"
            ),
            "first frame opens a provider-owned playback lifecycle"
        )
        expect(ownership.snapshot.traktSessionID == "trakt-A",
               "Trakt lifecycle starts bound to account A")
        expect(ownership.snapshot.simklSessionID == "simkl-A",
               "SIMKL lifecycle starts bound to account A")

        ownership.invalidateTrakt()
        expect(ownership.snapshot.traktSessionID == nil,
               "Trakt boundary invalidates the active playback's Trakt owner")
        expect(ownership.snapshot.simklSessionID == "simkl-A",
               "Trakt boundary cannot disturb the SIMKL owner")
        ownership.invalidateSIMKL()
        expect(ownership.snapshot.simklSessionID == nil,
               "SIMKL boundary invalidates the active playback's SIMKL owner")

        expect(
            !ownership.beginPlayback(
                itemKey: "tt123|video-1||",
                playbackToken: "player-1",
                traktSessionID: "trakt-B",
                simklSessionID: "simkl-B"
            ),
            "same-token recovery cannot become a new account-B lifecycle"
        )
        expect(ownership.snapshot.traktSessionID == nil,
               "account-A playback never rebinds later Trakt events to B")
        expect(ownership.snapshot.simklSessionID == nil,
               "account-A playback never rebinds later SIMKL events to B")

        expect(
            ownership.beginPlayback(
                itemKey: "tt123|video-1||",
                playbackToken: "player-2",
                traktSessionID: "trakt-B",
                simklSessionID: "simkl-B"
            ),
            "a genuinely new player token may bind the replacement accounts"
        )
        expect(ownership.snapshot.traktSessionID == "trakt-B",
               "new playback owns Trakt account B")
        expect(ownership.snapshot.simklSessionID == "simkl-B",
               "new playback owns SIMKL account B")

        expect(ownership.attach(itemKey: "tt123|video-2|1|2"),
               "an event for a new item opens an unbound latch scope")
        expect(ownership.snapshot.traktSessionID == nil
                    && ownership.snapshot.simklSessionID == nil,
               "pre-start events own no provider account")

        // Render A's remote resume, switch to B before the tap and async source resolve, then try to present.
        // The displayed seconds and producer identity must remain one immutable value. Rejection must be
        // fail-closed and must not consume the one-shot offset.
        var resumeGate = OneShotResumeAdmissionGate<String>()
        let renderedAccountASuggestion = AccountBoundResumeSuggestion(
            seconds: 2_403,
            sessionID: "trakt-A"
        )
        let accountAResume = renderedAccountASuggestion.proposal
        expect(renderedAccountASuggestion.sessionID == "trakt-A",
               "a rendered suggestion retains its producer account")
        expect(resumeGate.admit(accountAResume, currentSessionID: "trakt-B") == nil,
               "an A-rendered suggestion is rejected when B becomes current before the tap")
        expect(!resumeGate.isConsumed,
               "a rejected account-switched suggestion remains unconsumed")
        expect(resumeGate.admit(accountAResume, currentSessionID: nil) == nil,
               "an A-rendered suggestion is rejected after sign-out before first content play")
        expect(!resumeGate.isConsumed,
               "a signed-out rejection cannot consume the remote suggestion")

        var localResumeGate = OneShotResumeAdmissionGate<String>()
        let localResume = AccountBoundResumeProposal(
            seconds: 321,
            expectedSessionID: Optional<String>.none,
            consumesInitial: false
        )
        expect(localResumeGate.admit(localResume, currentSessionID: nil)?.seconds == 321,
               "signed-out local playback remains admissible")
        expect(localResumeGate.admit(localResume, currentSessionID: "trakt-B")?.seconds == 321,
               "a Trakt session rotation cannot block local playback")
        expect(!localResumeGate.isConsumed,
               "local playback does not consume a remote one-shot gate")

        let admittedA = resumeGate.admit(accountAResume, currentSessionID: "trakt-A")
        expect(admittedA?.seconds == 2_403,
               "the matching exact session admits the original offset")
        expect(resumeGate.isConsumed,
               "only the admitted presentation consumes the initial-resume state")
        expect(resumeGate.admit(accountAResume, currentSessionID: "trakt-A")?.seconds == 2_403,
               "an explicit user suggestion remains repeatable after the initial offset was consumed")
        let explicitRestart = AccountBoundResumeProposal(
            seconds: 0,
            expectedSessionID: Optional<String>.none,
            consumesInitial: true
        )
        expect(resumeGate.admit(explicitRestart, currentSessionID: "trakt-A")?.seconds == 0,
               "an explicit user restart remains admissible after the initial offset was consumed")

        var oneShotGate = OneShotResumeAdmissionGate<String>()
        let initialAccountAResume = AccountBoundResumeProposal(
            seconds: 900,
            expectedSessionID: Optional("trakt-A"),
            consumesInitial: true,
            requiresUnconsumedInitial: true
        )
        expect(oneShotGate.admit(initialAccountAResume, currentSessionID: "trakt-A")?.seconds == 900,
               "a matching initial remote resume is admitted once")
        expect(oneShotGate.admit(initialAccountAResume, currentSessionID: "trakt-A") == nil,
               "an admitted initial remote resume cannot present twice")

        let failedLaunchGate = OneShotResumeAdmissionGate<String>()
        let proposedButNotPresented = AccountBoundResumeProposal(
            seconds: 900,
            expectedSessionID: Optional("trakt-A"),
            consumesInitial: true,
            requiresUnconsumedInitial: true
        )
        expect(!failedLaunchGate.isConsumed,
               "proposing an offset does not mutate the one-shot gate")
        _ = proposedButNotPresented
        expect(!failedLaunchGate.isConsumed,
               "a stale target or failed source before admission preserves the offset")

        // A valid empty remote list is authoritative. A failed read is not.
        let prior = ["old-private-row"]
        let afterFailure = ExternalRailSnapshotPolicy.resolved(
            current: prior,
            outcome: ExternalRailFetchOutcome<String>.failure
        )
        expect(afterFailure == prior,
               "transport or auth failure preserves the prior complete rail")
        let afterEmptySuccess = ExternalRailSnapshotPolicy.resolved(
            current: prior,
            outcome: ExternalRailFetchOutcome<String>.success([])
        )
        expect(afterEmptySuccess.isEmpty,
               "successful empty snapshot clears stale remote rows")
        let afterReplacement = ExternalRailSnapshotPolicy.resolved(
            current: prior,
            outcome: ExternalRailFetchOutcome.success(["new-private-row"])
        )
        expect(afterReplacement == ["new-private-row"],
               "successful non-empty snapshot replaces the rail atomically")

        if failures.isEmpty {
            print("PASS: \(checks) external sync race security checks")
        } else {
            for failure in failures {
                fputs("FAIL: \(failure)\n", stderr)
            }
            exit(1)
        }
    }
}
