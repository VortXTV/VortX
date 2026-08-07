package com.vortx.android.integrations

import android.content.Context
import android.util.Log
import com.vortx.android.BuildConfig
import com.vortx.android.security.PersistentCredentialAvailability
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/// SIMKL PIN/device auth plus encrypted token storage. Kotlin port of `app/SourcesShared/SIMKLAuth.swift`.
/// SIMKL's model is simpler than Trakt's: a PIN flow (request a code, poll until the user authorizes) that
/// yields a LONG-LIVED access token with NO refresh rotation. A missing/zero expiry is therefore treated
/// as "valid" (do NOT copy Trakt's leeway refresh, which SIMKL lacks).
///
///   1. [requestPin] -> `GET /oauth/pin` returns `{ user_code, verification_url, expires_in, interval }`.
///   2. [pollForToken] loops `GET /oauth/pin/{user_code}` until `result == "OK"` with an `access_token`.
///   3. The token is stored in an [SecureTokenStore] (the Android analogue of the Apple Keychain).
///
/// Every request carries `client_id` / `app-name` / `app-version` query items and the `simkl-api-key`
/// header + a descriptive `User-Agent` (a blank UA risks SIMKL's abuse filters, which can suspend the key).
///
/// Credentials come from [BuildConfig.SIMKL_CLIENT_ID] (the PIN flow needs only the id; no secret). Empty
/// ships the feature DORMANT: [isConfigured] stays false and nothing here makes a network call.
object SIMKLAuth {

    // MARK: - Configuration (build-time; empty ships a dormant, invisible feature)

    private val clientId: String get() = BuildConfig.SIMKL_CLIENT_ID.trim()

    /// API base. SIMKL serves OAuth off the same host as the data API.
    const val API_BASE = "https://api.simkl.com"

    /// True once a non-empty client id is present. Everything no-ops until then.
    val isConfigured: Boolean get() = clientId.isNotEmpty()

    /// App marketing version, e.g. "0.3.0". SIMKL requires an `app-version` on every request.
    private val appVersion: String get() = BuildConfig.VERSION_NAME.ifEmpty { "1" }

    /// Descriptive User-Agent SIMKL wants on every request (see the class doc).
    private val userAgent: String get() = "VortX/$appVersion (Android; +https://vortx.tv)"

    // MARK: - Token storage keys (match the Apple keychain-account tails 1:1)

    private const val PREFS_FILE = "vortx_simkl_tokens"
    private const val ACCESS_KEY = "vortx.simkl.accessToken"
    private const val EXPIRY_KEY = "vortx.simkl.expiresAt"    // unix epoch seconds, or "0" for non-expiring

    private const val TAG = "SIMKLAuth"

    @Volatile private var tokenStore: TokenPersistence? = null
    private val tokenMutations = CredentialMutationCoordinator()
    private val sessionEpoch = AtomicLong(0L)
    private val _sessionBoundary = MutableStateFlow(0L)

    /** Changes after a confirmed sign-in replacement or disconnect so mounted Home rails reconcile now. */
    internal val sessionBoundary: StateFlow<Long> = _sessionBoundary.asStateFlow()

    /// Idempotent init: build the encrypted token store from the app context (see [TraktAuth.init]).
    fun init(context: Context) {
        if (tokenStore == null) {
            synchronized(this) {
                if (tokenStore == null) {
                    tokenStore = TokenPersistence(SecureTokenStore(context, PREFS_FILE))
                }
            }
        }
    }

    // MARK: - Public state

    internal val connectionState: CredentialConnectionState
        get() = tokenMutations.snapshot {
            tokenStore?.connectionState ?: CredentialConnectionState.DISCONNECTED
        }.value

    /// True when an access token is confirmed in persistent storage.
    val isSignedIn: Boolean get() = connectionState == CredentialConnectionState.CONNECTED

    /// Drop the stored token (the user disconnected). Does not revoke server-side.
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

