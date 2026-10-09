import Foundation
import CryptoKit

/// Website event host-CAS adapter only. Native field ordering, membership and receipts belong to
/// the private kernel. This helper never reads global preferences or invents an authoring base.
enum VortxNativeProfileEditHost {
    struct Conflict: Codable, Equatable, Sendable {
        let eventId: String
        let code: String
        let paths: [String]
    }
    struct Admission {
        let preferences: VortxNativeHostPreferences
        let conflict: Conflict?
    }
    typealias Baselines = [String: [String: VortxJSON]]

    static func events(_ carrier: VortxJSON?) throws -> [VortxJSON] {
        guard let carrier else { return [] }
        guard case .object(let object) = carrier, Set(object.keys) == ["schemaVersion", "events"],
              carrier["schemaVersion"] == .integer(2), let events = carrier["events"]?.array else { throw VortxNativeError.invalidSnapshot }
        try validateSource(events)
        return events
    }
    static func validateSource(_ events: [VortxJSON]) throws {
        // Never put credential-bearing/opaque material in the host checkpoint. The authenticated
        // cloud source remains untouched when this boundary rejects a malformed carrier.
        let data = try JSONEncoder().encode(VortxJSON.object(["events": .array(events)]))
        let archive = try JSONDecoder().decode(VortxJSON.self, from: VortxNativeBootstrapArchive.encode(document: data))
        guard archive["excludedCredentialPaths"] == .array([]), archive["hostDocument"]?["events"] == .array(events) else { throw VortxNativeError.invalidSnapshot }
    }
    static func validateJournal(_ local: VortxNativeHostPreferences.Local) throws {
        try validateSource(local.websitePending ?? [])
        for (id, hash) in local.websiteReceipts ?? [:] {
            guard !id.isEmpty, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw VortxNativeError.invalidSnapshot }
        }
    }
    static func outcome(_ local: VortxNativeHostPreferences.Local) throws -> VortxJSON {
        // Only nativeSync.legacyProfileEditReceipts is a website success authority. This adjacent
        // channel reports conflicts; the local receipt map exists solely for host replay recovery.
        .object(["conflicts": try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(local.websiteConflicts ?? []))])
    }

    static func baselines(_ profiles: [UserProfile]) throws -> Baselines {
        try Dictionary(uniqueKeysWithValues: profiles.map { profile in
            let value = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(profile))
            return (profile.id.uuidString, ["avatar": value["avatar"] ?? .null, "playback": value["playback"] ?? .null])
        })
    }

    static func admit(event: VortxJSON, hostPatch: VortxJSON, preferences: VortxNativeHostPreferences,
                      scope: VortxAccountScope, baseline: Baselines, committedReplay: Bool, remoteReplay: Bool = false) throws -> Admission {
        guard case .string(let eventID) = event["eventId"], case .object(let profiles) = hostPatch else { throw VortxNativeError.invalidResponse }
        guard !profiles.isEmpty else { return Admission(preferences: preferences, conflict: nil) }
        guard VortxNativeHostPreferences.validActor(eventID),
              let clock = try event["observedHostClock"]?.decode(UInt64.self), clock < VortxNativeHostPreferences.maxClock,
              case .object(let bases) = event["hostBases"] else { throw VortxNativeError.invalidSnapshot }
        var pending: [String: VortxJSON] = [:]
        var conflicts: [String] = []
        for profileID in profiles.keys.sorted() {
            guard case .object(let patch) = profiles[profileID] else { throw VortxNativeError.invalidResponse }
            var fields: [String: [String: VortxJSON]] = [:]
            for (path, value) in patch {
                let parts = path.split(separator: ".").map(String.init)
                if parts == ["settings", "avatar"] { fields["avatar", default: [:]][""] = value }
                else if parts.count == 3, parts[0] == "settings", parts[1] == "playback" {
                    fields["playback", default: [:]][parts[2] == "forced" ? "forcedPolicy" : parts[2]] = value
                } else { throw VortxNativeError.invalidResponse }
            }
            var registers: [String: VortxJSON] = [:]
            for field in fields.keys.sorted() {
                let path = "hostBases.\(profileID).\(field)"
                let current = preferences.local.document.profiles[profileID]?.fields[field]
                // A receipt proves an earlier atomic native+host application. Its deterministic
                // register cannot rewind a newer local/peer register during exact event replay.
                if committedReplay, let current,
                   current.clock > clock + 1 || (current.clock == clock + 1 && current.actor >= eventID) { continue }
                if remoteReplay {
                    // The private kernel has certified this exact immutable event/receipt already
                    // existed in the adopted peer state. Its paired host result still needs proof.
                    guard let current else { conflicts.append(path); continue }
                    if current.clock > clock + 1 || (current.clock == clock + 1 && current.actor > eventID) { continue }
                    guard current.clock == clock + 1, current.actor == eventID else { conflicts.append(path); continue }
                    let matches: Bool
                    if field == "avatar" { matches = current.value == fields[field]![""] }
                    else { matches = fields[field]!.allSatisfy { current.value[$0.key] == $0.value } }
                    guard matches else { conflicts.append(path); continue }
                    continue
                }
                guard let base = bases[profileID]?[field], case .object(let evidence) = base,
                      case .string(let expectedHash) = evidence["valueHash"],
                      expectedHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw VortxNativeError.invalidSnapshot }
                let existing: VortxJSON
                if evidence["absent"] == .bool(true) {
                    guard Set(evidence.keys) == ["absent", "valueHash"] else { throw VortxNativeError.invalidSnapshot }
                    guard current == nil, let authenticated = baseline[profileID]?[field] else { conflicts.append(path); continue }
                    existing = authenticated
                } else {
                    guard Set(evidence.keys) == ["clock", "actor", "valueHash"],
                          let baseClock = try evidence["clock"]?.decode(UInt64.self), baseClock <= clock,
                          case .string(let actor) = evidence["actor"], VortxNativeHostPreferences.validActor(actor) else { throw VortxNativeError.invalidSnapshot }
                    guard let current, current.clock == baseClock, current.actor == actor else { conflicts.append(path); continue }
                    existing = current.value
                }
                guard try valueHash(existing) == expectedHash else { conflicts.append(path); continue }
                let changed: VortxJSON
                if field == "avatar" { changed = fields[field]![""]! }
                else {
                    var object: [String: VortxJSON]
                    if existing == .null { object = [:] }
                    else if case .object(let value) = existing { object = value }
                    else { throw VortxNativeError.invalidSnapshot }
                    for (key, value) in fields[field]! { object[key] = value }
                    changed = .object(object)
                }
                registers[field] = .object(["clock": .unsigned(clock + 1), "actor": .string(eventID), "value": changed])
            }
            if !registers.isEmpty { pending[profileID] = .object(["fields": .object(registers)]) }
        }
        guard conflicts.isEmpty else { return Admission(preferences: preferences,
            conflict: Conflict(eventId: eventID, code: "host_base_changed", paths: conflicts.sorted())) }
        var candidate = preferences
        try candidate.merge(.object(["schemaVersion": .integer(1), "scope": .string(scope.account),
            "ownerProfileId": .string(scope.ownerProfileID), "profiles": .object(pending), "globals": .object(["fields": .object([:])])]), scope: scope)
        return Admission(preferences: candidate, conflict: nil)
    }

    /// Shared website hash: canonical UTF-8 JSON, UTF-16 sorted keys, ECMAScript number spelling.
    /// This is deliberately not Foundation's encoder (its exponent and slash escaping differ).
    static func valueHash(_ value: VortxJSON) throws -> String {
        SHA256.hash(data: Data(try canonicalJSON(value).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func canonicalJSON(_ value: VortxJSON) throws -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return quoted(value)
        case .integer(let value): return try number(Double(value))
        case .unsigned(let value): return try number(Double(value))
        case .number(let value): return try number(value)
        case .array(let values): return "[" + (try values.map(canonicalJSON)).joined(separator: ",") + "]"
        case .object(let values):
            let keys = values.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { quoted($0) + ":" + (try canonicalJSON(values[$0]!)) }).joined(separator: ",") + "}"
        }
    }
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    private static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw VortxNativeError.invalidSnapshot }
        if value == 0 { return "0" }
        let sign = value < 0 ? "-" : ""
        let parts = String(abs(value)).lowercased().split(separator: "e").map(String.init)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var digits = mantissa.joined()
        var exponent = (parts.count == 2 ? Int(parts[1])! : 0) - (mantissa.count == 2 ? mantissa[1].count : 0)
        while digits.first == "0" { digits.removeFirst() }
        while digits.last == "0" { digits.removeLast(); exponent += 1 }
        let position = digits.count + exponent
        if position > 0 && position <= 21 {
            if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
            let split = digits.index(digits.startIndex, offsetBy: position)
            return sign + digits[..<split] + "." + digits[split...]
        }
        if position <= 0 && position > -6 { return sign + "0." + String(repeating: "0", count: -position) + digits }
        let tail = digits.dropFirst()
        let scientificExponent = position - 1
        return sign + String(digits.first!) + (tail.isEmpty ? "" : "." + tail) + "e" + (scientificExponent >= 0 ? "+" : "") + String(scientificExponent)
    }
}
