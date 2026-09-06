import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}
enum DiagnosticsLog { static func log(_ tag: String, _ message: String) {} }

@main
enum VortXRemuxSeekReceiptTests {
    static func main() {
        var anchor = VortXHLSSeekAnchorState()
        let outgoingEpoch = anchor.playbackReceiptEpoch
        precondition(anchor.reportPlaybackPosition(400, receiptEpoch: outgoingEpoch))
        anchor.registerSeek(requestID: 1)
        precondition(!anchor.reportPlaybackPosition(401, receiptEpoch: outgoingEpoch))
        precondition(anchor.admitSeek(requestID: 1, playerSeconds: 100, targetIsPublished: true))
        let pendingEpoch = anchor.playbackReceiptEpoch
        precondition(!anchor.reportPlaybackPosition(402, receiptEpoch: pendingEpoch))
        anchor.completeSeek(requestID: 1, playerSeconds: 100)
        precondition(!anchor.reportPlaybackPosition(402, receiptEpoch: outgoingEpoch))
        precondition(!anchor.reportPlaybackPosition(402, receiptEpoch: pendingEpoch))
        precondition(anchor.reportPlaybackPosition(100.25, receiptEpoch: anchor.playbackReceiptEpoch))
        print("PASS old and pending observer receipts cannot cross a completed backward seek")

        let retained = (0..<260).map {
            VortXRemuxProducerLeadLedger.Segment(id: $0, end: Double($0 + 1) * 2, byteLength: 100)
        }
        var ledger = VortXRemuxProducerLeadLedger()
        for segment in retained { ledger.recordProduced(segment) }
        ledger.recordPlayback(400) // compacts consumed entries, including the future backward target
        precondition(ledger.outstandingBytes == 6_000)
        ledger.recordPlayback(100) // ordinary stale ticks remain rejected
        precondition(ledger.playbackSeconds == 400)
        ledger.reanchor(to: 100, retainedSegments: retained)
        precondition(ledger.playbackSeconds == 100 && ledger.outstandingBytes == 21_000)
        precondition(ledger.outstandingSegmentCount == 210 && ledger.producedEnd == 520)
        ledger.recordProduced(retained.last!) // snapshot already included this delayed boundary callback
        precondition(ledger.outstandingBytes == 21_000)
        ledger.recordProduced(.init(id: 260, end: 522, byteLength: 100))
        precondition(ledger.outstandingBytes == 21_100 && ledger.producedEnd == 522)
        ledger.recordPlayback(102)
        precondition(ledger.outstandingBytes == 21_000)
        print("PASS backward seek rebuilds compacted byte accounting without losing or duplicating the tail")

        ledger.recordPlayback(600)
        ledger.recordProduced(.init(id: 261, end: 524, byteLength: 100))
        ledger.recordProduced(.init(id: 262, end: 602, byteLength: 100))
        precondition(ledger.outstandingBytes == 100 && ledger.outstandingSegmentCount == 1)
        print("PASS delayed already-consumed boundaries do not subtract unreserved bytes")

        anchor.registerSeek(requestID: 2)
        let cancelledEpoch = anchor.playbackReceiptEpoch
        anchor.cancelSeek(requestID: 2)
        precondition(!anchor.reportPlaybackPosition(403, receiptEpoch: cancelledEpoch))
        precondition(anchor.reportPlaybackPosition(101, receiptEpoch: anchor.playbackReceiptEpoch))
        anchor.registerSeek(requestID: 3)
        anchor.registerSeek(requestID: 4)
        let latestEpoch = anchor.playbackReceiptEpoch
        anchor.cancelSeek(requestID: 3)
        precondition(anchor.playbackReceiptEpoch == latestEpoch && anchor.pendingAdmissionRequestID == 4)
        print("PASS cancellation retires receipts without clearing a superseding seek")
    }
}