    /// A live access token, or throws [SIMKLException.NotSignedIn]. SIMKL tokens are long-lived and do not
    /// refresh; a recorded expiry in the past (rare) throws so the UI can re-prompt.
    fun validToken(): String {
        val snapshot = tokenMutations.snapshot {
            tokenStore?.validToken()
        }
        val token = snapshot.value ?: throw SIMKLException.NotSignedIn
        if (!snapshot.operation.isCurrent()) throw SIMKLException.NotSignedIn
        return token
    }

    // MARK: - Step 1: request a PIN

    /// Begin the PIN flow. Returns the code + polling schedule to drive the UI and step 2.
    suspend fun requestPin(): SIMKLPin {
        ensureConfigured()
        val response = IntegrationsHttp.request(
            method = "GET",
            urlString = "$API_BASE/oauth/pin?${requiredQuery()}",
            headers = getHeaders(),
        )
        Log.d(TAG, "oauth/pin -> HTTP ${response.status}")
        if (response.status != 200) throw SIMKLException.Server(response.status)
        val json = runCatching { JSONObject(response.body) }.getOrNull() ?: throw SIMKLException.Decoding
        return SIMKLPin(
            userCode = json.optString("user_code"),
            verificationUrl = json.optString("verification_url").ifEmpty { "https://simkl.com/pin" },
            expiresIn = json.optInt("expires_in", 900),
            interval = json.optInt("interval", 5),
        )
    }

    // MARK: - Step 2: poll for the token

    sealed interface PollResult {
        data class Authorized(val accessToken: String) : PollResult
        data object Pending : PollResult
    }

    /// One poll of `GET /oauth/pin/{user_code}`. Stores the token on authorization.
    suspend fun poll(userCode: String): PollResult {
        val operation = tokenMutations.operation()
        return poll(userCode, operation)
    }

    private suspend fun poll(
        userCode: String,
        operation: CredentialMutationCoordinator.Operation,
    ): PollResult {
        if (!operation.isCurrent()) throw SIMKLException.NotSignedIn
        ensureConfigured()
        val publication = operation.publishAfter(
            awaitValue = {
                IntegrationsHttp.request(
                    method = "GET",
                    urlString = "$API_BASE/oauth/pin/$userCode?${requiredQuery()}",
                    headers = getHeaders(),
                )
            },
            publish = { response ->
                if (response.status != 200) throw SIMKLException.Server(response.status)
                val token = parsePollToken(response.body)
                if (token != null) {
                    store(token)
                    PollResult.Authorized(token)
                } else {
                    PollResult.Pending
                }
            },
        )
        return when (publication) {
            is CredentialMutationResult.Applied -> publication.value
            CredentialMutationResult.Stale -> throw SIMKLException.NotSignedIn
        }
    }

    /// Run the full polling loop until the user authorizes or the code expires. On success the token is
    /// already stored; the return value is the same token.
    suspend fun pollForToken(userCode: String, interval: Int, expiresIn: Int): String {
        val operation = tokenMutations.operation()
        val deadline = System.currentTimeMillis() / 1000L + expiresIn
        val waitSeconds = maxOf(interval, 1)
        while (System.currentTimeMillis() / 1000L < deadline) {
            delay(waitSeconds * 1000L)
            val result = poll(userCode, operation)
            if (result is PollResult.Authorized) return result.accessToken
        }
        throw SIMKLException.Expired
    }

    // MARK: - Persistence + HTTP plumbing

    /// Store a fresh access token. SIMKL tokens do not expire, so the expiry slot is "0" (non-expiring).
    private fun store(accessToken: String) {
        val store = tokenStore ?: throw SIMKLException.SecureStorage
        store.save(accessToken)
        publishSessionBoundary()
    }

