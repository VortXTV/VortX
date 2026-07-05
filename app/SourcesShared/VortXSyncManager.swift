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
    /// Newest doc version this device has pushed or applied. Persisted to UserDefaults (kVersionKey) so the
    /// version-wins guard stays consistent across relaunches: an in-memory 0 after a cold launch would treat
    /// the account's current doc as "newer" and re-apply it once on every launch (harmless but wasteful, and
    /// it re-runs the restore). Seeded from UserDefaults at init.
    private static let kVersionKey = "vortx.sync.lastSyncedVersion"
    private var lastSyncedVersion = UserDefaults.standard.integer(forKey: VortXSyncManager.kVersionKey)
    private func persistLastSyncedVersion() {
        UserDefaults.standard.set(lastSyncedVersion, forKey: Self.kVersionKey)
    }
    /// LWW stamp of the last web profileEdits applied. Persisted to UserDefaults so a sign-out / re-login
    /// does not re-window an old dashboard edit (e.g. a delete the app has already honored): an in-memory
    /// 0 after re-login would re-apply a stale profileEdits overlay. Re-apply is idempotent regardless.
    private static let kEditsAtKey = "vortx.sync.lastAppliedProfileEditsAt"
    private var lastAppliedProfileEditsAt: Double {
        get { UserDefaults.standard.double(forKey: Self.kEditsAtKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.kEditsAtKey) }
    }
    /// Last shared add-on ORDER applied from the account (Bug B). Persisted normalized transportUrls in the
    /// converged priority order. Read by ownedAddons(from:) as the ordering spine when a pulled doc does not
    /// itself carry addonOrder, so a device that hydrates after (but not during) an order change still lands
    /// the converged order. Empty means "no shared order yet" (fall back to the descriptor spine).
    private static let kAddonOrderKey = "vortx.sync.appliedAddonOrder"
    static var appliedAddonOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: kAddonOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: kAddonOrderKey) }
    }
    private var hasPendingPush = false  // a debounced syncUp is queued; don't pull over it
    /// Set while syncDown is applying a remote pull (the SettingsBackup.restore + apiKeys + overlays +
    /// tombstones region) and while ProfileStore is doing touch:false launch housekeeping. The global
    /// UserDefaults.didChangeNotification observer early-returns while this is true, so applying a pull
    /// (which rewrites every stremiox.* key) no longer self-echoes into requestSyncSoon() — which would
    /// re-arm hasPendingPush and push the just-applied peer values straight back, starving syncDown's
    /// guard at line ~471 so a receiving device never applies a peer's settings. A genuine user edit
    /// (touch:true) is NEVER wrapped in this, so real settings toggles still push and sync.
    private var isApplyingRemote = false

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
        // SUPPRESSION: while isApplyingRemote is true the write came from applying a remote pull or from
        // routine touch:false launch housekeeping, NOT a user edit, so it must not arm a push. Without this,
        // the receiving device's syncDown re-arms hasPendingPush (self-echo) and starves its own pull guard,
        // so peer settings never apply (the Beta 8/9 settings-sync regression). The notification is delivered
        // on the main queue, so reading the @MainActor flag here is safe.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isApplyingRemote else { return }
                self.requestSyncSoon()
            }
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

    /// Push a doc at an explicit version. Returns the worker's optimistic-concurrency verdict so the
    /// caller can react to a lost race, NOT a bare Bool that conflates "stored" with "rejected". The
    /// worker replies `{ accepted:true }` when it stored a strictly-newer version, or `{ accepted:false,
    /// version:<current stored> }` when a concurrent write already won. lastSyncedVersion advances ONLY on
    /// accepted==true: advancing it on a rejected write (the old bug) suppressed the recovery pull, so a
    /// write that LOST the race was silently dropped and the device stayed diverged.
    private enum PushOutcome { case accepted(version: Int); case rejected(storedVersion: Int?); case error }
    private func pushSyncDocAt(_ obj: [String: Any], version: Int) async -> PushOutcome {
        guard let dataKey, let pt = try? JSONSerialization.data(withJSONObject: obj),
              let ct = VortXSyncCrypto.seal(key: dataKey, pt) else { return .error }
        let (code, json) = await request("PUT", "/v1/backup", body: ["document": ct, "version": version], auth: true)
        guard code == 200 else { return .error }
        // accepted defaults to true so an older worker without the field (which stored the write) still
        // advances the version, matching the website's `accepted !== false` read.
        let accepted = (json?["accepted"] as? Bool) ?? true
        if accepted {
            lastSyncedVersion = max(lastSyncedVersion, version)
            persistLastSyncedVersion()   // survive relaunch so the version guard stays consistent
            return .accepted(version: version)
        }
        // Rejected (a concurrent write won). The worker echoes the current stored version so we can retry
        // deterministically at stored+1 instead of racing epoch-ms again. Do NOT advance lastSyncedVersion.
        let stored = (json?["version"] as? Int) ?? (json?["version"] as? Double).map(Int.init)
        return .rejected(storedVersion: stored)
    }

    /// Blind single-shot push of a fully-formed doc the caller does not re-derive (it holds no local pending
    /// changes to re-merge, so on a rejection it just re-pushes the SAME doc above the winner). The version is
    /// `max(storedVersion+1, epochMs)` so a device whose wall clock has skewed BACKWARD (a lower epoch-ms than
    /// the stored version) can never lock itself out: it retries strictly above the stored version instead of
    /// racing a permanently-lower epoch-ms. A rejection is retried once at storedVersion+1 (same as
    /// pushDerivedDoc); a lost second race or a .error leaves lastSyncedVersion unadvanced so the next pull
    /// reconciles.
    @discardableResult
    func pushSyncDoc(_ obj: [String: Any]) async -> Bool {
        var version = Int(Date().timeIntervalSince1970 * 1000)
        for attempt in 0..<2 {
            switch await pushSyncDocAt(obj, version: version) {
            case .accepted:
                return true
            case .error:
                return false
            case .rejected(let storedVersion):
                // A concurrent write won. Retry strictly above the winner's echoed version (falling back to a
                // fresh epoch-ms if the worker did not echo one). max(stored+1, epochMs) guarantees a backward
                // clock still produces a higher version than the stored one, so the device is never locked out.
                guard attempt < 1 else { return false }
                if let stored = storedVersion {
                    version = max(stored + 1, Int(Date().timeIntervalSince1970 * 1000))
                } else {
                    version = Int(Date().timeIntervalSince1970 * 1000)
                }
            }
        }
        return false
    }

    /// Push a doc that is DERIVED from a pulled base, with optimistic-concurrency recovery. `rebuild`
    /// re-runs the caller's exact merge onto a freshly pulled base, so a lost race is recovered by
    /// re-merging the local pending changes onto the winner's doc and retrying at storedVersion+1 (up to
    /// `maxRetries`). This preserves the caller's merge semantics (LWW, never clobber libraryItem) on every
    /// attempt. On exhaustion lastSyncedVersion is left unadvanced so the next natural pull reconciles.
    private func pushDerivedDoc(_ initial: [String: Any], rebuild: () async -> [String: Any]?) async -> Bool {
        let maxRetries = 3
        var doc = initial
        var version = Int(Date().timeIntervalSince1970 * 1000)
        for attempt in 0..<maxRetries {
            switch await pushSyncDocAt(doc, version: version) {
            case .accepted:
                return true
            case .error:
                return false   // network / server / encode failure: do not advance, next pull reconciles
            case .rejected(let storedVersion):
                // A concurrent write won. Re-pull, re-merge the local pending changes onto it (same merge as
                // the first attempt), and retry strictly above the winner's version. If the rebuild can no
                // longer produce a doc (e.g. the account pull now fails), abort WITHOUT advancing so the next
                // pull reconciles rather than clobbering the winner.
                guard attempt < maxRetries - 1, let rebuilt = await rebuild() else { return false }
                doc = rebuilt
                // storedVersion+1 beats the winner deterministically; fall back to a fresh epoch-ms if the
                // worker did not echo a version (the row-vanished race), still strictly increasing.
                if let stored = storedVersion {
                    version = max(stored + 1, Int(Date().timeIntervalSince1970 * 1000))
                } else {
                    version = Int(Date().timeIntervalSince1970 * 1000)
                }
            }
        }
        return false   // exhausted retries: leave lastSyncedVersion unadvanced, next pull reconciles
    }

    /// A small JSON view of local state the website dashboard can read (the binary-plist `settings`
    /// blob is opaque to a browser). Profiles let the dashboard show the family roster + the real count.
    /// `existingVortx` is the `doc["vortx"]` just pulled from the account (nil on a fresh/empty doc). It
    /// is used for the READ-SIDE UNION GUARD: a momentarily-degraded engine (no add-ons / empty library)
    /// must never SHRINK the account-owned set on push. Mirrors the existing roster-union and apiKeys
    /// read-merge guards.
    private func vortxSummary(existingVortx: [String: Any]? = nil) -> [String: Any] {
        let store = ProfileStore.shared
        let profiles: [[String: Any]] = store.profiles.map { p in
            // pinHash is the salted SHA-256 (salt = the profile id, already here), never the raw PIN,
            // so the dashboard can verify a PIN entry by re-hashing without ever seeing the digits.
            // `settings` mirrors the per-profile app settings so the dashboard can show + manage them
            // (it writes them back via doc.profileEdits[].settings, applied by ProfileStore.applyProfileEdits).
            var settings: [String: Any] = ["avatar": p.avatar, "accent": p.accentID, "oled": p.oled, "textScale": p.textScale, "isKids": p.isKids]
            if let pb = p.playback {
                var playback: [String: Any] = ["audioLang": pb.audioLang, "subtitleLang": pb.subtitleLang,
                    "forced": pb.forcedPolicy, "subFont": pb.subFont, "subSize": pb.subSize,
                    "subColor": pb.subColor, "subBackground": pb.subBackground]
                if let s = pb.subSizeScale { playback["subSizeScale"] = s }
                if let o = pb.sourceTypeOrder { playback["sourceTypeOrder"] = o }
                if let u = pb.useAddonOrder { playback["useAddonOrder"] = u }
                if let v = pb.safetyMode { playback["safetyMode"] = v }
                if let v = pb.instantOnly { playback["instantOnly"] = v }
                if let v = pb.hideDeadTorrents { playback["hideDeadTorrents"] = v }
                if let v = pb.hdrOnly { playback["hdrOnly"] = v }
                if let v = pb.excludeAV1 { playback["excludeAV1"] = v }
                if let v = pb.excludeKeywords { playback["excludeKeywords"] = v }
                if let v = pb.includeKeywords { playback["includeKeywords"] = v }
                if let v = pb.keywordsAreRegex { playback["keywordsAreRegex"] = v }
                if let v = pb.maxResolution { playback["maxResolution"] = v }
                if let v = pb.maxFileSizeGB { playback["maxFileSizeGB"] = v }
                settings["playback"] = playback
            }
            return ["id": p.id.uuidString, "name": p.name, "locked": p.pin != nil, "main": p.isOwner,
                    "familyEdit": p.familyEdit, "pinHash": p.pin ?? "", "settings": settings,
                    "disabledAddons": p.disabledAddons ?? []]
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
        // @MainActor, so reading CoreBridge's @Published state is on the main actor. Enriched with
        // `lastWatched`+`videoId` (Step 4) so another device can rebuild CW resume, not just membership.
        let engineLibrary: [[String: Any]] = (CoreBridge.shared.library?.catalog ?? [])
            .filter { !($0.removed ?? false) && !($0.temp ?? false) }
            .map { item in
                ["id": item.id, "name": item.name, "type": item.type, "poster": item.poster ?? "",
                 "t": Int(item.state.timeOffset / 1000), "d": Int(item.state.duration / 1000),
                 "v": item.state.videoId ?? ""]
            }
        // FLOOR vs MIRROR for the owner library, per the "Mirror library from Stremio" toggle. FLOOR (OFF,
        // default) = UNION the account's already-owned `doc.vortx.library` with the engine library, so a
        // Stremio removal never removes from VortX and an empty/degraded engine can never SHRINK it. The
        // `mirror CW` toggle, when OFF, is what keeps a prior in-progress item's t/d from being zeroed by a
        // Stremio drop (the union preserves it). MIRROR (ON) = REPLACE: the live Stremio set is authoritative
        // so removals propagate - but ONLY with a live Stremio session AND a non-empty engine library, so a
        // logged-out / mid-pull shrunken set can never propagate the shrink to every device (the add-on
        // guard's clobber fix; the library has no official-defaults concept, so no `!engineIsDefaultOnly`).
        var libraryByID: [String: [String: Any]] = [:]
        let mirrorReplaceLibrary = MirrorSettings.mirrorLibrary && !engineLibrary.isEmpty && CoreBridge.shared.isLoggedIn()
        if !mirrorReplaceLibrary, let prior = (existingVortx?["library"] as? [[String: Any]]) {
            for entry in prior { if let id = entry["id"] as? String, !id.isEmpty { libraryByID[id] = entry } }
        }
        for entry in engineLibrary { if let id = entry["id"] as? String { libraryByID[id] = entry } }
        let ownerLibrary = Array(libraryByID.values)
        // Installed add-ons, so the dashboard Add-ons page is populated AND the account can re-hydrate
        // the engine network-free. We now emit the FULL descriptor `{transportUrl, name, manifest,
        // flags}` (Step 2) instead of the old `{transportUrl, name}`: hydration needs the manifest +
        // flags to InstallAddon without a fetch. dash-ui keeps reading transportUrl/name (extra keys are
        // additive and ignored). The Stremio token never enters this; only descriptors do (they already
        // ride doc.addons + apiKeys E2E today).
        let engineAddons: [[String: Any]] = CoreBridge.shared.rawAddonDescriptorsOrdered().compactMap { raw in
            guard let url = raw["transportUrl"] as? String, !url.isEmpty else { return nil }
            var entry = raw
            // The dashboard reads `name`; lift it out of the manifest so the old summary shape is a subset.
            if entry["name"] == nil, let manifest = raw["manifest"] as? [String: Any], let n = manifest["name"] as? String {
                entry["name"] = n
            }
            return entry
        }
        // READ-SIDE GUARD on the owned add-on set. Two modes, decided per the owner's per-category
        // "Mirror add-ons from Stremio" toggle:
        //   FLOOR (toggle OFF, the default) = UNION: union the live engine descriptors with the account's
        //   already-owned `doc.vortx.addons` by transportUrl, so a Stremio removal NEVER removes from VortX
        //   and a degraded engine can never SHRINK the owned set.
        //   MIRROR (toggle ON) = REPLACE: the engine (which reflects the live Stremio set after a pull) is
        //   authoritative, so a Stremio removal propagates (adds AND removes tracked).
        // NEVER-ZERO, independent of the toggle: REPLACE only applies when the engine actually has a
        // non-empty add-on set; a degraded/empty engine falls back to UNION so a failed pull can never
        // zero the category. Engine entries win on conflict in both modes (freshest descriptor).
        // ORDER-PRESERVING merge (AIOManager-compat: the AddonCollectionSet array order = Stremio
        // priority, so sync must not scramble it). The engine collection order is authoritative and is
        // the spine; in UNION mode the VortX-doc-only add-ons (in the prior sync but not the engine)
        // append after, in their own order. The engine descriptor wins on a URL in both (freshest).
        // CLOBBER GUARD (data-loss fix): a Stremio logout / token-expiry resets the engine to the DEFAULT
        // official add-ons - a NON-EMPTY set - so "non-empty" is the wrong REPLACE signal: REPLACE would
        // overwrite the owned mirror with defaults and propagate that loss to every device. Only let
        // REPLACE (the live-Stremio-is-authoritative path) win when there IS a live Stremio session AND the
        // engine holds a genuinely user-owned set (not the official defaults). Otherwise UNION preserves the
        // owned mirror, so a logout can never shrink doc.vortx.addons to defaults.
        let engineIsDefaultOnly = engineAddons.allSatisfy { (($0["flags"] as? [String: Any])?["official"] as? Bool) == true }
        let mirrorReplaceAddons = MirrorSettings.mirrorAddons && !engineAddons.isEmpty
            && CoreBridge.shared.isLoggedIn() && !engineIsDefaultOnly
        // SUBTRACT the durable removal tombstones from the union (the add-on analogue of subtracting
        // deletedProfiles from the roster union): an add-on the user removed must NOT come back, even if
        // the engine still briefly holds it OR a peer device's prior doc.vortx.addons still carries it.
        // Official/protected stubs are never tombstoned, so this never drops a default. Compared on the
        // same normalized (trim+lowercase) transportUrl the tombstone is stored under.
        let removedAddons = AddonTombstones.all()
        var addonList: [[String: Any]] = []
        var seenAddonURLs = Set<String>()
        for entry in engineAddons {
            guard let url = entry["transportUrl"] as? String,
                  !removedAddons.contains(AddonTombstones.normalize(url)),
                  seenAddonURLs.insert(url).inserted else { continue }
            addonList.append(entry)
        }
        if !mirrorReplaceAddons, let prior = (existingVortx?["addons"] as? [[String: Any]]) {
            for entry in prior {
                guard let url = entry["transportUrl"] as? String, !url.isEmpty,
                      !removedAddons.contains(AddonTombstones.normalize(url)),
                      seenAddonURLs.insert(url).inserted else { continue }
                addonList.append(entry)
            }
        }

        var v: [String: Any] = ["profiles": profiles, "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
        if !byProfile.isEmpty { v["byProfile"] = byProfile }
        if !ownerLibrary.isEmpty { v["library"] = ownerLibrary }
        if !addonList.isEmpty {
            v["addons"] = addonList
            // addonsOwnedAt distinguishes "owns an empty set" from "never snapshotted". Set ONCE, the
            // first time a non-empty owned set is written; preserved verbatim thereafter (carried from the
            // pulled doc), so it anchors ownership age without being reset on every push.
            if let priorOwnedAt = existingVortx?["addonsOwnedAt"] {
                v["addonsOwnedAt"] = priorOwnedAt
            } else {
                v["addonsOwnedAt"] = Int(Date().timeIntervalSince1970 * 1000)
            }
        } else if let priorOwnedAt = existingVortx?["addonsOwnedAt"] {
            v["addonsOwnedAt"] = priorOwnedAt   // never lose the anchor even on an empty push
        }
        if let active = store.activeID { v["activeProfile"] = active.uuidString }
        // Durable cross-device delete tombstones (the app owns this; the dashboard only READS it). Carries
        // the set of deleted profile ids so a peer device drops them on its next union-merge instead of
        // resurrecting them. Empty set is omitted so a fresh account never writes the key.
        let deleted = store.deletedProfileIDs
        if !deleted.isEmpty { v["deletedProfiles"] = Array(deleted) }
        // Durable cross-device add-on REMOVAL tombstones (app-authoritative, exactly like deletedProfiles;
        // the dashboard only READS it). Carries the normalized transportUrls the user removed so a peer
        // device uninstalls them on its next pull instead of re-hydrating them. Empty set is omitted.
        if !removedAddons.isEmpty { v["deletedAddons"] = Array(removedAddons) }
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
        // Build the merged doc from the current account base, then push with optimistic-concurrency
        // recovery: if a concurrent write wins the race, re-run this exact merge onto the winner's doc and
        // retry (bounded). The rebuild closure re-pulls a fresh base each attempt so the recovered push
        // never clobbers the winner; it returns nil on a failed pull so the retry aborts safely.
        guard let initial = await mergeLocalIntoDoc(base: nil) else { return false }
        return await pushDerivedDoc(initial, rebuild: { await self.mergeLocalIntoDoc(base: nil) })
    }

    /// Build the doc to push by MERGING this device's profiles + settings + keys + add-on order onto a
    /// freshly pulled account base (preserving keys other surfaces wrote). Extracted from syncUp so the
    /// optimistic-concurrency retry can re-run the EXACT same merge onto the winner's doc after a lost
    /// race, with identical LWW / union / never-clobber-libraryItem semantics on every attempt. `base` is
    /// unused today (each call re-pulls) but kept so a caller could pass a known base to avoid a re-pull.
    /// Returns nil on a FAILED pull (network error / undecryptable doc): a failed pull must NEVER overwrite
    /// the account's existing document, or it wipes keys other surfaces wrote.
    private func mergeLocalIntoDoc(base: [String: Any]?) async -> [String: Any]? {
        var doc: [String: Any]
        switch await pullSyncDocResult() {
        case .failed: return nil
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
        guard let data = try? SettingsBackup.makeBackup() else { return nil }
        doc["settings"] = data.base64EncodedString()
        doc["format"] = 1
        // Pass the PULLED vortx block so vortxSummary can union the account-owned add-on set (never
        // shrink it from a degraded engine) and preserve addonsOwnedAt.
        doc["vortx"] = vortxSummary(existingVortx: doc["vortx"] as? [String: Any])
        // Shared cross-surface add-on ORDER (Bug B). A sibling top-level key (like profileEdits) the app
        // WRITES from the current engine order and the web dashboard also reads/writes, so a reorder on
        // any surface converges. Emit the normalized transportUrls in the engine's true priority order.
        // Omitted when there is nothing to order so a fresh account never writes an empty key.
        let order = Self.currentAddonOrder()
        if order.isEmpty { doc.removeValue(forKey: "addonOrder") } else { doc["addonOrder"] = order }
        // READ-MERGE, never wholesale-rebuild. Start from the PULLED apiKeys and only SET the keys this
        // device actually holds; never DELETE a key this device did not author. A device without a TMDB
        // key (or with no keys at all) used to drop the whole object on push, and because pushes version
        // with epoch-ms wall-clock they win last-writer-wins over the dashboard's save, wiping the
        // dashboard's TMDB key. Mirrors the asymmetric read-side debrid guard in syncDown.
        var keys = (doc["apiKeys"] as? [String: String]) ?? [:]
        if let t = ApiKeys.tmdbKey() { keys["tmdb"] = t }
        if let m = ApiKeys.mdblistKey() { keys["mdblist"] = m }
        if let f = ApiKeys.fanartKey() { keys["fanart"] = f }
        // Debrid keys ride the same encrypted apiKeys channel so they follow the account across devices
        // (they live in the Keychain, which SettingsBackup deliberately excludes, so they need this mirror).
        // Set only when configured locally; do NOT remove a key absent locally (another device authored it).
        let debrid = DebridKeys.shared
        if debrid.isConfigured(.realDebrid) { keys["realDebrid"] = debrid.key(for: .realDebrid) }
        if debrid.isConfigured(.allDebrid)  { keys["allDebrid"]  = debrid.key(for: .allDebrid) }
        if debrid.isConfigured(.premiumize) { keys["premiumize"] = debrid.key(for: .premiumize) }
        if debrid.isConfigured(.torBox)     { keys["torBox"]     = debrid.key(for: .torBox) }
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
        return doc
    }

    /// The current add-on order this device holds, as normalized transportUrls in the engine's true
    /// priority order (the same `rawAddonDescriptorsOrdered` spine `vortxSummary` uses). Removed add-ons
    /// (tombstoned) are excluded so the shared order never re-lists a removed add-on. Normalized on the
    /// same trim+lowercase as the tombstone + doc.addonOrder read side so cross-surface comparison holds.
    static func currentAddonOrder() -> [String] {
        let removed = AddonTombstones.all()
        var seen = Set<String>()
        var order: [String] = []
        for raw in CoreBridge.shared.rawAddonDescriptorsOrdered() {
            guard let url = raw["transportUrl"] as? String, !url.isEmpty else { continue }
            let normalized = AddonTombstones.normalize(url)
            guard !removed.contains(normalized), seen.insert(normalized).inserted else { continue }
            order.append(normalized)
        }
        return order
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
        // PENDING-EDIT GUARD. When a GENUINE local edit is queued (a settings toggle, a profile delete: the
        // observer armed hasPendingPush), defer this pull until that edit's debounced push lands. Without it an
        // interleaved pull re-applies the account's pre-edit value and the change the user just made flips back
        // within a second: the ERDB / fanart toggle that would not stay off, and the deleted profile that came
        // straight back. This is SAFE from the Beta 8/9 starvation now that routine touch:false launch
        // housekeeping is suppressed and no longer arms hasPendingPush (see the observer + suppressHousekeeping):
        // an idle receiving device has hasPendingPush == false, so it still applies a peer's newer settings. The
        // queued push fires on its own debounce and syncUp read-merges, so deferring here never loses anything.
        if !force, hasPendingPush { return false }
        guard let pulled = await pullDocVersioned() else { return false }
        // VERSION-WINS: once no local edit is pending, apply only a STRICTLY NEWER remote; a stale or equal pull
        // is a no-op. lastSyncedVersion is persisted (kVersionKey) so this holds across relaunches.
        if !force, pulled.version <= lastSyncedVersion { return false }
        // `force` (manual "Sync now" / sign-in reconciliation) intentionally re-applies even a stale/equal doc
        // for the UNION-SAFE merges (roster, settings, apiKeys): those can only ADD, never resurrect a delete.
        // But the DESTRUCTIVE folds (delete tombstones, add-on-removal uninstalls, profileEdits) must still be
        // version-gated even under force: a stale forced pull that predates a delete would otherwise let a
        // resurrected old edit/delete win over a newer local state. Gate them on a strictly-newer pull only.
        let pullIsNewer = pulled.version > lastSyncedVersion
        let doc = pulled.doc
        var restored = false
        // SUPPRESS THE OBSERVER for the whole apply region. SettingsBackup.restore + the apiKeys/overlay/
        // tombstone/profileEdits writes below all hit UserDefaults; without suppression each fires the
        // global didChangeNotification observer, which calls requestSyncSoon() -> re-arms hasPendingPush and
        // schedules a push of the just-applied peer values straight back up (the self-echo). That keeps the
        // receiving device permanently inside the hasPendingPush window, so its next syncDown bails at the
        // guard and the peer's settings are never applied. The body is fully synchronous (no awaits), so the
        // coalesced notifications drain on the next main-queue turn while the flag is still set.
        withRemoteApplySuppressed {
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
                ProfileStore.shared.applyLocalTombstones()           // a profile deleted this session stays gone even if the pulled doc predates its tombstone (the resurrect window)
                LastStreamStore.invalidateCache()                    // the restore wrote new lastStream behind the cache; re-read it
            }
        }
        if let keys = doc["apiKeys"] as? [String: String] {
            if let t = keys["tmdb"] { ApiKeys.shared.tmdb = t }
            if let m = keys["mdblist"] { ApiKeys.shared.mdblist = m }
            if let f = keys["fanart"] { ApiKeys.shared.fanart = f }
            // Debrid keys: apply only when present so a doc without them never clears a locally-entered key.
            let debrid = DebridKeys.shared
            if let v = keys["realDebrid"], v != debrid.key(for: .realDebrid) { debrid.setKey(v, for: .realDebrid) }
            if let v = keys["allDebrid"],  v != debrid.key(for: .allDebrid)  { debrid.setKey(v, for: .allDebrid) }
            if let v = keys["premiumize"], v != debrid.key(for: .premiumize) { debrid.setKey(v, for: .premiumize) }
            if let v = keys["torBox"],     v != debrid.key(for: .torBox)     { debrid.setKey(v, for: .torBox) }
            // A key that ARRIVED from another device must take effect here too: rebuild the resolvers so
            // the changed/new key is live (setKey already nudges this on a local edit; this covers the pull
            // path explicitly). @MainActor hop because the coordinator is main-actor isolated. This runs
            // AFTER the outer withRemoteApplySuppressed window has cleared isApplyingRemote, so wrap the body
            // in its own suppression to keep reload()'s writes from re-arming a self-echo push.
            Task { @MainActor in Self.shared.withRemoteApplySuppressed { DebridCoordinator.shared.reload() } }
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
        // Cross-device delete tombstones: fold any incoming doc.vortx.deletedProfiles into the local set
        // FIRST (before applying the roster below), so a profile another device deleted is dropped here
        // and the union-merge can never bring it back. mergeDeletedTombstones also prunes the live roster.
        if pullIsNewer, let vortx = doc["vortx"] as? [String: Any], let deleted = vortx["deletedProfiles"] as? [String] {
            if ProfileStore.shared.mergeDeletedTombstones(deleted) { restored = true }
        }
        // Cross-device add-on REMOVAL tombstones (the add-on analogue of the deletedProfiles fold above).
        // Reached ONLY inside this withRemoteApplySuppressed region, which runs after a STRICTLY-NEWER,
        // SUCCESSFUL pullDocVersioned() — a .failed/.empty pull returns earlier, so a stale/partial sync
        // can NEVER drive an uninstall. Fold the app-authored doc.vortx.deletedAddons AND a (future)
        // web-authored doc.webAddonRemovals array into the durable local set, then uninstall any
        // tombstoned add-on still installed in the engine. The uninstall is HARD-GATED to non-official,
        // non-protected descriptors so a default stub is never removed; it passes tombstone: false because
        // the URL is already tombstoned (re-recording would be a redundant no-op). The local set is also
        // subtracted from hydrateEngineFromOwnedAddons' ownedAddons(from:), so a removed add-on is never
        // reinstalled on the next hydrate even before this uninstall runs.
        // Fold the DOC's incoming removals only on a strictly-newer pull (see pullIsNewer above): a stale
        // forced pull that predates a locally-restored add-on must not resurrect its old removal. The uninstall
        // loop below still reads the durable LOCAL tombstone set, so a removal recorded on THIS device is
        // always honored regardless of force.
        var incomingAddonRemovals: [String] = []
        if pullIsNewer, let vortx = doc["vortx"] as? [String: Any], let removed = vortx["deletedAddons"] as? [String] {
            incomingAddonRemovals += removed
        }
        if pullIsNewer, let webRemoved = doc["webAddonRemovals"] as? [String] {   // web agent owns this write; we only READ it
            incomingAddonRemovals += webRemoved
        }
        if AddonTombstones.merge(incomingAddonRemovals) { restored = true }
        // Shared cross-surface add-on ORDER (Bug B, read side). Persist the incoming order locally so it is
        // durable and available to ownedAddons(from:) at the next hydrate (launch / degraded-engine
        // rehydrate), where it becomes the ordering spine so a reorder from any surface converges. Reached
        // ONLY inside this suppression region after a STRICTLY-NEWER, SUCCESSFUL pull, so a stale/partial
        // sync can never scramble the order. Reordering the ALREADY-hydrated live engine Vec needs a
        // CoreBridge action (out of scope here); the persisted order takes effect on the next hydrate.
        if let addonOrder = doc["addonOrder"] as? [String] {
            let normalized = addonOrder.map { AddonTombstones.normalize($0) }
            if normalized != Self.appliedAddonOrder {
                Self.appliedAddonOrder = normalized
                restored = true
            }
        }
        let removedAddonSet = AddonTombstones.all()
        if !removedAddonSet.isEmpty {
            // Runs AFTER the outer withRemoteApplySuppressed window has cleared isApplyingRemote, so wrap the
            // uninstall loop in its own suppression: uninstallAddon writes UserDefaults, which would otherwise
            // fire the observer and re-arm a self-echo push of the just-applied removal.
            Task { @MainActor in
                Self.shared.withRemoteApplySuppressed {
                    for addon in CoreBridge.shared.addons
                    where removedAddonSet.contains(AddonTombstones.normalize(addon.transportUrl))
                        && !addon.isOfficial && !addon.isProtected {
                        CoreBridge.shared.uninstallAddon(addon, tombstone: false)
                    }
                }
            }
        }
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
        // Gated on a strictly-newer pull (pullIsNewer) as well as the per-stamp editedAt guard: a stale forced
        // pull that predates a local change must not re-apply a resurrected old edit whose editedAt happens to
        // exceed this device's last-applied stamp.
        if pullIsNewer, let edits = doc["profileEdits"] as? [String: Any] {
            let editedAt = (edits["editedAt"] as? Double) ?? Double((edits["editedAt"] as? Int) ?? 0)
            if editedAt > lastAppliedProfileEditsAt {
                ProfileStore.shared.applyProfileEdits(edits)
                lastAppliedProfileEditsAt = editedAt
                restored = true
            }
        }
        // Stamp the applied version INSIDE the suppression window: persistLastSyncedVersion writes to
        // UserDefaults, which would otherwise fire the observer and re-arm a push (another self-echo path).
        lastSyncedVersion = max(lastSyncedVersion, pulled.version)
        persistLastSyncedVersion()
        }   // end withRemoteApplySuppressed
        return restored
    }

    // MARK: - Account owns everything (hydrate-from-doc + snapshot-on-import)

    /// Hydrate the engine from the VortX account's OWNED add-ons + recover the owner library, so a
    /// logged-out / degraded Stremio session shows the account's add-ons + sources + library instead of
    /// zero (the "post-update: 0 sources / 0 add-ons" fix). This is the load-bearing new capability.
    ///
    /// NEVER-ZERO INVARIANT: a `.failed` or `.empty` account pull does NOTHING (we never hydrate-then-
    /// empty). Only a real `.doc` triggers hydration. Not gated by the mirror toggles — the VortX-owned
    /// set always hydrates when the engine is empty/degraded; the toggles only control the snapshot
    /// DIRECTION (Stremio -> VortX), not the floor.
    ///
    /// Owned add-ons = `doc.vortx.addons` UNION `doc.addons` (the website Stremio import) by transportUrl.
    /// Hydration installs only descriptors the engine lacks (idempotent). Library recovery is gated to
    /// "engine account library empty AND the account owns one" so it runs at most once per fresh install.
    func hydrateEngineFromOwnedAddons() async {
        guard isSignedIn else { return }
        guard case let .doc(doc) = await pullSyncDocResult() else { return }   // .failed/.empty: do nothing
        let owned = Self.ownedAddons(from: doc)
        if !owned.isEmpty {
            CoreBridge.shared.hydrateAddonsFromAccount(owned)
        }
        await recoverOwnerLibraryIfEmpty(from: doc)
    }

    /// Compute the account-owned add-on descriptors from a pulled doc: `doc.vortx.addons` (the app's
    /// full descriptors) UNIONed with `doc.addons` (the website's Stremio import) by transportUrl.
    /// vortx.addons wins on conflict (it carries the freshest app descriptor). Legacy `{transportUrl,
    /// name}`-only entries (no manifest) are dropped: without a manifest the engine cannot InstallAddon.
    static func ownedAddons(from doc: [String: Any]) -> [VortXOwnedAddon] {
        var byUrl: [String: VortXOwnedAddon] = [:]
        var order: [String] = []   // preserve install order (AIOManager-compat: collection order = priority)
        // EXCLUDE durable removal tombstones so hydrateEngineFromOwnedAddons never REINSTALLS an add-on the
        // user removed (the install-only hydrate was the gap that let a removal come back). The doc's
        // deletedAddons subset was already folded into this local set on syncDown; we read the local set so
        // even a doc that predates the removal is honored. Same normalized transportUrl the set is keyed by.
        let removedAddons = AddonTombstones.all()
        func add(_ a: VortXOwnedAddon) {
            guard !removedAddons.contains(AddonTombstones.normalize(a.transportUrl)) else { return }
            // First sight wins both the order slot AND the descriptor, so the app/engine-owned set (added
            // first below) defines the order spine and its richer descriptor is kept for a shared URL.
            if byUrl[a.transportUrl] == nil { order.append(a.transportUrl); byUrl[a.transportUrl] = a }
        }
        // doc.vortx.addons (the app/engine-owned set) FIRST, so it defines the order spine - matching the
        // write-side spine in vortxSummary - and its richer descriptor wins a URL present in both; then the
        // web-import-only URLs append after.
        if let vortx = doc["vortx"] as? [String: Any], let appAddons = vortx["addons"] as? [[String: Any]] {
            for raw in appAddons { if let a = VortXOwnedAddon(json: raw) { add(a) } }
        }
        if let webAddons = doc["addons"] as? [[String: Any]] {
            for raw in webAddons { if let a = VortXOwnedAddon(json: raw) { add(a) } }
        }
        // Apply the shared cross-surface add-on ORDER (Bug B) as the ordering spine when the doc carries
        // one: a reorder made on any surface (app or web dashboard) converges here so a fresh/cold device
        // hydrates add-ons in the user's chosen priority. Compared on the same normalized transportUrl the
        // order is stored under. Any owned add-on NOT named in the order (newly installed elsewhere,
        // pre-order docs) keeps its existing relative slot AFTER the ordered ones, so nothing is dropped.
        let addonOrder = (doc["addonOrder"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? appliedAddonOrder
        if !addonOrder.isEmpty {
            var normalizedToUrl: [String: String] = [:]
            for url in order { normalizedToUrl[AddonTombstones.normalize(url)] = url }
            var ordered: [String] = []
            var placed = Set<String>()
            for normalized in addonOrder {
                guard let url = normalizedToUrl[normalized], byUrl[url] != nil, placed.insert(url).inserted
                else { continue }
                ordered.append(url)
            }
            for url in order where !placed.contains(url) { ordered.append(url) }
            return ordered.compactMap { byUrl[$0] }
        }
        return order.compactMap { byUrl[$0] }
    }

    /// Rebuild the OWNER (account) library on a cold Stremio-less device, ONLY when the engine's account
    /// library is empty AND the account doc owns one. Goes exclusively through the engine
    /// `AddToLibrary`/`addCatalogItemToAccount` path (real Cinemeta meta = schema-safe). NEVER writes app
    /// data into a libraryItem doc (the poisoned-account incident). Owner-profile semantics only: items
    /// land in the account library, which is the owner profile's history.
    private func recoverOwnerLibraryIfEmpty(from doc: [String: Any]) async {
        guard let vortx = doc["vortx"] as? [String: Any] else { return }
        // doc.vortx.library is the owner library; fall back to doc.library (web Stremio import) if present.
        let ownedLibrary = (vortx["library"] as? [[String: Any]]) ?? (doc["library"] as? [[String: Any]]) ?? []
        guard !ownedLibrary.isEmpty else { return }
        // Only recover when the engine's account library is genuinely empty (a fresh / cold device). Require
        // the engine to have POSITIVELY reported a library first (`library != nil`): a nil library is the
        // not-yet-loaded state, and treating that transient zero as "empty" would re-add a full account
        // library while the engine is still loading its real one. A nil library defers recovery to a later
        // call once the engine has emitted its library field.
        guard let engineLibrary = CoreBridge.shared.library?.catalog else { return }
        let engineHasLibrary = engineLibrary.contains { !($0.removed ?? false) && !($0.temp ?? false) }
        guard !engineHasLibrary else { return }
        var recovered = 0
        for item in ownedLibrary {
            guard let id = item["id"] as? String, !id.isEmpty,
                  // Real catalog ids only (tt… / tmdb…); never a synthetic id, or it poisons account sync.
                  id.hasPrefix("tt") || id.hasPrefix("tmdb") else { continue }
            let type = (item["type"] as? String) == "series" ? "series" : "movie"
            await CoreBridge.shared.addCatalogItemToAccount(id: id, type: type)
            recovered += 1
        }
        if recovered > 0 {
            DiagnosticsLog.log("sync", "recovered \(recovered) owner-library title(s) from the VortX account on a cold device")
        }
    }

    /// Snapshot the engine's CURRENT add-ons (full descriptors) into the account doc, anchoring
    /// ownership on Stremio sign-in (and once on an already-synced launch when addonsOwnedAt is unset).
    /// UNION-not-shrink with the never-zero guard: only runs when the engine actually has add-ons, and a
    /// `.failed` account pull aborts (never clobbers the account doc). The add-on union + addonsOwnedAt
    /// are handled by vortxSummary's read-side guard; this just forces a push so the snapshot lands.
    func snapshotOwnedFromEngine() async {
        guard isSignedIn else { return }
        guard !CoreBridge.shared.addons.isEmpty else { return }   // never-zero: nothing to anchor
        // Confirm the account doc is reachable before pushing (a .failed pull means a degraded network:
        // syncUp's own guard would already abort, but checking here avoids a wasted makeBackup).
        if case .failed = await pullSyncDocResult() { return }
        await syncUp()   // vortxSummary unions the engine descriptors into doc.vortx.addons + sets addonsOwnedAt
    }

    /// True when the account doc has NOT yet anchored an owned add-on set (`addonsOwnedAt` unset), so an
    /// already-synced launch can snapshot-on-import exactly once. A `.failed`/`.empty` pull returns false
    /// (nothing to do / no doc), so we never snapshot before the account is reachable.
    func ownedAddonsNeverSnapshotted() async -> Bool {
        guard isSignedIn else { return false }
        guard case let .doc(doc) = await pullSyncDocResult() else { return false }
        let vortx = doc["vortx"] as? [String: Any]
        return vortx?["addonsOwnedAt"] == nil
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
        // Universal "do not schedule a push from this write" gate. While syncDown is applying a remote pull
        // (isApplyingRemote), the writes it makes must NOT arm a push, or the receiving device re-pushes the
        // peer values and starves its own pull guard (the Beta 8/9 settings-sync starvation). The
        // UserDefaults.didChangeNotification observer already checks this, but apiKeys (ApiKeys.didSet) and
        // debrid keys (DebridKeys.setKey) call requestSyncSoon() DIRECTLY, bypassing the observer, so the gate
        // must live here too to cover every call path. A genuine user edit never runs inside the apply window.
        guard !isApplyingRemote else { return }
        hasPendingPush = true
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            await self?.syncUp()
            self?.hasPendingPush = false
        }
    }

    /// Run a SYNCHRONOUS block of UserDefaults writes that should NOT arm an auto-push: applying a remote
    /// pull (the self-echo case) or routine touch:false launch housekeeping. Sets isApplyingRemote for the
    /// duration AND across the next main-queue turn, because UserDefaults.didChangeNotification is delivered
    /// asynchronously on the main queue (queue: .main): the notifications generated by the writes are
    /// coalesced and run AFTER this returns, so the flag must stay set until they drain. Clearing it via a
    /// trailing DispatchQueue.main.async keeps it true while the queued observer block runs, then clears it.
    /// Must be called on the main actor with a synchronous body (no awaits inside, or notifications could
    /// leak past the window).
    func withRemoteApplySuppressed(_ body: () -> Void) {
        let wasSuppressing = isApplyingRemote
        isApplyingRemote = true
        body()
        // If we were already inside an outer suppression window, let the outer one clear it.
        guard !wasSuppressing else { return }
        DispatchQueue.main.async { [weak self] in self?.isApplyingRemote = false }
    }

    /// ProfileStore entry point: wrap a touch:false housekeeping persist so its UserDefaults writes do not
    /// arm a push. Static + main-actor-hopped so the synchronous, possibly-off-main `persist(touch:false)`
    /// can call it without itself being @MainActor; the actual flag flip + clear happen on the main actor
    /// where the observer is delivered. touch:true persists are never routed here, so user edits still sync.
    nonisolated static func suppressHousekeeping(_ writes: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.withRemoteApplySuppressed(writes) }
        } else {
            DispatchQueue.main.sync { shared.withRemoteApplySuppressed(writes) }
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
