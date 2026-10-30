import Foundation

/// Wire-domain codec for one profile-scoped saved playlist register. This layer only knows sanitized
/// catalog identity; owner/account/session, route authority, URLs, credentials and playback state stay out.
enum VortxNativePlaylist {
    static let prefix = "playlist."
    static let v1Prefix = "playlist.v1."
    static let maximumFieldBytes = 512
    static let maximumJSONDepth = 64
    static let maximumJSONNodes = 65_536
    static let maximumValueBytes = 512 * 1024
    static let maximumRegisterBytes = maximumValueBytes + 1024
    static let maximumLivePlaylists = 32

    struct Document: Equatable, Sendable {
        let id: UUID
        let name: String
        let entries: [PlaybackTitleQueuePolicy.Entry]
    }

    enum Projection: Equatable, Sendable {
        case deleted
        case supported(Document)
        /// A bounded value from a newer schema/field shape is preserved by the carrier and read-only here.
        case unsupported
    }

    enum Failure: Error, Equatable {
        case invalidField
        case wrongScope
        case invalidEnvelope
        case oversized
        case invalidDocument
        case staleRegister
        case tombstoneCannotBeResurrected
        case unsupportedOriginal
        case tooManyLivePlaylists
    }

    static func field(_ id: UUID) -> String { v1Prefix + id.uuidString.lowercased() }

