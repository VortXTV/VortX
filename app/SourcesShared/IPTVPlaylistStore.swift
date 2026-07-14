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

    private let defaultsKey = "vortx.iptv.playlists"
    private func credAccount(_ slug: String) -> String { "vortx.iptv.cred." + slug }

    private init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([IPTVPlaylist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        VortXSyncManager.shared.requestSyncSoon()
    }

    // MARK: Mutations

    /// Record a freshly-registered playlist: stash its credentials in the Keychain and prepend its metadata.
    /// Idempotent by slug (a re-add of the same slug replaces the existing entry).
    func add(_ playlist: IPTVPlaylist, credentials: IPTVCredentials) {
        if let data = try? JSONEncoder().encode(credentials) {
            Keychain.set(String(data: data, encoding: .utf8), for: credAccount(playlist.id))
        }
        playlists.removeAll { $0.id == playlist.id }
        playlists.insert(playlist, at: 0)
        save()
    }

    /// Forget a playlist locally: drop its Keychain credentials and its metadata. The caller is responsible for
    /// uninstalling the add-on from the engine and calling the worker's /revoke first.
    func remove(slug: String) {
        Keychain.set(nil, for: credAccount(slug))
        playlists.removeAll { $0.id == slug }
        save()
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
}
