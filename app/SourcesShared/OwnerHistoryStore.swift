import Foundation
import CoreFoundation

/// Account-scoped, membership-neutral owner playback history.  Unlike the engine library this
/// store is written only by an accepted, identity-bearing player progress callback.  It therefore
/// survives a cold device without treating an ordinary library row, a manual watched marker, or a
/// temporary engine item as evidence that the owner watched something.
///
/// Wire contract: `doc.vortx.byProfile[ownerUUID].ownerHistory` is an ARRAY.  Each valid row is
/// LWW by `(type, id)` and its real `eventEpochMs`; an equal clock retains the peer representation.
/// Unknown/malformed peer rows are opaque and are carried through untouched rather than being used
/// to delete a valid local row.  This lets newer Android rows coexist with older Apple clients.
enum OwnerHistoryStore {
    private static let keyPrefix = "vortx.owner.history.v1."
    private static let maximumRows = 10_000
    private static let maximumStringBytes = 1_024
    // Every production caller is on the credential/main-actor lane; this annotation keeps the
    // Foundation-only policy executable under strict concurrency without pretending UserDefaults is
    // a Sendable store.  Credential captures still fence every mutation/read at the API boundary.
    nonisolated(unsafe) private static var ownerID: String?

    static func bind(ownerID rawOwnerID: String?) {
        guard let rawOwnerID,
              let scope = CredentialScope(canonicalRemoteAccountID: rawOwnerID) else {
            ownerID = nil
            return
        }
        ownerID = scope.keychainOwnerID
    }

    private static var storageKey: String? { ownerID.map { keyPrefix + $0 } }

    /// Record only a player-originated progress event.  `positionSeconds == 0` is deliberately
    /// valid: a real restart/rewind is an observation, not an absence of history.
    @discardableResult
    @MainActor
    static func recordPlayback(
        titleID: String,
        type: String,
        name: String,
        poster: String?,
        videoID: String,
        positionSeconds: Double,
        durationSeconds: Double,
        capture: CredentialScopeRegistry.Capture = CredentialScopeRegistry.shared.capture()
    ) -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              capture.scope.keychainOwnerID == ownerID,
              validString(titleID), validString(name), validString(videoID),
              validType(type), validSeconds(positionSeconds), validSeconds(durationSeconds),
              durationSeconds > 0 else { return false }

