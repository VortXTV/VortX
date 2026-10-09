import Libmpv

/// The pinned mpv exposes this property as a NODE map, not slash-addressable subproperties.
/// Copy only typed numeric fields before freeing the native node; no source metadata escapes.
struct MPVDemuxerCacheSnapshot {
    enum Status: Equatable {
        case available
        case unavailable
        case readError(Int32)
        case malformed
    }
    let status: Status
    private var integers: [String: Int] = [:]
    private var doubles: [String: Double] = [:]
    private var flags: [String: Bool] = [:]

    static func read(from handle: OpaquePointer) -> Self {
        var node = mpv_node()
        let result = mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &node)
        guard result >= 0 else {
            return Self(status: result == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue ? .unavailable : .readError(result))
        }
        defer { mpv_free_node_contents(&node) }
        return Self(node: node)
    }

    init(status: Status) { self.status = status }

    init(node: mpv_node) {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list,
              list.pointee.num >= 0, list.pointee.num <= 128,
              list.pointee.num == 0 || (list.pointee.keys != nil && list.pointee.values != nil) else {
            self.init(status: .malformed)
            return
        }
        self.init(status: .available)
        var seen = Set<String>()
        for index in 0..<Int(list.pointee.num) {
            guard let keyPointer = list.pointee.keys[index] else { continue }
            let key = String(cString: keyPointer)
            // Duplicate native fields cannot certify a counter or a transport condition.
            guard seen.insert(key).inserted else {
                integers[key] = nil; doubles[key] = nil; flags[key] = nil
                continue
            }
            let value = list.pointee.values[index]
            switch key {
            case "fw-bytes", "debug-low-level-seeks":
                if value.format == MPV_FORMAT_INT64, value.u.int64 >= 0,
                   let integer = Int(exactly: value.u.int64) { integers[key] = integer }
            case "debug-seeking":
                if value.format == MPV_FORMAT_DOUBLE, value.u.double_.isFinite { doubles[key] = value.u.double_ }
            case "underrun", "idle":
                if value.format == MPV_FORMAT_FLAG, value.u.flag == 0 || value.u.flag == 1 {
                    flags[key] = value.u.flag == 1
                }
            default: break
            }
        }
    }

    func integer(_ key: String) -> Int? { integers[key] }
    func double(_ key: String) -> Double? { doubles[key] }
    func flag(_ key: String) -> Bool? { flags[key] }
}
