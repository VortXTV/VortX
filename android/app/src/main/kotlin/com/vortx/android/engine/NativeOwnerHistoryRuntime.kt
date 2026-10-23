package com.vortx.android.engine

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** A synchronous original-source/FIFO authority check, not an authentication implementation.
 * No binding/runtime retains this verifier after its one call. Reentry is rejected.
 */
fun interface NativeOwnerHistoryVerifier {
    fun verify(bytes: ByteArray): Boolean
}

/** Exact bytes in/out. Native errors remain protocol replies; the owner must reject kind:error. */
internal interface NativeOwnerHistoryBindings {
    fun canonicalize(evidence: ByteArray): ByteArray?
    fun open(snapshot: ByteArray, verifier: NativeOwnerHistoryVerifier): Long
    fun fork(handle: Long, fence: ByteArray, verifier: NativeOwnerHistoryVerifier): Long
    fun request(handle: Long, json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier): ByteArray?
    fun close(handle: Long): Boolean
}

/** One native call per handle; callbacks run outside the monitor and cannot reenter/close it.
 * No implicit/finalizer free: a false/throwing close keeps the exact handle for quarantine.
 * The Session owner must not publish, release its writer, or substitute a generic runtime until
 * retirement is confirmed. Native acceptance alone is never a durable checkpoint ACK.
 */
internal class NativeOwnerHistoryRuntime private constructor(
    private val bindings: NativeOwnerHistoryBindings,
    private var handle: Long,
) {
    private val lock = Any()
    private var inCall = false
    private var retirementRequested = false

    companion object {
        internal const val MAX_BYTES = 16 * 1024 * 1024
        internal const val MAX_FENCE_BYTES = 64 * 1024

        /** Copies without JSON/String round-trip. REPORT rejects replacement/surrogate UTF-8. */
        private fun raw(bytes: ByteArray, limit: Int): ByteArray {
            require(bytes.isNotEmpty() && bytes.size <= limit) { "Owner history bytes exceed bound" }
            val copy = bytes.copyOf()
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(copy))
            return copy
        }

        fun open(
            bindings: NativeOwnerHistoryBindings,
            snapshot: ByteArray,
            verifier: NativeOwnerHistoryVerifier,
        ): NativeOwnerHistoryRuntime {
            val handle = bindings.open(raw(snapshot, MAX_BYTES), verifier)
            check(handle > 0L) { "Owner history native open rejected" }
            return NativeOwnerHistoryRuntime(bindings, handle)
        }
    }

    fun fork(fence: ByteArray, verifier: NativeOwnerHistoryVerifier): NativeOwnerHistoryRuntime {
        val exact = raw(fence, MAX_FENCE_BYTES)
        return call { parent ->
            val child = bindings.fork(parent, exact, verifier)
            check(child > 0L && child != parent) { "Owner history native fork rejected" }
            NativeOwnerHistoryRuntime(bindings, child)
        }
    }

    /** now is explicit Unix seconds for real actions, never a discovery/import replay clock. */
    fun request(json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier): ByteArray {
        require(now >= 0L) { "Owner history action clock must be nonnegative" }
        val exact = raw(json, MAX_BYTES)
        return call { current ->
            raw(checkNotNull(bindings.request(current, exact, now, verifier)) {
                "Owner history native request unavailable"
            }, MAX_BYTES)
        }
    }

    fun close(): Boolean {
        val current = synchronized(lock) {
            if (inCall) return false
            if (handle == 0L) return true
            retirementRequested = true
            inCall = true
            handle
        }
        val retired = try {
            bindings.close(current)
        } catch (_: Throwable) {
            false
        }
        synchronized(lock) {
            if (retired) handle = 0L
            inCall = false
        }
        return retired
    }

    private inline fun <T> call(operation: (Long) -> T): T {
        val current = synchronized(lock) {
            check(!inCall) { "Owner history native call already active" }
            check(!retirementRequested) { "Owner history native retirement unconfirmed" }
            check(handle != 0L) { "Owner history native handle retired" }
            inCall = true
            handle
        }
        try {
            return operation(current)
        } finally {
            synchronized(lock) { inCall = false }
        }
    }
}

/** Only the explicit owner-history artifact gate may install this adapter. No load/activation
 * flag, fresh account seed, source validation shortcut or ordinary Engine* fallback lives here.
 */
internal object NativeOwnerHistoryJniBindings : NativeOwnerHistoryBindings {
    override fun canonicalize(evidence: ByteArray) = VortxCore.nativeOwnerHistoryCanonicalize(evidence)
    override fun open(snapshot: ByteArray, verifier: NativeOwnerHistoryVerifier) =
        VortxCore.nativeOwnerHistoryOpen(snapshot, verifier)
    override fun fork(handle: Long, fence: ByteArray, verifier: NativeOwnerHistoryVerifier) =
        VortxCore.nativeOwnerHistoryFork(handle, fence, verifier)
    override fun request(handle: Long, json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier) =
        VortxCore.nativeOwnerHistoryRequest(handle, json, now, verifier)
    override fun close(handle: Long) = VortxCore.nativeOwnerHistoryClose(handle)
}
