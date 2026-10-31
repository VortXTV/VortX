import Foundation
import Darwin
import Libmpv
import os

/// One original request's cancellation. Native work is only enqueued after this lock is released.
/// Each callback names its original async identifier/context; an old cancellation cannot abort A2.
final class MPVRemoteReferenceCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var pending: [UInt64: @Sendable () -> Void] = [:]
        var completed = false
        var completionRequested = false
        var predecessor: MPVRemoteReferenceCancellation?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Called once before the original request is dispatched or can finish.
    func setPredecessor(_ predecessor: MPVRemoteReferenceCancellation?) {
        state.withLock { state in
            precondition(!state.completionRequested && state.predecessor == nil)
            state.predecessor = predecessor
        }
    }

    func install(_ identifier: UInt64, abort: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { state -> Bool in
            guard !state.cancelled else { return true }
            precondition(state.pending[identifier] == nil)
            state.pending[identifier] = abort
            return false
        }
        if cancelled { abort() }
    }
    func clear(_ identifier: UInt64) {
        let removed = state.withLock { $0.pending.removeValue(forKey: identifier) }
        withExtendedLifetime(removed) {}
    }
    func cancel() {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            state.cancelled = true
            let callbacks = Array(state.pending.values)
            state.pending.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }
    /// A successor waits for the original effect's terminal release, never merely its cancel bit.
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let completed = state.withLock { state -> Bool in
                guard !state.completed else { return true }
                state.waiters.append(continuation); return false
            }
            if completed { continuation.resume() }
        }
    }
    func complete() {
        let admitted = state.withLock { state -> (Bool, MPVRemoteReferenceCancellation?) in
            guard !state.completionRequested else { return (false, nil) }
            state.completionRequested = true
            return (true, state.predecessor)
        }
        guard admitted.0 else { return }
        Task { [self] in
            if let predecessor = admitted.1 { await predecessor.waitForCompletion() }
            completeAfterPredecessor()
        }
    }
    private func completeAfterPredecessor() {
        let completed = state.withLock { state -> ([CheckedContinuation<Void, Never>], MPVRemoteReferenceCancellation?) in
            precondition(state.completionRequested && !state.completed)
            state.completed = true
            let waiters = state.waiters; state.waiters.removeAll()
            let predecessor = state.predecessor; state.predecessor = nil
            return (waiters, predecessor)
        }
        withExtendedLifetime(completed.1) { for waiter in completed.0 { waiter.resume() } }
    }
}

/// Typed scalar-only transport for the matched native reference reader. Unsupported old SDKs
/// return unavailable. No remote resource, headers, options, descriptor or pointer enters Swift.
enum MPVRemoteReferenceTransport {
    /// The v2 wire keeps the reference and visible-primary identities separate.
    /// sid/stream remain the existing caller-facing aliases for the reference
    /// SID and the actual MPV stream index. Outgoing command flags are packed
    /// because native commands are capped at MP_CMD_DEF_MAX_ARGS == 11:
    /// bit 0 = external primary, bit 1 = visible primary.
    struct Capture: Sendable, Equatable {
        let intent: Int64
        let entry: Int64
        let sid: Int64
        let referenceCommandIndex: Int64
        let stream: Int64
        let primarySID: Int64
        let primaryExternal: Bool
        let primaryVisible: Bool
        let origin: Double

        var referenceSID: Int64 { sid }
        var referenceStreamIndex: Int64 { stream }

        var arguments: [MPVOwnedSubtitleTransport.Argument] {
            [.integer(intent), .integer(entry), .integer(sid),
             .integer(referenceCommandIndex), .integer(stream), .integer(primarySID),
             .integer(Capture.packedPrimaryFlags(external: primaryExternal, visible: primaryVisible)),
             .number(origin)]
        }

        fileprivate static func packedPrimaryFlags(external: Bool, visible: Bool) -> Int64 {
            (external ? 1 : 0) | (visible ? 2 : 0)
        }
    }

    struct Receipt: Sendable, Equatable {
        let capture: Capture
        let grant: Int64
        let source: Int64
        let response: Int64
        let sourceEpoch: Int64
        let demuxEpoch: Int64
        let origin: Double
        let cues: [SubtitleReferenceNativeQuery.Timing]

        var prepareArguments: [MPVOwnedSubtitleTransport.Argument] {
            [.integer(grant), .integer(capture.intent), .integer(capture.entry),
             .integer(source), .integer(capture.sid),
             .integer(capture.referenceCommandIndex), .integer(capture.stream),
             .integer(capture.primarySID),
             .integer(Capture.packedPrimaryFlags(external: capture.primaryExternal, visible: capture.primaryVisible)),
             .number(capture.origin)]
        }
    }

