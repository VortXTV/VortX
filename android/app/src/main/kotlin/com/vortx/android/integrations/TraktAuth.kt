package com.vortx.android.integrations

import android.content.Context
import android.util.Log
import com.vortx.android.BuildConfig
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/// Trakt.tv OAuth device-code flow plus encrypted token storage. Kotlin port of the Apple
/// `app/SourcesShared/TraktAuth.swift`, matching its verified-live flow byte for byte:
///
///   1. [requestDeviceCode] -> `POST /oauth/device/code` with `{ client_id }` returns the user code,
///      verification URL, and polling schedule. Show the user code + URL, then step 2.
///   2. [pollForToken] loops `POST /oauth/device/token` with `{ code, client_id, client_secret }` at the
///      server `interval` for the whole `expires_in` window: 200 = authorized (tokens returned + stored),
///      400 = authorization_pending (keep polling), 429 = slow_down (back off +1s), 410 = expired (stop),
///      418 = denied (stop). Headers on every call: `trakt-api-version: 2`, `trakt-api-key: <client_id>`.
///   3. Tokens are stored in an [SecureTokenStore] (the Android analogue of the Apple Keychain), never in
///      plain prefs, never in a backup.
///   4. [validToken] returns a live access token, refreshing transparently when near expiry.
///
/// The `refresh_token` grant MUST send `redirect_uri = urn:ietf:wg:oauth:2.0:oob` (a PUBLIC constant),
/// byte-for-byte equal to the app's registered value, or Trakt 401s the refresh and silently drops the
/// session. The DEVICE token exchange, by contrast, sends NO redirect_uri (see the Apple doc comment).
///
/// Credentials come from [BuildConfig.TRAKT_CLIENT_ID] / [BuildConfig.TRAKT_CLIENT_SECRET], injected by
/// gradle from a gitignored property / CI secret (see app/build.gradle.kts). Both empty ships the feature
/// DORMANT: [isConfigured] stays false and nothing here makes a network call.
object TraktAuth {

    // MARK: - Configuration (build-time credentials; empty ships a dormant, invisible feature)

    private val clientId: String get() = BuildConfig.TRAKT_CLIENT_ID.trim()
    private val clientSecret: String get() = BuildConfig.TRAKT_CLIENT_SECRET.trim()

    /// API base. Trakt serves OAuth off the same host as the data API.
    const val API_BASE = "https://api.trakt.tv"

    /// The OAuth redirect URI registered for this app. Trakt REQUIRES it on the `refresh_token` grant and
    /// it must byte-for-byte equal the registered value. Public constant, not a secret. The device token
    /// exchange does NOT send it.
    private const val REGISTERED_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob"

    /// True once a non-empty client id/secret pair is present. Everything no-ops until then.
    val isConfigured: Boolean get() = clientId.isNotEmpty() && clientSecret.isNotEmpty()

    // MARK: - Token storage keys (match the Apple keychain-account tails 1:1)

    private const val PREFS_FILE = "vortx_trakt_tokens"
    private const val ACCESS_KEY = "vortx.trakt.accessToken"
    private const val REFRESH_KEY = "vortx.trakt.refreshToken"
    private const val EXPIRY_KEY = "vortx.trakt.expiresAt"     // unix epoch seconds, as a string
    private const val CREATED_KEY = "vortx.trakt.createdAt"    // unix epoch seconds, as a string

    private const val TAG = "TraktAuth"

    @Volatile private var tokenStore: SecureTokenStore? = null

    /// A single in-flight refresh serializer. Trakt rotates the refresh token on every refresh, so two
    /// concurrent refreshes would race and the loser 401s on an already-spent token, dropping the session.
    /// The mutex collapses concurrent callers into one rotation (the Apple `inFlightRefresh` single-flight).
    private val refreshMutex = Mutex()

