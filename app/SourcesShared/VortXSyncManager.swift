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

    private init() { restore() }

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
        // On sign-in, pull the account's profiles + settings; if the account has none yet (a fresh
        // account), seed it from this device. Last-writer-wins, good enough for v1 cross-device sync.
        Task { [weak self] in
            guard let self else { return }
            let restored = await self.syncDown()
            if !restored { await self.syncUp() }
        }
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

    @discardableResult
    func pushSyncDoc(_ obj: [String: Any]) async -> Bool {
        guard let dataKey, let pt = try? JSONSerialization.data(withJSONObject: obj),
              let ct = VortXSyncCrypto.seal(key: dataKey, pt) else { return false }
        let version = Int(Date().timeIntervalSince1970 * 1000)
        let (code, _) = await request("PUT", "/v1/backup", body: ["document": ct, "version": version], auth: true)
        return code == 200
    }

    // MARK: - Profiles + settings sync (reuses the SettingsBackup serialization as the doc payload)

    /// Push this device's profiles + settings to the account. MERGES into the existing doc (preserving
    /// keys other surfaces wrote, e.g. the website's Stremio import) instead of replacing it, and carries
    /// the metadata keys explicitly because they live in the Keychain (SettingsBackup excludes them).
    @discardableResult
    func syncUp() async -> Bool {
        guard isSignedIn, let data = try? SettingsBackup.makeBackup() else { return false }
        var doc = await pullSyncDoc() ?? [:]
        doc["settings"] = data.base64EncodedString()
        doc["format"] = 1
        var keys: [String: String] = [:]
        if let t = ApiKeys.tmdbKey() { keys["tmdb"] = t }
        if let m = ApiKeys.mdblistKey() { keys["mdblist"] = m }
        if keys.isEmpty { doc.removeValue(forKey: "apiKeys") } else { doc["apiKeys"] = keys }
        return await pushSyncDoc(doc)
    }

    /// Pull the account's profiles + settings (and metadata keys) and apply them locally. True if anything
    /// was restored.
    @discardableResult
    func syncDown() async -> Bool {
        guard isSignedIn, let doc = await pullSyncDoc() else { return false }
        var restored = false
        if let b64 = doc["settings"] as? String, let data = Data(base64Encoded: b64),
           ((try? SettingsBackup.restore(from: data)) ?? 0) > 0 { restored = true }
        if let keys = doc["apiKeys"] as? [String: String] {
            if let t = keys["tmdb"] { ApiKeys.shared.tmdb = t }
            if let m = keys["mdblist"] { ApiKeys.shared.mdblist = m }
            restored = true
        }
        return restored
    }
}
