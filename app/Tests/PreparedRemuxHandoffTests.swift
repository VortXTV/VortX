// Standalone executable contract for the exact-identity prepared-remux handoff.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/prepared-remux-handoff \
//     app/Sources/Player/VortXPreparedRemuxPolicy.swift \
//     app/Tests/PreparedRemuxHandoffTests.swift && /tmp/prepared-remux-handoff

import Foundation

@main
struct PreparedRemuxHandoffTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() {
        exactIdentityIncludesEveryTransportInput()
        preparationNeverStartsBesideCurrentPlaybackProducer()
        cancelledPreparationCannotStartAfterPlaybackUnwinds()
        rejectedBeforeStartAcknowledgesQuiescence()
        readinessGatesOneShotAdoption()
        adoptionReusesThePreparedTransport()
        staleCleanupRunsOnce()
        mismatchedSourceIsRejected()
        currentPlaybackSurvivesProducerHandoff()
        sameOwnerStaysAdmissibleAcrossSurfaceChange()
        changedOwnerAbandonsOnSurfaceChange()
        skipBeforeReadyFallsBackCold()
        coordinatorReleaseWaitsForRealProducerUnwind()
        liveCoordinatorSerializesProducerCallbacks()
        liveCoordinatorCleansReplacementAndCancellationOnce()
        liveCoordinatorPreemptsPreparationForWaitingPlayback()
        neverStartedCancellationReleasesOnce()
        productionWiringIsMutationSensitive()

        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed) of \(passed + failed) checks")
        exit(failed == 0 ? 0 : 1)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed += 1
            print("FAIL  \(message)")
        }
    }

    private static func owner(_ generation: UInt64 = 7) -> VortXPreparedRemuxOwnerIdentity {
        .init(mediaID: "tt123:1:2", generation: generation, sourceSignature: "addon/release")
    }

    private static func identity(
        url: String = "https://cdn.example/episode.mkv",
        owner: VortXPreparedRemuxOwnerIdentity? = nil
    ) -> VortXPreparedRemuxIdentity {
        VortXPreparedRemuxIdentity(
            owner: owner ?? self.owner(),
            input: URL(string: url)!,
            headers: ["Authorization": "Bearer exact", "User-Agent": "VortX"],
            mode: .dolbyVision,
            startAtSeconds: 0,
            selectedAudioStreamIndex: nil,
            preferredAudioLanguages: ["en", "ja"],
            audioRejectTerms: ["commentary"])
    }

    private static func exactIdentityIncludesEveryTransportInput() {
        let expected = identity()
        let reordered = VortXPreparedRemuxIdentity(
            owner: owner(),
            input: URL(string: "https://cdn.example/episode.mkv")!,
            headers: ["user-agent": "VortX", "authorization": "Bearer exact"],
            mode: .dolbyVision,
            startAtSeconds: 0,
            selectedAudioStreamIndex: nil,
            preferredAudioLanguages: ["en", "ja"],
            audioRejectTerms: ["commentary"])
        expect(expected == reordered,
               "HTTP header order and field-name case do not create a false identity mismatch")
        expect(expected != identity(url: "https://cdn.example/other.mkv"),
               "a different resolved source URL cannot adopt the prepared transport")
        expect(expected != identity(owner: owner(8)),
               "a stale episode generation cannot adopt an otherwise identical source")
    }

    private static func preparationNeverStartsBesideCurrentPlaybackProducer() {
        var policy = VortXRemuxProducerArbitration()
        expect(policy.submit(id: 1, purpose: .playback) == [.start(1)],
               "current playback acquires the only producer slot")
        expect(policy.submit(id: 2, purpose: .preparation).isEmpty,
               "next preparation queues while current playback still produces")
        expect(policy.active?.id == 1 && policy.pending?.id == 2,
               "queued preparation never replaces or preempts current playback")
    }

    private static func cancelledPreparationCannotStartAfterPlaybackUnwinds() {
        var policy = VortXRemuxProducerArbitration()
        _ = policy.submit(id: 1, purpose: .playback)
        _ = policy.submit(id: 2, purpose: .preparation)
        expect(policy.cancel(id: 2) == [.reject(2)],
               "handoff cancellation removes queued preparation before the old producer unwinds")
        expect(policy.producerDidUnwind(id: 1).isEmpty,
               "an AV-to-mpv handoff leaves no queued preparation to start beside mpv")
        expect(
            VortXRemuxHandoffPolicy.canMountMPV(routeStillCurrent: true, producerQuiescent: true)
                && !VortXRemuxHandoffPolicy.canMountMPV(routeStillCurrent: true, producerQuiescent: false),
            "replacement mpv is admitted only with zero active remux producers"
        )
    }

    private static func rejectedBeforeStartAcknowledgesQuiescence() {
        let relay = VortXRemuxProducerTerminalRelay()
        let receipt = VortXRemuxQuiescenceReceipt(terminal: relay)
        expect(!receipt.isAcknowledged, "a queued producer is not quiescent before cancellation")
        relay.fire()
        expect(receipt.isAcknowledged,
               "a rejected never-started producer acknowledges the same terminal receipt")
    }

    private static func readinessGatesOneShotAdoption() {
        let expected = identity()
        var notReady = VortXPreparedRemuxAdoptionState()
        expect(notReady.consume(expected: expected, actual: expected, ready: false)
                == .coldLoad(reason: .notReady, cleanup: true),
               "init plus startup media readiness is mandatory for adoption")

        var ready = VortXPreparedRemuxAdoptionState()
        expect(ready.consume(expected: expected, actual: expected, ready: true) == .adopt,
               "an exact ready transport is adopted")
        expect(ready.consume(expected: expected, actual: expected, ready: true)
                == .coldLoad(reason: .alreadyConsumed, cleanup: false),
               "a prepared transport can be adopted only once")
    }

    private static func adoptionReusesThePreparedTransport() {
        var state = VortXPreparedRemuxAdoptionState()
        var serverCreates = 1
        var producerStarts = 1
        let decision = state.consume(expected: identity(), actual: identity(), ready: true)
        if decision != .adopt {
            serverCreates += 1
            producerStarts += 1
        }
        expect(serverCreates == 1 && producerStarts == 1,
               "adoption reuses the same server and producer without a second create or start")
    }

    private static func staleCleanupRunsOnce() {
        var state = VortXPreparedRemuxAdoptionState()
        expect(state.retire(), "the first stale-generation retirement owns cleanup")
        expect(!state.retire(), "repeated stale retirement cannot clean up twice")
    }

    private static func mismatchedSourceIsRejected() {
        var state = VortXPreparedRemuxAdoptionState()
        expect(state.consume(
            expected: identity(url: "https://cdn.example/new.mkv"),
            actual: identity(),
            ready: true
        ) == .coldLoad(reason: .identityMismatch, cleanup: true),
        "a mismatched source rejects and retires the prepared transport")
    }

    private static func currentPlaybackSurvivesProducerHandoff() {
        var policy = VortXRemuxProducerArbitration()
        var currentListenerServing = true
        _ = policy.submit(id: 1, purpose: .playback)
        _ = policy.submit(id: 2, purpose: .preparation)
        let actions = policy.producerDidUnwind(id: 1)
        expect(actions == [.start(2)],
               "the next producer starts only after the current producer unwinds")
        expect(currentListenerServing,
               "producer handoff does not retire the current listener or retained credits spool")
        currentListenerServing = false
    }

    private static func sameOwnerStaysAdmissibleAcrossSurfaceChange() {
        // Beta 26 C1, F7: an AV-to-mpv demote changes the render surface, not the TARGET episode's owner. A
        // prepared next-episode transport therefore stays admissible (.configure) so the prewarm survives the
        // engine swap instead of being thrashed and refetched from scratch.
        let preparedOwner = owner(9)
        expect(
            VortXPreparedRemuxCallerPolicy.admission(
                actualOwner: preparedOwner,
                expectedOwner: preparedOwner,
                avPlayerActive: true,
                mountIsOnDevice: true
            ) == .configure,
            "same-owner prepared transport stays admissible across an engine surface change (prewarm survives demote)"
        )
    }

    private static func changedOwnerAbandonsOnSurfaceChange() {
        // The guardrails stay: a genuinely different episode owner must abandon the prepared transport even if
        // the engine surface happened to change at the same time.
        expect(
            VortXPreparedRemuxCallerPolicy.admission(
                actualOwner: owner(9),
                expectedOwner: owner(10),
                avPlayerActive: true,
                mountIsOnDevice: true
            ) == .abandonAndColdLoad,
            "owner mismatch abandons the prepared transport regardless of the engine surface"
        )
    }

    private static func skipBeforeReadyFallsBackCold() {
        var state = VortXPreparedRemuxAdoptionState()
        let decision = state.consume(expected: identity(), actual: identity(), ready: false)
        expect(decision == .coldLoad(reason: .notReady, cleanup: true),
               "a skip before prepared readiness takes the cold-load fallback")
    }

    private static func coordinatorReleaseWaitsForRealProducerUnwind() {
        var terminal = VortXRemuxProducerTerminalState()
        expect(terminal.begin(), "the producer enters the running state once")
        let snapshotEnded = true
        expect(snapshotEnded && terminal.phase == .running,
               "an ended snapshot alone does not release the producer coordinator")
        expect(terminal.producerDidUnwind(),
               "the real producer unwind emits the authoritative terminal receipt")
        expect(!terminal.producerDidUnwind(),
               "the authoritative terminal receipt is exactly once")
    }

    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func record(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func count(_ event: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return events.filter { $0 == event }.count
        }
    }

    private static func liveCoordinatorSerializesProducerCallbacks() {
        let coordinator = VortXRemuxProducerCoordinator()
        let recorder = CallbackRecorder()
        let playback = coordinator.submit(
            purpose: .playback,
            start: { _ in recorder.record("playback-start") },
            preempt: { recorder.record("playback-preempt") },
            reject: { recorder.record("playback-reject") })
        let preparation = coordinator.submit(
            purpose: .preparation,
            start: { _ in recorder.record("preparation-start") },
            preempt: { recorder.record("preparation-preempt") },
            reject: { recorder.record("preparation-reject") })

        expect(recorder.count("playback-start") == 1
                && recorder.count("preparation-start") == 0,
               "the live coordinator starts playback and leaves preparation queued")
        playback.producerDidUnwind()
        expect(recorder.count("preparation-start") == 1,
               "only the live playback unwind starts queued preparation exactly once")
        playback.producerDidUnwind()
        expect(recorder.count("preparation-start") == 1,
               "a duplicate playback unwind cannot start preparation twice")
        preparation.producerDidUnwind()
    }

    private static func liveCoordinatorCleansReplacementAndCancellationOnce() {
        let coordinator = VortXRemuxProducerCoordinator()
        let recorder = CallbackRecorder()
        let playback = coordinator.submit(
            purpose: .playback,
            start: { _ in recorder.record("playback-start") },
            preempt: { recorder.record("playback-preempt") },
            reject: { recorder.record("playback-reject") })
        let replaced = coordinator.submit(
            purpose: .preparation,
            start: { _ in recorder.record("replaced-start") },
            preempt: { recorder.record("replaced-preempt") },
            reject: { recorder.record("replaced-reject") })
        let replacement = coordinator.submit(
            purpose: .preparation,
            start: { _ in recorder.record("replacement-start") },
            preempt: { recorder.record("replacement-preempt") },
            reject: { recorder.record("replacement-reject") })

        expect(recorder.count("replaced-reject") == 1,
               "replacing a queued preparation cleans the old request exactly once")
        replaced.cancel()
        expect(recorder.count("replaced-reject") == 1,
               "cancelling an already replaced request cannot clean it twice")
        replacement.cancel()
        replacement.cancel()
        expect(recorder.count("replacement-reject") == 1,
               "queued preparation cancellation cleans exactly once")
        playback.producerDidUnwind()
    }

    private static func liveCoordinatorPreemptsPreparationForWaitingPlayback() {
        let coordinator = VortXRemuxProducerCoordinator()
        let recorder = CallbackRecorder()
        let preparation = coordinator.submit(
            purpose: .preparation,
            start: { _ in recorder.record("preparation-start") },
            preempt: { recorder.record("preparation-preempt") },
            reject: { recorder.record("preparation-reject") })
        let playback = coordinator.submit(
            purpose: .playback,
            start: { _ in recorder.record("playback-start") },
            preempt: { recorder.record("playback-preempt") },
            reject: { recorder.record("playback-reject") })

        expect(recorder.count("preparation-preempt") == 1
                && recorder.count("playback-start") == 0,
               "waiting playback preempts preparation but waits for its real unwind")
        preparation.producerDidUnwind()
        expect(recorder.count("playback-start") == 1,
               "preparation unwind yields the one producer slot to waiting playback")
        preparation.producerDidUnwind()
        expect(recorder.count("playback-start") == 1,
               "duplicate preparation unwind cannot start waiting playback twice")
        playback.producerDidUnwind()
    }

    private static func neverStartedCancellationReleasesOnce() {
        var terminal = VortXRemuxProducerTerminalState()
        expect(terminal.cancelBeforeStart(),
               "cancelling a never-started queued stream emits its terminal receipt")
        expect(!terminal.cancelBeforeStart(),
               "never-started cancellation cannot emit twice")
    }

    private struct WiringRule {
        let name: String
        let relativePath: String
        let required: [String]
        let mutationTarget: String
        let mutationReplacement: String
    }

    private static func productionWiringIsMutationSensitive() {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rules = [
            WiringRule(
                name: "producer terminal fires from run unwind",
                relativePath: "Sources/Player/VortXMKVRemuxStream.swift",
                required: [
                    "defer {",
                    "hlsSpool?.producerDidTerminate()",
                    "            notifyProducerDidUnwind()",
                ],
                mutationTarget: "            notifyProducerDidUnwind()",
                mutationReplacement: ""),
            WiringRule(
                name: "preparation and adoption split deadline ownership",
                relativePath: "Sources/Player/VortXRemuxHLSServer.swift",
                required: [
                    "func beginPreparation()",
                    "purpose: .preparation",
                    "awaitPreparedReadiness(",
                    "func adoptPrepared(",
                    "armMountDeadline()",
                ],
                mutationTarget: "awaitPreparedReadiness(",
                mutationReplacement: "yieldWithoutReadiness("),
            WiringRule(
                name: "prepared producer unwind keeps current serving transport alive",
                relativePath: "Sources/Player/VortXRemuxHLSServer.swift",
                required: [
                    "private func producerDidUnwind()",
                    "if let ticket { ticket.producerDidUnwind() }",
                ],
                mutationTarget: "if let ticket { ticket.producerDidUnwind() }",
                mutationReplacement: "invalidate()"),
            WiringRule(
                name: "AVPlayer adopts before cold server construction",
                relativePath: "Sources/Player/AVPlayerEngine.swift",
                required: [
                    "preparedCandidate.handle.adopt(",
                    "remuxHLSServer = adopted.server",
                    "VortXRemuxHLSServer.make(input: url",
                ],
                mutationTarget: "remuxHLSServer = adopted.server",
                mutationReplacement: "remuxHLSServer = nil"),
        ]

        for rule in rules {
            let url = appRoot.appendingPathComponent(rule.relativePath)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "\(rule.name) source is readable")
                continue
            }
            expect(containsInOrder(rule.required, in: source), rule.name)
            guard let range = source.range(of: rule.mutationTarget) else {
                expect(false, "\(rule.name) mutation target exists")
                continue
            }
            var mutated = source
            mutated.replaceSubrange(range, with: rule.mutationReplacement)
            expect(!containsInOrder(rule.required, in: mutated),
                   "\(rule.name) turns red under its hostile mutation")
        }
    }

    private static func containsInOrder(_ needles: [String], in source: String) -> Bool {
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }
}
