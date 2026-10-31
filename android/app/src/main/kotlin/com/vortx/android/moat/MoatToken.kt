package com.vortx.android.moat

import android.content.Context
import com.vortx.android.singularity.SourceIndexLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.math.BigDecimal
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Short-lived account-authenticated MOAT tokens. Secrets are never logged or persisted by this client.
 * Legacy SourceIndex entry points remain compile-time dormant; the App-owned authorized path supplies
 * its captured account scope and live give-to-get gates before requesting this token. */
object MoatToken {
    const val HEADER = "X-VX-Moat"
    const val QUERY_PARAM = "vmoat"

    data class SessionCredential(val bearer: String, val accountId: String) {
        override fun toString(): String = "SessionCredential(<redacted>)"
    }
    data class Minted(val token: String, val expiresAtMs: Long) {
        override fun toString(): String = "Minted(<redacted>)"
    }

    /** Reads the CURRENT VortX account bearer, never a streaming-provider credential. */
    @Volatile var sessionProvider: (() -> SessionCredential?)? = null
    @Volatile var appContext: Context? = null
    /** Existing issuer test seam. Production always uses the fixed-origin bounded transport. */
    @Volatile var mintProvider: (suspend (String) -> Minted?)? = null

    private val cache = MoatSourceEpochCache(
        credentialProvider = { sessionProvider?.invoke() },
        permitted = { appContext?.let(MoatConsent::contributeAndConsume) == true },
        mint = { bearer, cancellation ->
            val injected = mintProvider
            if (injected != null) injected(bearer) else mint(bearer, cancellation)
        },
    )

    suspend fun current(isSignedIn: Boolean): String? = if (isSignedIn) cache.current() else null
    suspend fun prewarm(isSignedIn: Boolean) { current(isSignedIn) }
    suspend fun stamp(connection: HttpURLConnection, isSignedIn: Boolean) {
        current(isSignedIn)?.let { connection.setRequestProperty(HEADER, it) }
    }
    suspend fun queryValue(isSignedIn: Boolean): String? = current(isSignedIn)

    /** Explicit test/shutdown teardown. Authorization mutations use the scoped overload or lifecycle callback. */
    suspend fun clear() { cache.clear() }
    internal fun clear(retiredSourceEpoch: Long) { cache.clearThrough(retiredSourceEpoch) }

    private const val MINT_TIMEOUT_MS = 8_000
    private const val MAX_MINT_BYTES = 64 * 1024
    private const val DEFAULT_TTL_MS = 15 * 60 * 1000L
    private const val ISSUER_URL = "https://api.vortx.tv/v1/moat/token"

