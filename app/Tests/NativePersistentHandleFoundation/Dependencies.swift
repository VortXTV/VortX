import Foundation

// Exact complete production declarations, not simplified test doubles.
// VortxResourceBridge.swift:8-39; VortxNativeSession.swift:211-261.
// VortxNativeError comes from the complete Runtime afterimage.

indirect enum VortxJSON: Codable, Equatable, Sendable {
    case object([String: VortxJSON]), array([VortxJSON]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: VortxJSON].self) { self = .object(v) }
        else if let v = try? c.decode([VortxJSON].self) { self = .array(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> VortxJSON? {
        guard case .object(let v) = self else { return nil }; return v[key]
    }
    var array: [VortxJSON]? { guard case .array(let v) = self else { return nil }; return v }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct VortxAccountScope: Codable, Hashable, Sendable {
    let account: String
    let ownerProfileID: String
    var authenticatedData: Data { Data((account + "\u{0}" + ownerProfileID).utf8) }
    func validate() throws {
        guard !account.isEmpty, !ownerProfileID.isEmpty,
              !account.contains("\u{0}"), !ownerProfileID.contains("\u{0}") else { throw VortxNativeError.invalidSnapshot }
    }
    func validateSnapshot(_ snapshot: String) throws -> VortxJSON {
        let value = try JSONDecoder().decode(VortxJSON.self, from: Data(snapshot.utf8))
        guard case .object(let profiles) = value["roster"]?["profiles"],
              profiles[ownerProfileID]?["owner"] == .bool(true),
              profiles[ownerProfileID]?["deleted"] != .bool(true),
              profiles.values.filter({ $0["owner"] == .bool(true) }).count == 1,
              profiles.allSatisfy({ $0.value["id"] == .string($0.key) }),
              case .string(let active) = value["activeProfileId"],
              profiles[active] != nil, profiles[active]?["deleted"] != .bool(true),
              case .object(let libraries) = value["libraries"], case .object = libraries[active],
              libraries.keys.allSatisfy({ profiles[$0] != nil }) else { throw VortxNativeError.invalidSnapshot }
        if let sync = value["nativeSync"], sync != .null {
            guard sync["scope"] == .string(account), sync["ownerProfileId"] == .string(ownerProfileID),
                  Self.supportedNativeSyncSchema(sync["schemaVersion"]) else { throw VortxNativeError.invalidSnapshot }
        }
        return value
    }
    private static func supportedNativeSyncSchema(_ value: VortxJSON?) -> Bool {
        switch value {
        case .integer(let schema): return (1...5).contains(schema)
        case .unsigned(let schema): return (1...5).contains(schema)
        default: return false
        }
    }
    func validateHydration(from original: String, to hydrated: String) throws {
        let before = try validateSnapshot(original), after = try validateSnapshot(hydrated)
        guard before["nativeSync"] == after["nativeSync"] else { throw VortxNativeError.invalidSnapshot }
        guard case .object(let libraries) = before["libraries"] else { throw VortxNativeError.invalidSnapshot }
        for (profile, library) in libraries {
            if let context = library["watchContexts"] {
                let hydrated = after["libraries"]?[profile]?["watchContexts"]
                if case .object(let retained) = context, case .object(let projected)? = hydrated {
                    // The unchanged nativeSync authority can synthesize a missing context during
                    // hydration. Additions are lossless; every previously sealed entry must still
                    // survive exactly, including metadata and duration, before mounting/committing.
                    guard retained.allSatisfy({ projected[$0.key] == $0.value }) else { throw VortxNativeError.invalidSnapshot }
                } else {
                    guard context == hydrated else { throw VortxNativeError.invalidSnapshot }
                }
            }
        }
    }
}
