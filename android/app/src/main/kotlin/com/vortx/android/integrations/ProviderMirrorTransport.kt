package com.vortx.android.integrations

import com.vortx.android.account.AccountWatchlistClient
import com.vortx.android.account.providerWatchlistUrl
import com.vortx.android.account.watchlistOperation
import com.vortx.android.engine.NativeLibraryMirrorOrigin
import com.vortx.android.sync.ProviderRetryOutbox
import com.vortx.android.sync.ProviderRetryStart
import com.vortx.android.sync.SessionOperationCoordinator
import com.vortx.android.sync.VortXSyncManager
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
import java.security.MessageDigest
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

    fun isClaimedAndCurrent(): Boolean = state.get() == CLAIMED

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

internal enum class DurableProviderPost { Refused, Unsettled, Confirmed }

/** The fresh and durable paths each need their original authority. Legacy rows remain outside both. */
internal object ProviderMirrorTransport {
    private const val MAX_RECEIPT_REQUEST_BYTES = 4_096
    private const val MAX_RECEIPT_RESPONSE_BYTES = 32_768
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

    private fun interface FirstIo { fun claim(): Boolean }

    private class FreshFirstIo(
        private val origin: NativeLibraryMirrorOrigin,
        private val operation: CredentialMutationCoordinator.Operation,
        private val manager: SessionOperationCoordinator.OutboundCallPermit,
        private val ticket: ProviderCallTicket,
        private val caller: Job?,
        private val matches: () -> Boolean,
    ) : FirstIo {
        // Session -> credential -> original manager -> vault -> exact native mount.
        // The callback claims a scalar once and leaves every monitor before chain.proceed.
        override fun claim(): Boolean = try {
            origin.withOriginalNativeOwner {
                operation.claimOutbound(ticket) {
                    matches() && origin.admitAccountMount {
                        caller?.isActive != false && manager.isCurrent() && ticket.claim()
                    }
                }
            }
        } catch (_: Exception) { false }
    }

    private class DurableFirstIo(
        private val owner: VortXSyncManager.ProviderRetryOwner,
        private val origin: NativeLibraryMirrorOrigin?,
        private val credential: DurableProviderMirrorCredential,
        private val manager: SessionOperationCoordinator.OutboundCallPermit,
        private val ticket: ProviderCallTicket,
        private val caller: Job?,
        private val start: ProviderRetryStart,
    ) : FirstIo {
        override fun claim(): Boolean = underOriginal {
            ticket.claim() && start.tryClaimFirstIo()
        }

        fun confirm(): Boolean = underOriginal {
            ticket.isClaimedAndCurrent() && start.wasClaimed()
        }

        private fun underOriginal(action: () -> Boolean): Boolean = try {
            fun guardedClaim(): Boolean = credential.operation.claimOutbound(ticket) {
                // The exact retry guard already confirmed the persisted credential under the vault gate.
                // This reenters the same manager gate and runs only scalar checks and claims.
                credential.matches() && owner.admitCall(manager) {
                    fun currentClaim() = caller?.isActive != false && action()
                    if (origin == null) currentClaim() else origin.admitAccountMount(::currentClaim)
                }
            }
            if (origin == null) guardedClaim() else origin.withOriginalNativeOwner(::guardedClaim)
        } catch (_: Exception) { false }
    }

    private class JsonBody(private val bytes: ByteArray) : RequestBody() {
        private val wrote = AtomicBoolean(false)
        private val submitted = AtomicBoolean(false)

        override fun contentType() = "application/json".toMediaType()
        override fun contentLength() = bytes.size.toLong()
        override fun isOneShot() = true

        override fun writeTo(sink: BufferedSink) {
            if (!wrote.compareAndSet(false, true)) throw IOException("Repeated provider request body")
            sink.write(bytes)
            submitted.set(true)
        }

        fun wasSubmitted(): Boolean = submitted.get()
    }

    private fun preparedCall(url: String, headers: Map<String, String>, body: JsonBody, firstIo: FirstIo): Call =
        client.newCall(Request.Builder().url(url).tag(FirstIo::class.java, firstIo)
            .apply { headers.forEach { (name, value) -> header(name, value) } }.post(body).build())

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
                call = preparedCall(url, headers, JsonBody(bytes), FreshFirstIo(origin, operation, permit, ticket, caller[Job], matches))
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

