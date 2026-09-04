import Foundation
import CryptoKit
import os

/// Wave 4: local, per-device cache of the OWNER library's resume offsets (id -> seconds), sourced from the
/// VortX account doc (`doc.vortx.library`). stremio-core exposes NO action to inject a saved timeOffset back
/// into its own library bucket (only AddToLibrary, which starts an item at time 0, RewindLibraryItem, and the
/// Player's live TimeChanged), so a cold / reinstalled / post-import-Logout device re-adds owner titles at 0
/// and would otherwise lose every resume position. This cache is the VortX-owned resume source that CoreBridge's
/// resume reads consult when the engine's own bucket has no positive offset for a title, so a second VortX-only
/// device resumes exactly where device A left off.
///
/// Read-only convenience for playback: it never gates library membership and never deletes a title. Entries are
/// refreshed from the authoritative doc on every cold recovery, so a stale value self-heals on the next sync.
enum OwnerResumeStore {
    private static let keyPrefix = "vortx.owner.resumeCache.v2."
    private static let receiptKeyPrefix = "vortx.owner.resumeCache.readdReceipt.v2."
    /// Process-local ownership prevents the previous VortX account's UserDefaults rows from being readable
    /// during startup, sign-out, or an account transition. The rows themselves remain account-namespaced so
    /// returning to the same account can still use its own cache after a fresh authoritative refresh.
    private static var ownerID: String?

    static func bind(ownerID rawOwnerID: String?) {
        guard let rawOwnerID, let scope = CredentialScope(canonicalRemoteAccountID: rawOwnerID) else {
            ownerID = nil
            return
        }
        ownerID = scope.keychainOwnerID
    }

    private static var storageKeys: (cache: String, receipt: String)? {
        guard let ownerID else { return nil }
        return (keyPrefix + ownerID, receiptKeyPrefix + ownerID)
    }

    /// A cached resume position: `t`/`d` in whole seconds, `v` = the resume video id (episode) for a series.
    struct Entry { let t: Double; let d: Double; let v: String? }

    /// Upsert owner-library resume entries from a pulled document. `t`/`d` are in SECONDS. A library page is
    /// not a complete snapshot, so omission must never delete another title's cached resume. Explicit library
    /// tombstones evict removed entries through `evict(libraryIDs:)` instead.
    static func merge(_ entries: [(id: String, t: Double, d: Double, v: String?, lastWatched: String?)]) {
        guard !entries.isEmpty, let keys = storageKeys else { return }
        var map = (UserDefaults.standard.dictionary(forKey: keys.cache)) ?? [:]
        var receipts = (UserDefaults.standard.dictionary(forKey: keys.receipt)) ?? [:]
        for e in entries where !e.id.isEmpty {
            let id = LibraryTombstones.normalize(e.id)
            guard !id.isEmpty else { continue }
            if let addedAt = (receipts[id] as? NSNumber)?.doubleValue ?? (receipts[id] as? Double),
               !(lastWatchedMilliseconds(e.lastWatched) > addedAt) {
                continue // Legacy/missing/older row cannot prove it post-dates the re-add.
            }
            receipts.removeValue(forKey: id)
            map[id] = ["t": e.t, "d": e.d, "v": e.v ?? ""]
        }
        UserDefaults.standard.set(map, forKey: keys.cache)
        if receipts.isEmpty { UserDefaults.standard.removeObject(forKey: keys.receipt) }
        else { UserDefaults.standard.set(receipts, forKey: keys.receipt) }
    }

    /// A removed-to-present transition invalidates prior progress even when its page omits the title. The
    /// receipt survives that omission and admits a later row only with the engine's causal lastWatched clock.
    static func recordReadds(_ addedAtByID: [String: Double]) {
        guard !addedAtByID.isEmpty, let keys = storageKeys else { return }
        var receipts = (UserDefaults.standard.dictionary(forKey: keys.receipt)) ?? [:]
        for (rawID, addedAt) in addedAtByID where addedAt.isFinite {
            let id = LibraryTombstones.normalize(rawID)
            if !id.isEmpty { receipts[id] = addedAt }
        }
        UserDefaults.standard.set(receipts, forKey: keys.receipt)
    }