    /** Exact-account authenticated GET. Stale responses are discarded after disconnect/account switch. */
    internal suspend fun sessionBoundGet(path: String, expectedEpoch: Long): IntegrationsHttp.Response? {
        if (!isSessionCurrent(expectedEpoch)) return null
        val token = runCatching { validToken() }.getOrNull() ?: return null
        if (!isSessionCurrent(expectedEpoch)) return null
        val response = IntegrationsHttp.request(
            method = "GET",
            urlString = "$API_BASE$path?${requiredQuery()}",
            headers = authHeaders(token),
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
                val snapshot = store.confirmedSnapshot(ACCESS_KEY, EXPIRY_KEY)
                if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) {
                    return CredentialConnectionState.STORAGE_UNAVAILABLE
                }
                return if (validStoredToken(snapshot.values) != null) {
                    CredentialConnectionState.CONNECTED
                } else {
                    CredentialConnectionState.DISCONNECTED
                }
            }

        val isSignedIn: Boolean get() = connectionState == CredentialConnectionState.CONNECTED

        fun validToken(): String? {
            val snapshot = store.confirmedSnapshot(ACCESS_KEY, EXPIRY_KEY)
            if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) {
                throw SIMKLException.SecureStorage
            }
            return validStoredToken(snapshot.values)
        }

        fun save(accessToken: String) {
            if (accessToken.isBlank()) throw SIMKLException.Decoding
            val stored = store.set(mapOf(ACCESS_KEY to accessToken, EXPIRY_KEY to "0"))
            if (!stored) throw SIMKLException.SecureStorage
        }

        fun clear() {
            val cleared = store.clear(ACCESS_KEY, EXPIRY_KEY)
            if (!cleared) throw SIMKLException.SecureStorage
        }

        private fun validStoredToken(values: Map<String, String?>): String? {
            val token = values[ACCESS_KEY]?.takeUnless(String::isBlank) ?: return null
            val rawExpiry = values[EXPIRY_KEY] ?: return token
            if (rawExpiry == "0") return token
            val expiry = rawExpiry.toLongOrNull() ?: return null
            return token.takeIf { expiry > 0L && nowSeconds() < expiry }
        }
    }

    private fun ensureConfigured() {
        if (!isConfigured) throw SIMKLException.NotConfigured
    }

    internal fun parsePollToken(body: String): String? {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: throw SIMKLException.Decoding
        if (json.optString("result").uppercase() != "OK") return null
        return json.optString("access_token").takeUnless(String::isBlank)
            ?: throw SIMKLException.Decoding
    }

    /// The `client_id` / `app-name` / `app-version` query items SIMKL requires on EVERY request.
    internal fun requiredQuery(): String =
        "client_id=$clientId&app-name=VortX&app-version=$appVersion"

    /// The header set SIMKL wants on an unauthenticated request.
    private fun getHeaders(): Map<String, String> = mapOf(
        "Content-Type" to "application/json",
        "simkl-api-key" to clientId,
        "User-Agent" to userAgent,
    )

    /// The header set for an AUTHENTICATED request (adds the bearer). Used by [ScrobbleService].
    internal fun authHeaders(token: String): Map<String, String> = getHeaders() + mapOf(
        "Authorization" to "Bearer $token",
    )
}

/// The code + polling schedule from `GET /oauth/pin`.
data class SIMKLPin(
    val userCode: String,
    val verificationUrl: String,
    val expiresIn: Int,
    val interval: Int,
)

/// Typed errors for the SIMKL auth flow. Mirrors the Apple `SIMKLError`.
sealed class SIMKLException(message: String) : Exception(message) {
    data object NotConfigured : SIMKLException("SIMKL is not configured in this build.")
    data object NotSignedIn : SIMKLException("You are not connected to SIMKL.")
    data object Expired : SIMKLException("The SIMKL sign-in code expired. Please try again.")
    data object Decoding : SIMKLException("Could not read the response from SIMKL.")
    data object SecureStorage : SIMKLException(
        "Secure storage is unavailable. Your SIMKL connection was not changed. Please try again.",
    )
    data class Server(val status: Int) : SIMKLException("SIMKL returned an error (HTTP $status).")
}
