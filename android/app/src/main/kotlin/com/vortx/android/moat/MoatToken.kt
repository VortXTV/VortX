package com.vortx.android.moat

import android.content.Context
import com.vortx.android.config.RemoteConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Short-lived MOAT token issuer + cache for the VortX community SERVE side. The Kotlin port of Apple
 * `app/SourcesShared/MoatToken.swift`.
 *
 * The gated community pools (`sources.vortx.tv` Singularity, and the other pooled reads) do NOT merely
 * edge-sign reads; their READ path additionally requires a per-account MOAT token (`X-VX-Moat`): no token
 * means an empty list, a HARD login gate. CONTRIBUTE stays open, only SERVE is moat-gated. The token is minted
 * by the issuer at `api.vortx.tv`, is short-lived, and must be refreshed before it expires. This is the client
 * that mints, caches (with expiry), refreshes, and stamps it onto outgoing gated reads.
 *
 * DORMANCY: this is groundwork, kept DORMANT exactly like Apple ships it gated. On Android the sole SERVE
 * consumer, [com.vortx.android.singularity.SourceIndexClient], stays behind its own compile-time
 * `isEnabled = false` gate pending a separately security-signed-off lane, and its `moatTokenProvider` (which
 * this client is wired to) is never invoked while that gate is closed. So this mints nothing at runtime today;
 * it exists so the token flows the same way Apple wires MoatToken into SourceIndexClient once SERVE re-enables.
 *
 * FAIL-SOFT CONTRACT (every method): an unwired client, no session, a mint error, offline, a signed-out
 * account, or withdrawn consent all collapse to "no token" -> the caller stamps nothing -> the gated read
 * returns empty. Nothing throws to a caller and nothing ever blocks or crashes. A missing token is a normal,
 * expected state (the whole app works signed out), so it is never surfaced as an error.
 *
 * IDENTITY: the mint is authenticated with the VortX account session bearer (the `api.vortx.tv` session token
 * VortXSyncManager persists), NOT the Stremio authKey (which goes solely to api.strem.io per the account
 * invariant). The bearer is supplied through [sessionProvider], injected once at app start from the already-
 * built session manager, so this client never reaches into another type's private storage.
 *
 * GATING: minting is gated on [MoatConsent.contributeAndConsume] (give-to-get: no consent -> no moat token ->
 * no SERVE) AND on the caller-supplied signed-in flag. A signed-out or opted-out device never mints.
 *
 * CONCURRENCY: a [Mutex] guards the cache + in-flight mint so a burst of gated reads shares ONE mint instead
 * of stampeding the issuer, and the network mint itself runs OUTSIDE the lock (the lock is never held across a
 * suspending request).
 */
object MoatToken {

    /** The gated-read header, byte-for-byte Apple's `MoatToken.header`. */
    const val HEADER = "X-VX-Moat"

    /** The query-param fallback for element loads that cannot carry a header, byte-for-byte Apple's `queryParam`. */
    const val QUERY_PARAM = "vmoat"

    /** The VortX account session credential the mint authenticates with (bearer + account id for the scope digest). */
    data class SessionCredential(val bearer: String, val accountId: String)

    /** The issuer's mint response, decoded from `{ token, expiresIn?|expiresAt? }`. */
    data class Minted(val token: String, val expiresAtMs: Long)

    /**
     * Injected once at app start (see VortXApplication). Reads the CURRENT VortX session live on each call so a
     * later sign-in / sign-out is reflected without re-wiring. null (unwired) keeps the client dormant.
     */
    @Volatile
    var sessionProvider: (() -> SessionCredential?)? = null

    /**
     * Injected once at app start. Needed to consult [MoatConsent] from the context-free SERVE call sites. null
     * (unwired) keeps the client dormant.
     */
    @Volatile
    var appContext: Context? = null

    /** Test seam for the issuer round trip. null uses the real [mint]. */
    @Volatile
    var mintProvider: (suspend (String) -> Minted?)? = null

    /**
     * Refresh the token this far BEFORE its stated expiry, so a read never rides an about-to-die token across
     * the worker's clock skew. Matches Apple's 60 s.
     */
    private const val REFRESH_SKEW_MS = 60_000L

    /** Default token lifetime when the issuer states neither an absolute expiry nor a TTL. Matches Apple's 15 min. */
    private const val DEFAULT_TTL_MS = 15 * 60 * 1000L

    private const val MINT_TIMEOUT_MS = 8_000

    private data class Scope(val credentialDigest: String)

    private data class Cached(val scope: Scope, val token: String, val expiresAtMs: Long)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private var cached: Cached? = null
    private var inFlight: Deferred<String?>? = null
    private var inFlightScope: Scope? = null

    // MARK: - Public API

    /**
     * The current valid moat token, minting or refreshing as needed. Returns null (never throws) when the
     * device cannot or should not hold one: unwired, opted out of the pool, signed out, offline, or the mint
     * failed. Mirrors Apple `current(isSignedIn:)`.
     *
     * [isSignedIn] is the caller's account signed-in flag (the SERVE gate is login-only). Passed in rather than
     * read here so this stays free of a UI dependency and testable.
     */
    suspend fun current(isSignedIn: Boolean): String? {
        val context = appContext ?: return null
        if (!isSignedIn) return null
        if (!MoatConsent.contributeAndConsume(context)) return null
        val credential = sessionProvider?.invoke()?.takeIf { it.bearer.isNotEmpty() } ?: return null
        val tokenScope = Scope(credentialDigest = digest(credential))

        val flight = mutex.withLock {
            val fresh = cached
            if (fresh != null && fresh.scope == tokenScope && fresh.expiresAtMs - nowMs() > REFRESH_SKEW_MS) {
                return fresh.token
            }
            if (fresh != null && fresh.scope != tokenScope) cached = null
            val existing = inFlight
            if (existing != null && inFlightScope == tokenScope) {
                existing
            } else {
                val bearer = credential.bearer
                val started = scope.async(start = CoroutineStart.LAZY) { mintAndStore(bearer, tokenScope) }
                inFlight = started
                inFlightScope = tokenScope
                started
            }
        }
        flight.start()
        return runCatching { flight.await() }.getOrNull()
    }

