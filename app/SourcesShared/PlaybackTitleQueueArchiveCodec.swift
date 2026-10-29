import Foundation

/// The durable wire format contains only bounded catalog identity and display text. It deliberately has no
/// owner, profile, account, credential, source URL, header, lease, route, ticket, or playback-progress field.
enum PlaybackTitleQueueArchiveCodec {
    static let schema = 1
    static let maximumBytes = 512 * 1024

    enum Failure: Error, Equatable, Sendable {
        case oversized
        case malformed
        case unsupportedSchema
        case invalidShape
        case invalidEntry
        case duplicateEntry
        case tooManyEntries
    }

    private struct Document: Codable {
        let schema: Int
        let entries: [Record]
    }

    private struct Record: Codable {
        let entryID: String
        let contentID: String
        let type: String
        let title: String
        let videoIDHint: String?
        let episodeLabel: String?

        init(_ entry: PlaybackTitleQueuePolicy.Entry) {
            entryID = entry.id.uuidString.lowercased()
            contentID = entry.candidate.contentID
            type = entry.candidate.type
            title = entry.candidate.title
            videoIDHint = entry.candidate.videoIDHint
            episodeLabel = entry.candidate.episodeLabel
        }
    }

    static func encode(_ entries: [PlaybackTitleQueuePolicy.Entry]) throws -> Data {
        guard entries.count <= PlaybackTitleQueuePolicy.capacity,
              Set(entries.map(\.id)).count == entries.count else {
            throw entries.count > PlaybackTitleQueuePolicy.capacity ? Failure.tooManyEntries : Failure.duplicateEntry
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(schema: schema, entries: entries.map(Record.init)))
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.oversized }
        return data
    }

    static func decode(_ data: Data) throws -> [PlaybackTitleQueuePolicy.Entry] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.oversized }
        try validateStrictJSONShape(data)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw Failure.malformed
        }
        guard document.schema == schema else { throw Failure.unsupportedSchema }
        guard document.entries.count <= PlaybackTitleQueuePolicy.capacity else { throw Failure.tooManyEntries }
        // This is a brand-new format, so canonical sorted-key JSON is part of schema v1. Re-encoding must
        // reproduce every byte. That rejects duplicate keys, alternate UUID spelling, ignored fields,
        // whitespace variants and future encodings without adding a second JSON parser.
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard (try? canonical.encode(document)) == data else { throw Failure.invalidShape }
        var seen = Set<UUID>()
        var entries: [PlaybackTitleQueuePolicy.Entry] = []
        entries.reserveCapacity(document.entries.count)
        for record in document.entries {
            guard let entryID = UUID(uuidString: record.entryID),
                  record.entryID == entryID.uuidString.lowercased() else { throw Failure.invalidEntry }
            guard seen.insert(entryID).inserted else { throw Failure.duplicateEntry }
            guard let candidate = PlaybackTitleQueuePolicy.Candidate(
                contentID: record.contentID,
                type: record.type,
                title: record.title,
                videoIDHint: record.videoIDHint,
                episodeLabel: record.episodeLabel
            ) else { throw Failure.invalidEntry }
            entries.append(.init(id: entryID, candidate: candidate))
        }
        return entries
    }

    /// Codable intentionally ignores unknown keys. A future schema must therefore fail closed here so an old
    /// binary preserves those bytes instead of decoding and later replacing a document it does not understand.
    private static func validateStrictJSONShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.malformed
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == Set(["schema", "entries"]),
              root["schema"] is NSNumber,
              let rows = root["entries"] as? [[String: Any]],
              rows.count <= PlaybackTitleQueuePolicy.capacity else {
            throw Failure.invalidShape
        }
        let required: Set<String> = ["entryID", "contentID", "type", "title"]
        let allowed = required.union(["videoIDHint", "episodeLabel"])
        for row in rows {
            let keys = Set(row.keys)
            guard required.isSubset(of: keys), keys.isSubset(of: allowed),
                  row["entryID"] is String, row["contentID"] is String,
                  row["type"] is String, row["title"] is String,
                  row["videoIDHint"].map({ $0 is String }) ?? true,
                  row["episodeLabel"].map({ $0 is String }) ?? true else {
                throw Failure.invalidShape
            }
        }
    }
}

/// A queue edit is a value transaction: mutation and canonical encoding finish before the live queue or its
/// route/token state changes. The caller must still admit payload to the exact durability attachment.
struct PlaybackTitleQueuePreparedMutation {
    let policy: PlaybackTitleQueuePolicy
    let payload: Data

    fileprivate init(policy: PlaybackTitleQueuePolicy, payload: Data) {
        self.policy = policy
        self.payload = payload
    }
}

enum PlaybackTitleQueueMutationTransaction {
    enum Result {
        case unchanged
        case rejected(PlaybackTitleQueueArchiveCodec.Failure)
        case prepared(PlaybackTitleQueuePreparedMutation)
    }

    static func prepare(
        current: PlaybackTitleQueuePolicy,
        mutation: (inout PlaybackTitleQueuePolicy) -> Bool
    ) -> Result {
        var staged = current
        guard mutation(&staged) else { return .unchanged }
        do {
            let payload = try PlaybackTitleQueueArchiveCodec.encode(staged.durableEntries)
            return .prepared(.init(policy: staged, payload: payload))
        } catch let failure as PlaybackTitleQueueArchiveCodec.Failure {
            return .rejected(failure)
        } catch {
            return .rejected(.invalidShape)
        }
    }
}

/// The player first proves the exact live queue token/media owner. This pure decision then keeps an owned EOF
/// claimed even when durability cannot admit the finish, while forbidding any queue advance in that state.
enum PlaybackTitleQueueOwnedEOFPolicy {
    enum Decision: Equatable {
        case notOwned
        case claimWithoutMutation
        case stageDurableFinish
    }

    static func decide(exactActiveOwned: Bool, durabilityCanAdmit: Bool) -> Decision {
        guard exactActiveOwned else { return .notOwned }
        return durabilityCanAdmit ? .stageDurableFinish : .claimWithoutMutation
    }
}


/// Write-slot policy only. Live attachment/owner checks and exact canonical payload validation precede it.
enum PlaybackTitleQueueWriteAdmissionPolicy {
    enum Decision: Equatable {
        case reusePending(Int)
        case reuseSaved
        case appendWrite
        case reject
    }

    static func decide(payloadMatchesProjected: Bool, payloadMatchesCertified: Bool,
                       partitionPending: Int, totalPending: Int, capacity: Int) -> Decision {
        guard capacity > 0, partitionPending >= 0, totalPending >= partitionPending,
              totalPending <= capacity else { return .reject }
        if payloadMatchesProjected {
            if partitionPending > 0 { return .reusePending(partitionPending) }
            return payloadMatchesCertified ? .reuseSaved : .reject
        }
        return totalPending < capacity ? .appendWrite : .reject
    }
}
