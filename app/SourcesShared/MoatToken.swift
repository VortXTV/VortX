import Foundation

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

    /// The cached token + its absolute expiry. nil until a first successful mint (and after a hard clear).
    private var cached: (token: String, expiresAt: Date)?
    /// A single in-flight mint shared by concurrent callers, so N simultaneous gated reads mint once.
    private var inFlight: Task<String?, Never>?

    /// Refresh the token this far BEFORE its stated expiry, so a read never rides an about-to-die token across
    /// the worker's clock skew. 60 s covers a slow mint + request latency.
    private let refreshSkew: TimeInterval = 60

    // MARK: - Public API

    /// The current valid moat token, minting or refreshing as needed. Returns nil (never throws) when the
    /// device cannot or should not hold one: opted out of the pool, signed out, offline, or the mint failed.
    ///
    /// `isSignedIn` is the caller's account signed-in flag (the SERVE gate is login-only). Passed in rather
    /// than read here so this stays free of a SwiftUI/main-actor dependency and testable.
    func current(isSignedIn: Bool) async -> String? {
        guard MoatConsent.contributeAndConsume, isSignedIn else {
            // Opted out or signed out: drop any stale token so a later opt-in / sign-in re-mints cleanly.
            cached = nil
            return nil
        }
        // Fresh cached token (with skew headroom): hand it straight back.
        if let c = cached, c.expiresAt.timeIntervalSinceNow > refreshSkew {
            return c.token
        }
        // Coalesce concurrent mints onto one task.
        if let task = inFlight { return await task.value }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            let minted = await Self.mint()
            await self.store(minted)
            await self.clearInFlight()
            return minted?.token
        }
        inFlight = task
        return await task.value
    }

    /// Proactively warm the token (e.g. right after login) so the first gated read does not pay the mint
    /// latency. Fire-and-forget; result ignored. No-op when opted out / signed out / already warm.
    func prewarm(isSignedIn: Bool) async {
        _ = await current(isSignedIn: isSignedIn)
    }

    /// Drop the cached token (e.g. on sign-out / consent withdrawal). The next `current` re-mints.
    func clear() {
        cached = nil
        inFlight?.cancel()
        inFlight = nil
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
    func queryValue(isSignedIn: Bool) async -> String? {
        await current(isSignedIn: isSignedIn)
    }

    static let header = "X-VX-Moat"
    static let queryParam = "vmoat"

    // MARK: - Mint (issuer round trip)

    private struct Minted { let token: String; let expiresAt: Date }

    /// One mint round trip to the issuer. Fail-soft to nil on any error / non-2xx / decode miss / no session.
    /// POSTs to `<issuer>/moat/token` with the VortX account session bearer; the worker returns
    /// `{ token, expiresIn?|expiresAt? }`.
    private static func mint() async -> Minted? {
        guard let bearer = sessionBearer(), !bearer.isEmpty else { return nil }   // no VortX session -> no mint
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
    private static func sessionBearer() -> String? {
        guard let raw = Keychain.string(vortxSessionSlot),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// The Keychain account slot `VortXSyncManager` stores its `{ token, account, dataKey }` blob under. Kept
    /// in sync with `VortXSyncManager.kcAccount` (a private literal there); if that constant ever changes,
    /// change it here too (a compile-time comment marker, since the two cannot share a private symbol).
    private static let vortxSessionSlot = "vortx.sync.session.v1"

    // MARK: - Actor-isolated mutators (called from the mint Task)

    private func store(_ minted: Minted?) {
        guard let minted else { return }   // keep any still-valid cached token on a failed refresh
        cached = (token: minted.token, expiresAt: minted.expiresAt)
    }

    private func clearInFlight() { inFlight = nil }

    // MARK: - Wire shape

    private struct MintResponse: Decodable {
        let token: String?
        let expiresIn: Int?    // seconds-to-live
        let expiresAt: Int?    // absolute unix seconds (preferred when present)
    }
}
