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

    var usesSeriesLifecycle: Bool {
        EpisodePlaybackIdentity.usesSeriesLifecycle(type: type)
    }
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
    /// The active profile's Keychain slot (shared profiles use the primary slot), so a profile
    /// switch re-points every token read and write at once.
    private var tokenKey: String { ProfileStore.shared.activeKeychainAccount }
    private var tokenBaseKey: String {
        guard let profile = ProfileStore.shared.active else { return ProfileStore.primaryTokenAccount }
        return ProfileStore.shared.tokenBaseAccount(for: profile)
    }
    private let emailKey = "stremiox.email"
    private let log = Logger(subsystem: "com.stremiox.app", category: "account")

    private var authKey: String? {
        get { Keychain.string(tokenKey) }
    }

    init() {
        email = Self.displayEmail()
        migrateTokenToKeychain()
        if authKey != nil { isSignedIn = true; Task { await loadAddons() } }
    }

    /// Re-read the session for the newly active profile (called after a profile switch).
    func reloadForActiveProfile() {
        _ = captureCredentialStamp()
        signInError = nil
        streamSources = []
        addons = []
        email = Self.displayEmail()
        // Only publish when the value actually changes. `@Published` re-fires its publisher on every
        // assignment (even true→true), so an unconditional write here can re-enter any
        // `.onReceive($isSignedIn)` sink that calls back into this method — the loop that froze the
        // iOS sign-in. Assigning only on change keeps this method safe for any observer.
        let signedIn = authKey != nil
        if isSignedIn != signedIn { isSignedIn = signedIn }
        if signedIn { Task { await loadAddons() } }
    }

    /// Own-account profiles carry their email; shared profiles show the primary account's.
    private static func displayEmail() -> String? {
        if let profile = ProfileStore.shared.active, profile.usesOwnAccount { return profile.email }
        return UserDefaults.standard.string(forKey: "stremiox.email")
    }

    /// Move a token saved by an older build (UserDefaults) into the Keychain, once.
    private func migrateTokenToKeychain() {
        guard let stamp = captureCredentialStamp(),
              let destination = stamp.stremioSlot?.account,
              Keychain.string(destination) == nil,
              let legacy = UserDefaults.standard.string(forKey: tokenBaseKey), !legacy.isEmpty else { return }
        _ = CredentialScopeAuthority.shared.commitIfCurrent(stamp) {
            guard Keychain.set(legacy, for: destination),
                  Keychain.string(destination) == legacy else { return }
            UserDefaults.standard.removeObject(forKey: tokenBaseKey)
        }
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
        guard let credentialStamp = captureCredentialStamp(operation: .stremioSignIn) else { return }
        do {
            let res: Res = try await post("login", body: Req(email: email, password: password))
            guard let key = res.result?.authKey else {
                let msg = res.error?.message ?? "Sign-in failed"
                _ = CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
                    signInError = msg
                    log.error("signIn failed: \(msg, privacy: .public)")
                }
                return
            }
            guard commitTokenReplacement(
                key,
                email: res.result?.user?.email ?? email,
                credentialStamp: credentialStamp
            ) else { return }
            log.info("signed in ok")
            await loadAddons()
        } catch {
            _ = CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
                signInError = "Couldn't reach Stremio. Check your connection."
                log.error("signIn network error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func signInWithAuthKey(_ token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { signInError = "Sign-in failed."; return }
        signInError = nil
        guard let credentialStamp = captureCredentialStamp(operation: .stremioSignIn),
              commitTokenReplacement(token, email: nil, credentialStamp: credentialStamp) else { return }
        let adoptedStamp = captureCredentialStamp()
        await backfillEmail(credentialStamp: adoptedStamp)
        log.info("signed in with link ok")
        await loadAddons()
    }

    func signOut() {
        guard let stamp = captureCredentialStamp(operation: .stremioLogout),
              let profile = ProfileStore.shared.active,
              let account = stamp.stremioSlot?.account else { return }
        _ = CredentialScopeAuthority.shared.commitIfCurrent(stamp) {
            let cleared = Keychain.set(nil, for: account) && Keychain.string(account) == nil
            CredentialScopeAuthority.shared.transitionStremioSlot(
                profileID: profile.id,
                account: account
            )
            if cleared {
                isSignedIn = false
                streamSources = []
                addons = []
                setEmail(nil)
            }
        }
    }

    private func captureCredentialStamp(
        operation domain: CredentialOperationDomain? = nil
    ) -> CredentialCommitStamp? {
        guard let profile = ProfileStore.shared.active else { return nil }
        let authority = CredentialScopeAuthority.shared
        let account = ProfileStore.shared.keychainAccount(for: profile)
        let slot = authority.bindStremioSlot(profileID: profile.id, account: account)
        let operation = domain.map { authority.beginOperation($0) }
        return CredentialCommitStamp(
            scope: slot.scope,
            stremioSlot: slot,
            document: nil,
            operation: operation
        )
    }

    private func commitTokenReplacement(
        _ token: String,
        email: String?,
        credentialStamp: CredentialCommitStamp
    ) -> Bool {
        guard let slot = credentialStamp.stremioSlot else { return false }
        return CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
            guard Keychain.set(token, for: slot.account),
                  Keychain.string(slot.account) == token else { return false }
            CredentialScopeAuthority.shared.transitionStremioSlot(
                profileID: slot.profileID,
                account: slot.account
            )
            if let email { setEmail(email) }
            if !isSignedIn { isSignedIn = true }
            return true
        } ?? false
    }

    private func setEmail(_ value: String?) {
        email = value
        let store = ProfileStore.shared
        if var profile = store.active, profile.usesOwnAccount {
            profile.email = value          // the bound account belongs to this profile only
            store.update(profile)
        } else {
            UserDefaults.standard.setValue(value, forKey: emailKey)
        }
    }

    func loadAddons() async {
        guard let credentialStamp = captureCredentialStamp(),
              let account = credentialStamp.stremioSlot?.account,
              let key = Keychain.string(account) else { return }
        struct Req: Encodable { let authKey: String; let update = true }
        struct Res: Decodable { struct R: Decodable { let addons: [AddonDescriptor] }; let result: R? }
        do {
            let res: Res = try await post("addonCollectionGet", body: Req(authKey: key))
            let addons = res.result?.addons ?? []
            let needsEmail = CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
                self.addons = addons
                // Keep the user's addon order (addonCollectionGet = their Stremio order) so the sources
                // and catalogs they prioritised come first. (A broken `.sorted` was scrambling it.)
                streamSources = addons.filter { $0.providesStreams }
                    .map { StreamSource(base: $0.baseUrl, name: $0.manifest.name) }
                log.info("loaded \(self.addons.count) addons, \(self.streamSources.count) stream addons")
                return email == nil
            } ?? false
            if needsEmail { await backfillEmail(credentialStamp: credentialStamp) }
        } catch {
            // keep whatever we had, but surface why the refresh failed
            _ = CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
                log.error("loadAddons failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Backfill the account email (for sessions that predate email capture).
    private func backfillEmail(credentialStamp suppliedStamp: CredentialCommitStamp? = nil) async {
        guard let credentialStamp = suppliedStamp ?? captureCredentialStamp(),
              let account = credentialStamp.stremioSlot?.account,
              let key = Keychain.string(account) else { return }
        struct Req: Encodable { let authKey: String }
        struct Res: Decodable { struct U: Decodable { let email: String? }; let result: U? }
        if let res: Res = try? await post("getUser", body: Req(authKey: key)), let e = res.result?.email {
            _ = CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) { setEmail(e) }
        }
    }

    // MARK: - Watch progress (tvOS writes the playback position back to the account library)

    /// Saved resume position in **seconds** for `meta` (0 = start fresh). For series, only resumes
    /// when the stored progress is for the same episode the user is opening. Overlay profiles
    /// (a non-owner shared profile) resume from their own private history instead.
    func resumeOffset(for meta: PlaybackMeta) async -> Double {
        if !ProfileStore.shared.activeUsesEngineHistory {
            return ProfileStore.shared.resumeOffset(for: meta)
        }
        // Wave 4: VortX owns the MAIN profile's resume. Read the engine's LOCAL library bucket BY ID (mirrored
        // from doc.vortx.library, re-hydrated on cold devices) instead of the Stremio account datastore. Callers
        // already try `core.engineResumeSeconds(for:)` first and only fall through to here when meta_details is
        // not yet loaded (the Continue-Watching direct-resume race); this by-id read still finds the position, so
        // gating the Stremio read off cannot lose resume. Only consult api.strem.io when the user opted into the
        // two-way mirror (default OFF).
        if let engine = CoreBridge.shared.engineResumeSecondsByLibraryId(for: meta) { return engine }
        guard ProfileSync.alsoSyncToStremio else { return 0 }
        guard let credentialStamp = captureCredentialStamp(),
              let account = credentialStamp.stremioSlot?.account,
              let key = Keychain.string(account),
              let item = await rawLibraryItem(
                id: meta.libraryId,
                authKey: key,
                credentialStamp: credentialStamp
              ),
              CredentialScopeAuthority.shared.isCurrent(credentialStamp),
              let state = item["state"] as? [String: Any] else { return 0 }
        if EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: meta.usesSeriesLifecycle,
            savedVideoID: state["video_id"] as? String,
            requestedVideoID: meta.videoId
        ) { return 0 }
        let ms = Self.numeric(state["timeOffset"])
        return ms > 0 ? ms / 1000 : 0
    }

    /// Upsert the library item with the current playback position so Continue Watching reflects what
    /// was watched on Apple TV. Fetches the existing item and mutates only the progress fields so no
    /// other client's data is clobbered; creates a minimal item only if it's new to the library.
    /// Overlay profiles write to their own private synced history and never touch the account library.
    func saveProgress(for meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double) async {
        if !ProfileStore.shared.activeUsesEngineHistory {
            ProfileStore.shared.recordProgress(meta: meta, positionSeconds: positionSeconds,
                                               durationSeconds: durationSeconds)
            return
        }
        // Wave 4: VortX owns the MAIN profile's Continue Watching + resume. The position is already persisted to
        // the engine's LOCAL library bucket by the co-located `CoreBridge.reportProgress` at every player call
        // site (the engine Player's TimeChanged), and that bucket is mirrored to doc.vortx.library and re-hydrated
        // on cold devices, so Continue Watching + resume survive with NO Stremio dependency. Do NOT write to the
        // Stremio account datastore by default; only ALSO write it when the user opted into two-way sync (OFF).
        guard ProfileSync.alsoSyncToStremio else { return }
        guard let credentialStamp = captureCredentialStamp(),
              let account = credentialStamp.stremioSlot?.account,
              let key = Keychain.string(account),
              durationSeconds > 0, positionSeconds >= 0 else { return }
        let now = Self.isoNow()
        var item = await rawLibraryItem(
            id: meta.libraryId,
            authKey: key,
            credentialStamp: credentialStamp
        ) ?? Self.newLibraryItem(meta, now: now)
        guard CredentialScopeAuthority.shared.isCurrent(credentialStamp) else { return }
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
        await datastorePut(authKey: key, change: item, credentialStamp: credentialStamp)
    }

    /// Fetch a single library item as raw JSON so all its fields survive a progress update.
    private func rawLibraryItem(
        id: String,
        authKey: String,
        credentialStamp: CredentialCommitStamp
    ) async -> [String: Any]? {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "ids": [id], "all": false]
        guard let data = try? await postRaw("datastoreGet", body: body, credentialStamp: credentialStamp),
              CredentialScopeAuthority.shared.isCurrent(credentialStamp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["result"] as? [[String: Any]] else { return nil }
        return arr.first
    }

    private func datastorePut(
        authKey: String,
        change: [String: Any],
        credentialStamp: CredentialCommitStamp
    ) async {
        let body: [String: Any] = ["authKey": authKey, "collection": "libraryItem", "changes": [change]]
        do {
            _ = try await postRaw("datastorePut", body: body, credentialStamp: credentialStamp)
        } catch {
            guard CredentialScopeAuthority.shared.isCurrent(credentialStamp) else { return }
            // Progress saves are best-effort, but don't drop the failure silently: log it and retry once.
            log.error("datastorePut failed: \(error.localizedDescription, privacy: .public); retrying once")
            do {
                _ = try await postRaw("datastorePut", body: body, credentialStamp: credentialStamp)
            } catch {
                if CredentialScopeAuthority.shared.isCurrent(credentialStamp) {
                    log.error("datastorePut retry failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Like `post`, but with an untyped JSON body/response, for library items whose full shape we
    /// deliberately don't model (we preserve unknown fields rather than round-trip through Codable).
    private func postRaw(
        _ path: String,
        body: [String: Any],
        credentialStamp: CredentialCommitStamp
    ) async throws -> Data {
        guard CredentialScopeAuthority.shared.isCurrent(credentialStamp) else {
            throw CancellationError()
        }
        guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard CredentialScopeAuthority.shared.isCurrent(credentialStamp) else {
            throw CancellationError()
        }
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
        guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
