import Foundation
import os

// MARK: - Stremio account: login + addon collection + library (HTTP api.strem.io)

/// A resource entry in an addon manifest, can be a bare string ("stream") or an object
/// ({ name: "stream", types: [...] }). Decoded flexibly.
struct AddonResource: Decodable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s; types = nil; idPrefixes = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        types = try? c.decode([String].self, forKey: .types)
        idPrefixes = try? c.decode([String].self, forKey: .idPrefixes)
    }
    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
}

/// A catalog (board row) declared in a manifest. `extra`/`extraRequired` flag catalogs that
/// need a parameter (search, genre), those can't load as a plain board row.
struct AddonCatalog: Decodable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?
    let extraRequired: [String]?
    // `options` carries the selectable values for a parameter, e.g. the genre list for filtering.
    struct CatalogExtra: Decodable, Hashable { let name: String; let isRequired: Bool?; let options: [String]? }

    /// Genres this catalog can be filtered by (from its optional `genre` extra), or [] if none.
    var genreOptions: [String] { extra?.first { $0.name == "genre" }?.options ?? [] }

    /// Names of all REQUIRED extras (from either `extraRequired` or `extra[].isRequired`).
    private var requiredExtras: [String] {
        (extraRequired ?? []) + (extra?.filter { $0.isRequired == true }.map { $0.name } ?? [])
    }

    /// Home-row eligible: needs no required parameter at all.
    var isBoardEligible: Bool { requiredExtras.isEmpty }

    /// Discover-eligible: needs no required parameter OTHER than `genre` (Discover supplies that via
    /// the genre chips). Search-only catalogs are excluded, they belong in Search. This is what was
    /// wrongly dropping ~95% of catalogs from Discover.
    var isDiscoverEligible: Bool { requiredExtras.allSatisfy { $0 == "genre" } }

    /// True when a genre MUST be supplied to load this catalog (Discover defaults to the first one).
    var requiresGenre: Bool { requiredExtras.contains("genre") }
}

struct AddonManifest: Decodable {
    let id: String
    let name: String
    let resources: [AddonResource]
    let types: [String]?
    let catalogs: [AddonCatalog]?
    let idPrefixes: [String]?
}

struct AddonDescriptor: Decodable {
    let transportUrl: String
    let manifest: AddonManifest
    /// Base URL for resource requests (manifest URL minus the trailing /manifest.json).
    var baseUrl: String { transportUrl.replacingOccurrences(of: "/manifest.json", with: "") }
    var providesStreams: Bool { manifest.resources.contains { $0.name == "stream" } }
    var providesMeta: Bool { manifest.resources.contains { $0.name == "meta" } }
    /// id-prefixes this addon handles for meta lookups (resource-level first, else manifest-level).
    var metaIdPrefixes: [String] {
        (manifest.resources.first { $0.name == "meta" }?.idPrefixes) ?? manifest.idPrefixes ?? []
    }
}

/// A library entry from the account datastore, used by the player's resume lookup.
struct LibraryItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let poster: String?
    let removed: Bool?
    let state: State?
    struct State: Decodable, Hashable {
        let timeOffset: Double?
        let duration: Double?
        let lastWatched: String?     // ISO timestamp, used to order Continue Watching, newest first
    }
    enum CodingKeys: String, CodingKey { case id = "_id", name, type, poster, removed, state }

    var isRemoved: Bool { removed == true }
    /// 0…1 watched fraction, for the continue-watching progress bar (0 if duration unknown).
    var progress: Double {
        guard let t = state?.timeOffset, let d = state?.duration, d > 0 else { return 0 }
        return min(1, max(0, t / d))
    }
    /// In the Continue Watching shelf? Matches Stremio: keep anything you've actually watched, and
    /// for a SERIES keep it even when the current episode is finished, the *next* episode is what
    /// you continue (the old "must be mid-progress" test dropped these, leaving only the 1–2 titles
    /// you were literally paused inside). Only a finished MOVIE is excluded.
    var inProgress: Bool {
        guard !isRemoved else { return false }
        let watched = (state?.timeOffset ?? 0) > 0 || !lastWatched.isEmpty
        guard watched else { return false }
        if type == "movie", let t = state?.timeOffset, let d = state?.duration, d > 0, t >= d * 0.95 {
            return false                                            // a finished movie isn't "continue"
        }
        return true
    }
    var lastWatched: String { state?.lastWatched ?? "" }
}

