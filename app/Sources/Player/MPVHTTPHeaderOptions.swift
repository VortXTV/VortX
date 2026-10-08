import Darwin
import Libmpv

/// `http-header-fields` is a string-list option. A comma-joined STRING is parsed as list syntax,
/// corrupting otherwise valid header values. A NODE containing an array preserves each full field.
enum MPVHTTPHeaderOptions {
    static func set(_ fields: [String], on handle: OpaquePointer?) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
        guard let count = Int32(exactly: fields.count),
              !fields.contains(where: { $0.utf8.contains(0) }) else {
            return MPV_ERROR_INVALID_PARAMETER.rawValue
        }
        let strings = fields.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return MPV_ERROR_NOMEM.rawValue }
        var values = strings.map { string -> mpv_node in
            var value = mpv_node()
            value.format = MPV_FORMAT_STRING
            value.u.string = string
            return value
        }
        return values.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list()
            list.num = count
            list.values = buffer.baseAddress
            return withUnsafeMutablePointer(to: &list) { listPointer in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = listPointer
                // NODE_ARRAY is only the inner node's format, never the C API's outer format.
                // The setter copies synchronously; all strings/list/storage stay alive through it.
                return mpv_set_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node)
            }
        }
    }
}
