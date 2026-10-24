import Foundation
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
