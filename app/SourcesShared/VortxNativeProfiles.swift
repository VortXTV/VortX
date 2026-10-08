import Foundation

/// Presentation conversion only. Private-kernel profile fields always override the host baseline.
enum VortxNativeProfiles {
    private static let nativeKeys: Set<String> = ["id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale", "disabledAddons", "usesOwnAccount"]
    static func project(state: VortxJSON, host: VortxJSON, baseline: [UserProfile]) throws -> [UserProfile] {
        guard case .object(let records) = state["roster"]?["profiles"] else { throw VortxNativeError.invalidSnapshot }
        let prior = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id.uuidString, $0) })
        let order = baseline.map { $0.id.uuidString } + records.keys.filter { prior[$0] == nil }.sorted()
        return try order.compactMap { id in
            guard let record = records[id], record["deleted"] != .bool(true) else { return nil }
            guard let uuid = UUID(uuidString: id), case .string(let name) = record["name"],
                  case .bool(let owner) = record["owner"] else { throw VortxNativeError.invalidSnapshot }
            let base = prior[id] ?? UserProfile(id: uuid, name: name, avatar: "🍿", isOwner: owner)
            guard case .object(var object) = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(base)) else { throw VortxNativeError.invalidSnapshot }
            if case .object(let registers) = host["profiles"]?[id]?["fields"] {
                for (key, register) in registers where !nativeKeys.contains(key) {
                    // Unknown safe fields are retained in the carrier, never applied to the UI.
                    guard ["avatar", "email", "playback", "discovery", "addonPreferences"].contains(key), let value = register["value"] else { continue }
                    if value == .null {
                        if key == "avatar" { object[key] = .string("🍿") } else { object.removeValue(forKey: key) }
                    } else { object[key] = value }
                }
            }
            object["id"] = .string(id); object["name"] = .string(name); object["isOwner"] = .bool(owner)
            object["usesOwnAccount"] = .bool(false)
            object["pin"] = record["pin"] ?? .null
            object["isKids"] = record["parental"]?["kids"] ?? .bool(false)
            object["familyEdit"] = record["parental"]?["familyEdit"] ?? .bool(false)
            object["accentID"] = record["settings"]?["accent"] ?? .string("ember")
            if object["accentID"] == .null { object["accentID"] = .string("ember") }
            object["oled"] = record["settings"]?["oled"] ?? .bool(false)
            let scale = try record["settings"]?["textScale"]?.decode(UInt32.self) ?? 1000
            object["textScale"] = .number(Double(scale) / 1000)
            object["disabledAddons"] = record["settings"]?["disabledAddons"] ?? .array([])
            return try VortxJSON.object(object).decode(UserProfile.self)
        }
    }
    static func mutation(_ desired: UserProfile, previous: UserProfile?, ownerID: String) throws -> ([VortxJSON], VortxNativeHostPreferences.Edit) {
        guard !desired.usesOwnAccount, desired.isOwner == (desired.id.uuidString == ownerID),
              desired.textScale.isFinite, desired.textScale > 0, desired.textScale <= 100,
              !desired.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VortxNativeError.invalidSnapshot }
        if let pin = desired.pin, !pin.isEmpty {
            guard pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { throw VortxNativeError.invalidSnapshot }
        }
        var edits: [VortxJSON] = []
        func edit(_ field: String, _ value: VortxJSON, changed: Bool) { if changed { edits.append(.object(["field": .string(field), "value": value])) } }
        edit("name", .string(desired.name), changed: previous?.name != desired.name)
        edit("pin", desired.pin.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null, changed: previous?.pin != desired.pin)
        edit("kids", .bool(desired.isKids), changed: previous?.isKids != desired.isKids)
        edit("familyEdit", .bool(desired.familyEdit), changed: previous?.familyEdit != desired.familyEdit)
        edit("accent", .string(desired.accentID), changed: previous?.accentID != desired.accentID)
        edit("oled", .bool(desired.oled), changed: previous?.oled != desired.oled)
        edit("textScale", .integer(Int64((desired.textScale * 1000).rounded())), changed: previous?.textScale != desired.textScale)
        let disabled = desired.addonPreferences?.disabledAddonURLsOverride ?? desired.disabledAddons ?? []
        let oldDisabled = previous?.addonPreferences?.disabledAddonURLsOverride ?? previous?.disabledAddons ?? []
        edit("disabledAddons", .array(disabled.map(VortxJSON.string)), changed: previous == nil || oldDisabled != disabled)
        var actions: [VortxJSON] = previous == nil ? [.object(["type": .string("add_profile"), "id": .string(desired.id.uuidString), "name": .string(desired.name)])] : []
        if !edits.isEmpty { actions.append(.object(["type": .string("patch_profile"), "id": .string(desired.id.uuidString), "edits": .array(edits)])) }
        guard case .object(let next) = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(desired)) else { throw VortxNativeError.invalidSnapshot }
        let old = try previous.map { try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode($0)) }
        let oldKeys: [String] = if case .object(let object) = old { Array(object.keys) } else { [] }
        var host: [String: VortxJSON] = [:]
        for key in Set(next.keys).union(oldKeys).subtracting(nativeKeys) {
            if previous == nil || next[key] != old?[key] { host[key] = next[key] ?? .null }
        }
        return (actions, .init(profileID: desired.id.uuidString, fields: host))
    }
}