    enum Operation: Sendable {
        case read(Capture)
        case prepare(Receipt)
        case commit(Receipt, ticket: Int64)
    }

    enum Reply: Sendable {
        case read(Receipt)
        case prepared(grant: Int64, ticket: Int64)
        case committed(grant: Int64, ticket: Int64)
        case rejected, unconfirmed, terminated
    }

    private enum Value {
        case integer(Int64), number(Double), flag(Bool), cues([SubtitleReferenceNativeQuery.Timing])
    }

    private static let commonKeys: Set<String> = [
        "version", "intent-generation", "entry-id", "reference-sid",
        "reference-command-index", "reference-stream-index", "demux-origin",
        "primary-sid", "primary-external", "primary-visible"
    ]
    private static let activeKeys: Set<String> =
        commonKeys.union(["grant", "ticket", "source-generation"])
    private static let readKeys: Set<String> =
        commonKeys.union([
            "grant", "source-generation", "response-generation",
            "source-epoch", "demux-epoch", "origin",
            "prefix-start-ms", "prefix-end-ms", "cues"
        ])

    static func capability(_ handle: OpaquePointer, expectedEntry: Int64) -> Capture? {
        var node = mpv_node()
        guard mpv_get_property(handle, "vortx-subtitle-reference-capability", MPV_FORMAT_NODE, &node) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        guard let fields = exactFields(node, names: commonKeys),
              integer(fields["version"]) == 2,
              let capture = capture(fields),
              capture.entry == expectedEntry else { return nil }
        return capture
    }

    static func active(_ handle: OpaquePointer, grant: Int64, ticket: Int64) -> Bool {
        var node = mpv_node()
        guard mpv_get_property(handle, "vortx-subtitle-reference-active", MPV_FORMAT_NODE, &node) >= 0 else {
            return false
        }
        defer { mpv_free_node_contents(&node) }
        guard let fields = exactFields(node, names: activeKeys),
              integer(fields["version"]) == 2,
              integer(fields["grant"]) == grant,
              integer(fields["ticket"]) == ticket,
              positive(fields["source-generation"]) != nil,
              capture(fields) != nil else { return false }
        return true
    }

    static func begin(_ handle: OpaquePointer, identifier: UInt64,
                      operation: Operation, payload: String?) -> Int32 {
        switch operation {
        case .read(let capture):
            return command("vortx-subtitle-reference-read", capture.arguments) {
                mpv_command_node_async(handle, identifier, $0)
            }
        case .prepare(let receipt):
            guard let payload else { return -1 }
            return command("vortx-subtitle-reference-prepare",
                           receipt.prepareArguments + [.string(payload)]) {
                mpv_command_node_async(handle, identifier, $0)
            }
        case .commit(let receipt, let ticket):
            guard ticket > 0 else { return -1 }
            return command("vortx-subtitle-reference-commit",
                           [.integer(ticket)] + receipt.prepareArguments) {
                mpv_command_node_async(handle, identifier, $0)
            }
        }
    }

    static func decode(_ node: mpv_node, operation: Operation) -> Reply {
        switch operation {
        case .read(let expected):
            guard let fields = exactFields(node, names: readKeys),
                  integer(fields["version"]) == 2,
                  capture(fields) == expected,
                  let grant = positive(fields["grant"]),
                  let source = positive(fields["source-generation"]),
                  let response = positive(fields["response-generation"]),
                  let sourceEpoch = positive(fields["source-epoch"]),
                  let demuxEpoch = positive(fields["demux-epoch"]),
                  case .some(.number(let origin)) = fields["origin"],
                  origin.isFinite, abs(origin) <= 86_400,
                  integer(fields["prefix-start-ms"]) == 0,
                  integer(fields["prefix-end-ms"]) == Int64(SubtitleReferenceNativeQuery.referenceWindowEndMs),
                  case .some(.cues(let cues)) = fields["cues"] else { return .unconfirmed }
            return .read(.init(capture: expected, grant: grant, source: source,
                response: response, sourceEpoch: sourceEpoch, demuxEpoch: demuxEpoch,
                origin: origin, cues: cues))

        case .prepare(let receipt):
            guard let fields = exactFields(node, names: ["version", "grant", "ticket"]),
                  integer(fields["version"]) == 2,
                  integer(fields["grant"]) == receipt.grant,
                  let ticket = positive(fields["ticket"]) else { return .unconfirmed }
            return .prepared(grant: receipt.grant, ticket: ticket)

        case .commit(let receipt, let ticket):
            guard let fields = exactFields(node, names: ["version", "grant", "ticket", "committed"]),
                  integer(fields["version"]) == 2,
                  integer(fields["grant"]) == receipt.grant,
                  integer(fields["ticket"]) == ticket,
                  case .some(.flag(true)) = fields["committed"] else { return .unconfirmed }
            return .committed(grant: receipt.grant, ticket: ticket)
        }
    }

