import Foundation
import Darwin
import Libmpv

/// Owned scalar evidence only. Construct on the MPV serial queue while its existing
/// load transaction is held; never return a native node, pointer or descriptor.
/// This is capture evidence, not the final atomic source/track/owner admission.
struct MPVReferenceAlignmentCapture: Sendable, Equatable {
    struct LocalFile: Sendable, Equatable {
        let entryID: Int64
        let generation: Int64
        let identity: String

        func matches(_ file: SubtitleEmbeddedExtractor.TimingLocalFileIdentity) -> Bool {
            identity == "\(file.device):\(file.inode):\(file.byteCount):\(file.modificationSeconds):\(file.modificationNanoseconds):\(file.changeSeconds):\(file.changeNanoseconds)"
        }

        static func read(_ handle: OpaquePointer) -> Self? {
            var node = mpv_node()
            guard mpv_get_property(handle, "vortx-original-local-file", MPV_FORMAT_NODE, &node) >= 0 else {
                return nil // Old binary or unsupported source is unavailable, never an all-zero witness.
            }
            defer { mpv_free_node_contents(&node) }
            return decode(node)
        }

        static func decode(_ node: mpv_node) -> Self? {
            guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list,
                  list.pointee.num == 5, let keys = list.pointee.keys,
                  let values = list.pointee.values else { return nil }
            var integers: [String: Int64] = [:]
            var identity: String?
            var oscDisabled = false
            var seen = Set<String>()
            for index in 0..<5 {
                guard let key = keys[index] else { return nil }
                let name = String(cString: key)
                guard seen.insert(name).inserted else { return nil }
                let value = values[index]
                switch name {
                case "version", "entry-id", "source-generation":
                    guard value.format == MPV_FORMAT_INT64 else { return nil }
                    integers[name] = value.u.int64
                case "identity":
                    guard value.format == MPV_FORMAT_STRING, let text = value.u.string else { return nil }
                    identity = String(cString: text)
                case "osc-disabled":
                    // This versioned property explicitly certifies the compiled capability.
                    // No-Lua builds do not expose an `osc` option; absence is not a false flag.
                    guard value.format == MPV_FORMAT_FLAG, value.u.flag == 1 else { return nil }
                    oscDisabled = true
                default: return nil
                }
            }
            guard oscDisabled, integers["version"] == 1,
                  let entry = integers["entry-id"], entry > 0,
                  let generation = integers["source-generation"], generation > 0,
                  let identity, identity.utf8.count <= 256 else { return nil }
            let fields = identity.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 7, Int64(fields[0]) != nil, UInt64(fields[1]) != nil,
                  let size = Int64(fields[2]), size > 0, Int64(fields[3]) != nil,
                  let modificationNS = Int64(fields[4]), (0..<1_000_000_000).contains(modificationNS),
                  Int64(fields[5]) != nil,
                  let changeNS = Int64(fields[6]), (0..<1_000_000_000).contains(changeNS) else { return nil }
            return .init(entryID: entry, generation: generation, identity: identity)
        }
    }

    let localFile: LocalFile
    let input: String
    let trackID: Int
    let streamIndex: Int
    let timestampOrigin: Double

    /// MPV's builtin MKV ff-index is only an approximation. Positively require
    /// lavf and its actual AVStream.index; no language/title, picker ordinal,
    /// src-id or unknown-property fallback is an original stream mapping.
    static func read(_ handle: OpaquePointer, expectedEntryID: Int64) -> Self? {
        guard let source = LocalFile.read(handle), source.entryID == expectedEntryID,
              string("current-demuxer", handle) == "lavf",
              flag("input-terminal", handle) == false,
              flag("input-default-bindings", handle) == false,
              flag("input-vo-keyboard", handle) == false,
              flag("options/rebase-start-time", handle) == true,
              let input = string("stream-path", handle), input.utf8.count <= 4096,
              SubtitleEmbeddedExtractor.isLocalFileInput(input), !input.contains("\0"),
              let origin = double("demuxer-start-time", handle), abs(origin) <= 86_400,
              double("sub-delay", handle) == 0, double("sub-speed", handle) == 1,
              double("sub-fps", handle) == 0,
              let primary = integer("sid", handle), primary > 0,
              let count = integer("track-list/count", handle), (1...128).contains(count) else { return nil }
        var selected: (Int, Int)?
        for row in 0..<count {
            let prefix = "track-list/\(row)/"
            guard let type = string(prefix + "type", handle) else { return nil }
            guard type == "sub" else { continue } // MPV IDs are per type, not globally unique.
            guard let id = integer(prefix + "id", handle) else { return nil }
            guard id == primary else { continue }
            guard selected == nil,
                  flag(prefix + "external", handle) == false,
                  flag(prefix + "selected", handle) == true,
                  integer(prefix + "main-selection", handle) == 0,
                  let index = integer(prefix + "ff-index", handle), (0..<128).contains(index) else { return nil }
            // Codec admissibility is checked against this exact AVStream by the extractor.
            selected = (id, index)
        }
        guard let selected, integer("sid", handle) == primary,
              LocalFile.read(handle) == source else { return nil }
        return .init(localFile: source, input: input, trackID: selected.0,
                     streamIndex: selected.1, timestampOrigin: origin)
    }

