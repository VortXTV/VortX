import Foundation
import Darwin
import Libmpv
import os

// Compile with the literal production v2 transport declarations and actual Timing and
// Argument declarations. This finite node fixture does not emulate a core, network or renderer.
private indirect enum NodeSpec {
    case integer(Int64), number(Double), flag(Bool), array([NodeSpec]), map([(String, NodeSpec)])
}
private final class NodeArena {
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var lists: [UnsafeMutablePointer<mpv_node_list>] = []
    private var values: [(UnsafeMutablePointer<mpv_node>, Int)] = []
    private var keys: [(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, Int)] = []
    func node(_ spec: NodeSpec) -> mpv_node {
        var node = mpv_node()
        switch spec {
        case .integer(let value): node.format = MPV_FORMAT_INT64; node.u.int64 = value
        case .number(let value): node.format = MPV_FORMAT_DOUBLE; node.u.double_ = value
        case .flag(let value): node.format = MPV_FORMAT_FLAG; node.u.flag = value ? 1 : 0
        case .array(let rows): node.format = MPV_FORMAT_NODE_ARRAY; node.u.list = list(rows, names: nil)
        case .map(let rows): node.format = MPV_FORMAT_NODE_MAP; node.u.list = list(rows.map(\.1), names: rows.map(\.0))
        }
        return node
    }
    private func list(_ rows: [NodeSpec], names: [String]?) -> UnsafeMutablePointer<mpv_node_list> {
        let buffer = UnsafeMutablePointer<mpv_node>.allocate(capacity: rows.count)
        for (index, row) in rows.enumerated() { buffer.advanced(by: index).initialize(to: node(row)) }
        values.append((buffer, rows.count))
        var keyBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        if let names {
            let allocated = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: names.count)
            for (index, name) in names.enumerated() {
                let value = strdup(name)!
                strings.append(value); allocated.advanced(by: index).initialize(to: value)
            }
            keys.append((allocated, names.count)); keyBuffer = allocated
        }
        let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
        list.initialize(to: .init(num: Int32(rows.count), values: buffer, keys: keyBuffer))
        lists.append(list); return list
    }
    deinit {
        for value in strings { free(value) }
        for (pointer, count) in keys { pointer.deinitialize(count: count); pointer.deallocate() }
        for (pointer, count) in values { pointer.deinitialize(count: count); pointer.deallocate() }
        for pointer in lists { pointer.deinitialize(count: 1); pointer.deallocate() }
    }
}

