import Foundation

/// Same-session retention for the existing private Trakt cache envelope. Unknown values retain their
/// original JSON bytes at their original member/queue paths; they are not interpreted as actions.
/// The raw range utility reuses the archive's existing lexical scanner without changing its policy.
struct TraktSyncSnapshotEnvelope {
    enum Failure: Error { case malformed, wrongSession, excessive }
    static let maximumBytes = 32 * 1024 * 1024
    private static let maximumOpaqueBytes = 1024 * 1024
    private static let knownKeys: Set<String> = [
        "sessionID", "watchedIDs", "watchedEpisodeKeys", "pendingPushes",
        "lastActivityFingerprint", "watchedReadVersion", "watchedShowInventory", "watchedInventoryRevision"
    ]
    private static let pushKeys: Set<String> = [
        "kind", "isSeries", "imdb", "tmdb", "season", "episode",
        "sessionID", "rating", "ratedAtEpoch"
    ]
    private let sessionID: TraktSessionID
    private let unknown: [VortxNativeBootstrapArchive.RawJSONMember]
    private enum QueueRow { case known(Data), opaque(Data) }
    private let queueLayout: [QueueRow]

    /// Produces only the understood projection for the existing Codable decoder. Unknown queue
    /// actions, unknown row fields and malformed/ownerless rows stay raw and never reach drainQueue.
    static func prepare(
        _ data: Data, expectedSession: TraktSessionID, knownRowKey: (Data) -> Data?
    ) throws -> (owned: Data, retention: Self) {
        let members = try VortxNativeBootstrapArchive.rawJSONObjectMembers(data, maximumBytes: maximumBytes)
        guard members.count <= 512,
              let session = members.first(where: { $0.key == "sessionID" }),
              let decoded = try? JSONDecoder().decode(TraktSessionID.self, from: session.valueJSON) else {
            throw Failure.malformed
        }
        guard decoded == expectedSession else { throw Failure.wrongSession }
        guard let pending = members.first(where: { $0.key == "pendingPushes" }) else { throw Failure.malformed }
        let rows = try VortxNativeBootstrapArchive.rawJSONArrayValues(pending.valueJSON, maximumBytes: maximumBytes)
        guard rows.count <= 400 else { throw Failure.excessive }
        var understood: [Data] = []
        var quarantined: [Data] = []
        var queueLayout: [QueueRow] = []
        for row in rows {
            if let fields = try? VortxNativeBootstrapArchive.rawJSONObjectMembers(row, maximumBytes: maximumBytes),
               Set(fields.map(\.key)).isSubset(of: pushKeys), let key = knownRowKey(row) {
                understood.append(row)
                queueLayout.append(.known(key))
            } else {
                quarantined.append(row)
                queueLayout.append(.opaque(row))
            }
        }
        guard understood.count <= 200, quarantined.count <= 200 else { throw Failure.excessive }
        let unknown = members.filter { !knownKeys.contains($0.key) }
        var bytes = 0
        for value in unknown.map({ $0.keyJSON.count + $0.valueJSON.count }) + quarantined.map(\.count) {
            guard value <= maximumOpaqueBytes - bytes else { throw Failure.excessive }
            bytes += value
        }
        let retention = Self(sessionID: expectedSession, unknown: unknown, queueLayout: queueLayout)
        let owned = object(members.filter { knownKeys.contains($0.key) }.map {
            ($0.keyJSON, $0.key == "pendingPushes" ? array(understood) : $0.valueJSON)
        })
        return (owned, retention)
    }

    /// Known generated fields are authoritative, including omissions. Never resurrect an old owned
    /// cursor/version or key set. Retain original queue order for surviving rows and byte-identical
    /// opaque rows. Removed known pushes stay removed; genuinely new known pushes append after them.
    func merging(
        _ owned: Data, expectedSession: TraktSessionID, knownRowKey: (Data) -> Data?
    ) throws -> Data {
        guard sessionID == expectedSession else { throw Failure.wrongSession }
        let members = try VortxNativeBootstrapArchive.rawJSONObjectMembers(owned, maximumBytes: Self.maximumBytes)
        guard members.allSatisfy({ Self.knownKeys.contains($0.key) }),
              let session = members.first(where: { $0.key == "sessionID" }),
              try JSONDecoder().decode(TraktSessionID.self, from: session.valueJSON) == expectedSession,
              let pending = members.first(where: { $0.key == "pendingPushes" }) else { throw Failure.malformed }
        let knownRows = try VortxNativeBootstrapArchive.rawJSONArrayValues(
            pending.valueJSON, maximumBytes: Self.maximumBytes
        )
        guard knownRows.count <= 200 else { throw Failure.excessive }
        let newKeys = knownRows.map(knownRowKey)
        guard newKeys.allSatisfy({ $0 != nil }) else { throw Failure.malformed }
        var used = Set<Int>()
        var queue: [Data] = []
        for row in queueLayout {
            switch row {
            case .opaque(let bytes): queue.append(bytes)
            case .known(let key):
                if let index = knownRows.indices.first(where: { !used.contains($0) && newKeys[$0] == key }) {
                    queue.append(knownRows[index]); used.insert(index)
                }
            }
        }
        for index in knownRows.indices where !used.contains(index) { queue.append(knownRows[index]) }
        let pairs = members.map {
            ($0.keyJSON, $0.key == "pendingPushes" ? Self.array(queue) : $0.valueJSON)
        } + unknown.map { ($0.keyJSON, $0.valueJSON) }
        let data = Self.object(pairs)
        guard data.count <= Self.maximumBytes else { throw Failure.excessive }
        return data
    }

    private static func array(_ values: [Data]) -> Data {
        var result = Data("[".utf8)
        for (index, value) in values.enumerated() {
            if index != 0 { result.append(44) }
            result.append(value)
        }
        result.append(93)
        return result
    }
    private static func object(_ pairs: [(Data, Data)]) -> Data {
        var result = Data("{".utf8)
        for (index, pair) in pairs.enumerated() {
            if index != 0 { result.append(44) }
            result.append(pair.0); result.append(58); result.append(pair.1)
        }
        result.append(125)
        return result
    }
}