    /**
     * Proactively warm the token (e.g. right after login) so the first gated read does not pay the mint latency.
     * Fire-and-forget; result ignored. No-op when unwired / opted out / signed out. Mirrors Apple `prewarm`.
     */
    suspend fun prewarm(isSignedIn: Boolean) {
        current(isSignedIn)
    }

    /**
     * Stamp the moat token onto a gated READ [connection] as `X-VX-Moat`. No-op when there is no token (the
     * worker then returns an empty list, the correct fail-soft SERVE result). Call AFTER the edge signature so
     * both ride together. Mirrors Apple `stamp`.
     */
    suspend fun stamp(connection: HttpURLConnection, isSignedIn: Boolean) {
        val token = current(isSignedIn) ?: return
        connection.setRequestProperty(HEADER, token)
    }

    /**
     * The moat token as a query-param value for element loads that cannot carry a custom header. Returns null
     * when there is no token. Mirrors Apple `queryValue`. Callers MUST NOT log the built URL and SHOULD load it
     * on an ephemeral request so the short-lived token is not written to a persistent cache.
     */
    suspend fun queryValue(isSignedIn: Boolean): String? = current(isSignedIn)

    /** Unconditional teardown for sign-out / consent-off / shutdown. Mirrors Apple `clear()`. */
    suspend fun clear() {
        mutex.withLock {
            cached = null
            inFlight?.cancel()
            inFlight = null
            inFlightScope = null
        }
    }

    // MARK: - Mint (issuer round trip)

    private suspend fun mintAndStore(bearer: String, tokenScope: Scope): String? {
        val minted = (mintProvider ?: { b -> mint(b) }).invoke(bearer)
        return mutex.withLock {
            if (inFlightScope == tokenScope) {
                inFlight = null
                inFlightScope = null
            }
            // Re-validate every live authorization fact before storing: a sign-out / consent-off / account swap
            // that happened while the mint was in flight must not surface a now-stale token.
            val context = appContext
            val credential = sessionProvider?.invoke()
            val stillCurrent = context != null &&
                MoatConsent.contributeAndConsume(context) &&
                credential != null && credential.bearer.isNotEmpty() &&
                digest(credential) == tokenScope.credentialDigest
            if (!stillCurrent || minted == null) {
                null
            } else {
                cached = Cached(tokenScope, minted.token, minted.expiresAtMs)
                minted.token
            }
        }
    }

    /**
     * One mint round trip to the issuer. Fail-soft to null on any error / non-2xx / decode miss / empty bearer.
     * POSTs to `<issuer>/v1/moat/token` with the VortX account session bearer; the worker returns
     * `{ token, expiresIn?|expiresAt? }`. Mirrors Apple `mint`.
     */
    private fun mint(bearer: String): Minted? {
        if (bearer.isEmpty()) return null
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(issuerBase() + "/v1/moat/token").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = MINT_TIMEOUT_MS
                readTimeout = MINT_TIMEOUT_MS
                useCaches = false
                instanceFollowRedirects = false
                setRequestProperty("accept", "application/json")
                setRequestProperty("authorization", "Bearer $bearer")
            }
            val code = conn.responseCode
            if (code !in 200..299) return null
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            val json = runCatching { JSONObject(text) }.getOrNull() ?: return null
            val token = json.optString("token").takeIf { it.isNotBlank() } ?: return null
            val expiresAtMs = when {
                json.has("expiresAt") && !json.isNull("expiresAt") -> json.optLong("expiresAt") * 1000L
                json.has("expiresIn") && !json.isNull("expiresIn") -> nowMs() + json.optLong("expiresIn") * 1000L
                else -> nowMs() + DEFAULT_TTL_MS
            }
            return Minted(token, expiresAtMs)
        } catch (_: Throwable) {
            return null
        } finally {
            conn?.disconnect()
        }
    }

    /**
     * The issuer base, baked to api.vortx.tv. The `endpoint("moat")` lookup is a forward hook: RemoteConfig has
     * no `moat` endpoint wired today (it returns null for it), so this always resolves to the baked default
     * until a `moat` key is decoded there. Repoint by wiring that key, not by editing here. Mirrors Apple
     * `issuerBase`.
     */
    private fun issuerBase(): String =
        RemoteConfig.current().endpoint("moat") ?: "https://api.vortx.tv"

    // MARK: - Helpers

    /**
     * A private digest binding the cache to the exact account session credential. A token minted for account A
     * is never served to account B: the digest changes with either the account id or the bearer. Never logged,
     * persisted, or returned. Mirrors Apple's `identityDigest`.
     */
    private fun digest(credential: SessionCredential): String {
        val input = (credential.accountId + " " + credential.bearer).toByteArray(Charsets.UTF_8)
        return MessageDigest.getInstance("SHA-256").digest(input)
            .joinToString("") { "%02x".format(it) }
    }

    private fun nowMs(): Long = System.currentTimeMillis()
}