    /// Idempotent init: build the encrypted token store from the app context. Safe to call from every
    /// entry point (the Integrations screen, the player scrobble hook); only the first call does work.
    fun init(context: Context) {
        if (tokenStore == null) {
            synchronized(this) {
                if (tokenStore == null) tokenStore = SecureTokenStore(context, PREFS_FILE)
            }
        }
    }

    // MARK: - Public state

    /// True when a token set is stored (the user has connected Trakt). Does not check expiry.
    val isSignedIn: Boolean get() = tokenStore?.string(ACCESS_KEY) != null

    /// Drop all stored Trakt tokens (the user disconnected). Does not revoke server-side.
    fun signOut() {
        tokenStore?.clear(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY)
    }

    // MARK: - Step 1: request a device code

    /// Begin the device flow. Returns the codes and polling schedule to drive the UI and step 2. Throws
    /// [TraktAuthException] on a provisioning error (401 = the shipped client_id is not a valid app key).
    suspend fun requestDeviceCode(): TraktDeviceCode {
        ensureConfigured()
        val body = JSONObject().put("client_id", clientId).toString()
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "$API_BASE/oauth/device/code",
            headers = baseHeaders(),
            body = body,
        )
        Log.d(TAG, "device/code -> HTTP ${response.status}")
        if (response.status != 200) {
            if (response.status == 401) throw TraktAuthException.InvalidClient
            throw TraktAuthException.Server(response.status)
        }
        val json = runCatching { JSONObject(response.body) }.getOrNull() ?: throw TraktAuthException.Decoding
        return TraktDeviceCode(
            deviceCode = json.optString("device_code"),
            userCode = json.optString("user_code"),
            verificationUrl = json.optString("verification_url").ifEmpty { "https://trakt.tv/activate" },
            expiresIn = json.optInt("expires_in", 600),
            interval = json.optInt("interval", 5),
        )
    }

    // MARK: - Step 2: poll for the token

    /// One poll of `POST /oauth/device/token`. [PollResult.Pending] / [PollResult.SlowDown] are the
    /// keep-polling signals; [PollResult.Authorized] returns + stores the token; terminal states throw.
    suspend fun poll(deviceCode: String): PollResult {
        ensureConfigured()
        val body = JSONObject()
            .put("code", deviceCode)
            .put("client_id", clientId)
            .put("client_secret", clientSecret)
            .toString()
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "$API_BASE/oauth/device/token",
            headers = baseHeaders(),
            body = body,
        )
        return when (response.status) {
            200 -> {
                val token = parseToken(response.body) ?: throw TraktAuthException.Decoding
                store(token)
                Log.d(TAG, "device/token -> 200 authorized")
                PollResult.Authorized(token)
            }
            // Pending: the user has not finished authorizing yet. Keep polling. (Not logged: it repeats
            // every `interval` seconds.)
            400 -> PollResult.Pending
            // The client_id/client_secret PAIR was rejected. device/code needs only the id (so a user code
            // was still shown), but this exchange also needs the secret; a wrong TRAKT_CLIENT_SECRET fails
            // ONLY here. Terminal + actionable.
            401 -> {
                Log.w(TAG, "device/token -> 401 invalid_client (verify TRAKT_CLIENT_SECRET matches the app)")
                throw TraktAuthException.InvalidClient
            }
            // Slow down: polled faster than `interval`. Back off, then keep polling.
            429 -> PollResult.SlowDown
            404 -> throw TraktAuthException.InvalidDeviceCode
            409 -> throw TraktAuthException.CodeAlreadyUsed
            410 -> throw TraktAuthException.Expired
            418 -> throw TraktAuthException.Denied
            else -> throw TraktAuthException.Server(response.status)
        }
    }

    /// Run the full polling loop until the user authorizes, denies, or the codes expire. Honors the server
    /// [interval], backs off an extra second on a 429 (escalating on repeated 429s, capped), and stops once
    /// [expiresIn] elapses. On success the token is already stored; the return value is the same token.
    suspend fun pollForToken(deviceCode: String, interval: Int, expiresIn: Int): TraktToken {
        val deadline = nowSeconds() + expiresIn
        val baseInterval = maxOf(interval, 1)
        var waitSeconds = baseInterval
        Log.d(TAG, "poll start interval=${baseInterval}s expiresIn=${expiresIn}s")
        while (nowSeconds() < deadline) {
            delay(waitSeconds * 1000L)
            when (val result = poll(deviceCode)) {
                is PollResult.Authorized -> return result.token
                PollResult.Pending -> waitSeconds = baseInterval
                // Escalate on REPEATED 429s (Trakt raises the required interval each time), capped so a
                // persistent 429 cannot stretch a poll unbounded; a successful pending resets to the base.
                PollResult.SlowDown -> waitSeconds = minOf(waitSeconds + 1, baseInterval + 10)
            }
        }
        Log.d(TAG, "poll deadline reached without authorization (expired)")
        throw TraktAuthException.Expired
    }

    // MARK: - Token access + refresh

    /// A live access token, refreshing first if the stored one is near expiry. Throws
    /// [TraktAuthException.NotSignedIn] when no token is stored.
    suspend fun validToken(): String {
        val token = currentToken() ?: throw TraktAuthException.NotSignedIn
        if (token.isExpired) return refresh(token.refreshToken).accessToken
        return token.accessToken
    }

    /// Exchange the refresh token for a fresh set via `POST /oauth/token`, SINGLE-FLIGHT via [refreshMutex]:
    /// a second concurrent caller re-checks the store under the lock and reuses the winner's fresh token
    /// instead of spending the already-rotated refresh token (which would 401 and drop the session).
    private suspend fun refresh(refreshToken: String): TraktToken = refreshMutex.withLock {
        // A refresh may have completed while we waited on the lock; reuse its result rather than spending
        // the now-rotated token again.
        currentToken()?.let { if (!it.isExpired) return@withLock it }
        performRefresh(refreshToken)
    }

    private suspend fun performRefresh(refreshToken: String): TraktToken {
        ensureConfigured()
        val body = JSONObject()
            .put("refresh_token", refreshToken)
            .put("client_id", clientId)
            .put("client_secret", clientSecret)
            // REQUIRED on the refresh grant and must equal the registered value exactly (the device token
            // exchange sends none).
            .put("redirect_uri", REGISTERED_REDIRECT_URI)
            .put("grant_type", "refresh_token")
            .toString()
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "$API_BASE/oauth/token",
            headers = baseHeaders(),
            body = body,
        )
        if (response.status != 200) {
            // A rejected refresh token usually means the session is dead. Only sign out when the stored
            // set still carries the exact spent refresh token (a concurrent winner may have rotated a
            // newer one during our await); otherwise keep the winner's live session.
            if (response.status == 401) {
                val stored = currentToken()
                if (stored != null && stored.refreshToken != refreshToken) return stored
                signOut()
            }
            throw TraktAuthException.Server(response.status)
        }
        val token = parseToken(response.body) ?: throw TraktAuthException.Decoding
        store(token)
        return token
    }

    // MARK: - Persistence

    /// The stored token set, reconstructed from the store, or null if not signed in. Rebuilds with the
    /// ORIGINAL issue time when present so the early-refresh leeway fires correctly (see [TraktToken]).
    private fun currentToken(): TraktToken? {
        val store = tokenStore ?: return null
        val access = store.string(ACCESS_KEY) ?: return null
        val refresh = store.string(REFRESH_KEY) ?: return null
        val expiry = store.string(EXPIRY_KEY)?.toLongOrNull() ?: return null
        val createdAt = store.string(CREATED_KEY)?.toLongOrNull()
        // Rebuild with the original issue time when the created slot has it, so `expiresIn` is the original
        // lifetime and the leeway gives a real early refresh. Fall back to now (hard-expiry only) for a
        // token stored before the slot existed, matching the Apple migration path.
        val created = if (createdAt != null && createdAt < expiry) createdAt else nowSeconds()
        return TraktToken(access, refresh, expiresIn = expiry - created, createdAt = created)
    }

    private fun store(token: TraktToken) {
        val store = tokenStore ?: return
        store.set(ACCESS_KEY, token.accessToken)
        store.set(REFRESH_KEY, token.refreshToken)
        store.set(EXPIRY_KEY, token.expiresAtSeconds.toString())
        store.set(CREATED_KEY, token.createdAt.toString())
    }

    // MARK: - HTTP plumbing

    /// The API-key headers required on EVERY Trakt call, even the unauthenticated OAuth ones.
    private fun baseHeaders(): Map<String, String> = mapOf(
        "Content-Type" to "application/json",
        "trakt-api-version" to "2",
        "trakt-api-key" to clientId,
    )

    private fun ensureConfigured() {
        if (!isConfigured) throw TraktAuthException.NotConfigured
    }

    private fun parseToken(body: String): TraktToken? {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val access = json.optString("access_token")
        val refresh = json.optString("refresh_token")
        if (access.isEmpty() || refresh.isEmpty()) return null
        val expiresIn = json.optLong("expires_in", 0L).takeIf { it > 0 } ?: (90L * 24 * 3600)
        val createdAt = json.optLong("created_at", nowSeconds())
        return TraktToken(access, refresh, expiresIn = expiresIn, createdAt = createdAt)
    }

    private fun nowSeconds(): Long = System.currentTimeMillis() / 1000L

    // MARK: - Poll result

    sealed interface PollResult {
        data class Authorized(val token: TraktToken) : PollResult
        data object Pending : PollResult
        data object SlowDown : PollResult
    }
}