    /// Evict cached positions for explicitly tombstoned owner-library ids. Tombstones use normalized identity,
    /// while the cache preserves the source id for playback, so compare normalized forms rather than assuming
    /// casing stays identical across a remove and a later document pull.
    static func evict(libraryIDs: Set<String>, clearingFence: Bool = false) {
        guard !libraryIDs.isEmpty, let keys = storageKeys else { return }
        let normalizedIDs = Set(libraryIDs.map(LibraryTombstones.normalize)).subtracting([""])
        guard !normalizedIDs.isEmpty else { return }
        if var map = UserDefaults.standard.dictionary(forKey: keys.cache) {
            let evicted = map.keys.filter { normalizedIDs.contains(LibraryTombstones.normalize($0)) }
            for id in evicted {
                map.removeValue(forKey: id)
            }
            if !evicted.isEmpty { UserDefaults.standard.set(map, forKey: keys.cache) }
        }
        guard clearingFence, var receipts = UserDefaults.standard.dictionary(forKey: keys.receipt) else { return }
        for id in receipts.keys.filter({ normalizedIDs.contains(LibraryTombstones.normalize($0)) }) {
            receipts.removeValue(forKey: id)
        }
        if receipts.isEmpty { UserDefaults.standard.removeObject(forKey: keys.receipt) }
        else { UserDefaults.standard.set(receipts, forKey: keys.receipt) }
    }

    private static func lastWatchedMilliseconds(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 0 }
        if let date = fractionalISO8601.date(from: value) ?? plainISO8601.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        let base = value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return (formatter.date(from: base.replacingOccurrences(of: "Z", with: ""))?.timeIntervalSince1970 ?? 0) * 1000
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The cached resume entry for an owner-library id, or nil when the cache has none.
    static func entry(forId id: String) -> Entry? {
        guard let keys = storageKeys,
              let map = UserDefaults.standard.dictionary(forKey: keys.cache),
              let raw = map[LibraryTombstones.normalize(id)] as? [String: Any] else { return nil }
        func seconds(_ v: Any?) -> Double {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            if let i = v as? Int { return Double(i) }
            return 0
        }
        let v = raw["v"] as? String
        return Entry(t: seconds(raw["t"]), d: seconds(raw["d"]), v: (v?.isEmpty == false) ? v : nil)
    }
}

/// One title's watch state inside a profile's private overlay: enough to render Continue Watching,
/// resume, and watched markers without touching the account's shared library.
struct WatchEntry: Codable, Equatable {
    var videoId: String?          // movie id, or imdbId:season:episode for the episode in progress
    var timeOffsetMs: Int
    var durationMs: Int
    var lastWatched: String       // ISO timestamp, orders the rail
    var name: String
    var type: String
    var poster: String?
    var watchedVideoIds: [String] = []

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(timeOffsetMs) / Double(durationMs), 0), 1)
    }
}

/// The LEGACY / optional Stremio-datastore transport for profiles and their watch history.
///
/// VortX (doc.vortx.* via VortXSyncManager) is now AUTHORITATIVE for the roster and the per-profile
/// overlay watch history. This transport is used for two things only: the one-time IMPORT read that
/// migrates a user's existing Stremio-datastore data into the VortX account, and, when the user opts into
/// the "also sync to Stremio" mirror (`alsoSyncToStremio`, default OFF), the legacy two-way Stremio sync.
/// The automatic Stremio WRITE is dormant by default. `repairPoisonedLibrary` still runs on every launch
/// as a permanent safety scan (an old build on the same account can still poison official library sync).
///
/// Transport: our OWN datastore collection. Official clients only ever pull the collections they
/// know ("libraryItem", ...), so documents in a different collection are invisible to them and
/// carry whatever shape we want.
///
/// HISTORY, do not repeat it: two earlier transports rode inside `libraryItem` documents. Custom
/// top-level fields were silently STRIPPED by the API's schema normalization, and smuggling JSON
/// into the schema string field `state.watched` PARSED in official apps' stremio-core as a
/// watched-bitfield and FAILED, which broke the library pull for the entire account in every
/// official Stremio app ("Serialization error: state.watched: invalid digit found in string").
/// `repairPoisonedLibrary` scrubs those documents and runs on every launch until clean.
enum ProfileSync {
    private static let api = "https://api.strem.io/api"
    private static let collection = "stremioxProfiles"     // our own, invisible to official clients
    private static let rosterID = "stremiox:profiles"
    private static let log = Logger(subsystem: "com.stremiox.app", category: "profilesync")

    /// UserDefaults key for the opt-in "also sync to Stremio" mirror (a future Settings toggle writes it).
    static let alsoSyncKey = "vortx.profiles.alsoSyncToStremio"
    /// Whether the app should ALSO write the roster + per-profile overlay watch history to the legacy Stremio
    /// account datastore. VortX (doc.vortx.*) is authoritative, so this is OFF by default and the automatic
    /// Stremio write stays dormant. It turns ON only when the user opts into the mirror. The one-time IMPORT
    /// read from Stremio is separate and always allowed (it is how existing data migrates into VortX).
    static var alsoSyncToStremio: Bool { UserDefaults.standard.bool(forKey: alsoSyncKey) }

    // MARK: Wave 4: one-time Stremio library import gate (VortX owns the library + Continue Watching)

