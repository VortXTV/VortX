package com.vortx.android.communityjs

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.coroutines.resume

/**
 * Bounded QuickJS host for one CommonJS provider invocation.
 *
 * The only host capability is [NativeFetch.fetch]. It returns serialized response data, never a Java object,
 * and the script wrapper reconstructs the small browser-like response contract. A fresh QuickJS context is
 * created per invocation and deterministically destroyed by native code before the result leaves this class.
 */
class CommunityJsRuntime(
    context: Context,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val maxResultCount: Int = MAX_RESULT_COUNT,
) {
    private val appContext = context.applicationContext
    data class Invocation(
        val provider: CommunityJsProviderStore.Provider,
        val tmdbId: String,
        val mediaType: String,
        val season: Int?,
        val episode: Int?,
        val settingsJson: String = "{}",
    )

    data class ProviderStream(
        val name: String?,
        val title: String?,
        val url: String,
        val quality: String?,
        val size: String?,
        val headers: Map<String, String>,
        val subtitles: List<Subtitle>,
    )

    data class Subtitle(val url: String, val language: String?, val name: String?, val headers: Map<String, String>)

    sealed interface Result {
        data class Success(val streams: List<ProviderStream>) : Result
        data class Failure(val message: String) : Result
    }

    suspend fun execute(invocation: Invocation): Result {
        if (invocation.provider.code.toByteArray().size > MAX_SOURCE_BYTES ||
            invocation.provider.code.length > CommunityJsBinderPayloads.MAX_EXECUTE_CODE_CHARS
        ) return Result.Failure("Provider source exceeds the limit.")
        if (invocation.mediaType !in setOf("movie", "tv") || invocation.tmdbId.toIntOrNull() == null) return Result.Failure("Invalid media identity.")
        val host = NativeFetchImpl(timeoutMs)
        val cancellation = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
            if (cause is CancellationException) host.cancel()
        }
        return try {
            withContext(Dispatchers.Default) { evaluate(invocation, host) }
        } finally {
            cancellation?.dispose()
        }
    }

    private suspend fun evaluate(invocation: Invocation, host: NativeFetchImpl): Result = try {
        val output = withTimeoutOrNull(timeoutMs + BROKER_COMPLETION_GRACE_MS) { executeInBroker(invocation, host) }
            ?: return Result.Failure("Provider execution timed out.")
        val envelope = JSONObject(output)
        if (!envelope.optBoolean("ok")) {
            Result.Failure(envelope.optString("error", "Provider execution failed."))
        } else {
            decodeStreams(envelope.optJSONArray("payload")?.toString() ?: "[]")
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        Result.Failure("Provider execution failed.")
    }

    private suspend fun executeInBroker(invocation: Invocation, host: NativeFetchImpl): String {
        val token = UUID.randomUUID().toString()
        val settingsJson = CommunityJsBinderPayloads.canonicalSettingsJson(invocation.settingsJson)
            ?: return FAILURE_ENVELOPE
        if (!CommunityJsBinderPayloads.isExecuteRequestSafe(
                token, invocation.provider.code, invocation.tmdbId, invocation.mediaType, settingsJson,
            )
        ) return FAILURE_ENVELOPE
        val executionAdmission = CommunityJsBrokerExecutionAdmission<ICommunityJsBroker>()
        lateinit var connection: ServiceConnection
        val binding = CommunityJsBindingOwner { runCatching { appContext.unbindService(connection) } }
        return try {
            suspendCancellableCoroutine { continuation ->
                val callback = object : ICommunityJsBrokerCallback.Stub() {
            override fun fetch(tokenValue: String, url: String, optionsJson: String, remainingTimeoutMs: Long): String =
                if (tokenValue == token && CommunityJsBinderPayloads.isFetchRequestSafe(tokenValue, url, optionsJson)) {
                    CommunityJsBinderPayloads.boundedFetchResponse(host.fetch(url, optionsJson, remainingTimeoutMs))
                } else {
                    EMPTY_RESPONSE
                }

            override fun isCancelled(tokenValue: String): Boolean = tokenValue != token || host.isCancelled() || !continuation.isActive

            override fun complete(tokenValue: String, envelope: String) {
                if (tokenValue == token && continuation.isActive) {
                    binding.terminate()
                    continuation.resume(communityJsBoundedEnvelope(envelope))
                }
            }
        }
                connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                val connectedBroker = ICommunityJsBroker.Stub.asInterface(service)
                val lease = executionAdmission.reserveIfActive(
                    broker = connectedBroker,
                    isActive = { continuation.isActive },
                )
                if (lease == null || !executionAdmission.claimForCall(lease)) {
                    binding.terminate()
                    return
                }
                runCatching {
                    communityJsExecuteOverBinder(
                        token, invocation.provider.code, invocation.tmdbId, invocation.mediaType, settingsJson,
                    ) {
                        connectedBroker.execute(token, invocation.provider.code, invocation.tmdbId, invocation.mediaType,
                            settingsJson, invocation.season ?: 0, invocation.episode ?: 0,
                            timeoutMs, MAX_MEMORY_BYTES, callback)
                    }
                }.onSuccess { invoked ->
                    if (!invoked && continuation.isActive) { binding.terminate(); continuation.resume(FAILURE_ENVELOPE) }
                }.onFailure { if (continuation.isActive) { binding.terminate(); continuation.resume(FAILURE_ENVELOPE) } }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                if (continuation.isActive) { binding.terminate(); continuation.resume(FAILURE_ENVELOPE) }
            }

            override fun onBindingDied(name: ComponentName) {
                if (continuation.isActive) { binding.terminate(); continuation.resume(FAILURE_ENVELOPE) }
            }
        }
                val didBind = runCatching {
                    appContext.bindService(Intent(appContext, CommunityJsBrokerService::class.java), connection, Context.BIND_AUTO_CREATE)
                }.getOrDefault(false)
                binding.onBindResult(didBind)
                if (!didBind && continuation.isActive) continuation.resume(FAILURE_ENVELOPE)
            }
        } finally {
            val brokerToCancel = executionAdmission.cancel()
            host.cancel()
            runCatching { brokerToCancel?.cancel(token) }
            binding.terminate()
        }
    }

    /** The single native capability. No filesystem, reflection, application object, or credential bridge is bound. */
    interface NativeFetch {
        fun fetch(url: String, optionsJson: String, remainingTimeoutMs: Long): String
        fun isCancelled(): Boolean
    }

    private class NativeFetchImpl(private val invocationTimeoutMs: Long) : NativeFetch {
        private var requestCount = 0
        @Volatile private var cancelled = false

        fun cancel() { cancelled = true }

        override fun isCancelled(): Boolean = cancelled

        override fun fetch(url: String, optionsJson: String, remainingTimeoutMs: Long): String {
            if (++requestCount > MAX_REQUEST_COUNT) return responseJson(0, "Request limit reached", "", emptyMap())
            if (!CommunityJsUrlPolicy.isPublicHttpUrl(url)) return responseJson(0, "Blocked URL", "", emptyMap())
            val options = runCatching { JSONObject(optionsJson) }.getOrDefault(JSONObject())
            val request = runCatching {
                val headers = options.optJSONObject("headers") ?: JSONObject()
                val mappedHeaders = buildMap {
                    val keys = headers.keys()
                    while (keys.hasNext() && size < MAX_HEADER_COUNT) {
                        val key = keys.next()
                        val value = headers.optString(key)
                        if (key.length in 1..256 && value.length <= MAX_HEADER_VALUE_BYTES) put(key, value)
                    }
                }
                val safeHeaders = if (mappedHeaders.keys.none { it.equals("User-Agent", ignoreCase = true) }) {
                    mappedHeaders + ("User-Agent" to USER_AGENT)
                } else {
                    mappedHeaders
                }
                val method = options.optString("method", "GET").uppercase()
                require(method in ALLOWED_METHODS)
                val bodyText = options.optString("body", "").take(MAX_REQUEST_BODY_BYTES)
                FetchRequest(safeHeaders, method, bodyText.takeIf { method in BODY_METHODS })
            }.getOrNull() ?: return responseJson(0, "Invalid request", "", emptyMap())
            return CommunityJsPublicHttp.fetch(
                rawUrl = url,
                requireHttps = false,
                headers = request.headers,
                method = request.method,
                body = request.body,
                timeoutMs = minOf(invocationTimeoutMs, remainingTimeoutMs).coerceAtLeast(1),
                maxBytes = MAX_RESPONSE_BYTES,
            )?.let { response ->
                responseJson(response.status, response.statusText, response.body, response.headers)
            } ?: responseJson(0, "Network error", "", emptyMap())
        }

        private data class FetchRequest(val headers: Map<String, String>, val method: String, val body: String?)
    }

    private fun decodeStreams(raw: String): Result {
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return Result.Failure("Provider result is not an array.")
        val streams = buildList {
            for (i in 0 until minOf(array.length(), maxResultCount)) {
                val item = array.optJSONObject(i) ?: continue
                val url = item.optString("url").trim()
                if (!CommunityJsUrlPolicy.isPublicHttpUrl(url)) continue
                add(ProviderStream(
                    name = item.optString("name").trim().ifEmpty { null },
                    title = item.optString("title").trim().ifEmpty { null },
                    url = url,
                    quality = item.optString("quality").trim().ifEmpty { null },
                    size = item.opt("size")?.toString()?.trim()?.ifEmpty { null },
                    headers = strings(item.optJSONObject("headers")),
                    subtitles = subtitles(item.optJSONArray("subtitles")),
                ))
            }
        }
        return Result.Success(streams)
    }

    private fun subtitles(array: JSONArray?): List<Subtitle> = buildList {
        if (array == null) return@buildList
        for (i in 0 until minOf(array.length(), MAX_SUBTITLE_COUNT)) {
            val item = array.optJSONObject(i) ?: continue
            val url = item.optString("url").trim()
            if (CommunityJsUrlPolicy.isPublicHttpUrl(url)) add(Subtitle(url, item.optString("language").ifBlank { null }, item.optString("name").ifBlank { null }, strings(item.optJSONObject("headers"))))
        }
    }

    private fun strings(json: JSONObject?): Map<String, String> = buildMap {
        val keys = json?.keys() ?: return@buildMap
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.opt(key)?.toString()?.takeIf { it.length <= 4096 } ?: continue
            if (key.length <= 256) put(key, value)
        }
    }

    companion object {
        private const val DEFAULT_TIMEOUT_MS = 25_000L
        private const val BROKER_COMPLETION_GRACE_MS = 2_000L
        private const val MAX_SOURCE_BYTES = 1_000_000
        private const val MAX_RESPONSE_BYTES = 128 * 1024
        private const val MAX_RESULT_COUNT = 100
        private const val MAX_SUBTITLE_COUNT = 20
        private const val MAX_REQUEST_COUNT = 20
        private const val MAX_HEADER_COUNT = 32
        private const val MAX_HEADER_VALUE_BYTES = 4096
        private const val MAX_REQUEST_BODY_BYTES = 256 * 1024
        private const val MAX_MEMORY_BYTES = 16L * 1024 * 1024
        private const val USER_AGENT = "Mozilla/5.0 (Android) AppleWebKit/537.36 Chrome/125 Safari/537.36"
        private const val EMPTY_RESPONSE = COMMUNITY_JS_EMPTY_FETCH_RESPONSE
        private const val FAILURE_ENVELOPE = "{\"ok\":false,\"error\":\"Provider execution failed\"}"
        private val ALLOWED_METHODS = setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE")
        private val BODY_METHODS = setOf("POST", "PUT", "PATCH", "DELETE")
        private fun responseJson(status: Int, statusText: String, body: String, headers: Map<String, String>): String = JSONObject().apply {
            put("status", status); put("statusText", statusText); put("body", body); put("headers", JSONObject(headers))
        }.toString()
    }
}

