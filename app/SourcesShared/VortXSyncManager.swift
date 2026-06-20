import Foundation
import SwiftUI

/// The VortX end-to-end-encrypted account on-device: create / sign in / recover / sign out, plus
/// push and pull the encrypted sync document. Mirrors the website (vortx-site/src/lib/vault.ts) and
/// the Cloudflare Worker contract through VortXSyncCrypto. The session token, account, and the data
/// key are persisted in the Keychain (the data key is sensitive, never UserDefaults). Optional: VortX
/// works fully signed out; this only adds cross-device sync, backup, and recovery.
@MainActor
final class VortXSyncManager: ObservableObject {
    static let shared = VortXSyncManager()

    struct Account: Codable, Equatable {
        let id: String
        let email: String
        var username: String
        var twoFactorEnabled: Bool
    }

    @Published private(set) var account: Account?
    @Published private(set) var isSignedIn = false

    private let base = "https://api.vortx.tv"
    private let kcAccount = "vortx.sync.session.v1"
    private var token: String?
    private var dataKey: Data?
    private var lastSyncedVersion = 0   // newest doc version this device has pushed or applied
    private var lastAppliedProfileEditsAt: Double = 0  // LWW stamp of the last web profileEdits applied (in-memory; re-apply is idempotent)
    private var hasPendingPush = false  // a debounced syncUp is queued; don't pull over it

    // MARK: - Real-time sync state (WebSocket + while-active poll)
    /// The live SyncRoom socket; nil whenever disconnected. Receives {"type":"updated","version":N}
    /// pushes from other devices and triggers a pull within ~1s.
    private var ws: URLSessionWebSocketTask?
    private var wsBackoff: TimeInterval = 1          // reconnect delay, doubled per failure (capped)
    private var wsReconnect: Task<Void, Never>?      // pending reconnect attempt
    private var wsKeepAlive: Task<Void, Never>?      // periodic "ping" so the room never idles us out
    private var pollTask: Task<Void, Never>?         // while-active fallback poll
    private var realtimeActive = false               // true between startRealtime() and stopRealtime()
    private let wsMaxBackoff: TimeInterval = 30
    private let pollIntervalNanos: UInt64 = 10_000_000_000   // 10s fallback poll while active
    private let keepAliveNanos: UInt64 = 30_000_000_000      // 30s ping to hold the room open