/// The codes + polling schedule from `POST /oauth/device/code`.
data class TraktDeviceCode(
    val deviceCode: String,
    val userCode: String,
    val verificationUrl: String,
    val expiresIn: Int,
    val interval: Int,
)

/// A Trakt token set. [isExpired] applies the same early-refresh leeway as the Apple `TraktToken`: refresh
/// when within `min(30 min, lifetime/2)` of hard expiry, so a data call never carries a token that expires
/// in flight.
data class TraktToken(
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Long,
    val createdAt: Long,
) {
    val expiresAtSeconds: Long get() = createdAt + expiresIn

    val isExpired: Boolean
        get() {
            val now = System.currentTimeMillis() / 1000L
            val remaining = expiresAtSeconds - now
            val leeway = minOf(DEFAULT_LEEWAY_SECONDS, expiresIn / 2)
            return remaining <= leeway
        }

    private companion object {
        const val DEFAULT_LEEWAY_SECONDS = 1800L // 30 minutes, matching the Apple defaultLeeway
    }
}

/// Typed errors for the Trakt auth flow, mapping to the documented device/token status codes plus
/// transport/decode faults. Mirrors the Apple `TraktAuthError`.
sealed class TraktAuthException(message: String) : Exception(message) {
    data object NotConfigured : TraktAuthException("Trakt is not configured in this build.")
    data object NotSignedIn : TraktAuthException("You are not connected to Trakt.")
    data object InvalidDeviceCode : TraktAuthException("This Trakt sign-in code is not valid.")
    data object CodeAlreadyUsed : TraktAuthException("This Trakt sign-in code was already used.")
    data object Expired : TraktAuthException("The Trakt sign-in code expired. Please try again.")
    data object Denied : TraktAuthException("Trakt access was denied.")
    data object InvalidClient : TraktAuthException("Trakt did not accept this app's credentials.")
    data object Decoding : TraktAuthException("Could not read the response from Trakt.")
    data class Server(val status: Int) : TraktAuthException("Trakt returned an error (HTTP $status).")
}
