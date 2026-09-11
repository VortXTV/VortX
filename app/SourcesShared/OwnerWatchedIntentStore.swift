import Foundation

/// Account-scoped causal watched intent for the owner profile. The engine remains local playback
/// bookkeeping; this is the exact per-title/per-video sync carrier for explicit watch and unwatch.
enum OwnerWatchedIntentStore {
    struct Entry: Codable, Equatable { let titleID: String; let videoID: String; let watched: Bool; let updatedAt: Double; let actor: String }
    private static let keyPrefix = "vortx.owner.watchedIntent.v1."
    private static let actorPrefix = "vortx.owner.watchedIntent.actor.v1."
    private static var ownerID: String?
    private static var cachedOwnerID: String?
    private static var cache: [String: Entry] = [:]
    private static let cacheLock = NSLock()
    // A long-running account can legitimately exceed a few thousand episode intents. This is a
    // malformed-document safety ceiling, not a transport trim; writers preserve all known rows.
    private static let maximumRows = 50_000
    @MainActor static func bind(ownerID raw: String?) {
        guard let raw, let scope = CredentialScope(canonicalRemoteAccountID: raw) else {
            ownerID = nil; cacheLock.lock(); cachedOwnerID = nil; cache = [:]; cacheLock.unlock(); return
        }
        let nextOwner = scope.keychainOwnerID
        let nextCache = load(owner: nextOwner)
        // Publish identity and its decoded snapshot together. Readers reject a snapshot whose owner
        // does not match their current credential capture during a switch-before-bind window.
        cacheLock.lock(); ownerID = nextOwner; cachedOwnerID = nextOwner; cache = nextCache; cacheLock.unlock()
    }
    private static var key: String? { ownerID.map { keyPrefix + $0 } }
    private static var actorKey: String? { ownerID.map { actorPrefix + $0 } }
    private static func id(_ title: String, _ video: String) -> String { title + "\u{1f}" + video }
    private static func actor() -> String? {
        guard let actorKey else { return nil }
        if let value = UserDefaults.standard.string(forKey: actorKey), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased(); UserDefaults.standard.set(value, forKey: actorKey); return value
    }
    private static func load(owner: String) -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + owner),
              let value = try? JSONDecoder().decode([String: Entry].self, from: data),
              value.count <= maximumRows else { return [:] }
        return value.reduce(into: [:]) { result, pair in
            let entry = pair.value
            guard valid(entry.titleID), valid(entry.videoID), validActor(entry.actor),
                  entry.updatedAt.isFinite, entry.updatedAt > 0 else { return }
            let canonical = id(entry.titleID, entry.videoID)
            if wins(entry, over: result[canonical]) { result[canonical] = entry }
        }
    }
    private static func entries() -> [String: Entry] {
        let capture = CredentialScopeRegistry.shared.capture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return [:] }
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard cachedOwnerID == capture.scope.keychainOwnerID else { return [:] }
        return cache
    }
    private static func save(_ value: [String: Entry]) {
        guard let key, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
        cacheLock.lock(); cache = value; cacheLock.unlock()
    }
    @discardableResult @MainActor static func record(titleID: String, videoID: String, watched: Bool,
                                                     capture: CredentialScopeRegistry.Capture = CredentialScopeRegistry.shared.capture()) -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(capture), capture.scope.keychainOwnerID == ownerID,
              valid(titleID), valid(videoID), let actor = actor() else { return false }
        var all = entries(); let key = id(titleID, videoID); let prior = all[key]
        all[key] = Entry(titleID: titleID, videoID: videoID, watched: watched,
                          updatedAt: max(Date().timeIntervalSince1970 * 1000, (prior?.updatedAt ?? 0) + 1), actor: actor)
        save(all); return true
    }
    @discardableResult @MainActor static func mergeWire(_ raw: Any?, capture: CredentialScopeRegistry.Capture = CredentialScopeRegistry.shared.capture()) -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(capture), capture.scope.keychainOwnerID == ownerID else { return false }
        guard let rows = raw as? [String: [String: Any]], !rows.isEmpty, rows.count <= maximumRows else { return false }
        var all = entries(); var changed = false
        for row in rows.values {
            guard let t = row["t"] as? String, valid(t), let v = row["v"] as? String, valid(v),
                  let w = row["w"] as? Bool, let a = row["a"] as? String, validActor(a) else { continue }
            let u = (row["u"] as? NSNumber)?.doubleValue ?? (row["u"] as? Double) ?? 0
            let incoming = Entry(titleID: t, videoID: v, watched: w, updatedAt: u, actor: a); guard u.isFinite, u > 0 else { continue }
            let key = id(t, v); if wins(incoming, over: all[key]) { all[key] = incoming; changed = true }
        }
        if changed { save(all) }; return changed
    }
    static func wire(merging raw: Any?) -> [String: [String: Any]] {
        var all = entries()
        if let rows = raw as? [String: [String: Any]], rows.count <= maximumRows { for row in rows.values {
            guard let t = row["t"] as? String, valid(t), let v = row["v"] as? String, valid(v), let w = row["w"] as? Bool, let a = row["a"] as? String, validActor(a) else { continue }
            let u = (row["u"] as? NSNumber)?.doubleValue ?? (row["u"] as? Double) ?? 0; guard u.isFinite, u > 0 else { continue }
            let e = Entry(titleID: t, videoID: v, watched: w, updatedAt: u, actor: a); let key = id(t, v)
            if wins(e, over: all[key]) { all[key] = e }
        }}
        return Dictionary(uniqueKeysWithValues: all.map { key, e in (key, ["t": e.titleID, "v": e.videoID, "w": e.watched, "u": e.updatedAt, "a": e.actor]) })
    }
    static func watchedTitleIDs() -> Set<String> { Set(entries().values.filter(\.watched).map(\.titleID)) }
    static func watchedVideoIDs(forTitle titleID: String) -> Set<String> { Set(entries().values.filter { $0.titleID == titleID && $0.watched }.map(\.videoID)) }
    static func effectiveVideoIDs(forTitle titleID: String, engine: Set<String>, knownVideoIDs: Set<String> = []) -> Set<String> {
        let scoped = entries().values.filter { $0.titleID == titleID }
        let whole = scoped.filter { $0.videoID == titleID }.max { lhs, rhs in !wins(lhs, over: rhs) }
        // A whole-title action is a causal baseline over the detail's known episode inventory. A
        // newer exact episode action may refine it; older episode rows cannot resurrect a later
        // whole-title unwatch.
        var result: Set<String> = whole.map { $0.watched ? knownVideoIDs : [] } ?? engine
        for entry in scoped where entry.videoID != titleID {
            guard whole == nil || wins(entry, over: whole) else { continue }
            if entry.watched { result.insert(entry.videoID) } else { result.remove(entry.videoID) }
        }
        return result
    }
    static func effectiveTitleIDs(engine: Set<String>) -> Set<String> {
        var result = engine
        for entry in entries().values where entry.videoID == entry.titleID {
            if entry.watched { result.insert(entry.titleID) } else { result.remove(entry.titleID) }
        }
        return result
    }
    private static func wins(_ incoming: Entry, over existing: Entry?) -> Bool { guard let existing else { return true }; return incoming.updatedAt > existing.updatedAt || (incoming.updatedAt == existing.updatedAt && incoming.actor > existing.actor) }
    private static func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && value.rangeOfCharacter(from: .controlCharacters) == nil }
    private static func validActor(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && value.rangeOfCharacter(from: .controlCharacters) == nil }
}