    /// Carrier admission is deliberately looser than v1 projection: a future playlist object stays intact
    /// in the Lamport register until a client understands it. All playlist fields remain profile-only.
    static func validateEnvelope(name: String, value: VortxJSON, global: Bool) throws {
        guard name.hasPrefix(prefix) else { return }
        guard name.utf8.count <= maximumFieldBytes,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidField }
        guard !global else { throw Failure.wrongScope }
        if name.hasPrefix(v1Prefix) {
            let rawID = String(name.dropFirst(v1Prefix.count))
            guard let id = UUID(uuidString: rawID), rawID == id.uuidString.lowercased() else {
                throw Failure.invalidField
            }
        }
        if value == .null { return }
        guard case .object = value else { throw Failure.invalidEnvelope }
        guard boundedJSONCost(value) != nil else { throw Failure.oversized }
    }

    /// Strictly projects the known v1 wire form. Future schemas or extra fields are unsupported and remain
    /// writable only through an explicit Save as new document; callers must retain the original raw register.
    static func projection(field: String, value: VortxJSON) -> Projection {
        guard field.hasPrefix(v1Prefix) else { return .unsupported }
        let rawID = String(field.dropFirst(v1Prefix.count))
        guard let id = UUID(uuidString: rawID), rawID == id.uuidString.lowercased() else { return .unsupported }
        if value == .null { return .deleted }
        guard case .object(let root) = value,
              boundedJSONCost(value) != nil,
              let schema = root["schema"], isIntegerOne(schema) else { return .unsupported }
        guard Set(root.keys) == Set(["schema", "id", "name", "entries"]),
              case .string(let documentID) = root["id"], documentID == rawID,
              case .string(let name) = root["name"], validName(name),
              case .array(let rows) = root["entries"], rows.count <= PlaybackTitleQueuePolicy.capacity else {
            return .unsupported
        }
        var seen = Set<UUID>()
        var entries: [PlaybackTitleQueuePolicy.Entry] = []
        entries.reserveCapacity(rows.count)
        for row in rows {
            guard case .object(let fields) = row else { return .unsupported }
            let required: Set<String> = ["entryID", "contentID", "type", "title"]
            let allowed = required.union(["videoIDHint", "episodeLabel"])
            guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: allowed),
                  case .string(let rawEntryID) = fields["entryID"],
                  let entryID = UUID(uuidString: rawEntryID), rawEntryID == entryID.uuidString.lowercased(),
                  seen.insert(entryID).inserted,
                  case .string(let contentID) = fields["contentID"],
                  case .string(let type) = fields["type"],
                  case .string(let title) = fields["title"] else { return .unsupported }
            let videoIDHint: String?
            if let rawHint = fields["videoIDHint"] {
                guard case .string(let hint) = rawHint else { return .unsupported }
                videoIDHint = hint
            } else { videoIDHint = nil }
            let episodeLabel: String?
            if let rawLabel = fields["episodeLabel"] {
                guard case .string(let label) = rawLabel else { return .unsupported }
                episodeLabel = label
            } else { episodeLabel = nil }
            guard let candidate = PlaybackTitleQueuePolicy.Candidate(contentID: contentID, type: type,
                  title: title, videoIDHint: videoIDHint, episodeLabel: episodeLabel) else { return .unsupported }
            entries.append(.init(id: entryID, candidate: candidate))
        }
        return .supported(.init(id: id, name: name, entries: entries))
    }

    /// Pure registry-independent mutation admission. The facade still performs captured-owner checks,
    /// raw-register CAS, and prospective whole-checkpoint budget validation before committing.
    static func validateMutation(_ edit: VortxNativeHostFieldEdit,
                                 fields: [String: VortxJSON]) throws {
        guard edit.field.hasPrefix(v1Prefix) else { throw Failure.invalidField }
        let rawID = String(edit.field.dropFirst(v1Prefix.count))
        guard let id = UUID(uuidString: rawID), rawID == id.uuidString.lowercased() else { throw Failure.invalidField }
        let current = fields[edit.field]
        if let current, boundedRegisterValue(current) == nil { throw Failure.invalidDocument }
        if let expected = edit.expectedRegister, boundedRegisterValue(expected) == nil { throw Failure.invalidDocument }
        guard VortxNativeHostFieldEvidence.json(current, edit.expectedRegister) else { throw Failure.staleRegister }
        if current == nil {
            guard edit.expectedRegister == nil, edit.value != .null else { throw Failure.tombstoneCannotBeResurrected }
            guard case .supported(let created) = projection(field: edit.field, value: edit.value), created.id == id else {
                throw Failure.invalidDocument
            }
            let liveCount = fields.reduce(into: 0) { count, pair in
                guard pair.key.hasPrefix(prefix) else { return }
                if case .object(let register) = pair.value, register["value"] == .null { return }
                count += 1
            }
            guard liveCount < maximumLivePlaylists else { throw Failure.tooManyLivePlaylists }
            return
        }
        guard let expectedRegister = edit.expectedRegister,
              case .object(let register) = expectedRegister,
              let originalValue = register["value"],
              case .supported(let original) = projection(field: edit.field, value: originalValue), original.id == id else {
            throw Failure.unsupportedOriginal
        }
        if edit.value == .null { return } // Delete is a retained tombstone for an existing known v1 value.
        guard case .supported(let replacement) = projection(field: edit.field, value: edit.value), replacement.id == id else {
            throw Failure.invalidDocument
        }
    }

    static func encodedValue(_ document: Document) throws -> VortxJSON {
        guard validName(document.name),
              document.entries.count <= PlaybackTitleQueuePolicy.capacity,
              Set(document.entries.map(\.id)).count == document.entries.count else { throw Failure.invalidDocument }
        let rows: [VortxJSON] = document.entries.map { entry in
            var row: [String: VortxJSON] = [
                "entryID": .string(entry.id.uuidString.lowercased()),
                "contentID": .string(entry.candidate.contentID),
                "type": .string(entry.candidate.type),
                "title": .string(entry.candidate.title)
            ]
            if let hint = entry.candidate.videoIDHint { row["videoIDHint"] = .string(hint) }
            if let label = entry.candidate.episodeLabel { row["episodeLabel"] = .string(label) }
            return .object(row)
        }
        let value: VortxJSON = .object([
            "schema": .integer(1),
            "id": .string(document.id.uuidString.lowercased()),
            "name": .string(document.name),
            "entries": .array(rows)
        ])
        guard boundedJSONCost(value) != nil else { throw Failure.oversized }
        return value
    }

    /// Bounded exact register encoding for receipt identity. Call only after validating the carrier
    /// register envelope; never serialize an unbounded caller-supplied VortxJSON first.
    static func canonicalReceiptRegister(_ raw: VortxJSON) -> Data? {
        guard boundedRegisterValue(raw) != nil,
              let bytes = try? VortxNativeHostFieldEvidence.canonicalData(raw),
              bytes.count <= maximumRegisterBytes else { return nil }
        return bytes
    }

    /// Validate the complete observed register before the raw CAS serializer/equality helper runs.
    /// Exact carrier shape bounds metadata; the full-tree walk also rejects deep/cyclic future extras.
    private static func boundedRegisterValue(_ raw: VortxJSON) -> VortxJSON? {
        guard boundedJSONCost(raw, maximum: maximumRegisterBytes) != nil,
              case .object(let register) = raw,
              Set(register.keys) == Set(["clock", "actor", "value"]),
              case .string(let actor) = register["actor"],
              VortxNativeHostPreferences.validActor(actor),
              let value = register["value"], boundedJSONCost(value) != nil else { return nil }
        let validClock: Bool
        switch register["clock"] {
        case .integer(let clock): validClock = clock >= 0 && UInt64(clock) <= VortxNativeHostPreferences.maxClock
        case .unsigned(let clock): validClock = clock <= VortxNativeHostPreferences.maxClock
        default: validClock = false
        }
        guard validClock else { return nil }
        switch value {
        case .null, .object: return value
        default: return nil
        }
    }

    /// Serializer-independent conservative JSON cost. The iterative walk bounds depth and total
    /// value/key nodes before any serializer runs, and its string costs cover raw UTF-8 and escaped
    /// JSON spellings used by either platform's encoder.
    private static func boundedJSONCost(_ root: VortxJSON, maximum: Int = maximumValueBytes) -> Int? {
        var pending: [(VortxJSON, Int)] = [(root, 0)]
        var nodes = 1
        var cost = 0

        func add(_ amount: Int) -> Bool {
            guard amount >= 0, amount <= maximum - cost else { return false }
            cost += amount
            return true
        }
        func addString(_ text: String) -> Bool {
            guard add(2) else { return false } // quotes
            for scalar in text.unicodeScalars {
                let value = scalar.value
                let escapedCost: Int
                switch value {
                case 0x22, 0x2F, 0x5C: escapedCost = 2 // quote, slash, backslash
                case 0x00...0x1F, 0x7F...0x9F: escapedCost = 6
                case 0x00...0x7F: escapedCost = 1
                case 0x80...0xFFFF: escapedCost = 6
                default: escapedCost = 12 // escaped UTF-16 surrogate pair
                }
                guard add(escapedCost) else { return false }
            }
            return true
        }

        while let (value, depth) = pending.popLast() {
            switch value {
            case .object(let fields):
                let count = fields.count
                guard count <= (maximumJSONNodes - nodes) / 2,
                      count == 0 || depth < maximumJSONDepth,
                      add(2) else { return nil } // braces
                nodes += count * 2 // each property key and value counts as a node
                var first = true
                for (key, child) in fields {
                    if !first, !add(1) { return nil }
                    first = false
                    guard addString(key), add(1) else { return nil } // key and colon
                    pending.append((child, depth + 1))
                }
            case .array(let values):
                let count = values.count
                guard count <= maximumJSONNodes - nodes,
                      count == 0 || depth < maximumJSONDepth,
                      add(2) else { return nil } // brackets
                nodes += count
                for (index, child) in values.enumerated() {
                    if index > 0, !add(1) { return nil }
                    pending.append((child, depth + 1))
                }
            case .string(let text):
                guard addString(text) else { return nil }
            case .integer(_), .unsigned(_):
                guard add(64) else { return nil } // shared conservative number allowance
            case .number(let number):
                guard number.isFinite, add(64) else { return nil }
            case .bool(let value):
                guard add(value ? 4 : 5) else { return nil }
            case .null:
                guard add(4) else { return nil }
            }
        }
        return cost
    }

    private static func isIntegerOne(_ value: VortxJSON) -> Bool {
        switch value {
        case .integer(1), .unsigned(1): return true
        default: return false
        }
    }

    private static func validName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !trimmed.isEmpty && value.utf8.count <= 160
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
