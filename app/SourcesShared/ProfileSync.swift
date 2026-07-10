import Foundation
import CryptoKit
import os

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