/** Reconciles a terminal callback that races bindService's return without unbinding too early. */
internal class CommunityJsBindingOwner(private val unbind: () -> Unit) {
    private enum class State { BINDING, BOUND, TERMINAL }
    private val lock = Any()
    private var state = State.BINDING

    fun onBindResult(success: Boolean) {
        val shouldUnbind = synchronized(lock) {
            if (!success) {
                state = State.TERMINAL
                false
            } else if (state == State.TERMINAL) {
                true
            } else {
                state = State.BOUND
                false
            }
        }
        if (shouldUnbind) unbind()
    }

    fun terminate() {
        val shouldUnbind = synchronized(lock) {
            when (state) {
                State.BINDING -> { state = State.TERMINAL; false }
                State.BOUND -> { state = State.TERMINAL; true }
                State.TERMINAL -> false
            }
        }
        if (shouldUnbind) unbind()
    }
}

/** Orders broker execution admission against cancellation without holding a lock across Binder IPC. */
internal class CommunityJsBrokerExecutionAdmission<T : Any> {
    internal class Lease<T : Any> internal constructor(
        internal val generation: Long,
        internal val broker: T,
    )

    private enum class State { OPEN, LEASED, IN_FLIGHT, TERMINAL }

    private val lock = Any()
    private var state = State.OPEN
    private var generation = 0L
    private var broker: T? = null

    fun reserveIfActive(broker: T, isActive: () -> Boolean): Lease<T>? = synchronized(lock) {
        if (state != State.OPEN || !isActive()) return@synchronized null
        generation += 1
        this.broker = broker
        state = State.LEASED
        Lease(generation, broker)
    }

    fun claimForCall(lease: Lease<T>): Boolean = synchronized(lock) {
        if (state != State.LEASED || lease.generation != generation || broker !== lease.broker) {
            return@synchronized false
        }
        state = State.IN_FLIGHT
        true
    }

    fun cancel(): T? = synchronized(lock) {
        state = State.TERMINAL
        broker
    }
}
