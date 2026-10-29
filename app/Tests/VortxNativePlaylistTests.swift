import Foundation

@main
struct VortxNativePlaylistTests {
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        print("PASS \(label)")
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body() } catch { print("PASS \(label)"); return }
        preconditionFailure(label)
    }
    static func main() throws {
        let playlistID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let candidate = PlaybackTitleQueuePolicy.Candidate(contentID: "tt123", type: "movie", title: "Example")!
        let doc = VortxNativePlaylist.Document(id: playlistID, name: "Favorites", entries: [.init(id: entryID, candidate: candidate)])
        let value = try VortxNativePlaylist.encodedValue(doc)
        let field = VortxNativePlaylist.field(playlistID)
        check(VortxNativePlaylist.projection(field: field, value: value) == .supported(doc), "v1 roundtrip")
        let supplementary = VortxNativePlaylist.Document(id: playlistID, name: "Saved 🎬", entries: [
            .init(id: entryID, candidate: PlaybackTitleQueuePolicy.Candidate(contentID: "tt123", type: "movie", title: "Example 🌍")!)
        ])
        check(VortxNativePlaylist.projection(field: field, value: try VortxNativePlaylist.encodedValue(supplementary)) == .supported(supplementary),
              "supplementary Unicode roundtrip")
        check(UnicodeScalar(0xD800) == nil && UnicodeScalar(0xDC00) == nil, "lone surrogate scalars are unrepresentable")
        for escape in ["\"\\uD800\"", "\"\\uDC00\""] {
            rejects("JSON rejects escaped lone surrogate") {
                _ = try JSONDecoder().decode(String.self, from: Data(escape.utf8))
            }
        }
        for formatControl in ["\u{00AD}", "\u{200B}", "\u{200D}"] {
            check(PlaybackTitleQueuePolicy.Candidate(contentID: "tt123", type: "movie", title: "bad\(formatControl)title") == nil,
                  "known catalog text rejects Cc/Cf")
            rejects("playlist family key rejects Cc/Cf") {
                try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.\(formatControl)", value: .object([:]), global: false)
            }
        }
        try VortxNativePlaylist.validateEnvelope(name: field, value: value, global: false)
        try VortxNativePlaylist.validateEnvelope(name: field, value: .null, global: false)
        check(VortxNativePlaylist.projection(field: field, value: .null) == .deleted, "null is retained tombstone")
        try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.opaque", value: .object(["schema": .integer(2), "future": .bool(true)]), global: false)
        check(VortxNativePlaylist.projection(field: "playlist.v2.opaque", value: value) == .unsupported, "future namespace is opaque")
        rejects("global playlist register denied") {
            try VortxNativePlaylist.validateEnvelope(name: field, value: value, global: true)
        }
        let boundaryKey = "playlist.v2." + String(repeating: "a", count: 500)
        try VortxNativePlaylist.validateEnvelope(name: boundaryKey, value: .object(["future": .bool(true)]), global: false)
        rejects("oversized future playlist field key denied") {
            try VortxNativePlaylist.validateEnvelope(name: boundaryKey + "a", value: .object(["future": .bool(true)]), global: false)
        }
        let multibyteBoundary = "playlist.v2." + String(repeating: "🍿", count: 125)
        try VortxNativePlaylist.validateEnvelope(name: multibyteBoundary, value: .object(["future": .bool(true)]), global: false)
        rejects("future playlist key uses UTF8 byte ceiling") {
            try VortxNativePlaylist.validateEnvelope(name: multibyteBoundary + "🍿", value: .object(["future": .bool(true)]), global: false)
        }
        try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.opaque", value: .object(["text": .string("👩‍💻")]), global: false)
        let exactCost = VortxJSON.object(["x": .string(String(repeating: "🍿", count: 43_690))])
        try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.cost", value: exactCost, global: false)
        rejects("shared conservative JSON cost boundary") {
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.cost", value: .object(["x": .string(String(repeating: "🍿", count: 43_691))]), global: false)
        }
        let falseHeavy = VortxJSON.object([
            "items": .array(Array(repeating: .bool(false), count: 50_000)),
            "pad": .string(String(repeating: "x", count: 250_000))
        ])
        check(try JSONEncoder().encode(falseHeavy).count > VortxNativePlaylist.maximumValueBytes,
              "false-heavy actual encoded body exceeds value ceiling")
        rejects("false-heavy envelope denied before serialization") {
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.false-heavy", value: falseHeavy, global: false)
        }
        for boolean in [true, false] {
            // Compact {"v":<bool>,"p":""} is 17 bytes for true, 18 for false.
            let overhead = boolean ? 17 : 18
            let padding = String(repeating: "x", count: VortxNativePlaylist.maximumValueBytes - overhead)
            let boundary = VortxJSON.object(["v": .bool(boolean), "p": .string(padding)])
            check(try JSONEncoder().encode(boundary).count == VortxNativePlaylist.maximumValueBytes,
                  "Boolean boundary agrees with actual serializer")
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.bool-boundary", value: boundary, global: false)
            rejects("Boolean boundary plus one denied") {
                try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.bool-boundary",
                    value: .object(["v": .bool(boolean), "p": .string(padding + "x")]), global: false)
            }
        }
        var tooDeep: VortxJSON = .bool(true)
        for _ in 0...VortxNativePlaylist.maximumJSONDepth { tooDeep = .object(["child": tooDeep]) }
        rejects("deep future object denied before serialization") {
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.deep", value: .object(["child": tooDeep]), global: false)
        }
        let deepKnownValue = VortxJSON.object(["schema": .integer(1), "id": .string(playlistID.uuidString.lowercased()),
            "name": .string("Favorites"), "entries": .array([]), "future": tooDeep])
        check(VortxNativePlaylist.projection(field: field, value: deepKnownValue) == .unsupported,
              "known-v1 projection uses the same bounded walk")
        let tooManyNodes = VortxJSON.object(Dictionary(uniqueKeysWithValues: (0..<32_768).map { ("k\($0)", VortxJSON.bool(true)) }))
        rejects("over-node-limit future object denied") {
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.nodes", value: tooManyNodes, global: false)
        }
        rejects("non-object playlist envelope denied") {
            try VortxNativePlaylist.validateEnvelope(name: field, value: .array([]), global: false)
        }
        let mismatched = VortxJSON.object(["schema": .integer(1), "id": .string("00000000-0000-0000-0000-000000000999"), "name": .string("Favorites"), "entries": .array([])])
        check(VortxNativePlaylist.projection(field: field, value: mismatched) == .unsupported, "field id binds document id")
        let oversized = VortxJSON.object(["future": .string(String(repeating: "x", count: VortxNativePlaylist.maximumValueBytes))])
        rejects("oversized opaque object denied") {
            try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.opaque", value: oversized, global: false)
        }
        let rawRegister: VortxJSON = .object(["clock": .integer(1), "actor": .string("00000000-0000-0000-0000-000000000001"), "value": value])
        let create = VortxNativeHostFieldEdit(field: field, expectedRegister: nil, value: value)
        try VortxNativePlaylist.validateMutation(create, fields: [:])
        let update = VortxNativeHostFieldEdit(field: field, expectedRegister: rawRegister, value: value)
        try VortxNativePlaylist.validateMutation(update, fields: [field: rawRegister])
        let delete = VortxNativeHostFieldEdit(field: field, expectedRegister: rawRegister, value: .null)
        try VortxNativePlaylist.validateMutation(delete, fields: [field: rawRegister])
        let registerWithDeepExtra = VortxJSON.object(["clock": .integer(1), "actor": .string("00000000-0000-0000-0000-000000000001"),
            "value": value, "future": tooDeep])
        rejects("complete raw register bounds extra members before CAS") {
            try VortxNativePlaylist.validateMutation(.init(field: field, expectedRegister: registerWithDeepExtra, value: value),
                                                       fields: [field: registerWithDeepExtra])
        }
        try VortxNativePlaylist.validateEnvelope(name: "playlist.v2.large-number",
            value: .object(["largeNumber": .number(1e100), "largeInteger": .integer(Int64.max)]), global: false)
        rejects("stale observed register denied") {
            try VortxNativePlaylist.validateMutation(update, fields: [field: .object(["clock": .integer(2), "actor": .string("00000000-0000-0000-0000-000000000001"), "value": value])])
        }
        rejects("tombstone cannot be resurrected") {
            try VortxNativePlaylist.validateMutation(create, fields: [field: .object(["clock": .integer(2), "actor": .string("00000000-0000-0000-0000-000000000001"), "value": .null])])
        }
        var capped: [String: VortxJSON] = [:]
        for index in 0..<32 {
            capped["playlist.v2.opaque\(index)"] = .object(["clock": .integer(1), "actor": .string("00000000-0000-0000-0000-000000000001"), "value": .object(["future": .bool(true)])])
        }
        rejects("create counts unknown live playlist registers") {
            try VortxNativePlaylist.validateMutation(create, fields: capped)
        }
        let scope = VortxAccountScope(account: "account.fixture", ownerProfileID: "00000000-0000-0000-0000-00000000A11C")
        let actor = "00000000-0000-0000-0000-000000000001"
        var host = try VortxNativeHostPreferences(scope: scope, actor: actor)
        try host.edit(profileID: scope.ownerProfileID, fields: [field: value], scope: scope)
        try host.edit(profileID: scope.ownerProfileID, fields: [field: .null], scope: scope)
        check(try host.document["profiles"]?[scope.ownerProfileID]?["fields"]?[field]?["value"] == .null,
              "host retains playlist tombstone")
        rejects("host rejects global playlist edit") {
            try host.edit(profileID: nil, fields: [field: value], scope: scope)
        }
    }
}