    /// Per-Stremio-account flag: the engine's Stremio-synced OWNER library + Continue Watching have been
    /// captured into the VortX account doc (`doc.vortx.library`). Once set, the app stops LOADING the Stremio
    /// token into the stremio-core engine (`CoreBridge.bootstrapAuth`) and stops the direct Stremio progress
    /// writes (`StremioAccount.saveProgress`/`resumeOffset`). The engine then runs on its purely-LOCAL library
    /// bucket, which is ALREADY mirrored to `doc.vortx.library` (FLOOR union, never shrinks) and re-hydrated on
    /// cold devices, so nothing is lost. Keyed by a SHA-256 prefix of the authKey (the same shape as
    /// `repairDoneKey`) so the raw token never lands in UserDefaults and a DIFFERENT account re-imports.
    ///
    /// Non-destructive + idempotent: the flag ONLY records that the VortX copy exists; it never deletes a
    /// library item or a removal tombstone, and the library mirror keeps running regardless of this flag. A
    /// reinstall that clears the flag re-imports additively (union), so it can never lose a title. The Keychain
    /// token itself is never dropped here: the user can still Connect Stremio, or opt into `alsoSyncToStremio`.
    private static func libraryImportKey(_ authKey: String) -> String {
        let digest = SHA256.hash(data: Data(authKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "vortx.library.importedFromStremio.\(digest)"
    }

    /// True once THIS Stremio account's library has been imported into the VortX account doc.
    static func libraryImportedFromStremio(authKey: String) -> Bool {
        guard !authKey.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: libraryImportKey(authKey))
    }

    /// Record the completed one-time library import. Call ONLY after a confirmed, non-failed capture into the
    /// VortX account doc (see `VortXSyncManager.importOwnerLibraryFromStremioOnce`), never speculatively.
    static func markLibraryImportedFromStremio(authKey: String) {
        guard !authKey.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: libraryImportKey(authKey))
    }

    /// nil = not probed yet; false = the API refused our collection, cloud sync is disabled and
    /// profiles stay per-device (never fall back to libraryItem smuggling again).
    private(set) static var cloudAvailable: Bool?

    private static func watchID(_ profileID: UUID) -> String { "stremiox:watch:\(profileID.uuidString)" }

    // MARK: Launch preparation: repair the old poison, then probe our collection

    /// Idempotent and cheap once clean. Returns watch payloads salvaged from the old transport
    /// (keyed by document id) so they can be migrated.
    static func prepare(authKey: String) async -> [String: String] {
        let salvaged = await repairPoisonedLibrary(authKey: authKey)
        if cloudAvailable == nil {
            await probeCollection(authKey: authKey)
        }
        return salvaged
    }

    /// Scrub every `stremiox:*` document the old transports left in the account's libraryItem
    /// collection: their `state.watched` JSON breaks the official apps' library deserialization.
    /// Overwrites each with a valid empty watched string (the documents stay invisible: type
    /// "other" + removed). Returns the payloads found, so watch history can be salvaged.
    private static func repairPoisonedLibrary(authKey: String) async -> [String: String] {
        // Once a launch scans the whole library and finds nothing poisoned, remember that per account
        // so we stop pulling the entire libraryItem collection (and rebuilding an unbounded salvage map)
        // on every subsequent launch. Cleared implicitly if the flag is ever reset.
        if UserDefaults.standard.bool(forKey: repairDoneKey(authKey)) { return [:] }
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "all": true]
        guard let data = try? await post("datastoreGet", body: body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["result"] as? [[String: Any]] else {
            log.error("repair: could not list the library")
            return [:]
        }
        var salvaged: [String: String] = [:]
        var repaired = 0
        for item in items {
            guard let id = item["_id"] as? String, id.hasPrefix("stremiox:") else { continue }
            let watched = (item["state"] as? [String: Any])?["watched"] as? String ?? ""
            if !watched.isEmpty { salvaged[id] = watched }
            guard !watched.isEmpty else { continue }   // already clean
            await putLibraryItem(sanitizedDoc(id: id, name: item["name"] as? String ?? "StremioX"),
                                 authKey: authKey)
            repaired += 1
        }
        if repaired > 0 {
            log.info("repair: scrubbed \(repaired) poisoned documents; official apps can sync again")
        } else {
            // Nothing to fix this launch: mark the account clean so we skip the full-library scan next time.
            UserDefaults.standard.set(true, forKey: repairDoneKey(authKey))
        }
        return salvaged
    }