@main private enum MPVRemoteReferenceTransportTestsV2 {
    private static let capture = MPVRemoteReferenceTransport.Capture(
        intent: 8, entry: 41, sid: 12, referenceCommandIndex: 17, stream: 37,
        primarySID: 77, primaryExternal: true, primaryVisible: false, origin: 100
    )
    private static func fields(_ capture: MPVRemoteReferenceTransport.Capture = capture) -> [(String, NodeSpec)] {
        let starts: [Int64] = [1_000, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000]
        return [
            ("version", .integer(2)), ("intent-generation", .integer(capture.intent)),
            ("entry-id", .integer(capture.entry)), ("reference-sid", .integer(capture.sid)),
            ("reference-command-index", .integer(capture.referenceCommandIndex)),
            ("reference-stream-index", .integer(capture.stream)), ("demux-origin", .number(capture.origin)),
            ("primary-sid", .integer(capture.primarySID)), ("primary-external", .flag(capture.primaryExternal)),
            ("primary-visible", .flag(capture.primaryVisible)), ("grant", .integer(11)),
            ("source-generation", .integer(7)), ("response-generation", .integer(9)),
            ("source-epoch", .integer(10)), ("demux-epoch", .integer(12)), ("origin", .number(100)),
            ("prefix-start-ms", .integer(0)), ("prefix-end-ms", .integer(1_080_000)),
            ("cues", .array(starts.map { .array([.integer($0), .integer($0 + 300_000)]) }))
        ]
    }
    private static func decode(_ fields: [(String, NodeSpec)], _ operation: MPVRemoteReferenceTransport.Operation? = nil)
        -> MPVRemoteReferenceTransport.Reply {
        let arena = NodeArena()
        return MPVRemoteReferenceTransport.decode(arena.node(.map(fields)), operation: operation ?? .read(capture))
    }
    private static func refused(_ fields: [(String, NodeSpec)], _ operation: MPVRemoteReferenceTransport.Operation? = nil) {
        guard case .unconfirmed = decode(fields, operation) else { preconditionFailure("Malformed v2 receipt was accepted") }
    }
    private static func run() async {
        guard case .read(let original) = decode(fields()) else { preconditionFailure("Valid v2 receipt refused") }
        precondition(original.grant == 11 && original.cues.count == 8)
        precondition(original.cues[0].startMs == original.cues[1].startMs)
        precondition(original.cues[0].endMs - original.cues[0].startMs == 300_000)
        precondition(original.capture == capture && original.response == 9 && original.demuxEpoch == 12)
        precondition(original.capture.referenceSID == 12 && original.capture.referenceCommandIndex == 17
                     && original.capture.referenceStreamIndex == 37)
        precondition(original.capture.primarySID == 77 && original.capture.primaryExternal && !original.capture.primaryVisible)

        // Off and hidden-primary are valid v2 states; the reference identity remains independent.
        let off = MPVRemoteReferenceTransport.Capture(
            intent: 8, entry: 41, sid: 12, referenceCommandIndex: 17, stream: 37,
            primarySID: 0, primaryExternal: false, primaryVisible: false, origin: 100
        )
        guard case .read(let offReceipt) = decode(fields(off), .read(off)) else { preconditionFailure("Off reference refused") }
        precondition(offReceipt.capture.primarySID == 0 && !offReceipt.capture.primaryExternal)

        for count in [1, 7] {
            var shortPrefix = fields()
            shortPrefix[18].1 = .array((0..<count).map { .array([.integer(Int64($0)), .integer(Int64($0 + 1))]) })
            guard case .read(let retained) = decode(shortPrefix) else { preconditionFailure("Valid short-prefix grant lost") }
            precondition(retained.grant == original.grant && retained.cues.count == count)
        }
        for name in ["version", "grant", "entry-id", "reference-sid", "source-generation", "source-epoch", "demux-epoch"] {
            var changed = fields(); let index = changed.firstIndex { $0.0 == name }!
            changed[index].1 = .integer(0); refused(changed)
        }
        var changed = fields(); changed[1].1 = .integer(9); refused(changed) // Original intent ABA fence.
        changed = fields(); changed[6].1 = .number(.nan); refused(changed) // Demux origin must be finite.
        changed = fields(); changed[8].1 = .integer(1); refused(changed) // Exact FLAG, no numeric coercion.
        changed = fields(); changed[9].1 = .integer(1); refused(changed)
        changed = fields(); changed[7].1 = .integer(0); changed[8].1 = .flag(true); refused(changed) // Off cannot be external.
        changed = fields(); changed[16].1 = .integer(1); refused(changed) // Missing original prefix.
        changed = fields(); changed[17].1 = .integer(1_079_999); refused(changed)
        changed = fields(); changed[18].1 = .array([]); refused(changed)
        changed = fields(); changed[18].1 = .array((0..<8).map { .array([.integer(Int64(8 - $0)), .integer(50)]) }); refused(changed)
        changed = fields(); changed[18].1 = .array((0..<8).map { .array([.integer(Int64($0)), .integer(1_080_001)]) }); refused(changed)
        changed = fields(); changed[2].0 = "version"; refused(changed) // Duplicate key fails closed.
        changed = fields(); changed[3].0 = "sid"; refused(changed) // v1 field names fail closed.
        changed = fields(); changed.append(("unexpected", .integer(1))); refused(changed)

        let ready: [(String, NodeSpec)] = [("version", .integer(2)), ("grant", .integer(11)), ("ticket", .integer(19))]
        guard case .prepared(let grant, let ticket) = decode(ready, .prepare(original)) else { preconditionFailure("Prepare receipt refused") }
        precondition(grant == 11 && ticket == 19)
        var wrong = ready; wrong[0].1 = .integer(1); refused(wrong, .prepare(original))
        wrong = ready; wrong[1].1 = .integer(12); refused(wrong, .prepare(original))
        let committed = ready + [("committed", .flag(true))]
        guard case .committed = decode(committed, .commit(original, ticket: 19)) else { preconditionFailure("Commit receipt refused") }
        refused(committed, .commit(original, ticket: 20))

        let events = OSAllocatedUnfairLock(initialState: [Int]())
        let cancel = MPVRemoteReferenceCancellation()
        cancel.install(1) { events.withLock { $0.append(1) }; cancel.clear(1) }
        cancel.install(2) { events.withLock { $0.append(2) } }
        cancel.clear(2); cancel.cancel(); cancel.cancel()
        precondition(cancel.isCancelled && events.withLock { $0 } == [1])
        cancel.install(3) { events.withLock { $0.append(3) } }
        precondition(events.withLock { $0 } == [1, 3])
        let a1 = MPVRemoteReferenceCancellation(), a2 = MPVRemoteReferenceCancellation(), a3 = MPVRemoteReferenceCancellation()
        a2.setPredecessor(a1); a3.setPredecessor(a2); a2.cancel(); a3.complete(); a3.complete(); a2.complete(); a1.complete()
        await a3.waitForCompletion(); await a2.waitForCompletion(); await a1.waitForCompletion()
        print("PASS v2 remote identity separation, strict maps, Off/external visibility and cancellation; controlled nodes only")
    }
    static func main() async { await Task.detached(priority: .utility) { await run() }.value }
}
