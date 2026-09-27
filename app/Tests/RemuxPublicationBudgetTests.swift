// Compile with VortXRemuxBuffer.swift and VortXRemuxProducerLeadPolicy.swift.
// Exercises the real floor, producer gate budget, physical admission and HLS resource deadlines.
import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}
enum DiagnosticsLog { static func log(_ tag: String, _ message: String) {} }

@main enum RemuxPublicationBudgetTests {
    static let unit = 8 * 1024 * 1024
    static func key(_ id: Int) -> VortXHLSSessionSpool.ResourceKey { .video(segmentID: id) }
    static func resource(_ id: Int) -> VortXHLSSessionSpool.SpillResource {
        .init(key: key(id), data: Data([UInt8(id % 256)]), durationMilliseconds: 1_250)
    }

    static func main() {
        // Field shape: 44 history segments + 20 ahead segments used to publish 512 MiB
        // even though the capacity proof reserved only 352 MiB per generation.
        let window = VortXHLSWindow(segments: (0..<80).map {
            VortXHLSSegment(id: $0, byteOffset: $0 * unit, byteLength: unit,
                start: Double($0) * 1.25, duration: 1.25)
        })
        let floor = VortXHLSConsumptionWindowPolicy.floor(frontier: 59, window: window)
        let published = window.segments.filter { $0.id >= floor }
        let budget = VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes
        precondition(published.reduce(0) { $0 + $1.byteLength } <= budget,
                     "behind + ahead must fit one publication share, not two")
        precondition(published.filter { $0.id > 59 }.count == 20, "unseen segments must not be evicted")

        // Charge the operational allowance as physical auxiliary bytes, leaving H as free headroom.
        // The old 64-unit publication blocks at step 33, 41.25s before its first legal expiry.
        let legacy = replay(windowCount: 64, steps: 200)
        precondition(legacy.blockedAt == 33 && legacy.firstDeadline == 82.5)
        // Run the largest complete-segment generation allowed by BOTH partitioned production policies.
        let behindCount = published.filter { $0.id <= 59 }.count
        let aheadCount = VortXRemuxProducerLeadPolicy.maximumAheadBytes / unit
        let repaired = replay(windowCount: behindCount + aheadCount, steps: 200)
        precondition(repaired.blockedAt == nil, "normal rolling publication must not starve at physical cap")
        precondition(repaired.peak <= 128)
        print("PASS real spool replay: legacy blocked at step 33; partitioned window advanced 200 steps with every URI retained through its deadline (peak \(repaired.peak)/128)")
        replayVariableSegments()
    }

    static func replay(windowCount: Int, steps: Int) -> (blockedAt: Int?, firstDeadline: Double?, peak: Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vortx-budget-\(UUID())")
        guard let spool = VortXHLSSessionSpool(parentDirectory: root, capacityBytes: 128) else {
            preconditionFailure("scratch spool unavailable")
        }
        defer { spool.invalidateSession(); try? FileManager.default.removeItem(at: root) }
        precondition(spool.setAuxiliaryBytes(32)) // 256 MiB operational charge / 8 MiB
        for id in 0..<windowCount { precondition(spool.spill([resource(id)])) }
        precondition(spool.recordPlaylistGeneration(playlistID: "video",
            resourceKeys: (0..<windowCount).map(key), now: 0) != nil)
        var deadlines: [Int: Double] = [:]
        var peak = spool.accounting.physicalBytes
        var firstDeadline: Double?
        for first in 1...steps {
            let now = Double(first) * 1.25
            // No reclamation can run ahead of a distributed playlist's promised lifetime.
            for (id, deadline) in deadlines where now < deadline { precondition(spool.contains(key(id))) }
            spool.collectExpired(now: now)
            guard spool.spillOutcome([resource(first + windowCount - 1)]) == .committed else {
                return (first, firstDeadline, peak)
            }
            precondition(spool.recordPlaylistGeneration(playlistID: "video",
                resourceKeys: (first..<first + windowCount).map(key), now: now) != nil)
            let removed = first - 1
            guard let deadline = spool.retentionDeadline(for: key(removed)) else {
                preconditionFailure("removed resource has no HLS retention receipt")
            }
            precondition(abs(deadline - (now + 1.25 + Double(windowCount) * 1.25)) < 0.001)
            deadlines[removed] = deadline
            firstDeadline = firstDeadline ?? deadline
            peak = max(peak, spool.accounting.physicalBytes)
        }
        return (nil, firstDeadline, peak)
    }