/// The context the tvOS player needs to record watch progress against the right library item.
/// (`libraryId` is the movie/series id = the libraryItem `_id`; `videoId` is the movie id, or
/// `imdbId:season:episode` for an episode.)
struct PlaybackMeta: Hashable {
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?
}

/// Manages the signed-in Stremio session: auth token (persisted), installed addons, and the
/// chosen stream addon. The token + addon URLs (which carry debrid keys) stay on-device only.
@MainActor
final class StremioAccount: ObservableObject {
    @Published var isSignedIn = false
    @Published var email: String?                       // shown on the Settings/Account screen
    @Published var streamSources: [StreamSource] = []   // stream addons (base + name), for tagging/filtering
    @Published var addons: [AddonDescriptor] = []       // for the Addons screen
    @Published var signInError: String?

    /// Convenience: just the stream-addon base URLs (count shown in Settings, etc.).
    var streamAddonBases: [String] { streamSources.map(\.base) }

    private let api = "https://api.strem.io/api"
    private let tokenKey = "stremiox.authKey"
    private let emailKey = "stremiox.email"
    private let log = Logger(subsystem: "com.stremiox.app", category: "account")

    private var authKey: String? {
        get { Keychain.string(tokenKey) }
        set { Keychain.set(newValue, for: tokenKey) }
    }

    init() {
        email = UserDefaults.standard.string(forKey: emailKey)
        migrateTokenToKeychain()
        if authKey != nil { isSignedIn = true; Task { await loadAddons() } }
    }

