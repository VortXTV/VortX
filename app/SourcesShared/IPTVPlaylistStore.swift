import SwiftUI

/// Local record of the IPTV playlists the user has added (M3U URLs and Xtream Codes logins), each converted
/// by the hosted `iptv.vortx.tv` worker into a first-party Stremio add-on that flows through VortX's existing
/// Live tab. This store keeps ONLY the non-secret management metadata (display name, kind, the worker slug,
/// and the installed manifest transportUrl) in UserDefaults. The credential-bearing bits (Xtream host / user /
/// password, and any credential-carrying M3U or XMLTV URL) live in the Keychain under `vortx.iptv.cred.<slug>`,
/// mirroring the `ApiKeys` didSet pattern, so they are never written into a settings backup (which serializes
/// only the UserDefaults domain) and never leave the device except to the worker over the signed edge.
///
/// The worker slug is treated like a key: it is an opaque capability, and removing a playlist calls the
/// worker's /revoke so the slug is destroyed server-side, not just forgotten locally.
enum IPTVKind: String, Codable, Equatable {
    case m3u
    case xtream

    var label: String {
        switch self {
        case .m3u: return String(localized: "M3U playlist")
        case .xtream: return String(localized: "Xtream login")
        }
    }
}

/// The non-secret, syncable metadata for one installed IPTV playlist. `id` is the worker slug.
struct IPTVPlaylist: Codable, Identifiable, Equatable {
    let id: String            // the opaque worker slug (also the /c/<slug>/ path capability)
    var name: String
    let kind: IPTVKind
    let transportUrl: String  // the installed https://iptv.vortx.tv/c/<slug>/manifest.json
    let createdAt: Date
}

/// The credential-bearing fields for one playlist. Kept in the Keychain only. Optional throughout: an M3U
/// playlist has only `m3uURL` (+ optional `xmltvURL`); an Xtream login has host / user / pass (+ optional
/// `xmltvURL`). Retained after registration so a future refresh can re-register without re-prompting.
struct IPTVCredentials: Codable, Equatable {
    var m3uURL: String?
    var xtreamHost: String?
    var xtreamUser: String?
    var xtreamPass: String?
    var xmltvURL: String?
}

@MainActor
final class IPTVPlaylistStore: ObservableObject {
    static let shared = IPTVPlaylistStore()

    /// The installed playlists, newest first. Persisted as a JSON array in UserDefaults.
    @Published private(set) var playlists: [IPTVPlaylist] = []

    private static let defaultsKey = "vortx.iptv.playlists"
    private static let removedKey = "vortx.iptv.removed"   // slug -> removal stamp (epoch ms), last-writer-wins
    private func credAccount(_ slug: String) -> String { "vortx.iptv.cred." + slug }

    private init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([IPTVPlaylist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    /// Re-read the persisted playlists. The singleton loads them ONLY at init, so an account settings pull or
    /// a backup restore (which write `UserDefaults` directly, and whose dotted key does not fire `UserDefaults`
    /// KVO) leaves this object holding the pre-restore list. As with the other init-once stores that is also a
    /// write-back hazard, not just a stale view: `save()` re-encodes the WHOLE in-memory array, so adding or
    /// renaming one playlist after a restore would flush the stale array back over the restored one and drop
    /// every playlist the restore brought back. Re-reading first means a later `save()` can only build on the
    /// restored list. Does not `save()` (a read must never write) and does not nudge sync.
    func reloadFromDefaults() {
        load()
    }

    private func persistList() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func save() {
        persistList()
        VortXSyncManager.shared.requestSyncSoon()
    }

    // MARK: Mutations

    /// Record a freshly-registered playlist: stash its credentials in the Keychain and prepend its metadata.
    /// Idempotent by slug (a re-add of the same slug replaces the existing entry).
    func add(_ playlist: IPTVPlaylist, credentials: IPTVCredentials) {
        if let data = try? JSONEncoder().encode(credentials) {
            Keychain.set(String(data: data, encoding: .utf8), for: credAccount(playlist.id))
        }
        clearRemovedTombstone(playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        playlists.insert(playlist, at: 0)
        save()
    }

    /// Forget a playlist locally: drop its Keychain credentials and its metadata. The caller is responsible for
    /// uninstalling the add-on from the engine and calling the worker's /revoke first.
    func remove(slug: String) {
        Keychain.set(nil, for: credAccount(slug))
        playlists.removeAll { $0.id == slug }
        stampRemovedTombstone(slug)
        save()
    }

    // MARK: Removal tombstones (last-writer-wins across devices)

    /// Required by the union-merge in `applySyncBlob`: without a tombstone, a peer still holding a playlist the
    /// user removed here would re-add it on the next pull (a resurrection, the mirror image of the loss this
    /// blob exists to fix). Mirrors `MediaServerStore`'s removal map exactly.
    private static func loadRemoved() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: removedKey) as? [String: Double]) ?? [:]
    }

    private func stampRemovedTombstone(_ slug: String) {
        var map = Self.loadRemoved()
        map[slug] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(map, forKey: Self.removedKey)
    }

    private func clearRemovedTombstone(_ slug: String) {
        var map = Self.loadRemoved()
        guard map[slug] != nil else { return }
        map.removeValue(forKey: slug)
        UserDefaults.standard.set(map, forKey: Self.removedKey)
    }

