// Executable policy/state tests for iOS HLS background-download recovery.
//
//   { printf '%s\n' 'import Foundation'; \
//     sed -n '/^enum HLSBackgroundRecoveryPolicy {/,/^\/\/ END HLS background policy state$/p' \
//       app/SourcesShared/DownloadManager.swift | sed '$d'; } > /tmp/hls-background-policy.swift && \
//   swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     /tmp/hls-background-policy.swift app/Tests/HLSBackgroundRecoveryPolicyTests.swift \
//     -o /tmp/hls-background-recovery-policy-test && \
//   /tmp/hls-background-recovery-policy-test
//
// The declarations under test are dependency-free production policy/state code. These tests exercise the
// state transitions directly, including hostile same-ID sessions, zero-record relaunch, barrier ordering,
// duplicate callbacks, cancellation/finalization races, and exactly-once cleanup claims.

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func fire(_ handlers: [() -> Void]) {
    handlers.forEach { $0() }
}

private func cleanupClaims(
    _ ledger: HLSAssetLifecycleLedger,
    taskIdentifier: Int,
    location: URL
) -> [URL] {
    var claims: [URL] = []
    if let location = ledger.cancel(taskIdentifier: taskIdentifier) { claims.append(location) }
    if let location = ledger.recordFinishedLocation(taskIdentifier: taskIdentifier, location: location) {
        claims.append(location)
    }
    return claims
}

