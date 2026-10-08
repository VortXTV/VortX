import Foundation

/// A want-to-watch ledger, not engine library membership. Each canonical type/id is independently
/// ordered by the existing host Lamport register; null is an explicit, retained removal.
enum VortxNativeWatchlist {
    static let prefix = "watchlist."
    static let displayCap = 1_000
    static let baselineActor = "00000000-0000-0000-0000-000000000000"
    enum Failure: LocalizedError {
        case capacity
        var errorDescription: String? { "This watchlist has 1,000 titles. Remove a title before adding another; no existing titles were deleted." }
    }
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let type: String
        let name: String?
        let poster: String?
        let addedAt: Double // Existing Apple ledger's epoch seconds, not milliseconds.
    }
    static func field(id: String, type: String) throws -> String {
        guard ["movie", "series"].contains(type), !id.isEmpty, id.utf8.count <= 512,
              id.hasPrefix("tt") || id.hasPrefix("tmdb"),
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-").contains($0) })
        else { throw VortxNativeError.invalidSnapshot }
        let suffix = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return prefix + type + "." + suffix
    }
    static func validate(_ field: String, value: VortxJSON) throws {
        let parts = field.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "watchlist" else { throw VortxNativeError.invalidSnapshot }
        var encoded = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let id = String(data: bytes, encoding: .utf8),
              try Self.field(id: id, type: String(parts[1])) == field else { throw VortxNativeError.invalidSnapshot }
        if value == .null { return }
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["id", "type", "name", "poster", "addedAt"]),
              Set(["id", "type", "addedAt"]).isSubset(of: Set(fields.keys)) else { throw VortxNativeError.invalidSnapshot }
        let entry = try value.decode(Entry.self)
        guard entry.id == id, entry.type == String(parts[1]), entry.addedAt.isFinite,
              entry.addedAt >= 0, entry.addedAt <= Double(VortxNativeHostPreferences.maxClock),
              entry.name?.utf8.count ?? 0 <= 4_096, entry.poster?.utf8.count ?? 0 <= 8_192 else { throw VortxNativeError.invalidSnapshot }
    }
    static func value(_ entry: Entry) throws -> VortxJSON {
        let value = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(entry))
        try validate(field(id: entry.id, type: entry.type), value: value)
        return value
    }
    static func entries(host: VortxJSON, profileID: UUID) throws -> [Entry] {
        guard case .object(let fields) = host["profiles"]?[profileID.uuidString]?["fields"] else { return [] }
        var values: [Entry] = []
        for (key, register) in fields where key.hasPrefix(prefix) {
            guard let value = register["value"] else { throw VortxNativeError.invalidSnapshot }
            try validate(key, value: value)
            if value != .null { values.append(try value.decode(Entry.self)) }
        }
        return values.sorted { $0.addedAt == $1.addedAt ? ($0.type, $0.id) < ($1.type, $1.id) : $0.addedAt > $1.addedAt }
    }
    /// Authenticated legacy arrays can seed absent identities only. Array absence is not a removal;
    /// a later register or tombstone always retains its authority. No device clock is fabricated.
    static func seed(_ entries: [Entry], profileID: UUID, into host: inout VortxNativeHostPreferences) throws {
        guard entries.count <= displayCap else { throw VortxNativeError.invalidSnapshot }
        var fields = host.local.document.profiles[profileID.uuidString] ?? .init()
        var seen = Set<String>()
        for entry in entries {
            let key = try field(id: entry.id, type: entry.type), value = try value(entry)
            guard seen.insert(key).inserted else { throw VortxNativeError.invalidSnapshot }
            if fields.fields[key] == nil { fields.fields[key] = .init(clock: 0, actor: baselineActor, value: value) }
        }
        host.local.document.profiles[profileID.uuidString] = fields
    }
}