    /// Per-account "library already scanned clean" flag key. Derived from a SHA-256 of the authKey so
    /// the raw account token never lands in UserDefaults (it stays Keychain-only).
    private static func repairDoneKey(_ authKey: String) -> String {
        let digest = SHA256.hash(data: Data(authKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "stremiox.libraryRepairComplete.\(digest)"
    }

    /// A valid, schema-clean, invisible libraryItem (empty watched string parses fine everywhere).
    private static func sanitizedDoc(id: String, name: String) -> [String: Any] {
        let now = isoNow()
        return [
            "_id": id,
            "name": name,
            "type": "other",
            "posterShape": "poster",
            "removed": true,
            "temp": false,
            "_ctime": now,
            "_mtime": now,
            "state": ["lastWatched": now, "timeWatched": 0, "timeOffset": 0, "overallTimeWatched": 0,
                      "timesWatched": 0, "flaggedWatched": 0, "duration": 0, "video_id": "",
                      "watched": "", "noNotif": true] as [String: Any],
        ]
    }

    /// One write + read against our own collection decides whether cloud sync is on.
    private static func probeCollection(authKey: String) async {
        let probeID = "stremiox:probe"
        await putDocument(["_id": probeID, "_mtime": isoNow(), "payload": "ok"], authKey: authKey)
        let echoed = await fetchDocument(id: probeID, authKey: authKey)?["payload"] as? String
        cloudAvailable = (echoed == "ok")
        log.info("custom collection probe: \(cloudAvailable == true ? "available, cloud sync on" : "unavailable, profiles stay per-device")")
    }

    // MARK: Roster (profile list, synced on the PRIMARY account)

    /// The remote roster and its modification time, or nil when none was ever pushed.
    static func fetchRoster(authKey: String) async -> (profiles: [UserProfile], mtime: Date)? {
        guard cloudAvailable == true,
              let document = await fetchDocument(id: rosterID, authKey: authKey),
              let payload = (document["payload"] as? String)?.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([UserProfile].self, from: payload),
              !profiles.isEmpty else { return nil }
        let mtime = (document["_mtime"] as? String).flatMap(parseISO) ?? .distantPast
        log.info("roster fetched: \(profiles.count) profiles")
        return (profiles, mtime)
    }

    static func pushRoster(_ profiles: [UserProfile], authKey: String) async {
        guard cloudAvailable == true,
              let data = try? JSONEncoder().encode(profiles),
              let string = String(data: data, encoding: .utf8) else { return }
        await putDocument(["_id": rosterID, "_mtime": isoNow(), "payload": string], authKey: authKey)
        log.info("roster pushed: \(profiles.count) profiles")
    }

    // MARK: Watch overlay (per profile, synced on that profile's account)

    static func fetchWatch(profileID: UUID, authKey: String) async -> [String: WatchEntry]? {
        guard cloudAvailable == true,
              let document = await fetchDocument(id: watchID(profileID), authKey: authKey),
              let payload = (document["payload"] as? String)?.data(using: .utf8),
              let watch = try? JSONDecoder().decode([String: WatchEntry].self, from: payload) else { return nil }
        log.info("watch overlay fetched from server: \(watch.count) entries")
        return watch
    }

    static func pushWatch(_ watch: [String: WatchEntry], profileID: UUID, authKey: String) async {
        guard cloudAvailable == true else { return }
        // Keep the document a sane size: the rail only ever shows recent titles anyway.
        let trimmed = watch.count <= 120 ? watch
            : Dictionary(uniqueKeysWithValues: watch.sorted { $0.value.lastWatched > $1.value.lastWatched }
                .prefix(120).map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(trimmed),
              let string = String(data: data, encoding: .utf8) else { return }
        await putDocument(["_id": watchID(profileID), "_mtime": isoNow(), "payload": string],
                          authKey: authKey)
        log.info("watch overlay pushed: \(trimmed.count) entries")
    }

    /// Decode a watch payload salvaged from the old transport (for one-time migration).
    static func decodeWatchPayload(_ string: String) -> [String: WatchEntry]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: WatchEntry].self, from: data)
    }

    static func salvagedWatchKey(for profileID: UUID) -> String { watchID(profileID) }

    // MARK: Datastore plumbing

    private static func fetchDocument(id: String, authKey: String) async -> [String: Any]? {
        let body: [String: Any] = ["authKey": authKey, "collection": collection, "ids": [id], "all": false]
        guard let data = try? await post("datastoreGet", body: body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [[String: Any]] else { return nil }
        return result.first
    }

    private static func putDocument(_ document: [String: Any], authKey: String) async {
        let body: [String: Any] = ["authKey": authKey, "collection": collection, "changes": [document]]
        guard let data = try? await post("datastorePut", body: body) else {
            log.error("datastorePut \(document["_id"] as? String ?? "?", privacy: .public): request failed")
            return
        }
        let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? "?"
        log.info("datastorePut \(document["_id"] as? String ?? "?", privacy: .public): \(String(raw), privacy: .public)")
    }

    private static func putLibraryItem(_ item: [String: Any], authKey: String) async {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "changes": [item]]
        _ = try? await post("datastorePut", body: body)
    }

    private static func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
    }
}
