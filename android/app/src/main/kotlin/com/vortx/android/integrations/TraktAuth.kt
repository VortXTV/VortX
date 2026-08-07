package com.vortx.android.integrations

import android.content.Context
import android.util.Log
import com.vortx.android.BuildConfig
import com.vortx.android.security.PersistentCredentialAvailability
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

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

    @Volatile private var tokenStore: TokenPersistence? = null
    private val tokenMutations = CredentialMutationCoordinator()
    private val sessionEpoch = AtomicLong(0L)
    private val _sessionBoundary = MutableStateFlow(0L)

    /** Changes after a confirmed sign-in replacement or disconnect so mounted Home rails reconcile now. */
    internal val sessionBoundary: StateFlow<Long> = _sessionBoundary.asStateFlow()

    /// A single in-flight refresh serializer. Trakt rotates the refresh token on every refresh, so two
    /// concurrent refreshes would race and the loser 401s on an already-spent token, dropping the session.
    /// The mutex collapses concurrent callers into one rotation (the Apple `inFlightRefresh` single-flight).
    private val refreshMutex = Mutex()

    /// Idempotent init: build the encrypted token store from the app context. Safe to call from every
    /// entry point (the Integrations screen, the player scrobble hook); only the first call does work.
    fun init(context: Context) {
        if (tokenStore == null) {
            synchronized(this) {
                if (tokenStore == null) {
                    tokenStore = TokenPersistence(SecureTokenStore(context, PREFS_FILE), ::nowSeconds)
                }
            }
        }
    }

    // MARK: - Public state

    internal val connectionState: CredentialConnectionState
        get() = tokenMutations.snapshot {
            tokenStore?.connectionState ?: CredentialConnectionState.DISCONNECTED
        }.value

    /// True when a token set is confirmed in persistent storage. Does not check expiry.
    val isSignedIn: Boolean get() = connectionState == CredentialConnectionState.CONNECTED

    /// Drop all stored Trakt tokens (the user disconnected). Does not revoke server-side.
    fun signOut() {
        tokenMutations.invalidate {
            tokenStore?.clear()
        }
        publishSessionBoundary()
    }

    /** Stable only for the currently connected credential generation. Contains no credential material. */
    internal val currentSessionEpoch: Long?
        get() = tokenMutations.snapshot {
            sessionEpoch.get() to (tokenStore?.connectionState == CredentialConnectionState.CONNECTED)
        }.value.let { (epoch, connected) -> epoch.takeIf { isConfigured && connected } }

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
        val operation = tokenMutations.operation()
        return poll(deviceCode, operation)
    }

    private suspend fun poll(
        deviceCode: String,
        operation: CredentialMutationCoordinator.Operation,
    ): PollResult {
        if (!operation.isCurrent()) throw TraktAuthException.NotSignedIn
        ensureConfigured()
        val body = JSONObject()
            .put("code", deviceCode)
            .put("client_id", clientId)
            .put("client_secret", clientSecret)
            .toString()
        val publication = operation.publishAfter(
            awaitValue = {
                IntegrationsHttp.request(
                    method = "POST",
                    urlString = "$API_BASE/oauth/device/token",
                    headers = baseHeaders(),
                    body = body,
                )
            },
            publish = { response ->
                when (response.status) {
                    200 -> {
                        val token = parseToken(response.body) ?: throw TraktAuthException.Decoding
                        store(token)
                        Log.d(TAG, "device/token -> 200 authorized")
                        PollResult.Authorized(token)
                    }
                    // Pending: the user has not finished authorizing yet. Keep polling. (Not logged: it
                    // repeats every `interval` seconds.)
                    400 -> PollResult.Pending
                    // Device code needs only the id, but this exchange also needs the secret.
                    401 -> {
                        Log.w(
                            TAG,
                            "device/token -> 401 invalid_client " +
                                "(verify TRAKT_CLIENT_SECRET matches the app)",
                        )
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
            },
        )
        return when (publication) {
            is CredentialMutationResult.Applied -> publication.value
            CredentialMutationResult.Stale -> throw TraktAuthException.NotSignedIn
        }
    }

    /// Run the full polling loop until the user authorizes, denies, or the codes expire. Honors the server
    /// [interval], backs off an extra second on a 429 (escalating on repeated 429s, capped), and stops once
    /// [expiresIn] elapses. On success the token is already stored; the return value is the same token.
    suspend fun pollForToken(deviceCode: String, interval: Int, expiresIn: Int): TraktToken {
        val operation = tokenMutations.operation()
        val deadline = nowSeconds() + expiresIn
        val baseInterval = maxOf(interval, 1)
        var waitSeconds = baseInterval
        Log.d(TAG, "poll start interval=${baseInterval}s expiresIn=${expiresIn}s")
        while (nowSeconds() < deadline) {
            delay(waitSeconds * 1000L)
            when (val result = poll(deviceCode, operation)) {
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
        val snapshot = tokenMutations.snapshot(::currentStoredToken)
        val storedToken = snapshot.value ?: throw TraktAuthException.NotSignedIn
        val token = storedToken.token
        if (token.isExpired) return refresh(snapshot.operation).accessToken
        if (!snapshot.operation.isCurrent()) throw TraktAuthException.NotSignedIn
        return token.accessToken
    }

    /// Exchange the refresh token for a fresh set via `POST /oauth/token`, SINGLE-FLIGHT via [refreshMutex]:
    /// a second concurrent caller re-checks the store under the lock and reuses the winner's fresh token
    /// instead of spending the already-rotated refresh token (which would 401 and drop the session).
    private suspend fun refresh(
        operation: CredentialMutationCoordinator.Operation,
    ): TraktToken = refreshMutex.withLock {
        // A refresh may have completed while we waited on the lock; reuse its result rather than spending
        // the now-rotated token again.
        val current = when (val result = operation.mutate(::currentStoredToken)) {
            is CredentialMutationResult.Applied ->
                result.value ?: throw TraktAuthException.NotSignedIn
            CredentialMutationResult.Stale -> throw TraktAuthException.NotSignedIn
        }
        if (!current.token.isExpired) return@withLock current.token
        performRefresh(operation, current)
    }

    private suspend fun performRefresh(
        operation: CredentialMutationCoordinator.Operation,
        spentToken: TokenPersistence.StoredToken,
    ): TraktToken {
        if (!operation.isCurrent()) throw TraktAuthException.NotSignedIn
        ensureConfigured()
        val body = JSONObject()
            .put("refresh_token", spentToken.token.refreshToken)
            .put("client_id", clientId)
            .put("client_secret", clientSecret)
            // REQUIRED on the refresh grant and must equal the registered value exactly (the device token
            // exchange sends none).
            .put("redirect_uri", REGISTERED_REDIRECT_URI)
            .put("grant_type", "refresh_token")
            .toString()
        val persistence = tokenStore ?: throw TraktAuthException.SecureStorage
        return performRefresh(
            operation = operation,
            spentToken = spentToken,
            persistence = persistence,
            clearCurrent = ::signOut,
            request = {
                IntegrationsHttp.request(
                    method = "POST",
                    urlString = "$API_BASE/oauth/token",
                    headers = baseHeaders(),
                    body = body,
                )
            },
        )
    }

    /**
     * Executes the refresh publication path with injectable transport and storage edges. Production and
     * tests share this exact response wiring so lineage preservation and rejected-refresh clearing stay
     * executable without a live provider account.
     */
    internal suspend fun performRefresh(
        operation: CredentialMutationCoordinator.Operation,
        spentToken: TokenPersistence.StoredToken,
        persistence: TokenPersistence,
        clearCurrent: () -> Unit,
        request: suspend () -> IntegrationsHttp.Response,
    ): TraktToken {
        if (!operation.isCurrent()) throw TraktAuthException.NotSignedIn
        val publication = operation.publishAfter(
            awaitValue = request,
            publish = { response ->
                if (response.status != 200) {
                    // Only clear a rejected session when it still carries the token this request spent.
                    // A device-flow winner may have installed a newer session during the network await.
                    if (response.status == 401) {
                        val preserved = handleUnauthorizedRefresh(
                            spentLineage = spentToken.lineage,
                            loadStored = persistence::loadStored,
                            clearCurrent = clearCurrent,
                        )
                        if (preserved != null) {
                            return@publishAfter preserved
                        }
                    }
                    throw TraktAuthException.Server(response.status)
                }
                val token = parseToken(response.body) ?: throw TraktAuthException.Decoding
                persistence.saveRefreshIfCurrent(spentToken.lineage, token)
            },
        )
        return when (publication) {
            is CredentialMutationResult.Applied -> publication.value
            CredentialMutationResult.Stale -> throw TraktAuthException.NotSignedIn
        }
    }

    /**
     * Apply one rejected refresh response to the current durable session. [clearCurrent] is the production
     * sign-out path, so clearing also invalidates every operation from the rejected session's generation.
     */
    internal fun handleUnauthorizedRefresh(
        spentLineage: TokenPersistence.PersistedLineage,
        loadStored: () -> TokenPersistence.StoredToken?,
        clearCurrent: () -> Unit,
    ): TraktToken? {
        val stored = loadStored()
        if (stored != null && stored.lineage != spentLineage) return stored.token
        clearCurrent()
        return null
    }

    // MARK: - Persistence

    /// The stored token set, reconstructed from the store, or null if not signed in. Rebuilds with the
    /// ORIGINAL issue time when present so the early-refresh leeway fires correctly (see [TraktToken]).
    private fun currentStoredToken(): TokenPersistence.StoredToken? = tokenStore?.loadStored()

    private fun store(token: TraktToken) {
        val store = tokenStore ?: throw TraktAuthException.SecureStorage
        store.save(token)
        publishSessionBoundary()
    }

    /**
     * One authenticated read fenced to the exact account generation captured before network I/O.
     * A disconnect or a second account completing auth while the request is in flight discards the body.
     */
    internal suspend fun sessionBoundGet(path: String, expectedEpoch: Long): IntegrationsHttp.Response? {
        if (!isSessionCurrent(expectedEpoch)) return null
        val token = runCatching { validToken() }.getOrNull() ?: return null
        if (!isSessionCurrent(expectedEpoch)) return null
        val response = IntegrationsHttp.request(
            method = "GET",
            urlString = "$API_BASE$path",
            headers = baseHeaders() + mapOf("Authorization" to "Bearer $token"),
        )
        return response.takeIf { isSessionCurrent(expectedEpoch) }
    }

    private fun isSessionCurrent(expectedEpoch: Long): Boolean = tokenMutations.snapshot {
        sessionEpoch.get() == expectedEpoch &&
            tokenStore?.connectionState == CredentialConnectionState.CONNECTED
    }.value

    private fun publishSessionBoundary() {
        val next = sessionEpoch.incrementAndGet()
        _sessionBoundary.value = next
    }

    internal class TokenPersistence(
        private val store: CredentialStoreAccess,
        private val nowSeconds: () -> Long = { System.currentTimeMillis() / 1000L },
    ) {
        val connectionState: CredentialConnectionState
            get() {
                val snapshot = store.confirmedSnapshot(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY)
                if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) {
                    return CredentialConnectionState.STORAGE_UNAVAILABLE
                }
                return if (parseStoredTuple(snapshot.values) != null) {
                    CredentialConnectionState.CONNECTED
                } else {
                    CredentialConnectionState.DISCONNECTED
                }
            }

        val isSignedIn: Boolean get() = connectionState == CredentialConnectionState.CONNECTED

        data class PersistedLineage(
            val accessToken: String,
            val refreshToken: String,
            val expiresAtSeconds: Long,
            val createdAt: Long?,
        )

        data class StoredToken(
            val token: TraktToken,
            val lineage: PersistedLineage,
        )

        private data class StoredTuple(
            val accessToken: String,
            val refreshToken: String,
            val expiresAtSeconds: Long,
            val createdAt: Long?,
        )

        fun load(): TraktToken? = loadStored()?.token

        fun loadStored(): StoredToken? {
            val snapshot = store.confirmedSnapshot(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY)
            if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) {
                throw TraktAuthException.SecureStorage
            }
            val tuple = parseStoredTuple(snapshot.values) ?: return null
            // Preserve the original issue time so early refresh remains meaningful. A token from before
            // CREATED_KEY existed falls back to hard-expiry behavior, matching the migration path.
            val created = if (tuple.createdAt != null && tuple.createdAt < tuple.expiresAtSeconds) {
                tuple.createdAt
            } else {
                nowSeconds()
            }
            return StoredToken(
                token = TraktToken(
                    tuple.accessToken,
                    tuple.refreshToken,
                    expiresIn = tuple.expiresAtSeconds - created,
                    createdAt = created,
                ),
                lineage = PersistedLineage(
                    tuple.accessToken,
                    tuple.refreshToken,
                    tuple.expiresAtSeconds,
                    tuple.createdAt,
                ),
            )
        }

        fun save(token: TraktToken) {
            if (
                token.accessToken.isBlank() ||
                token.refreshToken.isBlank() ||
                token.expiresIn <= 0L ||
                token.expiresAtSeconds <= 0L
            ) {
                throw TraktAuthException.Decoding
            }
            val stored = store.set(
                mapOf(
                    ACCESS_KEY to token.accessToken,
                    REFRESH_KEY to token.refreshToken,
                    EXPIRY_KEY to token.expiresAtSeconds.toString(),
                    CREATED_KEY to token.createdAt.toString(),
                ),
            )
            if (!stored) throw TraktAuthException.SecureStorage
        }

        private fun parseStoredTuple(values: Map<String, String?>): StoredTuple? {
            val access = values[ACCESS_KEY]?.takeUnless(String::isBlank) ?: return null
            val refresh = values[REFRESH_KEY]?.takeUnless(String::isBlank) ?: return null
            val expiry = values[EXPIRY_KEY]?.toLongOrNull()?.takeIf { it > 0L } ?: return null
            return StoredTuple(
                accessToken = access,
                refreshToken = refresh,
                expiresAtSeconds = expiry,
                createdAt = values[CREATED_KEY]?.toLongOrNull(),
            )
        }

        /**
         * Publish one refresh response only if encrypted storage still holds the token lineage that request
         * spent. The caller holds [CredentialMutationCoordinator]'s mutation lock across this load and save.
         */
        fun saveRefreshIfCurrent(spentLineage: PersistedLineage, candidate: TraktToken): TraktToken {
            val current = loadStored() ?: throw TraktAuthException.NotSignedIn
            if (current.lineage != spentLineage) return current.token
            save(candidate)
            return candidate
        }

        fun clear() {
            val cleared = store.clear(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY)
            if (!cleared) throw TraktAuthException.SecureStorage
        }
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

    internal fun parseToken(body: String): TraktToken? {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: return null
        val access = json.optString("access_token")
        val refresh = json.optString("refresh_token")
        if (access.isBlank() || refresh.isBlank()) return null
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
    data object SecureStorage : TraktAuthException(
        "Secure storage is unavailable. Your Trakt connection was not changed. Please try again.",
    )
    data class Server(val status: Int) : TraktAuthException("Trakt returned an error (HTTP $status).")
}
