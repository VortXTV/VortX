// Standalone strict contract for diagnostic export transfer ownership.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/vxdiag-transfer-policy \
//     app/SourcesShared/VXProbeRedaction.swift \
//     app/SourcesShared/VXDiagExportPolicy.swift \
//     app/Tests/VXDiagTransferPolicyTests.swift && /tmp/vxdiag-transfer-policy

import Foundation

@main
struct VXDiagTransferPolicyTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() {
        successfulTransferPreservesLogAndConsumesCapability()
        failedTransferPreservesAndRetries()
        restartedSessionRejectsOldCompletion()
        largeBodyIsChunkedExactly()
        nominalMultiChunkLANPreservesPrefixAcrossFreshSession()
        successfulSnapshotPreservesAppendedLines()
        changedPrefixFailsClosed()

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

    private static func successfulTransferPreservesLogAndConsumesCapability() {
        var gate = VXDiagExportPolicy.TransferGate()
        let claim = gate.claim()
        expect(claim != nil && gate.blocksNewClaim,
               "claim excludes a simultaneous second download")
        if let claim {
            let completion = gate.complete(claim, success: true)
            expect(completion == .deliveredPreservingLog,
                   "local send completion preserves the rolling log without receiver acknowledgement")
            expect(completion.connectionCleanup == .waitForPeerClose,
                   "nominal final-send completion cannot immediately cancel the connection")
        }
        expect(gate.claim() == nil, "successful transfer consumes the one-shot capability")
    }

    private static func failedTransferPreservesAndRetries() {
        var gate = VXDiagExportPolicy.TransferGate()
        let first = gate.claim()!
        let completion = gate.complete(first, success: false)
        expect(completion == .retryableFailure,
               "failed/interrupted send preserves the rolling log")
        expect(completion.connectionCleanup == .cancelImmediately,
               "failed transfer can close its broken connection immediately")
        expect(!gate.blocksNewClaim, "failure releases the in-flight claim")
        expect(gate.claim() != nil, "the same export window can retry after a failed transfer")
    }

    private static func restartedSessionRejectsOldCompletion() {
        var gate = VXDiagExportPolicy.TransferGate()
        let old = gate.claim()!
        gate.reset()
        let current = gate.claim()!
        expect(gate.complete(old, success: true) == .stale,
               "an old connection cannot finish a restarted export session")
        expect(gate.complete(current, success: true) == .deliveredPreservingLog,
               "the current generation still owns its completion")
    }

    private static func nominalMultiChunkLANPreservesPrefixAcrossFreshSession() {
        let snapshot = Data(
            repeating: 0x61,
            count: VXDiagExportPolicy.responseChunkBytes + 17
        )
        let appended = Data("new after snapshot\n".utf8)
        var rollingLog = snapshot
        rollingLog.append(appended)
        let ranges = VXDiagExportPolicy.chunkRanges(bodyBytes: snapshot.count)
        expect(ranges.count == 2, "the nominal LAN regression exercises multiple body chunks")

        var gate = VXDiagExportPolicy.TransferGate()
        let first = gate.claim()!
        let completion = gate.complete(first, success: true)
        expect(
            completion == .deliveredPreservingLog,
            "nominal multi-chunk LAN completion carries no log-clear authority"
        )
        expect(
            rollingLog.starts(with: snapshot),
            "nominal LAN completion preserves the delivered prefix in the rolling log"
        )

        gate.reset()
        expect(
            gate.claim() != nil,
            "a fresh export session receives a new one-shot claim"
        )
        expect(
            rollingLog.starts(with: snapshot),
            "the fresh export can serve the same preserved prefix again"
        )
    }

    private static func largeBodyIsChunkedExactly() {
        let size = 3 * 1024 * 1024 + 123
        let ranges = VXDiagExportPolicy.chunkRanges(bodyBytes: size)
        expect(ranges.count > 1, "a multi-megabyte diagnostic body is never one giant send")
        expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == size,
               "chunk ranges cover the complete response body")
        expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound },
               "chunk ranges are contiguous with no gaps or overlap")
        expect(ranges.allSatisfy { $0.count <= VXDiagExportPolicy.responseChunkBytes },
               "every network send stays under the fixed chunk bound")
        expect(ranges.reduce(0) { $0 + $1.count } == size,
               "chunk byte counts sum to Content-Length exactly")
        expect(VXDiagExportPolicy.chunkRanges(bodyBytes: 0).isEmpty,
               "an empty body does not invent a send range")
    }

    private static func successfulSnapshotPreservesAppendedLines() {
        let snapshot = Data("old line\n".utf8)
        let current = Data("old line\nnew during transfer\n".utf8)
        expect(
            VXDiagExportPolicy.remainingLogAfterSuccessfulSnapshot(
                snapshot: snapshot, current: current
            ) == Data("new during transfer\n".utf8),
            "Finder export consumes only the delivered prefix and preserves later lines"
        )
        expect(
            VXDiagExportPolicy.remainingLogAfterSuccessfulSnapshot(
                snapshot: Data(), current: current
            ) == current,
            "an empty snapshot never clears later log bytes"
        )
    }

    private static func changedPrefixFailsClosed() {
        expect(
            VXDiagExportPolicy.remainingLogAfterSuccessfulSnapshot(
                snapshot: Data("old line\n".utf8),
                current: Data("trimmed front\nnew line\n".utf8)
            ) == nil,
            "a trimmed or replaced log prefix is preserved instead of guessed"
        )
    }
}