        let now = Date()
        let eventEpochMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        guard eventEpochMs > 0 else { return false }
        let row: [String: Any] = [
            "id": titleID,
            "type": type,
            "name": name,
            "poster": poster ?? "",
            "v": videoID,
            "t": positionSeconds,
            "d": durationSeconds,
            "lastWatched": makeISO8601(fractional: true).string(from: now),
            "eventEpochMs": eventEpochMs
        ]
        return mergeLocal(row)
    }

    /// Fold a successful remote owner-history section into the local cache.  Absence, a wrong type,
    /// and an oversized/malformed payload all fail closed: they never empty the current cache.
    @discardableResult
    static func mergeWire(
        _ raw: Any?,
        capture: CredentialScopeRegistry.Capture = CredentialScopeRegistry.shared.capture()
    ) -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              capture.scope.keychainOwnerID == ownerID,
              let rows = raw as? [[String: Any]], rows.count <= maximumRows else { return false }
        let before = load()
        let after = merge(local: before, peer: rows).local
        // Admission is deliberately bounded. A full peer carrier plus disjoint local rows must
        // not turn into a cache that a later reader rejects as empty.
        guard after.count <= maximumRows else { return false }
        guard !sameRows(before, after) else { return false }
        save(after)
        return true
    }

    /// Produce the canonical wire array while preserving every opaque peer row from `raw`.  This
    /// function does not mutate local state: sync-up must not make a failed/stale read look accepted.
    static func wire(merging raw: Any?) -> [[String: Any]]? {
        // A missing carrier is safe to create only when this device has an accepted local event.
        // An existing non-array, mixed, or oversized carrier is opaque: nil tells the summary
        // writer to retain it unchanged rather than replacing it with a local subset.
        guard let raw else {
            let local = load()
            return local.isEmpty ? nil : local
        }
        guard let peer = raw as? [[String: Any]], peer.count <= maximumRows else { return nil }
        let merged = merge(local: load(), peer: peer).wire
        // Do not append local rows to a carrier that has reached the bounded contract.
        return merged.count <= maximumRows ? merged : nil
    }

    /// Valid local/remote rows only, for recommendation and resume hydration.  Opaque rows remain
    /// durable on export but never become UI/history evidence.
    static func validRows() -> [[String: Any]] {
        load().filter { validRow($0) != nil }
    }

    private static func mergeLocal(_ row: [String: Any]) -> Bool {
        guard let candidate = validRow(row) else { return false }
        var rows = load()
        let key = candidate.identity
        if let index = rows.firstIndex(where: { validRow($0)?.identity == key }) {
            guard candidate.clock > (validRow(rows[index])?.clock ?? 0) else { return false }
            rows[index] = row
        } else {
            guard rows.count < maximumRows else { return false }
            rows.append(row)
        }
        save(rows)
        return true
    }

    private static func merge(local: [[String: Any]], peer: [[String: Any]]) -> (local: [[String: Any]], wire: [[String: Any]]) {
        var localByIdentity: [String: [String: Any]] = [:]
        var localOrder: [String] = []
        for row in local {
            guard let parsed = validRow(row) else { continue }
            if let current = localByIdentity[parsed.identity],
               parsed.clock <= (validRow(current)?.clock ?? 0) { continue }
            if localByIdentity[parsed.identity] == nil { localOrder.append(parsed.identity) }
            localByIdentity[parsed.identity] = row
        }

        var peerByIdentity: [String: [String: Any]] = [:]
        var peerOrder: [String] = []
        var opaque: [[String: Any]] = []
        for row in peer {
            guard let parsed = validRow(row) else { opaque.append(row); continue }
            if let current = peerByIdentity[parsed.identity] {
                // Equal peer clocks preserve the earliest peer row verbatim, which is deterministic and
                // avoids rewriting fields introduced by a newer client.
                if parsed.clock <= (validRow(current)?.clock ?? 0) { continue }
            } else {
                peerOrder.append(parsed.identity)
            }
            peerByIdentity[parsed.identity] = row
        }

        var merged = localByIdentity
        for identity in peerOrder {
            guard let incoming = peerByIdentity[identity], let parsed = validRow(incoming) else { continue }
            if let current = merged[identity], let existing = validRow(current) {
                // Peer wins ties by contract.  This is important for equal-clock cross-platform rows
                // carrying Android-only fields Apple cannot reconstruct.
                if parsed.clock >= existing.clock { merged[identity] = incoming }
            } else {
                merged[identity] = incoming
            }
        }

        var ordered: [[String: Any]] = opaque
        var emitted = Set<String>()
        for identity in peerOrder + localOrder where emitted.insert(identity).inserted {
            if let row = merged[identity] { ordered.append(row) }
        }
        let persisted = ordered.compactMap { validRow($0) == nil ? nil : $0 }
        return (persisted, ordered)
    }

    private struct ParsedRow { let identity: String; let clock: Double }

    private static func validRow(_ row: [String: Any]) -> ParsedRow? {
        guard let id = row["id"] as? String, validString(id),
              let type = row["type"] as? String, validType(type),
              let name = row["name"] as? String, validString(name),
              let video = row["v"] as? String, validString(video),
              let t = number(row["t"]), validSeconds(t),
              let d = number(row["d"]), validSeconds(d), d > 0,
              let clock = number(row["eventEpochMs"]), validEventEpochMs(clock),
              let lastWatched = row["lastWatched"] as? String, parseISO8601(lastWatched) > 0 else { return nil }
        // Android's `watched` is an opaque String/null marker. The other flags stay strict so
        // Foundation cannot mistake numeric JSON 0/1 for a Boolean.
        if let watched = row["watched"], !isNull(watched), !(watched is String) { return nil }
        for key in ["currentVideoWatched", "wholeTitleWatched"]
        where row[key].map({ !isNull($0) }) == true {
            guard isStrictBoolean(row[key]) else { return nil }
        }
        if let timesWatched = row["timesWatched"], !isNull(timesWatched),
           !validUnsigned32(timesWatched) { return nil }
        _ = t // validates zero as a genuine observation rather than a missing value
        return ParsedRow(identity: type + "\u{1f}" + id, clock: clock)
    }

    private static func load() -> [[String: Any]] {
        guard let storageKey,
              let data = UserDefaults.standard.data(forKey: storageKey),
              let object = try? JSONSerialization.jsonObject(with: data),
              let rows = object as? [[String: Any]], rows.count <= maximumRows else { return [] }
        return rows
    }

    private static func save(_ rows: [[String: Any]]) {
        guard let storageKey,
              let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func sameRows(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    private static func validType(_ value: String) -> Bool { value == "movie" || value == "series" }
    private static func validString(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumStringBytes
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func validSeconds(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 2_000_000
    }
    private static func validEventEpochMs(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value.rounded(.towardZero) == value
            && value <= 9_007_199_254_740_991 // exactly representable JSON integer
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }
    private static func isStrictBoolean(_ raw: Any?) -> Bool {
        guard let value = raw as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }
    private static func validUnsigned32(_ raw: Any) -> Bool {
        guard let value = number(raw), value.isFinite,
              value.rounded(.towardZero) == value else { return false }
        return value >= 0 && value <= Double(UInt32.max)
    }
    private static func isNull(_ raw: Any) -> Bool { raw is NSNull }
    private static func parseISO8601(_ value: String) -> Double {
        guard !value.isEmpty,
              let date = makeISO8601(fractional: true).date(from: value)
                ?? makeISO8601(fractional: false).date(from: value) else { return 0 }
        return date.timeIntervalSince1970 * 1000
    }
    private static func makeISO8601(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