    /// The stored credentials for a slug, or nil when absent.
    func credentials(for slug: String) -> IPTVCredentials? {
        guard let s = Keychain.string(credAccount(slug)), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IPTVCredentials.self, from: data)
    }

    /// True when a playlist with this transportUrl is already recorded (so the UI can avoid duplicates).
    func contains(transportUrl: String) -> Bool {
        playlists.contains { $0.transportUrl == transportUrl }
    }

    // MARK: Sync blob (the account-encrypted `apiKeys` channel)

    /// The JSON string mirrored on the account `apiKeys` channel under `vortx.iptv`, or nil when there is
    /// nothing to sync (no playlists AND no tombstones).
    ///
    /// WHY THE CREDENTIALS RIDE THE DOC. The playlist METADATA lives in `UserDefaults`, so it already rides the
    /// `doc.settings` blob and comes back after a reinstall. The credentials are Keychain-only, and the Keychain
    /// is deliberately excluded from `SettingsBackup` (it serializes the `UserDefaults` domain only), so they do
    /// NOT come back: the playlist reappears in Settings but the app can no longer re-register or refresh it
    /// against the worker, and there is no path back except re-entering the Xtream login by hand. Mirroring them
    /// here is the same, already-established answer this app gives for every other Keychain-only secret that has
    /// to follow the account: the debrid keys, the Trakt / SIMKL tokens, and the media-server tokens all ride
    /// this exact channel for this exact reason. The doc is end-to-end encrypted under the account's data key,
    /// so the credentials are no more exposed than those are.
    ///
    /// UNAFFECTED: the ACCOUNT token itself stays Keychain-only and out of every backup. It is the key that
    /// opens this document, so it can never live inside it, and nothing here changes that.
    func syncBlob() -> String? {
        let removed = Self.loadRemoved()
        guard !playlists.isEmpty || !removed.isEmpty else { return nil }
        var listJSON: [[String: Any]] = []
        for p in playlists {
            var obj: [String: Any] = [
                "id": p.id,
                "name": p.name,
                "kind": p.kind.rawValue,
                "transportUrl": p.transportUrl,
                "createdAt": p.createdAt.timeIntervalSince1970 * 1000,
            ]
            // The credential JSON is carried as an opaque string, so a future field added to IPTVCredentials
            // rides along without a blob-schema change and an older client passes it through untouched.
            if let c = credentials(for: p.id), let data = try? JSONEncoder().encode(c),
               let s = String(data: data, encoding: .utf8) {
                obj["cred"] = s
            }
            listJSON.append(obj)
        }
        let blob: [String: Any] = ["v": 1, "playlists": listJSON, "removed": removed]
        guard let data = try? JSONSerialization.data(withJSONObject: blob),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Apply a pulled sync blob: union-merge playlists by slug, honor removal tombstones (a `removed` stamp
    /// newer than a playlist's `createdAt` deletes it locally), and write a synced credential to the Keychain
    /// ONLY when the local slot is empty (the Keychain stays the source of truth; the doc is a best-effort
    /// mirror). NEVER deletes a locally-added playlist the remote simply lacks (the same asymmetric read-merge
    /// as the debrid / media-server guards). Persists inline WITHOUT nudging sync, so applying a peer's blob
    /// cannot echo straight back up as a fresh push.
    ///
    /// `doc.settings` also carries the playlist array (it is a `UserDefaults` key), and `syncDown` applies that
    /// first; this union then merges on top, so the two channels converge on the strictly better answer rather
    /// than fighting. `MediaServerStore` has the identical overlap by design.
    func applySyncBlob(_ json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let remote = (root["playlists"] as? [[String: Any]]) ?? []
        let remoteRemoved = (root["removed"] as? [String: Double]) ?? [:]

        // Merge remote removal tombstones into the local map (keep the newest stamp per slug).
        var localRemoved = Self.loadRemoved()
        for (slug, stamp) in remoteRemoved where stamp > (localRemoved[slug] ?? 0) { localRemoved[slug] = stamp }

        var bySlug: [String: IPTVPlaylist] = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var didChange = false

        for obj in remote {
            guard let slug = obj["id"] as? String, !slug.isEmpty,
                  let name = obj["name"] as? String,
                  let kindRaw = obj["kind"] as? String, let kind = IPTVKind(rawValue: kindRaw),
                  let transportUrl = obj["transportUrl"] as? String, !transportUrl.isEmpty else { continue }
            let createdAt = (obj["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            // A removal newer than this playlist's add wins: drop it and do not resurrect.
            if let stamp = localRemoved[slug], stamp > createdAt.timeIntervalSince1970 * 1000 {
                if bySlug[slug] != nil {
                    bySlug[slug] = nil
                    Keychain.set(nil, for: credAccount(slug))
                    didChange = true
                }
                continue
            }
            // Credentials: adopt into the Keychain only when the local slot is empty (Keychain authoritative).
            // This is the leg that makes a reinstalled device's restored playlists live again.
            if credentials(for: slug) == nil, let cred = obj["cred"] as? String, !cred.isEmpty {
                Keychain.set(cred, for: credAccount(slug))
            }
            let record = IPTVPlaylist(id: slug, name: name, kind: kind, transportUrl: transportUrl, createdAt: createdAt)
            if bySlug[slug] != record { bySlug[slug] = record; didChange = true }
        }

        // Persist the merged tombstones regardless (a pure tombstone pull still needs to stick).
        UserDefaults.standard.set(localRemoved, forKey: Self.removedKey)
        guard didChange else { return }
        playlists = bySlug.values.sorted { $0.createdAt > $1.createdAt }   // newest-first, mirroring add()
        persistList()
    }
}
