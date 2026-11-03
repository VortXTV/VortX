package com.vortx.android.integrations

import com.vortx.android.engine.NativeLibraryMirrorOrigin
import com.vortx.android.sync.SessionOperationCoordinator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.resume

/** A prepared Call owns this one-use ticket. Revocation is published under the original
 * credential lock, with cancellation delivered off the credential/manager/vault stack. */
internal class ProviderCallTicket(private val cancel: () -> Unit) {
    private val state = AtomicInteger(0)

    fun claim(): Boolean = state.compareAndSet(0, CLAIMED)

    fun retire() {
        val previous = state.getAndUpdate { it or RETIRED }
        if (previous and (RETIRED or CLOSED) == 0)
            Dispatchers.IO.dispatch(EmptyCoroutineContext, Runnable { cancel() })
    }

    fun close() { state.getAndUpdate { it or CLOSED } }

    fun outcome(response: IntegrationsHttp.Response): ProviderMirrorResponse =
        if (state.get() and CLAIMED != 0) ProviderMirrorResponse.Started(response) else ProviderMirrorResponse.Refused

    private companion object {
        const val CLAIMED = 1
        const val RETIRED = 2
        const val CLOSED = 4
    }
}

internal sealed interface ProviderMirrorResponse {
    data object Refused : ProviderMirrorResponse
    data class Started(val response: IntegrationsHttp.Response) : ProviderMirrorResponse
}

internal enum class ProviderMirrorResult {
    REFUSED, REFRESH_FAILED, REFRESH_SUCCEEDED, ATTEMPTED_FAILURE, SUCCEEDED,
}

internal fun ProviderMirrorResponse.result(): ProviderMirrorResult = when (this) {
    ProviderMirrorResponse.Refused -> ProviderMirrorResult.REFUSED
    is ProviderMirrorResponse.Started ->
        if (response.isSuccess) ProviderMirrorResult.SUCCEEDED else ProviderMirrorResult.ATTEMPTED_FAILURE
}

/** The same exact provider Operation and material check travel from snapshot to dispatch. */
internal class ProviderMirrorCredential(
    val bearer: String,
    val operation: CredentialMutationCoordinator.Operation,
    val matches: () -> Boolean,
)

/** Only the newly produced native mirror uses this transport. Legacy rows do not gain authority. */
internal object ProviderMirrorTransport {
    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .authenticator(Authenticator.NONE)
        .proxyAuthenticator(Authenticator.NONE)
        .callTimeout(20, TimeUnit.SECONDS)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val request = chain.request()
            val firstIo = request.tag(FirstIo::class.java)
            if (chain.call().isCanceled() || firstIo == null || !firstIo.claim())
                throw IOException("Provider request admission retired")
            chain.proceed(request)
        }
        .build()

    private class FirstIo(
        private val origin: NativeLibraryMirrorOrigin,
        private val operation: CredentialMutationCoordinator.Operation,
        private val manager: SessionOperationCoordinator.OutboundCallPermit,
        private val ticket: ProviderCallTicket,
        private val caller: Job?,
        private val matches: () -> Boolean,
    ) {
        // Session -> credential -> original manager -> vault -> exact native mount.
        // The callback claims a scalar once and leaves every monitor before chain.proceed.
        fun claim(): Boolean = try {
            origin.withOriginalNativeOwner {
                operation.claimOutbound(ticket) {
                    matches() && origin.admitAccountMount {
                        caller?.isActive != false && manager.isCurrent() && ticket.claim()
                    }
                }
            }
        } catch (_: Exception) { false }
    }

    suspend fun post(
        origin: NativeLibraryMirrorOrigin,
        operation: CredentialMutationCoordinator.Operation,
        matches: () -> Boolean,
        url: String,
        headers: Map<String, String>,
        body: String,
    ): ProviderMirrorResponse {
        val caller = currentCoroutineContext()
        caller.ensureActive()
        val permit = try { origin.acquireCallPermit() } catch (_: Exception) { null }
            ?: return ProviderMirrorResponse.Refused
        try {
            // Preparation only. The tagged first-I/O gate runs on OkHttp's execution lane.
            val bytes = body.toByteArray(Charsets.UTF_8)
            lateinit var call: Call
            val ticket = ProviderCallTicket { call.cancel() }
            try {
                val request = Request.Builder().url(url)
                    .tag(FirstIo::class.java, FirstIo(origin, operation, permit, ticket, caller[Job], matches))
                    .apply { headers.forEach { (name, value) -> header(name, value) } }
                    .post(object : RequestBody() {
                        private val wrote = AtomicBoolean(false)
                        override fun contentType() = "application/json".toMediaType()
                        override fun contentLength() = bytes.size.toLong()
                        override fun isOneShot() = true
                        override fun writeTo(sink: BufferedSink) {
                            if (!wrote.compareAndSet(false, true)) throw IOException("Repeated provider request body")
                            sink.write(bytes)
                        }
                    }).build()
                call = client.newCall(request)
                if (!permit.attachCancellation(call::cancel) || !operation.attachOutbound(ticket)) {
                    call.cancel()
                    return ProviderMirrorResponse.Refused
                }
                return ticket.outcome(awaitDrained(call))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return ticket.outcome(failed())
            } finally {
                operation.closeOutbound(ticket)
                ticket.close()
                bytes.fill(0)
            }
        } finally { permit.close() }
    }

    /** Keep the parent writer lease until the prepared call's callback has closed its response. */
    private suspend fun awaitDrained(call: Call): IntegrationsHttp.Response {
        val drained = CompletableDeferred<Unit>()
        try {
            return suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation { call.cancel() }
                if (!continuation.isActive) {
                    drained.complete(Unit)
                    return@suspendCancellableCoroutine
                }
                fun finish(result: IntegrationsHttp.Response) {
                    drained.complete(Unit)
                    if (continuation.isActive) continuation.resume(result)
                }
                try {
                    call.enqueue(object : Callback {
                        override fun onFailure(call: Call, e: IOException) { finish(failed()) }
                        override fun onResponse(call: Call, response: Response) {
                            var result = failed()
                            try {
                                result = response.use { IntegrationsHttp.Response(it.code, it.body.string()) }
                            } catch (_: Exception) {
                                // Decode or transport failure is reported through the existing status 0.
                            } finally { finish(result) }
                        }
                    })
                } catch (_: Exception) {
                    call.cancel()
                    finish(failed())
                }
            }
        } finally {
            withContext(NonCancellable) { drained.await() }
        }
    }

    private fun failed() = IntegrationsHttp.Response(0, "")
}