    /** No RemoteConfig override or redirect may receive the account bearer. */
    private suspend fun mint(bearer: String, cancellation: MoatMintCancellation): Minted? {
        if (bearer.isBlank()) return null
        return try {
            withContext(Dispatchers.IO) {
                suspendCancellableCoroutine { continuation ->
                    val started = System.nanoTime()
                    val conn = URL(ISSUER_URL).openConnection() as HttpURLConnection
                    val registration = cancellation.onTransportCancelled(
                        cancelContinuation = { continuation.cancel() },
                        disconnect = { conn.disconnect() },
                    )
                    continuation.invokeOnCancellation { cancellation.cancel() }
                    try {
                        fun requireCurrent() {
                            if (!continuation.isActive || cancellation.isCancelled()) throw CancellationException("Moat authorization retired")
                            if (System.nanoTime() - started >= MINT_TIMEOUT_MS * 1_000_000L) throw IOException("Moat mint timed out")
                        }
                        conn.requestMethod = "POST"
                        conn.connectTimeout = MINT_TIMEOUT_MS
                        conn.readTimeout = MINT_TIMEOUT_MS
                        conn.useCaches = false
                        conn.instanceFollowRedirects = false
                        conn.setRequestProperty("accept", "application/json")
                        conn.setRequestProperty("authorization", "Bearer $bearer")
                        requireCurrent()
                        if (conn.responseCode !in 200..299) throw IOException("Moat HTTP error")
                        if (conn.contentLengthLong > MAX_MINT_BYTES) throw IOException("Moat response exceeds budget")
                        val bytes = conn.inputStream.use { input ->
                            val result = ByteArrayOutputStream()
                            val chunk = ByteArray(8 * 1024)
                            while (true) {
                                requireCurrent()
                                val count = input.read(chunk)
                                if (count < 0) break
                                if (count > MAX_MINT_BYTES - result.size()) throw IOException("Moat response exceeds budget")
                                result.write(chunk, 0, count)
                            }
                            requireCurrent()
                            result.toByteArray()
                        }
                        val json = JSONObject(bytes.toString(Charsets.UTF_8))
                        val token = (json.opt("token") as? String)?.takeIf {
                            it.isNotBlank() && it.length <= 16 * 1024 && it.none(Char::isISOControl)
                        } ?: throw IOException("Invalid Moat token")
                        val now = System.currentTimeMillis()
                        fun positiveInteger(key: String): Long {
                            val raw = json.opt(key) as? Number ?: throw IOException("Invalid Moat expiry")
                            return BigDecimal(raw.toString()).longValueExact().takeIf { it > 0 }
                                ?: throw IOException("Invalid Moat expiry")
                        }
                        val expiry = when {
                            json.has("expiresAt") && !json.isNull("expiresAt") -> Math.multiplyExact(positiveInteger("expiresAt"), 1000L)
                            json.has("expiresIn") && !json.isNull("expiresIn") -> Math.addExact(now, Math.multiplyExact(positiveInteger("expiresIn"), 1000L))
                            else -> Math.addExact(now, DEFAULT_TTL_MS)
                        }
                        if (expiry <= now) throw IOException("Expired Moat token")
                        requireCurrent()
                        if (continuation.isActive) continuation.resume(Minted(token, expiry))
                    } catch (failure: Throwable) {
                        if (continuation.isActive) continuation.resumeWithException(failure)
                    } finally {
                        registration.close()
                        runCatching { conn.disconnect() }
                    }
                }
            }
        } catch (_: Exception) {
            null
        }
    }
}

/** A connection cancellation latch. Registration and callbacks never run under the token-state lock. */
internal class MoatMintCancellation {
    private val lock = Any()
    private var cancelled = false
    private var nextID = 0L
    private val callbacks = mutableMapOf<Long, () -> Unit>()
    fun isCancelled(): Boolean = synchronized(lock) { cancelled }
    fun onCancelled(callback: () -> Unit): AutoCloseable {
        val id = synchronized(lock) {
            if (cancelled) null else (++nextID).also { callbacks[it] = callback }
        }
        if (id == null) runCatching(callback)
        return AutoCloseable { if (id != null) synchronized(lock) { callbacks.remove(id) } }
    }
    /** Cancellation state is immediate; a caller holding UI/native locks never performs blocking teardown. */
    fun onTransportCancelled(cancelContinuation: () -> Unit, disconnect: () -> Unit): AutoCloseable = onCancelled {
        cancelContinuation()
        SourceIndexLifecycle.dispatchTeardown(disconnect)
    }
    fun cancel() {
        val retired = synchronized(lock) {
            if (cancelled) return
            cancelled = true
            callbacks.values.toList().also { callbacks.clear() }
        }
        retired.forEach { runCatching { it() } }
    }
}

