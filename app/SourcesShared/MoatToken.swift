import Foundation
import CryptoKit

/// Short-lived MOAT token issuer + cache for the VortX community SERVE side.
///
/// The gated community pools (`sources.vortx.tv` Singularity, `subtitles.vortx.tv`, trickplay-serve) do NOT
/// merely edge-sign reads with `VortXEdgeAuth`; their READ path additionally requires a per-account MOAT token
/// (`verifyMoatToken` on the worker: no token => empty list, a HARD login gate). CONTRIBUTE stays open, only
/// SERVE is moat-gated. The token is minted by the issuer at `api.vortx.tv`, is short-lived, and must be
/// refreshed before it expires. This is the client that fetches, caches (with expiry), refreshes, and stamps
/// it onto outgoing gated reads.
///
/// FAIL-SOFT CONTRACT (every method): no token, a mint error, offline, a signed-out account, or a withdrawn
/// consent all collapse to "no token" -> the caller stamps nothing -> the gated read returns empty. Nothing
/// throws to a caller and nothing ever blocks or crashes. A missing token is a normal, expected state (the
/// whole app works signed out), so it is never surfaced as an error.
///
/// IDENTITY: the mint is authenticated with the VortX account session bearer (the `api.vortx.tv` session token
/// that `VortXSyncManager` persists), NOT the Stremio `authKey` (Keychain-only, goes solely to api.strem.io per
/// the account invariant). Read directly from the same Keychain slot so this stays self-contained.
///
/// GATING: minting is gated on `MoatConsent.contributeAndConsume` (give-to-get: no consent -> no moat token ->
/// no SERVE) AND on the caller-supplied signed-in flag. A signed-out or opted-out device never mints.
///
/// CONCURRENCY: an `actor` so the cache + in-flight mint are race-free; a burst of gated reads (sources + subs
/// + trickplay all firing on one detail open) shares ONE mint instead of stampeding the issuer.
actor MoatToken {
    static let shared = MoatToken()

    // MARK: - Cache state

    struct Credential: Equatable, Sendable {
        let bearer: String
        let identityDigest: String
    }

    struct Minted: Sendable {
        let token: String
        let expiresAt: Date
    }

    private struct Scope: Equatable, Sendable {
        let sessionGeneration: UInt64
        let consentGeneration: UInt64
        let credentialDigest: String
    }

    private struct Cached {
        let scope: Scope
        let token: String
        let expiresAt: Date
    }

    private struct InFlight {
        let scope: Scope
        let task: Task<String?, Never>
    }

    typealias CredentialProvider = @Sendable () -> Credential?
    typealias MintProvider = @Sendable (String) async -> Minted?

    /// The cached token is bound to both authorization generations and a private digest of the exact account
    /// session credential. The digest is never logged, persisted, or returned.
    private var cached: Cached?
    /// Only callers in the identical authorization scope share a mint.
    private var inFlight: InFlight?
    /// Monotonic tag identifying the current mint. clear() bumps it so a stale mint's final acceptance
    /// (which runs after its await returns) cannot clobber a newer mint's state.
    private var mintGeneration: UInt64 = 0
    private let credentialProvider: CredentialProvider
    private let mintProvider: MintProvider

    /// Refresh the token this far BEFORE its stated expiry, so a read never rides an about-to-die token across
    /// the worker's clock skew. 60 s covers a slow mint + request latency.
    private let refreshSkew: TimeInterval = 60

    init(
        credentialProvider: @escaping CredentialProvider = { MoatToken.sessionCredential() },
        mintProvider: @escaping MintProvider = { bearer in await MoatToken.mint(bearer: bearer) }
    ) {
        self.credentialProvider = credentialProvider
        self.mintProvider = mintProvider
    }

    // MARK: - Public API

    /// The current valid moat token, minting or refreshing as needed. Returns nil (never throws) when the
    /// device cannot or should not hold one: opted out of the pool, signed out, offline, or the mint failed.
    ///
    /// `isSignedIn` is the caller's account signed-in flag (the SERVE gate is login-only). Passed in rather
    /// than read here so this stays free of a SwiftUI/main-actor dependency and testable.
    func current(isSignedIn: Bool) async -> String? {
        // A delayed caller carrying false must not erase a newer account's cache. Known sign-out and consent
        // writers perform generation-scoped invalidation at their mutation boundary.
        guard MoatConsent.contributeAndConsume, isSignedIn,
              let credential = credentialProvider() else { return nil }

        let lifecycle = SourceIndexLifecycleClock.snapshot()
        let scope = Scope(
            sessionGeneration: lifecycle.sessionGeneration,
            consentGeneration: lifecycle.consentGeneration,
            credentialDigest: credential.identityDigest
        )

        discardMismatchedState(currentScope: scope)
        // Fresh cached token (with skew headroom): hand it straight back.
        if let c = cached, c.scope == scope, c.expiresAt.timeIntervalSinceNow > refreshSkew {
            return c.token
        }
        // Coalesce concurrent mints onto one task.
        if let inFlight, inFlight.scope == scope { return await inFlight.task.value }
        // Tag each mint so final acceptance acts only when THIS mint still owns inFlight; a concurrent
        // clear()/re-mint bumps the tag so a stale task cannot clobber the newer one.
        mintGeneration &+= 1
        let generation = mintGeneration
        let mintProvider = self.mintProvider
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            let minted = await mintProvider(credential.bearer)
            // Acceptance is one actor operation. It rechecks every live authorization fact, stores only an
            // accepted token, clears only this mint's pointer, and returns exactly the accepted value.
            return await self.accept(
                minted,
                scope: scope,
                generation: generation,
                wasCancelled: Task.isCancelled
            )
        }
        inFlight = InFlight(scope: scope, task: task)
        return await task.value
    }

    /// Proactively warm the token (e.g. right after login) so the first gated read does not pay the mint
    /// latency. Fire-and-forget; result ignored. No-op when opted out / signed out / already warm.
    func prewarm(isSignedIn: Bool) async {
        _ = await current(isSignedIn: isSignedIn)
    }

    /// Unconditional teardown for process shutdown/testing. Authorization mutations use the scoped overload.
    func clear() {
        cached = nil
        inFlight?.task.cancel()
        inFlight = nil
        mintGeneration &+= 1   // orphan any in-flight mint so its late store()/clearInFlight is a no-op
    }

    /// Clear only state from retired account or consent generations. A delayed invalidation from account A or
    /// consent-off cannot erase a token minted after account B signs in or consent is re-enabled.
    func clear(
        retiredSessionGeneration: UInt64?,
        retiredConsentGeneration: UInt64?
    ) {
        func isRetired(_ scope: Scope) -> Bool {
            if let retiredSessionGeneration,
               scope.sessionGeneration <= retiredSessionGeneration { return true }
            if let retiredConsentGeneration,
               scope.consentGeneration <= retiredConsentGeneration { return true }
            return false
        }

        if let cached, isRetired(cached.scope) { self.cached = nil }
        if let inFlight, isRetired(inFlight.scope) {
            inFlight.task.cancel()
            self.inFlight = nil
            mintGeneration &+= 1
        }
    }

    // MARK: - Header stamping helpers

    /// Stamp the moat token onto a gated READ `request` as `X-VX-Moat`. No-op when there is no token (the
    /// worker then returns an empty list, which is the correct fail-soft SERVE result). Call AFTER
    /// `VortXEdgeAuth.sign` so both the edge signature and the moat token ride together.
    func stamp(_ request: inout URLRequest, isSignedIn: Bool) async {
        guard let token = await current(isSignedIn: isSignedIn) else { return }
        request.setValue(token, forHTTPHeaderField: Self.header)
    }

    /// The moat token as a query-param value for `<img>`/`<video>` element loads that cannot carry a custom
    /// header (trickplay sprites, pooled art). Returns nil when there is no token. The worker reads `vmoat`
    /// as the query fallback for `X-VX-Moat`, mirroring the `VortXEdgeAuth` query-sig convention.
    ///
    /// LEAKAGE NOTE: prefer `stamp(_:isSignedIn:)` (the header path) wherever the loader can carry a header; a
    /// token on the URL is short-lived but can otherwise linger in logs and the persistent URLCache. Callers
    /// that must use this query form MUST NOT log the built URL and SHOULD load it on an ephemeral session so
    /// the token is not written to the on-disk cache. This type itself logs nothing.
    func queryValue(isSignedIn: Bool) async -> String? {
        await current(isSignedIn: isSignedIn)
    }

    static let header = "X-VX-Moat"
    static let queryParam = "vmoat"

    // MARK: - Mint (issuer round trip)

    /// One mint round trip to the issuer. Fail-soft to nil on any error / non-2xx / decode miss / no session.
    /// POSTs to `<issuer>/moat/token` with the VortX account session bearer; the worker returns
    /// `{ token, expiresIn?|expiresAt? }`.
    private static func mint(bearer: String) async -> Minted? {
        guard !bearer.isEmpty else { return nil }
        // The live issuer route is /v1/moat/token (api.vortx.tv). The un-versioned /moat/token 404s, so a
        // tokenless app never un-gates the moat SERVE (Singularity sources, pooled subs) - this is that fix.
        guard let url = URL(string: issuerBase + "/v1/moat/token") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MintResponse.self, from: data),
              let token = decoded.token, !token.isEmpty else { return nil }

        let ttl = decoded.expiresIn.map { TimeInterval($0) }
        let expiresAt: Date
        if let at = decoded.expiresAt { expiresAt = Date(timeIntervalSince1970: TimeInterval(at)) }
        else if let ttl { expiresAt = Date().addingTimeInterval(ttl) }
        else { expiresAt = Date().addingTimeInterval(defaultTTLStatic) }
        return Minted(token: token, expiresAt: expiresAt)
    }

    /// The issuer base, baked to api.vortx.tv. The `endpoint("moat")` lookup is a forward hook: RemoteConfig has
    /// no `moat` endpoint wired today (`endpoint(_:)` returns nil for it), so this always resolves to the baked
    /// default until a `moat` key is decoded + returned there. Repoint by wiring that key, not by editing here.
    private static var issuerBase: String {
        RemoteConfig.snapshot.endpoint("moat")?.absoluteString ?? "https://api.vortx.tv"
    }

    private static let defaultTTLStatic: TimeInterval = 15 * 60

    /// The VortX account session bearer, read from the Keychain slot `VortXSyncManager` persists. This is the
    /// api.vortx.tv identity (NOT the Stremio authKey). Decodes only the `token` field; a missing/garbled slot
    /// (signed out of VortX sync) yields nil, which fails the mint soft. Kept here so the client is
    /// self-contained and never reaches into another type's private state.
    private static func sessionCredential() -> Credential? {
        guard let raw = Keychain.string(vortxSessionSlot),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        let accountID = (obj["account"] as? [String: Any])?["id"] as? String ?? ""
        let digestInput = Data((accountID + "\u{0}" + token).utf8)
        let digest = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return Credential(bearer: token, identityDigest: digest)
    }

    /// The Keychain account slot `VortXSyncManager` stores its `{ token, account, dataKey }` blob under. Kept
    /// in sync with `VortXSyncManager.kcAccount` (a private literal there); if that constant ever changes,
    /// change it here too (a compile-time comment marker, since the two cannot share a private symbol).
    private static let vortxSessionSlot = "vortx.sync.session.v1"

    // MARK: - Actor-isolated final acceptance (called from the mint Task)

    private func accept(
        _ minted: Minted?,
        scope: Scope,
        generation: UInt64,
        wasCancelled: Bool
    ) -> String? {
        // A stale mint must never clear the pointer for a newer mint.
        guard generation == mintGeneration else { return nil }
        inFlight = nil
        guard !wasCancelled,
              Self.scopeIsCurrent(scope, credentialProvider: credentialProvider),
              let minted else { return nil }
        cached = Cached(scope: scope, token: minted.token, expiresAt: minted.expiresAt)
        return minted.token
    }

    private func discardMismatchedState(currentScope: Scope) {
        if cached?.scope != currentScope { cached = nil }
        if let inFlight, inFlight.scope != currentScope {
            inFlight.task.cancel()
            self.inFlight = nil
            mintGeneration &+= 1
        }
    }

    private static func scopeIsCurrent(
        _ scope: Scope,
        credentialProvider: CredentialProvider
    ) -> Bool {
        let lifecycle = SourceIndexLifecycleClock.snapshot()
        guard MoatConsent.contributeAndConsume,
              lifecycle.sessionGeneration == scope.sessionGeneration,
              lifecycle.consentGeneration == scope.consentGeneration,
              let credential = credentialProvider() else { return false }
        return credential.identityDigest == scope.credentialDigest
    }

    // MARK: - Wire shape

    private struct MintResponse: Decodable {
        let token: String?
        let expiresIn: Int?    // seconds-to-live
        let expiresAt: Int?    // absolute unix seconds (preferred when present)
    }
}
