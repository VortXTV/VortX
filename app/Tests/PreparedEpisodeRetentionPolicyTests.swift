// Standalone strict-concurrency contract for retained next-episode identity.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-episode-retention \
//     app/SourcesShared/NextEpisodePreparationWork.swift \
//     app/SourcesShared/PreparedEpisodeRetentionPolicy.swift \
//     app/Tests/PreparedEpisodeRetentionPolicyTests.swift && /tmp/prepared-episode-retention

import Foundation

@main
struct PreparedEpisodeRetentionPolicyTests {
    static func main() {
        var passed = 0
        func expect(_ condition: Bool, _ message: String) {
            if condition {
                passed += 1
                print("PASS  \(message)")
            } else {
                print("FAIL  \(message)")
                exit(1)
            }
        }

        expect(
            PreparedEpisodeRetentionPolicy.ownsCompletion(
                capturedGeneration: 4, currentGeneration: 4,
                capturedOriginEpisodeID: "show:1:1", currentOriginEpisodeID: "show:1:1",
                canceled: false
            ),
            "the exact prepared episode is retained for the unchanged playback generation"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.ownsCompletion(
                capturedGeneration: 4, currentGeneration: 5,
                capturedOriginEpisodeID: "show:1:1", currentOriginEpisodeID: "show:1:1",
                canceled: false
            ),
            "invalidation rejects a late prepared completion"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.ownsCompletion(
                capturedGeneration: 4, currentGeneration: 4,
                capturedOriginEpisodeID: "show:1:1", currentOriginEpisodeID: "show:1:1",
                canceled: true
            ),
            "cancellation rejects a late network completion before it can be retained"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.ownsCompletion(
                capturedGeneration: 4, currentGeneration: 4,
                capturedOriginEpisodeID: "show:1:1", currentOriginEpisodeID: "show:1:2",
                canceled: false
            ),
            "an old episode preparation cannot survive an origin transition"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.admitsPreparedValue(
                requestedEpisodeID: "show:1:2", returnedEpisodeID: "show:1:3",
            ),
            "a different episode cannot enter the retained slot"
        )
        expect(
            PreparedEpisodeRetentionPolicy.consumes(
                requestedEpisodeID: "show:1:2", preparedEpisodeID: "show:1:2"
            ),
            "the transition consumes its exact retained episode"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.consumes(
                requestedEpisodeID: "show:1:3", preparedEpisodeID: "show:1:2"
            ),
            "a manual jump cannot consume another episode's retained value"
        )
        expect(
            PreparedEpisodeRetentionPolicy.sourceIdentityTarget(
                requestedEpisodeID: "show:1:2", preparedEpisodeID: "show:1:2"
            ) == "show:1:2",
            "prepared admission advances failover ownership to the incoming episode"
        )
        expect(
            PreparedEpisodeRetentionPolicy.sourceIdentityTarget(
                requestedEpisodeID: "show:1:2", preparedEpisodeID: "show:1:1"
            ) == nil,
            "a stale prepared value cannot leave failover bound to the outgoing episode"
        )
        expect(
            PreparedEpisodeRetentionPolicy.isPendingReentry(
                requestedEpisodeID: "show:1:2", pendingEpisodeID: "show:1:2",
                pendingIssued: true, pendingTerminal: false, activeLoadMatches: true
            ),
            "an exact live pending reentry preserves the retained slot"
        )
        expect(
            !PreparedEpisodeRetentionPolicy.isPendingReentry(
                requestedEpisodeID: "show:1:3", pendingEpisodeID: "show:1:2",
                pendingIssued: true, pendingTerminal: false, activeLoadMatches: true
            ),
            "a different target may supersede the pending episode and consume its own prepared value"
        )

        var retry = PreparedEpisodeAttemptPolicy()
        let first = retry.evaluate(
            targetEpisodeID: "show:1:2", position: 50, duration: 100, now: 0
        )
        expect(first?.sequence == 1, "halfway playback launches one first preparation")
        expect(
            first?.deadline == NextEpisodePreparationBudget.attemptTimeout,
            "the player attempt owns the absolute preparation deadline"
        )
        let firstRequest = first?.preparationRequest(
            protectedTorrentHash: String(repeating: "a", count: 40)
        )
        expect(
            firstRequest?.episodeID == "show:1:2"
                && firstRequest?.attemptSequence == 1
                && firstRequest?.nearCredits == false
                && firstRequest?.deadline == first?.deadline,
            "the production request carries the exact player attempt identity"
        )
        expect(
            retry.evaluate(targetEpisodeID: "show:1:2", position: 51, duration: 100, now: 1) == nil,
            "ticks cannot duplicate an active preparation"
        )
        expect(
            first.map { retry.complete($0, succeeded: false, now: 1) } == .retryScheduled,
            "an empty first preparation schedules a bounded retry"
        )
        expect(
            retry.evaluate(targetEpisodeID: "show:1:2", position: 60, duration: 100, now: 20) == nil,
            "the retry cannot relaunch on every playback tick"
        )
        let second = retry.evaluate(
            targetEpisodeID: "show:1:2", position: 60, duration: 100, now: 21
        )
        expect(second?.sequence == 2, "the first backoff admits exactly one retry")
        expect(
            second.map { retry.complete($0, succeeded: true, now: 22) } == .ready,
            "a successful retry becomes the retained ready value"
        )
        expect(
            retry.evaluate(targetEpisodeID: "show:1:2", position: 99, duration: 100, now: 500) == nil,
            "a ready target never launches another preparation"
        )

        var exhausted = PreparedEpisodeAttemptPolicy()
        let exhaustedFirst = exhausted.evaluate(
            targetEpisodeID: "show:1:2", position: 500, duration: 1000, now: 0
        )!
        _ = exhausted.complete(exhaustedFirst, succeeded: false, now: 0)
        let exhaustedSecond = exhausted.evaluate(
            targetEpisodeID: "show:1:2", position: 520, duration: 1000, now: 20
        )!
        _ = exhausted.complete(exhaustedSecond, succeeded: false, now: 20)
        let exhaustedThird = exhausted.evaluate(
            targetEpisodeID: "show:1:2", position: 600, duration: 1000, now: 80
        )!
        expect(
            exhausted.complete(exhaustedThird, succeeded: false, now: 80) == .exhausted,
            "three failed regular attempts exhaust the normal retry budget"
        )
        expect(
            exhausted.evaluate(targetEpisodeID: "show:1:2", position: 700, duration: 1000, now: 200) == nil,
            "an exhausted target stays quiet before credits"
        )
        let credits = exhausted.evaluate(
            targetEpisodeID: "show:1:2", position: 901, duration: 1000, now: 201
        )
        expect(credits?.nearCredits == true, "credits admit one final recovery attempt")
        expect(
            credits.map { exhausted.complete($0, succeeded: false, now: 202) } == .exhausted,
            "a failed credits attempt stays exhausted"
        )
        expect(
            exhausted.evaluate(targetEpisodeID: "show:1:2", position: 950, duration: 1000, now: 400) == nil,
            "credits cannot create an unbounded retry loop"
        )
        expect(
            !PreparedEpisodeAttemptPolicy.shouldRearmAfterSourceSwitch(
                hasPendingAdvance: false, isEpisodePlayback: true,
                position: 49, duration: 100
            ),
            "a source switch before halfway cannot start preparation"
        )
        expect(
            PreparedEpisodeAttemptPolicy.shouldRearmAfterSourceSwitch(
                hasPendingAdvance: false, isEpisodePlayback: true,
                position: 50, duration: 100
            ),
            "a source switch after the gate can invalidate and immediately re-arm preparation"
        )
        expect(
            !PreparedEpisodeAttemptPolicy.shouldRearmAfterSourceSwitch(
                hasPendingAdvance: true, isEpisodePlayback: true,
                position: 90, duration: 100
            ),
            "an in-flight episode advance cannot re-arm from the outgoing episode identity"
        )

        let torrentRequest = NextEpisodePreparationRequest(
            episodeID: "show:1:2",
            attemptSequence: 2,
            deadline: 100,
            nearCredits: false,
            protectedTorrentHash: nil
        )
        let canceledLease = PreparedTorrentEngineLease(
            request: torrentRequest,
            hash: String(repeating: "b", count: 40)
        )
        expect(
            !canceledLease.canWarm(for: torrentRequest),
            "a raw torrent cannot issue its range GET before create succeeds"
        )
        expect(
            !canceledLease.adopt(episodeID: "show:1:2", attemptSequence: 2),
            "an unready torrent engine cannot be admitted"
        )
        expect(canceledLease.abandon(), "cancellation owns the active lease cleanup")
        expect(!canceledLease.abandon(), "cancellation cleanup is exactly once")
        expect(
            !canceledLease.markCreateSucceeded(),
            "a late create completion cannot resurrect an abandoned lease"
        )

        let readyLease = PreparedTorrentEngineLease(
            request: torrentRequest,
            hash: String(repeating: "c", count: 40)
        )
        expect(readyLease.markCreateSucceeded(), "a 2xx tracker-bearing create marks readiness")
        expect(
            !readyLease.markCreateSucceeded(),
            "player admission cannot perform a second create transition"
        )
        expect(readyLease.canWarm(for: torrentRequest), "only the exact ready attempt may range-warm")
        expect(
            !readyLease.canAdmit(episodeID: "show:1:3", attemptSequence: 2),
            "another episode cannot steal the prepared engine"
        )
        expect(
            !readyLease.canAdmit(episodeID: "show:1:2", attemptSequence: 3),
            "a stale retry cannot steal the prepared engine"
        )
        expect(
            readyLease.adopt(episodeID: "show:1:2", attemptSequence: 2),
            "the exact admitted target adopts the already-created engine"
        )
        expect(
            !readyLease.abandon(),
            "stale invalidation cannot remove an adopted engine"
        )
        expect(
            !PreparedTorrentAdmissionPolicy.shouldRetireLease(
                playerCommandIssued: true,
                leaseAdopted: false
            ),
            "an accepted player command cannot remove its live torrent after a failed lease transition"
        )
        expect(
            PreparedTorrentAdmissionPolicy.shouldRetireLease(
                playerCommandIssued: false,
                leaseAdopted: false
            ),
            "a rejected player command leaves cleanup with the preparation owner"
        )
        expect(
            !PreparedTorrentAdmissionPolicy.shouldIssuePlaybackCreate(
                rawTorrent: true,
                leaseAdopted: true
            ),
            "an adopted raw-torrent preload suppresses the ordinary duplicate playback create"
        )
        expect(
            PreparedTorrentAdmissionPolicy.shouldIssuePlaybackCreate(
                rawTorrent: true,
                leaseAdopted: false
            ),
            "a cold raw torrent still receives its one ordinary playback create"
        )

        let canceledRequest = NextEpisodePreparationRequest(
            episodeID: "show:1:4",
            attemptSequence: 1,
            deadline: 100,
            nearCredits: false,
            protectedTorrentHash: nil
        )
        let canceledAfterTake = PreparedTorrentEngineLease(
            request: canceledRequest,
            hash: String(repeating: "e", count: 40)
        )
        expect(canceledAfterTake.markCreateSucceeded(), "cancellation fixture owns a ready engine")
        var cancellationRemoveCount = 0
        if canceledAfterTake.abandon(), !canceledAfterTake.protectsPlayingEngine {
            cancellationRemoveCount += 1
        }
        if canceledAfterTake.abandon(), !canceledAfterTake.protectsPlayingEngine {
            cancellationRemoveCount += 1
        }
        expect(
            cancellationRemoveCount == 1,
            "cancellation after retained take removes a non-protected engine exactly once"
        )

        let protectedHash = String(repeating: "f", count: 40)
        let staleRequest = NextEpisodePreparationRequest(
            episodeID: "show:1:5",
            attemptSequence: 2,
            deadline: 100,
            nearCredits: false,
            protectedTorrentHash: protectedHash.uppercased()
        )
        let staleAfterTake = PreparedTorrentEngineLease(
            request: staleRequest,
            hash: protectedHash
        )
        expect(staleAfterTake.markCreateSucceeded(), "staleness fixture owns a ready shared engine")
        var staleRemoveCount = 0
        if staleAfterTake.abandon(), !staleAfterTake.protectsPlayingEngine {
            staleRemoveCount += 1
        }
        expect(
            staleRemoveCount == 0,
            "staleness after retained take does not remove the protected playing engine"
        )

        let seasonPackHash = String(repeating: "d", count: 40)
        let seasonPackRequest = NextEpisodePreparationRequest(
            episodeID: "show:1:2",
            attemptSequence: 4,
            deadline: 100,
            nearCredits: true,
            protectedTorrentHash: seasonPackHash.uppercased()
        )
        let seasonPackLease = PreparedTorrentEngineLease(
            request: seasonPackRequest,
            hash: seasonPackHash
        )
        expect(
            seasonPackLease.protectsPlayingEngine,
            "canceling a same-hash season-pack preload preserves the playing engine"
        )

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detail = try? String(
            contentsOf: root.appendingPathComponent("app/SourcesiOS/iOSDetailView.swift"),
            encoding: .utf8
        )
        let player = try? String(
            contentsOf: root.appendingPathComponent("app/Sources/PlayerScreen.swift"),
            encoding: .utf8
        )
        if let detail,
           let create = detail.range(of: "prepareWarmTorrentEngine(best, request: request)"),
           let range = detail.range(of: "var mediaRequest = URLRequest(url: url)",
                                    range: create.upperBound..<detail.endIndex),
           let retained = detail.range(of: "torrentPreparationLease: torrentLease",
                                       range: range.upperBound..<detail.endIndex) {
            expect(create.lowerBound < range.lowerBound && range.lowerBound < retained.lowerBound,
                   "production awaits tracker-aware create before range GET and retains the lease")
        } else {
            expect(false, "production awaits tracker-aware create before range GET and retains the lease")
        }
        expect(
            detail?.contains("TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)") == true
                && detail?.contains("TorrentCreateTransport.shared.create(") == true,
            "production create carries the stream tracker set through the no-redirect transport"
        )
        expect(
            player?.contains("preparedTorrentLeaseIsAdmissible(") == true
                && player?.contains("admissionLease.adopt(") == true
                && player?.contains("retirePreparedTorrentEngine(preparedEpisode?.torrentPreparationLease, reason: reason)") == true,
            "production admission adopts exactly once and invalidation retires the old lease"
        )
        expect(
            player?.contains("admissionCommandIssued = issued") == true
                && player?.contains("PreparedTorrentAdmissionPolicy.shouldRetireLease(") == true,
            "production transfers cleanup safety at the accepted player-command boundary"
        )
        if let player,
           let taskStart = player.range(of: "episodeResolutionTask = Task { @MainActor in"),
           let leaseOwner = player.range(
            of: "let admissionLease = retainedPreparedEpisode?.torrentPreparationLease",
            range: taskStart.upperBound..<player.endIndex
           ),
           let cleanup = player.range(
            of: "defer {",
            range: leaseOwner.upperBound..<player.endIndex
           ),
           let resolve = player.range(
            of: "let resolved: PlayerEpisodeStream?",
            range: cleanup.upperBound..<player.endIndex
           ) {
            expect(
                leaseOwner.lowerBound < cleanup.lowerBound && cleanup.lowerBound < resolve.lowerBound,
                "production installs retained-lease cleanup before any resolve or stale-generation return"
            )
        } else {
            expect(false, "production installs retained-lease cleanup before any resolve or stale-generation return")
        }
        print("ALL PASS (\(passed) checks)")
    }
}