/** The actual production cache, also usable by source fixtures without constructing an Android Context. */
internal class MoatSourceEpochCache(
    private val credentialProvider: () -> MoatToken.SessionCredential?,
    private val permitted: () -> Boolean,
    private val mint: suspend (String, MoatMintCancellation) -> MoatToken.Minted?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val epoch: () -> Long = SourceIndexLifecycle::currentEpoch,
    private val observeEpoch: (Long, () -> Unit) -> AutoCloseable = SourceIndexLifecycle::onEpochInvalidated,
) {
    private data class TokenScope(val epoch: Long, val credentialDigest: String)
    private data class Cached(val scope: TokenScope, val tag: Long, val value: MoatToken.Minted, val registration: AutoCloseable?)
    private class Flight(val scope: TokenScope, val tag: Long, val task: Deferred<String?>,
                         val cancellation: MoatMintCancellation, var registration: AutoCloseable? = null) {
        // A concurrent waiter must not start this LAZY task before its epoch observer is attached.
        val ready = CompletableDeferred<Unit>()
    }
    private val lock = Any()
    private var nextTag = 0L
    private var cached: Cached? = null
    private var inFlight: Flight? = null

    private fun capture(): Pair<TokenScope, MoatToken.SessionCredential>? {
        val originalEpoch = epoch()
        if (!runCatching(permitted).getOrDefault(false)) return null
        val credential = runCatching(credentialProvider).getOrNull()?.takeIf {
            it.bearer.isNotBlank() && it.accountId.isNotBlank()
        } ?: return null
        if (epoch() != originalEpoch) return null
        val input = (credential.accountId + "\u0000" + credential.bearer).toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(input).joinToString("") { "%02x".format(it) }
        return TokenScope(originalEpoch, digest) to credential
    }

    suspend fun current(): String? {
        val (original, credential) = capture() ?: return null
        var retiredFlight: Flight? = null
        var retiredRegistration: AutoCloseable? = null
        var fresh: Cached? = null
        var created = false
        val flight = synchronized(lock) {
            val previous = cached
            if (previous != null && previous.scope == original && previous.value.expiresAtMs - nowMs() > REFRESH_SKEW_MS) {
                fresh = previous
                null
            } else {
                cached = null
                retiredRegistration = previous?.registration
                val previousFlight = inFlight
                if (previousFlight != null && previousFlight.scope == original) previousFlight
                else {
                    retiredFlight = previousFlight
                    val tag = ++nextTag
                    val cancellation = MoatMintCancellation()
                    val task = scope.async(start = CoroutineStart.LAZY) { mintAndStore(original, tag, credential.bearer, cancellation) }
                    Flight(original, tag, task, cancellation).also { inFlight = it; created = true }
                }
            }
        }
        retiredRegistration?.close()
        retire(retiredFlight)
        val selectedCache = fresh
        if (selectedCache != null) {
            if (!currentCoroutineContext().isActive || capture()?.first != original) return null
            return selectedCache.value.token.takeIf { synchronized(lock) { cached === selectedCache } }
        }
        flight ?: return null
        if (created) {
            val registration = observeEpoch(original.epoch) { clearThrough(original.epoch) }
            val retained = synchronized(lock) {
                if (inFlight === flight) { flight.registration = registration; true } else false
            }
            if (!retained) registration.close()
            flight.ready.complete(Unit)
        }
        try { flight.ready.await() } catch (_: Exception) { return null }
        flight.task.start()
        val token = try { flight.task.await() } catch (_: Exception) { null }
        if (token == null || !currentCoroutineContext().isActive || capture()?.first != original) return null
        return token.takeIf { synchronized(lock) { cached?.let { it.tag == flight.tag && it.scope == original } == true } }
    }

    private suspend fun mintAndStore(original: TokenScope, tag: Long, bearer: String,
                                     cancellation: MoatMintCancellation): String? {
        val minted = try { mint(bearer, cancellation) } catch (_: Exception) { null }
        // Provider/native predicates run outside token state. The owner tag and epoch are checked again at acceptance.
        val live = currentCoroutineContext().isActive && !cancellation.isCancelled() && capture()?.first == original
        var registration: AutoCloseable? = null
        val accepted = synchronized(lock) {
            val owner = inFlight
            if (owner == null || owner.tag != tag || owner.scope != original) null
            else {
                inFlight = null
                if (live && epoch() == original.epoch && minted != null && minted.token.isNotBlank() && minted.expiresAtMs > nowMs()) {
                    cached = Cached(original, tag, minted, owner.registration)
                    minted.token
                } else { registration = owner.registration; null }
            }
        }
        registration?.close()
        return accepted
    }

    /** A delayed callback may retire A without touching a token or mint created in reopened epoch B. */
    fun clearThrough(retiredEpoch: Long) {
        val retired = synchronized(lock) {
            val oldCache = cached?.takeIf { it.scope.epoch <= retiredEpoch }
            if (oldCache != null) cached = null
            val oldFlight = inFlight?.takeIf { it.scope.epoch <= retiredEpoch }
            if (oldFlight != null) inFlight = null
            oldCache?.registration to oldFlight
        }
        retired.first?.close()
        retire(retired.second)
    }

    fun clear() {
        val retired = synchronized(lock) {
            val value = cached?.registration to inFlight
            cached = null
            inFlight = null
            value
        }
        retired.first?.close()
        retire(retired.second)
    }

    private fun retire(flight: Flight?) {
        if (flight == null) return
        flight.registration?.close()
        flight.cancellation.cancel()
        flight.task.cancel()
    }

    companion object { private const val REFRESH_SKEW_MS = 60_000L }
}