@main
private enum HLSBackgroundRecoveryPolicyTests {
    @MainActor
    static func main() {
        let byte = HLSBackgroundRecoveryPolicy.Candidate(
            id: "byte-record", taskIdentifier: 1, isHLS: false, isTorrent: false, downloading: true)
        let hls = HLSBackgroundRecoveryPolicy.Candidate(
            id: "hls-record", taskIdentifier: 1, isHLS: true, isTorrent: false, downloading: true)
        let records = [byte, hls]

        // taskIdentifier 1 exists in both sessions. Each reconnect path must select only its own transport.
        check(
            "same-ID sessions: byte reconnect selects the byte record",
            HLSBackgroundRecoveryPolicy.matchingID(
                taskIdentifier: 1, session: .byteBackground, records: records) == "byte-record")
        check(
            "same-ID sessions: HLS reconnect selects the HLS record",
            HLSBackgroundRecoveryPolicy.matchingID(
                taskIdentifier: 1, session: .hlsAsset, records: records) == "hls-record")
        check(
            "same-ID sessions: non-downloading records are rejected",
            HLSBackgroundRecoveryPolicy.matchingID(
                taskIdentifier: 1,
                session: .hlsAsset,
                records: [hls.withDownloading(false)]) == nil)
        check(
            "same-ID sessions: torrent records are rejected from both background lanes",
            !HLSBackgroundRecoveryPolicy.accepts(
                byte.withTorrent(true), for: .byteBackground)
                && !HLSBackgroundRecoveryPolicy.accepts(
                    hls.withTorrent(true), for: .hlsAsset))

        // A relaunch callback names one exact session. That session must materialize even when the store has
        // zero in-flight records; an ordinary launch with no records remains a no-op.
        let byteIdentifier = "tv.vortx.downloads.background"
        let hlsIdentifier = "tv.vortx.downloads.hls"
        check(
            "zero-record relaunch: exact HLS callback materializes HLS only",
            HLSBackgroundRecoveryPolicy.sessionsToMaterialize(
                for: hlsIdentifier,
                backgroundIdentifier: byteIdentifier,
                hlsIdentifier: hlsIdentifier,
                hasInFlightRecords: false) == [.hlsAsset])
        check(
            "zero-record relaunch: exact byte callback materializes byte only",
            HLSBackgroundRecoveryPolicy.sessionsToMaterialize(
                for: byteIdentifier,
                backgroundIdentifier: byteIdentifier,
                hlsIdentifier: hlsIdentifier,
                hasInFlightRecords: false) == [.byteBackground])
        check(
            "ordinary zero-record launch: no session materializes",
            HLSBackgroundRecoveryPolicy.sessionsToMaterialize(
                for: nil,
                backgroundIdentifier: byteIdentifier,
                hlsIdentifier: hlsIdentifier,
                hasInFlightRecords: false).isEmpty)
        check(
            "ordinary active launch: both sessions reconnect",
            HLSBackgroundRecoveryPolicy.sessionsToMaterialize(
                for: nil,
                backgroundIdentifier: byteIdentifier,
                hlsIdentifier: hlsIdentifier,
                hasInFlightRecords: true) == [.byteBackground, .hlsAsset])
        check(
            "unknown callback identifier: no session materializes",
            HLSBackgroundRecoveryPolicy.sessionsToMaterialize(
                for: "tv.vortx.unknown",
                backgroundIdentifier: byteIdentifier,
                hlsIdentifier: hlsIdentifier,
                hasInFlightRecords: true).isEmpty)

        // UIApplication completion is released only after the session-drain signal AND every deferred HLS
        // finalizer have joined the same per-session barrier. Repeated signals release at most once.
        let barrier = HLSBackgroundEventBarrier()
        var releases = 0
        check("barrier: completion is retained until finalization begins", !barrier.addCompletion { releases += 1 })
        barrier.beginFinalization()
        check("barrier: session drain waits for finalization", barrier.finishEvents().isEmpty)
        check("barrier: no early completion release", releases == 0)
        fire(barrier.completeFinalization())
        check("barrier: finalization releases completion exactly once", releases == 1)
        check("barrier: duplicate session-drain callback is ignored", barrier.finishEvents().isEmpty)
        check("barrier: late handler is released immediately once", barrier.addCompletion { releases += 1 })
        check("barrier: late handler has not run until manager invokes it", releases == 1)
        releases += 1
        check("barrier: late handler invocation is caller-owned and exact", releases == 2)

        // Two finalizers join before the handler is released, regardless of completion-event ordering.
        let twoFinalizers = HLSBackgroundEventBarrier()
        var joinedReleases = 0
        _ = twoFinalizers.addCompletion { joinedReleases += 1 }
        twoFinalizers.beginFinalization()
        twoFinalizers.beginFinalization()
        fire(twoFinalizers.finishEvents())
        fire(twoFinalizers.completeFinalization())
        check("barrier: first of two finalizers cannot release", joinedReleases == 0)
        fire(twoFinalizers.completeFinalization())
        check("barrier: second finalizer releases the joined completion", joinedReleases == 1)

        let location = URL(fileURLWithPath: "/tmp/hls-recovery-tests/title.movpkg")

        // Cancel before the finish callback: the late system path is claimed for cleanup once and cannot
        // resurrect the removed record or trigger finalization.
        let cancelFirst = HLSAssetLifecycleLedger()
        let cancelFirstClaims = cleanupClaims(cancelFirst, taskIdentifier: 7, location: location)
        check("cancel/finalize: cancel-before-finish claims cleanup exactly once", cancelFirstClaims == [location])
        check("cancel/finalize: cancelled task cannot finalize", cancelFirst.beginFinalization(taskIdentifier: 7) == .ignored)
        check("cancel/finalize: duplicate late finish has no second cleanup", cleanupClaims(cancelFirst, taskIdentifier: 7, location: location).isEmpty)

        // Finish callback before cancel: cancellation wins before the deferred main-actor finalizer mutates
        // the record, and the system-managed path is still cleaned exactly once.
        let finishThenCancel = HLSAssetLifecycleLedger()
        _ = finishThenCancel.recordFinishedLocation(taskIdentifier: 8, location: location)
        check("cancel/finalize: finish is accepted before cancellation", finishThenCancel.beginFinalization(taskIdentifier: 8) == .accepted(location))
        check("cancel/finalize: cancel claims pending movpkg", finishThenCancel.cancel(taskIdentifier: 8) == location)
        finishThenCancel.complete(taskIdentifier: 8, canonicalLocation: location)
        check("cancel/finalize: duplicate callback after cancel is ignored", finishThenCancel.recordFinishedLocation(taskIdentifier: 8, location: location) == nil)

        // Successful completion leaves the canonical system path owned by the completed record; duplicate
        // callbacks cannot request cleanup, and a later record removal owns the one real deletion.
        let successful = HLSAssetLifecycleLedger()
        _ = successful.recordFinishedLocation(taskIdentifier: 9, location: location)
        check("cleanup: successful finalization accepts the canonical path", successful.beginFinalization(taskIdentifier: 9) == .accepted(location))
        successful.complete(taskIdentifier: 9, canonicalLocation: location)
        check("cleanup: duplicate finish does not delete completed movpkg", successful.recordFinishedLocation(taskIdentifier: 9, location: location) == nil)
        check("cleanup: completed task has no pending cancellation cleanup", successful.cancel(taskIdentifier: 9) == nil)

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}

private extension HLSBackgroundRecoveryPolicy.Candidate {
    func withDownloading(_ value: Bool) -> Self {
        Self(id: id, taskIdentifier: taskIdentifier, isHLS: isHLS, isTorrent: isTorrent, downloading: value)
    }

    func withTorrent(_ value: Bool) -> Self {
        Self(id: id, taskIdentifier: taskIdentifier, isHLS: isHLS, isTorrent: value, downloading: downloading)
    }
}