    /// Move a token saved by an older build (UserDefaults) into the Keychain, once.
    private func migrateTokenToKeychain() {
        guard authKey == nil,
              let legacy = UserDefaults.standard.string(forKey: tokenKey), !legacy.isEmpty else { return }
        Keychain.set(legacy, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    func signIn(email rawEmail: String, password: String) async {
        signInError = nil
        // tvOS text fields tend to auto-capitalize / add stray whitespace; normalize the email so
        // it matches the registered account. The password is sent exactly as typed.
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        struct Req: Encodable { let email: String; let password: String; let facebook = false }
        struct Res: Decodable {
            struct R: Decodable { let authKey: String; let user: U? }
            struct U: Decodable { let email: String? }
            let result: R?; let error: ErrObj?
        }
        struct ErrObj: Decodable { let message: String? }
        guard !email.isEmpty, !password.isEmpty else { signInError = "Enter your email and password."; return }
        do {
            let res: Res = try await post("login", body: Req(email: email, password: password))
            guard let key = res.result?.authKey else {
                let msg = res.error?.message ?? "Sign-in failed"
                signInError = msg
                log.error("signIn failed: \(msg, privacy: .public)")
                return
            }
            authKey = key
            setEmail(res.result?.user?.email ?? email)
            isSignedIn = true
            log.info("signed in ok")
            await loadAddons()
        } catch {
            signInError = "Couldn't reach Stremio. Check your connection."
            log.error("signIn network error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signOut() {
        authKey = nil; isSignedIn = false; streamSources = []; addons = []
        setEmail(nil)
    }

    private func setEmail(_ value: String?) {
        email = value
        UserDefaults.standard.setValue(value, forKey: emailKey)
    }

    func loadAddons() async {
        guard let key = authKey else { return }
        struct Req: Encodable { let authKey: String; let update = true }
        struct Res: Decodable { struct R: Decodable { let addons: [AddonDescriptor] }; let result: R? }
        do {
            let res: Res = try await post("addonCollectionGet", body: Req(authKey: key))
            let addons = res.result?.addons ?? []
            self.addons = addons
            // Keep the user's addon order (addonCollectionGet = their Stremio order) so the sources
            // and catalogs they prioritised come first. (A broken `.sorted` was scrambling it.)
            streamSources = addons.filter { $0.providesStreams }
                .map { StreamSource(base: $0.baseUrl, name: $0.manifest.name) }
            log.info("loaded \(self.addons.count) addons, \(self.streamSources.count) stream addons")
            if email == nil { await backfillEmail() }   // older sessions saved no email
        } catch { /* keep whatever we had */ }
    }

    /// Backfill the account email (for sessions that predate email capture).
    private func backfillEmail() async {
        guard let key = authKey else { return }
        struct Req: Encodable { let authKey: String }
        struct Res: Decodable { struct U: Decodable { let email: String? }; let result: U? }
        if let res: Res = try? await post("getUser", body: Req(authKey: key)), let e = res.result?.email {
            setEmail(e)
        }
    }

    // MARK: - Watch progress (tvOS writes the playback position back to the account library)

    /// Saved resume position in **seconds** for `meta` (0 = start fresh). For series, only resumes
    /// when the stored progress is for the same episode the user is opening.
    func resumeOffset(for meta: PlaybackMeta) async -> Double {
        guard let key = authKey,
              let item = await rawLibraryItem(id: meta.libraryId, authKey: key),
              let state = item["state"] as? [String: Any] else { return 0 }
        if meta.type == "series", let saved = state["video_id"] as? String, saved != meta.videoId { return 0 }
        let ms = Self.numeric(state["timeOffset"])
        return ms > 0 ? ms / 1000 : 0
    }

    /// Upsert the library item with the current playback position so Continue Watching reflects what
    /// was watched on Apple TV. Fetches the existing item and mutates only the progress fields so no
    /// other client's data is clobbered; creates a minimal item only if it's new to the library.
    func saveProgress(for meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double) async {
        guard let key = authKey, durationSeconds > 0, positionSeconds >= 0 else { return }
        let now = Self.isoNow()
        var item = await rawLibraryItem(id: meta.libraryId, authKey: key) ?? Self.newLibraryItem(meta, now: now)
        var state = (item["state"] as? [String: Any]) ?? [:]
        state["timeOffset"] = Int((positionSeconds * 1000).rounded())
        state["duration"] = Int((durationSeconds * 1000).rounded())
        state["lastWatched"] = now
        state["video_id"] = meta.videoId
        item["state"] = state
        item["_mtime"] = now
        item["removed"] = false
        if item["name"] == nil { item["name"] = meta.name }
        if item["type"] == nil { item["type"] = meta.type }
        await datastorePut(authKey: key, change: item)
    }

    /// Fetch a single library item as raw JSON so all its fields survive a progress update.
    private func rawLibraryItem(id: String, authKey: String) async -> [String: Any]? {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "ids": [id], "all": false]
        guard let data = try? await postRaw("datastoreGet", body: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["result"] as? [[String: Any]] else { return nil }
        return arr.first
    }

    private func datastorePut(authKey: String, change: [String: Any]) async {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "changes": [change]]
        _ = try? await postRaw("datastorePut", body: body)
    }

    /// Like `post`, but with an untyped JSON body/response, for library items whose full shape we
    /// deliberately don't model (we preserve unknown fields rather than round-trip through Codable).
    private func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(api)/\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private static func numeric(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// A minimal but valid libraryItem for content not yet in the library (field names match the
    /// shape `library()` already decodes successfully).
    private static func newLibraryItem(_ meta: PlaybackMeta, now: String) -> [String: Any] {
        var item: [String: Any] = [
            "_id": meta.libraryId,
            "name": meta.name,
            "type": meta.type,
            "posterShape": "poster",
            "removed": false,
            "temp": false,
            "_ctime": now,
            "_mtime": now,
            "state": [
                "lastWatched": now, "timeWatched": 0, "timeOffset": 0, "overallTimeWatched": 0,
                "timesWatched": 0, "flaggedWatched": 0, "duration": 0, "video_id": meta.videoId,
                "watched": "", "noNotif": false,
            ],
            "behaviorHints": ["defaultVideoId": NSNull()],
        ]
        if let poster = meta.poster { item["poster"] = poster }
        return item
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        var req = URLRequest(url: URL(string: "\(api)/\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