    static func replayVariableSegments() {
        // Non-divisible 7...65 MiB cohorts, including the 6s / ~86 Mb/s shape from the lead-policy tests.
        // Drive the actual producer ledger/gate AFTER each close, so overshoot is charged, not rounded off.
        let mib = 1024 * 1024
        let sizes = [8, 9, 21, 65, 10, 18, 7]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vortx-variable-budget-\(UUID())")
        guard let spool = VortXHLSSessionSpool(parentDirectory: root, capacityBytes: 1024) else {
            preconditionFailure("scratch spool unavailable")
        }
        defer { spool.invalidateSession(); try? FileManager.default.removeItem(at: root) }
        precondition(spool.setAuxiliaryBytes(256))
        var ledger = VortXRemuxProducerLeadLedger()
        var segments: [VortXHLSSegment] = []
        var paused = false
        var peak = 0
        var overshoot = 0
        var previousKeys: Set<Int> = []
        var deadlines: [Int: Double] = [:]
        for frontier in 0..<300 {
            let now = Double(frontier) * 1.25
            for (id, deadline) in deadlines where now < deadline { precondition(spool.contains(key(id))) }
            spool.collectExpired(now: now)
            ledger.recordPlayback(now)
            paused = VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                leadSeconds: (ledger.producedEnd ?? now) - now,
                aheadBytes: ledger.outstandingBytes, currentlyPaused: paused)
            while !paused {
                let id = segments.count
                let size = sizes[id % sizes.count]
                let segment = VortXHLSSegment(id: id, byteOffset: id * 100 * mib,
                    byteLength: size * mib, start: Double(id) * 1.25, duration: 1.25)
                precondition(spool.spillOutcome([.init(key: key(id), data: Data(repeating: 1, count: size),
                    durationMilliseconds: 1_250)]) == .committed,
                    "ordinary variable-size close must fit: frontier=\(frontier) next=\(id) size=\(size) physical=\(spool.accounting.physicalBytes) aheadMiB=\(ledger.outstandingBytes / mib)")
                segments.append(segment)
                ledger.recordProduced(.init(id: id, end: segment.end, byteLength: segment.byteLength))
                paused = VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                    leadSeconds: segment.end - now, aheadBytes: ledger.outstandingBytes, currentlyPaused: paused)
                overshoot = max(overshoot, ledger.outstandingBytes - VortXRemuxProducerLeadPolicy.maximumAheadBytes)
                peak = max(peak, spool.accounting.physicalBytes)
            }
            precondition(segments.last!.end > now, "playing consumer must not run out of published media")
            let floor = VortXHLSConsumptionWindowPolicy.floor(frontier: frontier,
                window: VortXHLSWindow(segments: segments))
            let keys = Set(segments.filter { $0.id >= floor }.map(\.id))
            precondition(segments.filter { keys.contains($0.id) }.reduce(0) { $0 + $1.byteLength }
                <= VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes,
                "tested closed-cohort envelope must fit one publication share")
            precondition(spool.recordPlaylistGeneration(playlistID: "video", resourceKeys: keys.sorted().map(key), now: now) != nil)
            for id in previousKeys.subtracting(keys) {
                guard let deadline = spool.retentionDeadline(for: key(id)) else { preconditionFailure("missing lifetime") }
                deadlines[id] = deadline
            }
            previousKeys = keys
        }
        precondition(overshoot > 0, "fixture must exercise post-close byte-cap overshoot")
        precondition(overshoot <= VortXHLSConsumptionWindowPolicy.closedBoundaryAllowanceBytes,
                     "tested post-close overshoot must fit its explicit allowance")
        print("PASS production gate with variable cohorts: 300 playback steps, overshoot \(overshoot / mib) MiB, peak \(peak)/1024, no early URI eviction")
    }
}