    static func revoke(_ handle: OpaquePointer, grant: Int64) -> Bool {
        guard grant > 0 else { return false }
        var result = mpv_node()
        defer { mpv_free_node_contents(&result) }
        // Exact cleanup requires no fallible strdup before native dispatch, matching the local path.
        let status = "vortx-subtitle-reference-revoke".withCString { name in
            withUnsafeTemporaryAllocation(of: mpv_node.self, capacity: 2) { nodes in
                nodes.initialize(repeating: mpv_node())
                defer { nodes.deinitialize() }
                nodes[0].format = MPV_FORMAT_STRING
                nodes[0].u.string = UnsafeMutablePointer(mutating: name)
                nodes[1].format = MPV_FORMAT_INT64; nodes[1].u.int64 = grant
                var list = mpv_node_list(num: 2, values: nodes.baseAddress!, keys: nil)
                return withUnsafeMutablePointer(to: &list) { list in
                    var command = mpv_node(); command.format = MPV_FORMAT_NODE_ARRAY; command.u.list = list
                    return mpv_command_node(handle, &command, &result)
                }
            }
        }
        guard status >= 0,
              let fields = exactFields(result, names: ["version", "released"]),
              integer(fields["version"]) == 2,
              case .some(.flag(_)) = fields["released"] else { return false }
        return true // Both exact removal and exact absence certify this grant cannot publish again.
    }

