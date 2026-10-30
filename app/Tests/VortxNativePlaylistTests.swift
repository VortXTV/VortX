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
    static func main() async throws {
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

        // Actual volatile receipt ledger policy: exact register, local edit generation, owner scope and caps.
        let actorID = UUID().uuidString.lowercased()
        let register: VortxJSON = .object(["clock": .unsigned(7), "actor": .string(actorID), "value": value])
        let canonicalRegister = VortxNativePlaylist.canonicalReceiptRegister(register)!
        let receiptOwner = NativePlaylistReceiptOwner(credentialNamespace: "account.fixture",
            credentialGeneration: 4, accountGeneration: UUID(), profileID: UUID(uuidString: "A0000000-ABCD-EF01-AAAA-BBBBBBBBBBBB")!,
            profileKey: "A0000000-ABCD-EF01-AAAA-BBBBBBBBBBBB", profileGeneration: UUID(), sessionGeneration: UUID())
        let key = VortxNativePlaylist.field(playlistID)
        var ledger = NativePlaylistCloudReceiptLedger()
        let first = ledger.register(owner: receiptOwner, field: key, canonicalRegister: canonicalRegister)!
        let firstFingerprint = NativePlaylistRegisterFingerprint(canonicalRegister: canonicalRegister)
        check(ledger.state(owner: receiptOwner, field: key, current: firstFingerprint) == .pending,
              "cloud receipt starts pending for exact register")
        let wrongRegister = VortxNativePlaylist.canonicalReceiptRegister(.object([
            "clock": .unsigned(8), "actor": .string(actorID), "value": value
        ]))!
        check(canonicalRegister != wrongRegister, "whole-register identity includes clock and actor")
        check(!ledger.acknowledge(first.key, edit: first.edit, exactAcceptedRegister: wrongRegister, version: 9),
              "candidate with different register cannot acknowledge pending edit")
        let newer = ledger.register(owner: receiptOwner, field: key, canonicalRegister: wrongRegister)!
        check(!ledger.acknowledge(newer.key, edit: first.edit, exactAcceptedRegister: canonicalRegister, version: 9),
              "older edit generation cannot acknowledge newer local register")
        let newFingerprint = NativePlaylistRegisterFingerprint(canonicalRegister: wrongRegister)
        check(ledger.state(owner: receiptOwner, field: key, current: firstFingerprint) == .unknown
              && ledger.state(owner: receiptOwner, field: key, current: newFingerprint) == .pending,
              "superseded register is unknown while latest register stays pending")
        check(ledger.acknowledge(newer.key, edit: newer.edit, exactAcceptedRegister: wrongRegister, version: 10)
              && ledger.state(owner: receiptOwner, field: key, current: newFingerprint) == .saved(version: 10),
              "exact current candidate yields versioned volatile receipt")
        let replacementOwner = NativePlaylistReceiptOwner(credentialNamespace: receiptOwner.credentialNamespace,
            credentialGeneration: receiptOwner.credentialGeneration, accountGeneration: receiptOwner.accountGeneration,
            profileID: UUID(), profileKey: UUID().uuidString, profileGeneration: UUID(),
            sessionGeneration: receiptOwner.sessionGeneration)
        check(ledger.state(owner: replacementOwner, field: key, current: newFingerprint) == .unknown,
              "receipt cannot transfer to another profile generation")
        check(!ledger.invalidate(owner: replacementOwner) && ledger.state(owner: receiptOwner, field: key, current: newFingerprint) == .saved(version: 10),
              "repeated invalidation of an unrelated owner is idempotent and preserves the current receipt")
        var bounded = NativePlaylistCloudReceiptLedger()
        var firstKey: String?
        var last: (NativePlaylistReceiptKey, UUID)?
        for index in 0...NativePlaylistCloudReceiptLedger.maximumEntries {
            let id = UUID()
            let field = VortxNativePlaylist.field(id)
            let registered = bounded.register(owner: receiptOwner, field: field, canonicalRegister: canonicalRegister)!
            if index == 0 { firstKey = field }
            last = (registered.key, registered.edit)
        }
        let firstWasEvicted = bounded.state(owner: receiptOwner, field: firstKey!, current: firstFingerprint) == .unknown
        let newestIsPending = bounded.state(owner: receiptOwner, field: last!.0.field, current: firstFingerprint) == .pending
        check(firstWasEvicted && newestIsPending && bounded.pending.count == NativePlaylistCloudReceiptLedger.maximumEntries,
              "bounded ledger evicts only in-memory proof metadata")
        check(bounded.register(owner: receiptOwner, field: VortxNativePlaylist.field(UUID()),
              canonicalRegister: Data(repeating: 0x61, count: NativePlaylistCloudReceiptLedger.maximumRegisterBytes + 1)) == nil,
              "oversized receipt rejected before retention")
        var byteBounded = NativePlaylistCloudReceiptLedger()
        var oldestField: String?
        for index in 0..<9 {
            let field = VortxNativePlaylist.field(UUID())
            _ = byteBounded.register(owner: receiptOwner, field: field,
                canonicalRegister: Data(repeating: UInt8(index), count: 500 * 1024))!
            if index == 0 { oldestField = field }
        }
        check(byteBounded.state(owner: receiptOwner, field: oldestField!, current: firstFingerprint) == .unknown
              && byteBounded.pending.count < 9,
              "aggregate byte cap evicts only oldest volatile receipt metadata")

        let frozenPlaintext = try JSONEncoder().encode(VortxJSON.object(["nativeHostPreferences": .object([
            "profiles": .object([receiptOwner.profileKey: .object(["fields": .object([key: register])])])
        ])]))
        let candidateProjection = try await NativePlaylistCloudReceiptProjectionWorker.shared.candidateProjection(
            plaintext: frozenPlaintext, owner: receiptOwner, fields: [key], edits: [key: first.edit])
        check(candidateProjection.registers[key] == canonicalRegister && candidateProjection.edits[key] == first.edit,
              "background projection matches exact captured register and frozen edit generation")
        check(try await NativePlaylistCloudReceiptProjectionWorker.shared.fingerprint(register) == firstFingerprint,
              "background query fingerprint avoids main-actor register serialization")
        let wrongProfileCase = try JSONEncoder().encode(VortxJSON.object(["nativeHostPreferences": .object([
            "profiles": .object([receiptOwner.profileKey.lowercased(): .object(["fields": .object([key: register])])])
        ])]))
        do {
            _ = try await NativePlaylistCloudReceiptProjectionWorker.shared.candidateProjection(
                plaintext: wrongProfileCase, owner: receiptOwner, fields: [key], edits: [key: first.edit])
            preconditionFailure("carrier with a noncanonical profile key must not match the captured key")
        } catch NativePlaylistCloudReceiptProjectionWorker.Failure.invalidProjection {
            print("PASS profile key lookup uses captured spelling")
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