    /** Use the fixed watchlist wire and verify one correlated response against the exact submitted bytes. */
    suspend fun postDurable(
        owner: VortXSyncManager.ProviderRetryOwner,
        origin: NativeLibraryMirrorOrigin?,
        credential: DurableProviderMirrorCredential,
        start: ProviderRetryStart,
        receipt: ProviderWatchlistReceipt.Operation,
    ): DurableProviderPost {
        val caller = currentCoroutineContext()
        caller.ensureActive()
        val lane = start.head.lane
        if (owner.owner != lane.owner || (origin != null && origin.expectedAccount != lane.owner) || start.wasClaimed())
            return DurableProviderPost.Refused
        if (lane.provider.watchlistOperation(start.head.row.add) != receipt || !durableCredentialMatches(lane, start.head.row, credential))
            return DurableProviderPost.Refused
        val body = AccountWatchlistClient.durableRequestBody(lane, start.head.row) ?: return DurableProviderPost.Refused
        if (body.length !in 1..MAX_RECEIPT_REQUEST_BYTES) return DurableProviderPost.Refused
        val permit = try { owner.acquireCallPermit() } catch (_: Exception) { null } ?: return DurableProviderPost.Refused
        try {
            val bytes = body.toByteArray(Charsets.UTF_8)
            lateinit var call: Call
            val ticket = ProviderCallTicket { call.cancel() }
            try {
                if (bytes.size !in 1..MAX_RECEIPT_REQUEST_BYTES) return DurableProviderPost.Refused
                val requestBody = JsonBody(bytes)
                val firstIo = DurableFirstIo(owner, origin, credential, permit, ticket, caller[Job], start)
                val identityHeaders = AccountWatchlistClient.durableRequestHeaders(lane.provider, credential.bearer) +
                    ("Accept-Encoding" to "identity")
                call = preparedCall(providerWatchlistUrl(receipt), identityHeaders, requestBody, firstIo)
                if (!permit.attachCancellation(call::cancel) || !credential.operation.attachOutbound(ticket)) {
                    call.cancel()
                    return DurableProviderPost.Refused
                }
                val confirmed = awaitDrained(call, false) { response ->
                    requestBody.wasSubmitted() && exactReceipt(call.request(), requestBody, bytes, receipt, response)
                }
                return when {
                    !start.wasClaimed() -> DurableProviderPost.Refused
                    confirmed && firstIo.confirm() -> DurableProviderPost.Confirmed
                    else -> DurableProviderPost.Unsettled
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return if (start.wasClaimed()) DurableProviderPost.Unsettled else DurableProviderPost.Refused
            } finally {
                credential.operation.closeOutbound(ticket)
                ticket.close()
                bytes.fill(0)
            }
        } finally { permit.close() }
    }

    private fun durableCredentialMatches(
        lane: ProviderRetryOutbox.Lane,
        row: ProviderRetryOutbox.Row,
        credential: DurableProviderMirrorCredential,
    ): Boolean {
        val group = when (lane.provider) {
            ProviderRetryOutbox.Provider.TRAKT -> NativeProviderCredentials.GROUPS[0]
            ProviderRetryOutbox.Provider.SIMKL -> NativeProviderCredentials.GROUPS[1]
        }
        if (credential.guard.owner != lane.owner || credential.guard.keys != group ||
            !credential.operation.ownsRetryGuard(credential.guard) || !credential.matches()) return false
        val captured = credential.copyProof() ?: return false
        val original = row.credentialProof()
        return try { captured.size == original.size && MessageDigest.isEqual(original, captured) }
        finally { original.fill(0); captured.fill(0) }
    }

    private fun exactReceipt(
        request: Request, body: JsonBody, bytes: ByteArray, operation: ProviderWatchlistReceipt.Operation, response: Response,
    ): Boolean {
        if (response.code != operation.successStatus || response.priorResponse != null || response.cacheResponse != null ||
            response.networkResponse == null ||
            response.request.url != request.url || response.request.method != "POST" || response.request.body !== body ||
            response.headers.values("Content-Encoding").any { !it.equals("identity", ignoreCase = true) }) return false
        val expectedSize = response.body.contentLength()
        if (expectedSize == 0L || expectedSize > MAX_RECEIPT_RESPONSE_BYTES) return false
        val scratch = ByteArray(MAX_RECEIPT_RESPONSE_BYTES + 1)
        try {
            val stream = response.body.byteStream()
            var size = 0
            while (size < scratch.size) {
                val read = stream.read(scratch, size, scratch.size - size)
                if (read == -1) break
                if (read <= 0) return false
                size += read
            }
            if (size !in 1..MAX_RECEIPT_RESPONSE_BYTES || (expectedSize >= 0 && size.toLong() != expectedSize)) return false
            val exactResponse = scratch.copyOf(size)
            try {
                return when (ProviderWatchlistReceipt.evaluate(operation, bytes, response.code, exactResponse)) {
                    ProviderWatchlistReceipt.Outcome.ADDED, ProviderWatchlistReceipt.Outcome.ALREADY_PRESENT,
                    ProviderWatchlistReceipt.Outcome.REMOVED, ProviderWatchlistReceipt.Outcome.STATUS_CONFIRMED -> true
                    ProviderWatchlistReceipt.Outcome.ITEM_REPORTED_NOT_FOUND, ProviderWatchlistReceipt.Outcome.UNVERIFIED -> false
                }
            } finally { exactResponse.fill(0) }
        } finally { scratch.fill(0) }
    }

    /** Keep the parent writer lease until the prepared call's callback has closed its response. */
    private suspend fun awaitDrained(call: Call): IntegrationsHttp.Response = awaitDrained(call, failed()) {
        IntegrationsHttp.Response(it.code, it.body.string())
    }

    private suspend fun <T> awaitDrained(call: Call, failed: T, decode: (Response) -> T): T {
        val drained = CompletableDeferred<Unit>()
        try {
            return suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation { call.cancel() }
                if (!continuation.isActive) {
                    drained.complete(Unit)
                    return@suspendCancellableCoroutine
                }
                fun finish(result: T) {
                    drained.complete(Unit)
                    if (continuation.isActive) continuation.resume(result)
                }
                try {
                    call.enqueue(object : Callback {
                        override fun onFailure(call: Call, e: IOException) { finish(failed) }
                        override fun onResponse(call: Call, response: Response) {
                            var result = failed
                            try {
                                result = response.use(decode)
                            } catch (_: Exception) {
                                // Decode or transport failure is reported through the existing status 0.
                            } finally { finish(result) }
                        }
                    })
                } catch (_: Exception) {
                    call.cancel()
                    finish(failed)
                }
            }
        } finally {
            withContext(NonCancellable) { drained.await() }
        }
    }

    private fun failed() = IntegrationsHttp.Response(0, "")
}