    static func payload(_ file: SubtitleReferenceNativeQuery.RetimedFile, language: String) -> String? {
        struct Cue: Encodable { let startMs: UInt64; let endMs: UInt64; let text: String }
        struct Payload: Encodable { let version = 1; let language: String; let cues: [Cue] }
        guard language.utf8.count <= 255, !language.contains("\0") else { return nil }
        let body = Payload(language: language, cues: file.cues.map {
            Cue(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        })
        guard let data = try? JSONEncoder().encode(body), data.count <= 9 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func capture(_ fields: [String: Value]) -> Capture? {
        guard let intent = positive(fields["intent-generation"]),
              let entry = positive(fields["entry-id"]),
              let sid = integer(fields["reference-sid"]),
              (1...Int64(Int32.max)).contains(sid),
              let referenceCommandIndex = integer(fields["reference-command-index"]),
              (0..<128).contains(referenceCommandIndex),
              let stream = integer(fields["reference-stream-index"]),
              (0..<1024).contains(stream),
              let primarySID = integer(fields["primary-sid"]),
              (0...Int64(Int32.max)).contains(primarySID),
              case .some(.flag(let primaryExternal)) = fields["primary-external"],
              case .some(.flag(let primaryVisible)) = fields["primary-visible"],
              primarySID != 0 || !primaryExternal,
              case .some(.number(let origin)) = fields["demux-origin"],
              origin.isFinite, abs(origin) <= 86_400 else { return nil }
        return .init(intent: intent, entry: entry, sid: sid,
                     referenceCommandIndex: referenceCommandIndex, stream: stream,
                     primarySID: primarySID, primaryExternal: primaryExternal,
                     primaryVisible: primaryVisible, origin: origin)
    }

    private static func integer(_ value: Value?) -> Int64? {
        guard case .some(.integer(let value)) = value else { return nil }
        return value
    }

    private static func positive(_ value: Value?) -> Int64? {
        guard let value = integer(value), value > 0 else { return nil }
        return value
    }

    private static func fields(_ node: mpv_node, count: Int) -> [String: Value]? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list,
              Int(list.pointee.num) == count, let keys = list.pointee.keys,
              let values = list.pointee.values else { return nil }
        var result: [String: Value] = [:]
        for index in 0..<count {
            guard let key = keys[index] else { return nil }
            let name = String(cString: key)
            guard result[name] == nil else { return nil }
            let value = values[index]
            switch value.format {
            case MPV_FORMAT_INT64:
                result[name] = .integer(value.u.int64)
            case MPV_FORMAT_DOUBLE:
                result[name] = .number(value.u.double_)
            case MPV_FORMAT_FLAG:
                guard value.u.flag == 0 || value.u.flag == 1 else { return nil }
                result[name] = .flag(value.u.flag == 1)
            case MPV_FORMAT_NODE_ARRAY:
                guard name == "cues",
                      let list = value.u.list,
                      (1...1024).contains(Int(list.pointee.num)),
                      let rows = list.pointee.values else { return nil }
                var cues: [SubtitleReferenceNativeQuery.Timing] = []
                var previous: UInt64?
                for row in 0..<Int(list.pointee.num) {
                    guard rows[row].format == MPV_FORMAT_NODE_ARRAY,
                          let pair = rows[row].u.list,
                          pair.pointee.num == 2,
                          let ends = pair.pointee.values,
                          ends[0].format == MPV_FORMAT_INT64,
                          ends[1].format == MPV_FORMAT_INT64,
                          ends[0].u.int64 >= 0,
                          ends[0].u.int64 < ends[1].u.int64,
                          ends[1].u.int64 <= Int64(SubtitleReferenceNativeQuery.referenceWindowEndMs) else {
                        return nil
                    }
                    let start = UInt64(ends[0].u.int64)
                    let end = UInt64(ends[1].u.int64)
                    guard previous.map({ start >= $0 }) ?? true else { return nil }
                    cues.append(.init(startMs: start, endMs: end))
                    previous = start
                }
                result[name] = .cues(cues)
            default:
                return nil
            }
        }
        return result
    }

    private static func exactFields(_ node: mpv_node, names: Set<String>) -> [String: Value]? {
        guard let fields = fields(node, count: names.count),
              Set(fields.keys) == names else { return nil }
        return fields
    }

    private static func command(_ name: String, _ arguments: [MPVOwnedSubtitleTransport.Argument],
                                _ invoke: (UnsafeMutablePointer<mpv_node>) -> Int32) -> Int32 {
        let arguments = [MPVOwnedSubtitleTransport.Argument.string(name)] + arguments
        let nodes = UnsafeMutablePointer<mpv_node>.allocate(capacity: arguments.count)
        nodes.initialize(repeating: mpv_node(), count: arguments.count)
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer {
            for string in strings { free(string) }
            nodes.deinitialize(count: arguments.count); nodes.deallocate()
        }
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case .integer(let value):
                nodes[index].format = MPV_FORMAT_INT64; nodes[index].u.int64 = value
            case .number(let value):
                nodes[index].format = MPV_FORMAT_DOUBLE; nodes[index].u.double_ = value
            case .string(let value):
                guard !value.contains("\0"), let owned = strdup(value) else { return -1 }
                strings.append(owned)
                nodes[index].format = MPV_FORMAT_STRING; nodes[index].u.string = owned
            }
        }
        var list = mpv_node_list(num: Int32(arguments.count), values: nodes, keys: nil)
        return withUnsafeMutablePointer(to: &list) { list in
            var command = mpv_node(); command.format = MPV_FORMAT_NODE_ARRAY; command.u.list = list
            return withUnsafeMutablePointer(to: &command, invoke)
        }
    }
}

/// The reference is an owned native timing receipt, never a relabelled LocalTimingSource.
/// This worker runs the same real pure native query and prepares every returned cue occurrence.
enum SubtitleRemoteReferencePreparation {
    struct Prepared: Sendable {
        let originalIdentity: SubtitleReferencePreparation.Identity
        let originalReference: MPVRemoteReferenceTransport.Receipt
        let file: SubtitleReferenceNativeQuery.RetimedFile
        let presentation: SubtitleReferencePresentation.Prepared
    }
    nonisolated static func prepare(identity: SubtitleReferencePreparation.Identity,
        reference: MPVRemoteReferenceTransport.Receipt, externalSRT: Data,
        cancellation: SubtitleEmbeddedExtractor.TimingWindowCancellation
    ) -> Prepared? {
        guard !Thread.isMainThread, !cancellation.isCancelled,
              identity.originalReferenceTrackID == reference.capture.sid,
              identity.originalReferenceStreamIndex == reference.capture.stream,
              let file = SubtitleReferenceNativeQuery.align(externalSRT: externalSRT,
                  reference: reference.cues, originalJob: identity.originalJob),
              !cancellation.isCancelled,
              let presentation = try? SubtitleReferencePresentation.prepare(file),
              !cancellation.isCancelled else { return nil }
        return .init(originalIdentity: identity, originalReference: reference, file: file, presentation: presentation)
    }
}