    private static func string(_ name: String, _ handle: OpaquePointer) -> String? {
        guard let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    private static func integer(_ name: String, _ handle: OpaquePointer) -> Int? {
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return Int(exactly: value)
    }
    private static func double(_ name: String, _ handle: OpaquePointer) -> Double? {
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
        return value
    }
    private static func flag(_ name: String, _ handle: OpaquePointer) -> Bool? {
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0,
              value == 0 || value == 1 else { return nil }
        return value == 1
    }
}

/// Strict versioned node transport for the owned native subtitle renderer. Missing properties on an
/// older SDK mean unavailable. Native node pointers never escape a synchronous borrow.
enum MPVOwnedSubtitleTransport {
    struct Snapshot: Sendable, Equatable {
        let intent: Int64
        let entry: Int64
        let source: Int64
        let sid: Int64
        let stream: Int64
        let origin: Double
        let visible: Bool
        let activeTicket: Int64

        var arguments: [Argument] {
            [.integer(intent), .integer(entry), .integer(source), .integer(sid),
             .integer(stream), .number(origin)]
        }
    }
    enum Argument: Sendable { case integer(Int64), number(Double), string(String) }
    private enum Value { case integer(Int64), number(Double), flag(Bool) }

    static func snapshot(_ handle: OpaquePointer) -> Snapshot? {
        var node = mpv_node()
        guard mpv_get_property(handle, "vortx-owned-subtitle-state", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return decodeSnapshot(node)
    }

    static func decodeSnapshot(_ node: mpv_node) -> Snapshot? {
        guard let fields = fields(node, count: 9), integer(fields["version"]) == 1,
              let intent = integer(fields["intent-generation"]), intent > 0,
              let entry = integer(fields["entry-id"]), entry > 0,
              let source = integer(fields["source-generation"]), source > 0,
              let sid = integer(fields["sid"]), sid > 0,
              let stream = integer(fields["ff-index"]), (0..<128).contains(stream),
              case .some(.number(let origin)) = fields["origin"], origin.isFinite, abs(origin) <= 86_400,
              case .some(.flag(let visible)) = fields["primary-visible"], visible,
              let active = integer(fields["active-ticket"]), active >= 0 else { return nil }
        return .init(intent: intent, entry: entry, source: source, sid: sid, stream: stream,
                     origin: origin, visible: visible, activeTicket: active)
    }

    static func externalSRT(_ file: URL) -> Data? {
        guard file.isFileURL, !Thread.isMainThread else { return nil }
        let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = stat()
        let limit = 1024 * 1024
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0, status.st_size <= Int64(limit) else { return nil }
        var data = Data(count: limit + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < buffer.count {
                let amount = Darwin.read(descriptor, base.advanced(by: total), buffer.count - total)
                if amount < 0 { if errno == EINTR { continue }; return -1 }
                if amount == 0 { break }
                total += amount
            }
            return total
        }
        guard count > 0, count <= limit else { return nil }
        data.count = count
        return data
    }

    static func payload(_ prepared: SubtitleReferencePreparation.Prepared, language: String) -> String? {
        struct Cue: Encodable { let startMs: UInt64; let endMs: UInt64; let text: String }
        struct Payload: Encodable { let version = 1; let language: String; let cues: [Cue] }
        guard language.utf8.count <= 255, !language.contains("\0"),
              prepared.originalIdentity.originalJob == prepared.file.originalJob else { return nil }
        let body = Payload(language: language, cues: prepared.file.cues.map {
            Cue(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        })
        guard let data = try? JSONEncoder().encode(body), data.count <= 9 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum PreparationResult: Sendable { case ready(Int64), rejected, unconfirmed, terminated }

    static func beginPrepare(_ handle: OpaquePointer, identifier: UInt64,
                             snapshot: Snapshot, payload: String) -> Int32 {
        withCommand("vortx-subtitle-owned-prepare", snapshot.arguments + [.string(payload)]) {
            mpv_command_node_async(handle, identifier, $0)
        }
    }

    static func decodePreparationReply(_ node: mpv_node) -> PreparationResult {
        guard let result = fields(node, count: 2), integer(result["version"]) == 1,
              let ticket = integer(result["ticket"]), ticket > 0 else { return .unconfirmed }
        return .ready(ticket)
    }
    static func commit(_ handle: OpaquePointer, ticket: Int64, snapshot: Snapshot) -> Bool {
        var result = mpv_node()
        defer { mpv_free_node_contents(&result) }
        guard command(handle, "vortx-subtitle-owned-commit", [.integer(ticket)] + snapshot.arguments, &result) >= 0 else { return false }
        guard let result = fields(result, count: 3), integer(result["version"]) == 1,
              integer(result["ticket"]) == ticket, case .some(.flag(true)) = result["committed"] else { return false }
        return true
    }
    static func revoke(_ handle: OpaquePointer, ticket: Int64) -> Bool {
        guard ticket > 0 else { return false }
        var result = mpv_node()
        defer { mpv_free_node_contents(&result) }
        // Cleanup has no recoverable strdup failure before native dispatch. The two typed nodes
        // and borrowed static name cannot silently turn memory pressure into an unissued revoke.
        let status = "vortx-subtitle-owned-revoke".withCString { name in
            withUnsafeTemporaryAllocation(of: mpv_node.self, capacity: 2) { values in
                values.initialize(repeating: mpv_node())
                defer { values.deinitialize() }
                values[0].format = MPV_FORMAT_STRING
                values[0].u.string = UnsafeMutablePointer(mutating: name)
                values[1].format = MPV_FORMAT_INT64
                values[1].u.int64 = ticket
                var list = mpv_node_list(num: 2, values: values.baseAddress!, keys: nil)
                return withUnsafeMutablePointer(to: &list) { list in
                    var command = mpv_node(); command.format = MPV_FORMAT_NODE_ARRAY; command.u.list = list
                    return mpv_command_node(handle, &command, &result)
                }
            }
        }
        guard status >= 0, let result = fields(result, count: 2), integer(result["version"]) == 1,
              case .some(.flag(_)) = result["released"] else { return false }
        // Both true (exact slot removed) and false (exact ticket already absent) certify that
        // future native borrows cannot acquire this ticket. Neither proves physical display.
        return true
    }

    private static func integer(_ value: Value?) -> Int64? {
        guard case .some(.integer(let value)) = value else { return nil }; return value
    }
    private static func fields(_ node: mpv_node, count: Int) -> [String: Value]? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list,
              Int(list.pointee.num) == count, let keys = list.pointee.keys,
              let values = list.pointee.values else { return nil }
        var result: [String: Value] = [:]
        for index in 0..<count {
            guard let key = keys[index] else { return nil }
            let keyText = String(cString: key)
            guard result[keyText] == nil else { return nil }
            switch values[index].format {
            case MPV_FORMAT_INT64: result[keyText] = .integer(values[index].u.int64)
            case MPV_FORMAT_DOUBLE: result[keyText] = .number(values[index].u.double_)
            case MPV_FORMAT_FLAG:
                guard values[index].u.flag == 0 || values[index].u.flag == 1 else { return nil }
                result[keyText] = .flag(values[index].u.flag == 1)
            default: return nil
            }
        }
        return result
    }
    private static func command(_ handle: OpaquePointer, _ name: String,
                                _ arguments: [Argument], _ result: inout mpv_node) -> Int32 {
        withCommand(name, arguments) { mpv_command_node(handle, $0, &result) }
    }

    private static func withCommand(_ name: String, _ arguments: [Argument],
                                    _ invoke: (UnsafeMutablePointer<mpv_node>) -> Int32) -> Int32 {
        let arguments = [Argument.string(name)] + arguments
        let nodes = UnsafeMutablePointer<mpv_node>.allocate(capacity: arguments.count)
        nodes.initialize(repeating: mpv_node(), count: arguments.count)
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer {
            for string in strings { free(string) }
            nodes.deinitialize(count: arguments.count); nodes.deallocate()
        }
        for (index, value) in arguments.enumerated() {
            switch value {
            case .integer(let value): nodes[index].format = MPV_FORMAT_INT64; nodes[index].u.int64 = value
            case .number(let value): nodes[index].format = MPV_FORMAT_DOUBLE; nodes[index].u.double_ = value
            case .string(let value):
                guard !value.contains("\0"), let string = strdup(value) else { return -1 }
                strings.append(string); nodes[index].format = MPV_FORMAT_STRING; nodes[index].u.string = string
            }
        }
        var list = mpv_node_list(num: Int32(arguments.count), values: nodes, keys: nil)
        return withUnsafeMutablePointer(to: &list) { list in
            var command = mpv_node(); command.format = MPV_FORMAT_NODE_ARRAY; command.u.list = list
            return withUnsafeMutablePointer(to: &command, invoke)
        }
    }
}