    private init() {
        restore()
        // Auto-sync: profiles and settings persist to UserDefaults, so one observer catches every change
        // and schedules a debounced push (no-op when signed out). Metadata keys (Keychain) push via ApiKeys.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestSyncSoon() }
        }
    }

    // MARK: - Keychain persistence

    private struct Persisted: Codable { let token: String; let account: Account; let dataKey: String }

    private func persist() {
        guard let token, let account, let dataKey,
              let data = try? JSONEncoder().encode(Persisted(token: token, account: account, dataKey: dataKey.base64EncodedString())),
              let str = String(data: data, encoding: .utf8) else { return }
        Keychain.set(str, for: kcAccount)
    }

    private func restore() {
        guard let str = Keychain.string(kcAccount), let data = str.data(using: .utf8),
              let p = try? JSONDecoder().decode(Persisted.self, from: data),
              let dk = Data(base64Encoded: p.dataKey) else { return }
        token = p.token; account = p.account; dataKey = dk; isSignedIn = true
    }

    func signOut() {
        stopRealtime()   // drop the SyncRoom socket + poll before clearing the token
        token = nil; account = nil; dataKey = nil; isSignedIn = false
        Keychain.set(nil, for: kcAccount)
    }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = false) async -> (Int, [String: Any]?) {
        guard let url = URL(string: base + path) else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if auth, let token { req.setValue("Bearer " + token, forHTTPHeaderField: "authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (code, json)
        } catch { return (0, nil) }
    }

    private func adopt(token: String, account acct: [String: Any], dataKey: Data) {
        self.token = token
        self.dataKey = dataKey
        self.account = Account(
            id: acct["id"] as? String ?? "",
            email: acct["email"] as? String ?? "",
            username: acct["username"] as? String ?? "",
            twoFactorEnabled: acct["twoFactorEnabled"] as? Bool ?? false)
        self.isSignedIn = true
        persist()
        // A fresh sign-in is a foreground action, so open the real-time channel immediately (if the app
        // is active it would also be opened by scenePhase, but adopting here covers the in-place sign-in
        // flow where the scene never re-activates). Idempotent: startRealtime() no-ops if already live.
        startRealtime()
        // Reconciliation is decided by the UI after sign-in (reconcileAfterSignIn), so a sign-in never
        // blindly overwrites either side. A new account just gets seeded.
    }

    enum AuthResult: Equatable { case ok, totpRequired, failed(String) }

    // MARK: - Flows

    func register(email: String, username: String, password: String) async -> (result: AuthResult, recoveryCode: String?) {
        let kdfSalt = VortXSyncCrypto.randomBytes(16)
        let iters = VortXSyncCrypto.defaultIters
        let masterKey = VortXSyncCrypto.masterKey(password: password, kdfSalt: kdfSalt, iters: iters)
        let dataKey = VortXSyncCrypto.randomBytes(32)
        let recoveryCode = VortXSyncCrypto.makeRecoveryCode()
        let recoveryKey = VortXSyncCrypto.recoveryKey(recoveryCode: recoveryCode, kdfSalt: kdfSalt, iters: iters)
        guard let wrappedPw = VortXSyncCrypto.seal(key: masterKey, dataKey),
              let wrappedRec = VortXSyncCrypto.seal(key: recoveryKey, dataKey) else {
            return (.failed("Could not set up encryption."), nil)
        }
        let body: [String: Any] = [
            "email": email, "username": username,
            "kdfSalt": kdfSalt.base64EncodedString(), "kdfIters": iters,
            "authVerifier": VortXSyncCrypto.authVerifier(masterKey: masterKey, password: password),
            "wrappedKeyPassword": wrappedPw, "wrappedKeyRecovery": wrappedRec,
            "recVerifier": VortXSyncCrypto.recVerifier(recoveryKey: recoveryKey, recoveryCode: recoveryCode),
            // Sent ONLY so the worker can put it in the welcome email; it is never stored server-side
            // (index.ts marks it "NEVER written to the DB"), and the website register sends it the same way.
            // Without this the welcome email falls back to a generic "save your code" note (the regression).
            "recoveryCode": recoveryCode,
        ]
        let (code, json) = await request("POST", "/v1/auth/register", body: body)
        if code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any] {
            adopt(token: token, account: acct, dataKey: dataKey)
            return (.ok, recoveryCode)
        }
        switch json?["error"] as? String {
        case "email_taken": return (.failed("That email is already registered."), nil)
        case "username_taken": return (.failed("That username is taken."), nil)
        default: return (.failed("Could not create the account."), nil)
        }
    }

    func signIn(login: String, password: String, totp: String? = nil) async -> AuthResult {
        let (_, pre) = await request("POST", "/v1/auth/prelogin", body: ["login": login])
        guard let saltStr = pre?["kdfSalt"] as? String, let salt = Data(base64Encoded: saltStr),
              let iters = pre?["kdfIters"] as? Int else { return .failed("Could not reach VortX. Try again.") }
        let masterKey = VortXSyncCrypto.masterKey(password: password, kdfSalt: salt, iters: iters)
        var body: [String: Any] = ["login": login, "authVerifier": VortXSyncCrypto.authVerifier(masterKey: masterKey, password: password)]
        if let totp, !totp.isEmpty { body["totp"] = totp }
        let (code, json) = await request("POST", "/v1/auth/login", body: body)
        if code == 401, (json?["error"] as? String) == "totp_required" { return .totpRequired }
        guard code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any],
              let wrappedPw = json?["wrappedKeyPassword"] as? String,
              let dk = VortXSyncCrypto.open(key: masterKey, wrappedPw) else {
            return .failed(code == 401 ? "Wrong login or password." : "Could not sign in.")
        }
        adopt(token: token, account: acct, dataKey: dk)
        return .ok
    }

    func recover(email: String, recoveryCode: String, newPassword: String) async -> AuthResult {
        let trimmed = recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, start) = await request("POST", "/v1/auth/recover-start", body: ["email": email])
        guard let saltStr = start?["kdfSalt"] as? String, let salt = Data(base64Encoded: saltStr),
              let iters = start?["kdfIters"] as? Int, let wrappedRec = start?["wrappedKeyRecovery"] as? String else {
            return .failed("No recovery is set up for that email.")
        }
        let recoveryKey = VortXSyncCrypto.recoveryKey(recoveryCode: trimmed, kdfSalt: salt, iters: iters)
        guard let dk = VortXSyncCrypto.open(key: recoveryKey, wrappedRec) else { return .failed("That recovery code is not correct.") }
        // Keep the existing kdfSalt (it also derives the recovery key); derive the new master from it.
        let newMaster = VortXSyncCrypto.masterKey(password: newPassword, kdfSalt: salt, iters: iters)
        guard let wrappedPw = VortXSyncCrypto.seal(key: newMaster, dk) else { return .failed("Could not re-encrypt.") }
        let body: [String: Any] = [
            "email": email,
            "recVerifier": VortXSyncCrypto.recVerifier(recoveryKey: recoveryKey, recoveryCode: trimmed),
            "newAuthVerifier": VortXSyncCrypto.authVerifier(masterKey: newMaster, password: newPassword),
            "newWrappedKeyPassword": wrappedPw,
        ]
        let (code, json) = await request("POST", "/v1/auth/recover-complete", body: body)
        if code == 200, let token = json?["token"] as? String, let acct = json?["account"] as? [String: Any] {
            adopt(token: token, account: acct, dataKey: dk)
            return .ok
        }
        return .failed("Recovery failed.")
    }

    // MARK: - Encrypted sync document

    func pullSyncDoc() async -> [String: Any]? {
        guard let dataKey else { return nil }
        let (code, json) = await request("GET", "/v1/backup", auth: true)
        guard code == 200, let doc = json?["document"] as? String,
              let pt = VortXSyncCrypto.open(key: dataKey, doc) else { return nil }
        return (try? JSONSerialization.jsonObject(with: pt)) as? [String: Any]
    }

    /// Tri-state pull used by `syncUp`'s data-loss guard: distinguishes "the account has no backup yet"
    /// (safe to start from an empty doc) from "the pull failed" (must NOT push, or it clobbers the
    /// account's existing document). A non-200/non-404 response or an undecryptable document is a failure.
    private enum SyncDocPull { case doc([String: Any]); case empty; case failed }
    private func pullSyncDocResult() async -> SyncDocPull {
        guard let dataKey else { return .failed }
        let (code, json) = await request("GET", "/v1/backup", auth: true)
        if code == 404 { return .empty }                 // no backup yet
        guard code == 200 else { return .failed }        // network/server error: do not clobber
        guard let docStr = json?["document"] as? String, !docStr.isEmpty else { return .empty } // 200, no document
        guard let pt = VortXSyncCrypto.open(key: dataKey, docStr),
              let obj = (try? JSONSerialization.jsonObject(with: pt)) as? [String: Any] else { return .failed } // undecryptable: do not clobber
        return .doc(obj)
    }

    /// Pull the doc plus its server version, so the foreground pull can apply only changes that are
    /// newer than what this device already has (and not re-apply its own last push).
    private func pullDocVersioned() async -> (doc: [String: Any], version: Int)? {
        guard let dataKey else { return nil }
        let (code, json) = await request("GET", "/v1/backup", auth: true)
        guard code == 200, let docStr = json?["document"] as? String,
              let version = json?["version"] as? Int,
              let pt = VortXSyncCrypto.open(key: dataKey, docStr),
              let obj = (try? JSONSerialization.jsonObject(with: pt)) as? [String: Any] else { return nil }
        return (obj, version)
    }

    @discardableResult
    func pushSyncDoc(_ obj: [String: Any]) async -> Bool {
        guard let dataKey, let pt = try? JSONSerialization.data(withJSONObject: obj),
              let ct = VortXSyncCrypto.seal(key: dataKey, pt) else { return false }
        let version = Int(Date().timeIntervalSince1970 * 1000)
        let (code, _) = await request("PUT", "/v1/backup", body: ["document": ct, "version": version], auth: true)
        if code == 200 { lastSyncedVersion = max(lastSyncedVersion, version) }
        return code == 200
    }

    /// A small JSON view of local state the website dashboard can read (the binary-plist `settings`
    /// blob is opaque to a browser). Profiles let the dashboard show the family roster + the real count.
    private func vortxSummary() -> [String: Any] {
        let store = ProfileStore.shared
        let profiles: [[String: Any]] = store.profiles.map { p in
            // pinHash is the salted SHA-256 (salt = the profile id, already here), never the raw PIN,
            // so the dashboard can verify a PIN entry by re-hashing without ever seeing the digits.
            // `settings` mirrors the per-profile app settings so the dashboard can show + manage them
            // (it writes them back via doc.profileEdits[].settings, applied by ProfileStore.applyProfileEdits).
            var settings: [String: Any] = ["avatar": p.avatar, "accent": p.accentID, "oled": p.oled, "textScale": p.textScale]
            if let pb = p.playback {
                var playback: [String: Any] = ["audioLang": pb.audioLang, "subtitleLang": pb.subtitleLang,
                    "forced": pb.forcedPolicy, "subFont": pb.subFont, "subSize": pb.subSize,
                    "subColor": pb.subColor, "subBackground": pb.subBackground]
                if let s = pb.subSizeScale { playback["subSizeScale"] = s }
                if let o = pb.sourceTypeOrder { playback["sourceTypeOrder"] = o }
                if let u = pb.useAddonOrder { playback["useAddonOrder"] = u }
                settings["playback"] = playback
            }
            return ["id": p.id.uuidString, "name": p.name, "locked": p.pin != nil, "main": p.isOwner,
                    "familyEdit": p.familyEdit, "pinHash": p.pin ?? "", "settings": settings]
        }
        // Per-profile library / Continue Watching, so the dashboard shows each profile's titles instead
        // of "no titles yet". Overlay profiles only (the owner profile's history lives in the account
        // library, not a watch overlay). The dashboard derives CW from each item's t/d progress.
        var byProfile: [String: Any] = [:]
        for p in store.profiles where !p.isOwner {
            let cache = store.watchEntries(for: p.id)
            guard !cache.isEmpty else { continue }
            let library: [[String: Any]] = cache.map { (metaId, e) in
                // t/d in seconds for the dashboard; v (resume episode/movie id) + w (watched episode ids)
                // so syncDown can rebuild the FULL overlay on another device, not just library membership.
                ["id": metaId, "name": e.name, "type": e.type, "poster": e.poster ?? "",
                 "t": e.timeOffsetMs / 1000, "d": e.durationMs / 1000, "lastWatched": e.lastWatched,
                 "v": e.videoId ?? "", "w": e.watchedVideoIds]
            }
            byProfile[p.id.uuidString] = ["library": library]
        }
        // The owner/main profile's library lives in the account (not a watch overlay), so it was absent
        // from the dashboard, which only received the byProfile overlay libraries above. Emit it as
        // vortx.library from the engine's account library so the dashboard's main-profile Library is
        // populated (excluding removed/temp, which are not "in the library"). Safe here: this type is
        // @MainActor, so reading CoreBridge's @Published state is on the main actor.
        let ownerLibrary: [[String: Any]] = (CoreBridge.shared.library?.catalog ?? [])
            .filter { !($0.removed ?? false) && !($0.temp ?? false) }
            .map { item in
                ["id": item.id, "name": item.name, "type": item.type, "poster": item.poster ?? "",
                 "t": Int(item.state.timeOffset / 1000), "d": Int(item.state.duration / 1000)]
            }
        // Installed add-ons, so the dashboard Add-ons page is populated: it reads vortx.addons (and the
        // web Stremio import under doc.addons), neither of which the app emitted before.
        let addonList: [[String: Any]] = CoreBridge.shared.addons.map { desc in
            ["transportUrl": desc.transportUrl, "name": desc.manifest.name]
        }
        var v: [String: Any] = ["profiles": profiles, "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
        if !byProfile.isEmpty { v["byProfile"] = byProfile }
        if !ownerLibrary.isEmpty { v["library"] = ownerLibrary }
        if !addonList.isEmpty { v["addons"] = addonList }
        if let active = store.activeID { v["activeProfile"] = active.uuidString }
        return v
    }

    /// Decode just the profile roster out of a doc's `settings` blob (the base64 SettingsBackup
    /// envelope, whose payload is a binary-plist of the UserDefaults domain). Returns nil when the
    /// blob is absent or carries no roster key, so callers can skip the union when there is nothing
    /// to merge. Reads the same `stremiox.profiles` JSON the ProfileStore persists.
    static func decodeRoster(fromSettingsBlob blob: Any?) -> [UserProfile]? {
        guard let b64 = blob as? String, let data = Data(base64Encoded: b64),
              let domain = try? SettingsBackup.decodeDomain(from: data),
              let rosterData = domain["stremiox.profiles"] as? Data,
              let roster = try? JSONDecoder().decode([UserProfile].self, from: rosterData) else { return nil }
        return roster
    }

    // MARK: - Profiles + settings sync (reuses the SettingsBackup serialization as the doc payload)

    /// Push this device's profiles + settings to the account. MERGES into the existing doc (preserving
    /// keys other surfaces wrote, e.g. the website's Stremio import) instead of replacing it, and carries
    /// the metadata keys explicitly because they live in the Keychain (SettingsBackup excludes them).
    @discardableResult
    func syncUp() async -> Bool {
        guard isSignedIn else { return false }
        // Data-loss guard: a FAILED pull (network error or undecryptable doc) must NEVER overwrite the
        // account's existing document, or it wipes keys other surfaces wrote (the website's Stremio-imported
        // library + add-ons). Only start from an empty doc when the account POSITIVELY has no backup yet.
        var doc: [String: Any]
        switch await pullSyncDocResult() {
        case .failed: return false
        case .empty: doc = [:]
        case .doc(let existing): doc = existing
        }
        // UNION the cloud's roster into the local one BEFORE makeBackup(), so a device with FEWER
        // profiles never shrinks the cloud's profile set: the pushed blob already contains both sides.
        // Any cloud-only profile that gets merged back keeps its own watch overlay (mergeInRoster does
        // not clear watchCacheKey), so its Continue Watching is not lost when it returns to this device.
        if let cloudRoster = Self.decodeRoster(fromSettingsBlob: doc["settings"]) {
            ProfileStore.shared.mergeInRoster(cloudRoster)
        }
        guard let data = try? SettingsBackup.makeBackup() else { return false }
        doc["settings"] = data.base64EncodedString()
        doc["format"] = 1
        doc["vortx"] = vortxSummary()   // JSON the dashboard can read (profiles, active selection)
        var keys: [String: String] = [:]
        if let t = ApiKeys.tmdbKey() { keys["tmdb"] = t }
        if let m = ApiKeys.mdblistKey() { keys["mdblist"] = m }
        if keys.isEmpty { doc.removeValue(forKey: "apiKeys") } else { doc["apiKeys"] = keys }
        // Recent searches, per profile (SearchHistoryStore is UserDefaults-only so it does not ride the
        // SettingsBackup blob). Key by the same profile id the search UI uses (activeID), plus the
        // "default" bucket for searches made with no profile selected. Best-effort: skip empty lists.
        var searches: [String: [String]] = [:]
        for p in ProfileStore.shared.profiles {
            let terms = SearchHistoryStore.allTerms(for: p.id)
            if !terms.isEmpty { searches[p.id.uuidString] = terms }
        }
        let defaultTerms = SearchHistoryStore.allTerms(for: nil)
        if !defaultTerms.isEmpty { searches["default"] = defaultTerms }
        if searches.isEmpty { doc.removeValue(forKey: "searches") } else { doc["searches"] = searches }
        return await pushSyncDoc(doc)
    }

    /// Pull the account's profiles + settings (and metadata keys) and apply them locally. True if anything
    /// was restored.
    /// Pull the account's profiles + settings and apply them locally. Version-aware so it only applies
    /// changes NEWER than what this device already has (and skips while a local push is queued, so it
    /// never clobbers a fresh local edit). `force` ignores both guards (used by the manual "Sync now"
    /// and by sign-in reconciliation). True if anything was restored.
    @discardableResult
    func syncDown(force: Bool = false) async -> Bool {
        guard isSignedIn else { return false }
        if !force, hasPendingPush { return false }
        guard let pulled = await pullDocVersioned() else { return false }
        if !force, pulled.version <= lastSyncedVersion { return false }
        let doc = pulled.doc
        var restored = false
        if let b64 = doc["settings"] as? String, let data = Data(base64Encoded: b64) {
            // Capture the LIVE roster BEFORE restore: SettingsBackup.restore overwrites the roster key
            // with the cloud blob wholesale, and a cloud blob with FEWER profiles would otherwise delete
            // a richer local profile (the data-loss bug). Restore, re-read the cloud roster, then UNION
            // the captured local roster back in so no local-only profile is ever dropped by this pull.
            let localRosterBefore = ProfileStore.shared.profiles
            if ((try? SettingsBackup.restore(from: data)) ?? 0) > 0 {
                restored = true
                ProfileStore.shared.reloadFromDefaults()              // apply the cloud roster to the LIVE store, no relaunch
                ProfileStore.shared.mergeInRoster(localRosterBefore)  // cloud UNION local: keep every local-only profile
                LastStreamStore.invalidateCache()                    // the restore wrote new lastStream behind the cache; re-read it
            }
        }
        if let keys = doc["apiKeys"] as? [String: String] {
            if let t = keys["tmdb"] { ApiKeys.shared.tmdb = t }
            if let m = keys["mdblist"] { ApiKeys.shared.mdblist = m }
            restored = true
        }
        if let searches = doc["searches"] as? [String: [String]] {
            for (key, terms) in searches {
                // "default" is the no-profile bucket (nil); everything else is a profile UUID. Merge keeps
                // each profile's own list separate, so one profile's searches never leak to another.
                let profileID = key == "default" ? nil : UUID(uuidString: key)
                if key != "default", profileID == nil { continue }
                SearchHistoryStore.merge(terms, for: profileID)
            }
            restored = true
        }
        // Per-profile library / Continue Watching for OVERLAY profiles (the missing leg): syncUp wrote each
        // profile's overlay into doc.vortx.byProfile (what the dashboard reads); this pulls it BACK into the
        // local overlay so a secondary profile's library + CW actually appear in the app on every device, not
        // just the dashboard. ProfileStore.applyRemoteOverlay merges last-writer-wins per item and only ever
        // touches overlay caches, never the owner/engine (account) library.
        if let vortx = doc["vortx"] as? [String: Any], let byProfile = vortx["byProfile"] as? [String: Any] {
            for (idStr, raw) in byProfile {
                guard let uuid = UUID(uuidString: idStr),
                      let bucket = raw as? [String: Any],
                      let lib = bucket["library"] as? [[String: Any]] else { continue }
                var entries: [String: WatchEntry] = [:]
                for item in lib {
                    guard let metaId = item["id"] as? String, !metaId.isEmpty else { continue }
                    let tSec = (item["t"] as? Int) ?? Int((item["t"] as? Double) ?? 0)
                    let dSec = (item["d"] as? Int) ?? Int((item["d"] as? Double) ?? 0)
                    let videoId = (item["v"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    var e = WatchEntry(videoId: videoId, timeOffsetMs: tSec * 1000, durationMs: dSec * 1000,
                                       lastWatched: item["lastWatched"] as? String ?? "",
                                       name: item["name"] as? String ?? "",
                                       type: item["type"] as? String ?? "movie",
                                       poster: (item["poster"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                    e.watchedVideoIds = item["w"] as? [String] ?? []
                    entries[metaId] = e
                }
                ProfileStore.shared.applyRemoteOverlay(profileID: uuid, entries: entries)
            }
            restored = true
        }
        // Web-authored profile edits (vortx.tv dashboard writes doc.profileEdits, a SIBLING key the app
        // preserves via syncUp's read-merge-write, unlike doc.vortx which the app overwrites). Apply
        // name/familyEdit/pin + per-profile library adds, LWW by editedAt, once per stamp.
        if let edits = doc["profileEdits"] as? [String: Any] {
            let editedAt = (edits["editedAt"] as? Double) ?? Double((edits["editedAt"] as? Int) ?? 0)
            if editedAt > lastAppliedProfileEditsAt {
                ProfileStore.shared.applyProfileEdits(edits)
                lastAppliedProfileEditsAt = editedAt
                restored = true
            }
        }
        lastSyncedVersion = max(lastSyncedVersion, pulled.version)
        return restored
    }

    // MARK: - Reconciliation (no blind last-writer-wins)

    enum SignInReconcile: Equatable { case seededFromDevice, hasAccountData }

    /// True when the account already holds synced data (so a sign-in is a merge/conflict, not a seed).
    func accountHasSyncData() async -> Bool {
        guard let doc = await pullSyncDoc() else { return false }
        return doc["settings"] != nil || doc["apiKeys"] != nil
    }

    /// Call right after a successful sign-in. A fresh (empty) account is seeded from this device; if the
    /// account already has data, the UI must ASK the user which side to keep (useAccountData vs pushThisDevice).
    func reconcileAfterSignIn() async -> SignInReconcile {
        if await accountHasSyncData() { return .hasAccountData }
        await syncUp()
        return .seededFromDevice
    }

    /// Conflict resolution: replace this device's profiles + settings with the account's (forced).
    /// Even this "use account" path still UNIONs profiles (syncDown merges the local roster back in),
    /// so it can never delete a local-only profile; it only adopts the account's settings + fields.
    func useAccountData() async { await syncDown(force: true) }
    /// Conflict resolution / "Sync now": push this device's profiles + settings to the account.
    @discardableResult func pushThisDevice() async -> Bool { await syncUp() }

    /// Conflict resolution (the RECOMMENDED choice on an explicit "Sync now" when the rosters differ):
    /// union both ways so EVERY profile from both sides survives, then push. syncDown unions the cloud
    /// roster into this device, and syncUp re-unions and pushes, so afterwards both the device and the
    /// account hold the full set of profiles.
    @discardableResult func mergeBoth() async -> Bool {
        await syncDown(force: true)
        return await syncUp()
    }

    /// Whether this device's live roster differs (by the set of profile ids) from the account's, so the
    /// explicit "Sync now" button can decide between a silent push and the three-way conflict prompt.
    func rosterConflictWithAccount() async -> Bool {
        guard let cloudRoster = Self.decodeRoster(fromSettingsBlob: (await pullSyncDoc())?["settings"]) else { return false }
        return ProfileStore.shared.rosterDiffers(from: cloudRoster)
    }

    /// Refresh account fields from /me (e.g. two-factor was toggled on the website), so the app's view
    /// of the account is not stuck at whatever sign-in returned (Bug 1).
    func refreshAccount() async {
        guard isSignedIn, var a = account else { return }
        let (code, json) = await request("GET", "/v1/auth/me", auth: true)
        guard code == 200, let acct = json?["account"] as? [String: Any] else { return }
        a.username = acct["username"] as? String ?? a.username
        a.twoFactorEnabled = acct["twoFactorEnabled"] as? Bool ?? a.twoFactorEnabled
        account = a
        persist()
    }

    /// Auto-sync: a debounced push, called whenever a setting / profile / key changes. Coalesces a burst
    /// of edits into one push a couple of seconds later, so every change propagates without spamming.
    private var pendingSync: Task<Void, Never>?
    func requestSyncSoon() {
        guard isSignedIn else { return }
        hasPendingPush = true
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            await self?.syncUp()
            self?.hasPendingPush = false
        }
    }

    // MARK: - Real-time pull (WebSocket SyncRoom) + while-active poll fallback

    /// Open the real-time channel: connect to the worker SyncRoom and start the while-active poll.
    /// Called on scene .active and on sign-in. Fail-soft and idempotent: no-op when signed out or
    /// already running, and a missing/failed WebSocket never breaks the existing foreground pull.
    func startRealtime() {
        guard isSignedIn, !realtimeActive else { return }
        realtimeActive = true
        wsBackoff = 1
        connectWebSocket()
        startPoll()
        // Catch up immediately on the way in (matches the scenePhase foreground pull), so a change made
        // while this device was backgrounded applies right away rather than waiting for the next push.
        Task { await syncDown() }
    }

    /// Close the real-time channel: tear down the socket, reconnect, keep-alive, and the poll. Called on
    /// scene .background and on sign-out. Safe to call repeatedly.
    func stopRealtime() {
        realtimeActive = false
        wsReconnect?.cancel(); wsReconnect = nil
        wsKeepAlive?.cancel(); wsKeepAlive = nil
        pollTask?.cancel(); pollTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func connectWebSocket() {
        guard realtimeActive, isSignedIn, let token,
              // https -> wss for the SyncRoom upgrade endpoint.
              let url = URL(string: base.replacingOccurrences(of: "https://", with: "wss://") + "/v1/sync/connect")
        else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        ws = task
        task.resume()
        startKeepAlive()
        receiveNext()
    }

    /// One receive at a time, re-armed after each message. A failure means the socket dropped: schedule a
    /// backoff reconnect (the while-active poll keeps changes flowing in the meantime).
    private func receiveNext() {
        guard let task = ws else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.ws === task else { return }   // ignore a stale socket's late callback
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.wsBackoff = 1   // a clean message means the link is healthy; reset backoff
                    self.receiveNext()
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "updated" else { return }
        // Only pull when the broadcast version is genuinely newer than what we hold. This is the same
        // version guard syncDown() enforces, checked up front so our own push echo (and the keep-alive
        // pong) never triggers a redundant pull or a feedback loop with requestSyncSoon.
        let version = (obj["version"] as? Int) ?? Int(obj["version"] as? Double ?? 0)
        guard version > lastSyncedVersion else { return }
        Task { await syncDown() }   // syncDown re-checks the guard, so this stays idempotent
    }

    private func scheduleReconnect() {
        ws?.cancel(with: .abnormalClosure, reason: nil)
        ws = nil
        wsKeepAlive?.cancel(); wsKeepAlive = nil
        guard realtimeActive, isSignedIn else { return }
        let delay = wsBackoff
        wsBackoff = min(wsBackoff * 2, wsMaxBackoff)
        wsReconnect?.cancel()
        wsReconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.connectWebSocket() }
        }
    }

    /// Periodic "ping" so an idle room (Hibernation API) keeps our socket; the worker replies "pong".
    private func startKeepAlive() {
        wsKeepAlive?.cancel()
        wsKeepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.keepAliveNanos ?? 30_000_000_000)
                if Task.isCancelled { return }
                guard let self, let task = self.ws else { return }
                task.send(.string("ping")) { [weak self] error in
                    if error != nil { Task { @MainActor in self?.scheduleReconnect() } }
                }
            }
        }
    }

    /// Lightweight fallback: while active, pull every ~10s so changes propagate near-real-time even if the
    /// WebSocket is unavailable. Cheap (the version guard skips no-op pulls) and cancelled on background.
    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 10_000_000_000)
                if Task.isCancelled { return }
                await self?.syncDown()   // guarded: applies only versions newer than ours, skips while a push is queued
            }
        }
    }
}
