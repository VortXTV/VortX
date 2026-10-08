import Foundation
import Darwin
import Libmpv

/// Observations only. `stream-pos` is mpv's demuxer byte position, NOT an HTTP request offset,
/// returned Content-Range, or rendered frame position. Sizes may describe a local/remux input.
/// Read alongside the existing seek snapshot under the controller's source/command lock.
struct MPVSeekTransportDiagnostic {
    enum Kind { case nonnegativeInteger, flag, codecProfile }
    enum Value: Equatable {
        case integer(Int64), flag(Bool), profile(String), unavailable, error(Int32), malformed

        var receipt: String {
            switch self {
            case .integer(let value): return String(value)
            case .flag(let value): return value ? "true" : "false"
            case .profile(let value): return "\"\(value)\""
            case .unavailable: return "unavailable"
            case .error(let code): return "error(\(code))"
            case .malformed: return "malformed"
            }
        }
    }

    let seekable: Value
    let partiallySeekable: Value
    let demuxBytePosition: Value
    let sourceByteSize: Value

    var receipt: String {
        "seekable=\(seekable.receipt) partialSeekable=\(partiallySeekable.receipt)"
            + " demuxBytePos=\(demuxBytePosition.receipt) sourceByteSize=\(sourceByteSize.receipt)"
    }

    static func read(from handle: OpaquePointer) -> Self {
        Self(seekable: read("seekable", kind: .flag, from: handle),
             partiallySeekable: read("partially-seekable", kind: .flag, from: handle),
             demuxBytePosition: read("stream-pos", kind: .nonnegativeInteger, from: handle),
             sourceByteSize: read("file-size", kind: .nonnegativeInteger, from: handle))
    }

    static func codecProfile(from handle: OpaquePointer) -> Value {
        read("current-tracks/video/codec-profile", kind: .codecProfile, from: handle)
    }

    private static func read(_ property: String, kind: Kind, from handle: OpaquePointer) -> Value {
        var node = mpv_node()
        let status = mpv_get_property(handle, property, MPV_FORMAT_NODE, &node)
        defer { if status >= 0 { mpv_free_node_contents(&node) } }
        return decode(node, status: status, kind: kind)
    }

    static func decode(_ node: mpv_node, status: Int32, kind: Kind) -> Value {
        guard status >= 0 else {
            return status == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue ? .unavailable : .error(status)
        }
        switch kind {
        case .nonnegativeInteger:
            guard node.format == MPV_FORMAT_INT64, node.u.int64 >= 0 else { return .malformed }
            return .integer(node.u.int64)
        case .flag:
            guard node.format == MPV_FORMAT_FLAG, node.u.flag == 0 || node.u.flag == 1 else { return .malformed }
            return .flag(node.u.flag == 1)
        case .codecProfile:
            guard node.format == MPV_FORMAT_STRING, let pointer = node.u.string,
                  strnlen(pointer, 97) <= 96 else { return .malformed }
            let value = String(cString: pointer)
            // Native codec profile names only; never fall back to a title, URL, header or raw log.
            guard value.range(of: #"\A[A-Za-z0-9 ._()/:-]{1,96}\z"#, options: .regularExpression) != nil,
                  // Chroma profile names contain ratios (4:4:4); other colons are not profile data.
                  value.range(of: #"(?<![0-9]):|:(?![0-9])"#, options: .regularExpression) == nil
            else { return .malformed }
            return .profile(value)
        }
    }
}
