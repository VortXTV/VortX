package com.vortx.android.player.mpv.seam

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal interface MpvReferenceNative {
    fun property(handle: Long, property: Int): MpvReferenceNode?
    // Binding failures/exceptions occur before enqueue. The JNI implementation performs no Java
    // operation after mpv_command_node_async returns, and returns that exact queue status.
    fun begin(handle: Long, identifier: Long, command: MpvReferenceCommand): Int
    fun abort(handle: Long, identifier: Long)
    fun revoke(handle: Long, grant: Long): Boolean
}

/** A cancel signal is not terminal completion. This becomes terminal only after the real reply. */
class MpvReferenceRequest internal constructor(private val cancelOriginalRequest: () -> Unit) {
    private val terminal = AtomicBoolean(false)
    val isTerminal: Boolean get() = terminal.get()
    fun cancel() = cancelOriginalRequest()
    internal fun finish() { terminal.set(true) }
}

enum class MpvReferenceClose {
    /** Exact grant retirement/absence, not a claim that native reaper/source quiescence has finished. */
    RETIRED,
    /** Native proof was unavailable. Ordinary admission was closed and context teardown requested. */
    TEARDOWN_REQUESTED,
}

/**
 * One original native handle's effect registry. Internal callbacks are independent of the ordinary
 * observer list, which the player removes during destroy. Every admitted request reserves its ID
 * before enqueue and owns the handle until its real terminal reply and exact grant cleanup.
 */
internal class MpvReferenceTransport(
    private val gate: () -> MpvNativeHandleGate?,
    private val native: MpvReferenceNative,
    private val forceDestroy: () -> Unit,
    private val cleanupExecutor: ExecutorService = Executors.newSingleThreadExecutor { work ->
        Thread(work, "mpv-reference-cleanup").apply { isDaemon = true }
    },
) {
    private val lock = Any()
    private val sessions = mutableSetOf<MpvReferenceSession>()
    private val pending = mutableMapOf<Long, MpvReferenceSession>()
    private var nextIdentifier = 1L
    private var retired = false

    fun open(expectedEntry: Long): MpvReferenceSession? {
        if (expectedEntry <= 0) return null
        val originalGate = gate() ?: return null
        val capture = originalGate.withHandle<MpvReferenceCapture?>(null) { handle ->
            MpvReferenceProtocol.capture(native.property(handle, 0), expectedEntry)
        } ?: return null
        val session = synchronized(lock) {
            if (retired || sessions.size >= 4) return null
            MpvReferenceSession(this, native, capture).also { sessions.add(it) }
        }
        val lease = originalGate.acquireAsyncLease(session::close)
        if (lease == null) {
            closed(session)
            return null
        }
        session.attach(lease)
        return session
    }

    internal fun register(session: MpvReferenceSession): Long? = synchronized(lock) {
        if (retired || session !in sessions || nextIdentifier == Long.MAX_VALUE) return@synchronized null
        val identifier = nextIdentifier++
        pending[identifier] = session
        identifier
    }

    /** Native events have reserved reply slots. QUEUE_OVERFLOW must not synthesize completion. */
    fun reply(identifier: Long, error: Int, node: MpvReferenceNode?) {
        val session = synchronized(lock) { pending[identifier] } ?: return
        try { session.terminal(identifier, error, node) } catch (_: Throwable) {
            session.failedTerminal(identifier)
        }
        // Keep the registration available to the JNI failure handler if internal cleanup itself fails.
        synchronized(lock) { pending.remove(identifier) }
    }

    /** Only a known request is failed; success-without-proof is conservatively unconfirmed. */
    fun failedDelivery(identifier: Long) = reply(identifier, 0, null)

    fun retire() {
        val effects = synchronized(lock) {
            retired = true
            sessions.toList()
        }
        for (effect in effects) effect.close()
        shutdownIfRetired()
    }

    internal fun cleanup(work: () -> Unit, fallback: () -> Unit) {
        val begun = AtomicBoolean(false)
        try { cleanupExecutor.execute { if (begun.compareAndSet(false, true)) work() } }
        catch (_: Throwable) { if (begun.compareAndSet(false, true)) fallback() }
    }

    internal fun failClosed() = forceDestroy()

    internal fun closed(session: MpvReferenceSession) {
        synchronized(lock) { sessions.remove(session) }
        shutdownIfRetired()
    }

    private fun shutdownIfRetired() {
        val stop = synchronized(lock) { retired && sessions.isEmpty() }
        if (stop) cleanupExecutor.shutdown()
    }
}

/**
 * READ → PREPARE → COMMIT on one immutable v2 capture. Retain this effect for the lifetime of its
 * publication; close it on manual/source/account retirement. close() never waits on the event thread.
 * The session keeps a successful READ's exact grant even when cancellation wins before its reply.
 */
class MpvReferenceSession internal constructor(
    private val transport: MpvReferenceTransport,
    private val native: MpvReferenceNative,
    val capture: MpvReferenceCapture,
) {
    private val lock = Any()
    private var lease: MpvNativeHandleGate.AsyncLease? = null
    private var pending: Pending? = null
    private var receipt: MpvReferenceReceipt? = null
    private var ticket: Long? = null
    private var readStarted = false
    private var prepareStarted = false
    private var commitStarted = false
    private var closing = false
    private var cleaning = false
    private var closed: MpvReferenceClose? = null
    private var unknownGrant = false
    private var teardownRequested = false
    private val closedCallbacks = mutableListOf<(MpvReferenceClose) -> Unit>()

    private class Pending(
        val identifier: Long,
        val command: MpvReferenceCommand,
        val request: MpvReferenceRequest,
        val callback: (MpvReferenceReply) -> Unit,
        var enqueueReturned: Boolean = false,
        var cancelRequested: Boolean = false,
    )

    internal fun attach(originalLease: MpvNativeHandleGate.AsyncLease) {
        synchronized(lock) {
            check(lease == null)
            lease = originalLease
        }
        maybeCleanup() // destruction can close the session before attach finishes
    }

    fun read(callback: (MpvReferenceReply) -> Unit): MpvReferenceRequest? = begin(callback) {
        if (readStarted) return@begin null
        readStarted = true
        MpvReferenceCommand(MpvReferenceCommand.READ, capture.witness(), capture.origin)
    }

    fun prepare(payload: String, callback: (MpvReferenceReply) -> Unit): MpvReferenceRequest? {
        if (payload.isEmpty() || payload.length > MpvReferenceProtocol.MAX_PAYLOAD_BYTES || '\u0000' in payload) {
            close(); return null
        }
        val bytes = try { payload.toByteArray(Charsets.UTF_8) } catch (failure: Throwable) {
            close(); throw failure
        }
        if (bytes.size > MpvReferenceProtocol.MAX_PAYLOAD_BYTES) { close(); return null }
        return begin(callback) {
            val original = receipt ?: return@begin null
            if (prepareStarted) return@begin null
            prepareStarted = true
            MpvReferenceCommand(MpvReferenceCommand.PREPARE, original.prepareWitness(), capture.origin, bytes)
        }
    }

    fun commit(callback: (MpvReferenceReply) -> Unit): MpvReferenceRequest? = begin(callback) {
        val original = receipt ?: return@begin null
        val originalTicket = ticket ?: return@begin null
        if (commitStarted) return@begin null
        commitStarted = true
        MpvReferenceCommand(MpvReferenceCommand.COMMIT,
            longArrayOf(originalTicket) + original.prepareWitness(), capture.origin)
    }

    /** A current publication check, never a replacement for the application's original owner guard. */
    fun isActive(): Boolean {
        val state = synchronized(lock) {
            val original = receipt
            val originalTicket = ticket
            val originalLease = lease
            if (closing || closed != null || original == null || originalTicket == null || originalLease == null)
                return false
            Triple(originalLease, original, originalTicket)
        }
        val active = try { state.first.submit(false) { handle ->
            MpvReferenceProtocol.active(native.property(handle, 1), state.second, state.third)
        } } catch (_: Throwable) { close(); false }
        return active && synchronized(lock) {
            !closing && closed == null && receipt === state.second && ticket == state.third &&
                state.first.isOwnerCurrent
        }
    }

    fun whenClosed(callback: (MpvReferenceClose) -> Unit) {
        val result = synchronized(lock) {
            closed.also { if (it == null) closedCallbacks.add(callback) }
        }
        if (result != null) callback(result)
    }

    fun close() {
        val operationToAbort = synchronized(lock) {
            closing = true
            pending?.also { it.cancelRequested = true }?.takeIf { it.enqueueReturned }
        }
        if (operationToAbort != null) abort(operationToAbort.identifier)
        maybeCleanup()
    }

    private fun begin(callback: (MpvReferenceReply) -> Unit, command: () -> MpvReferenceCommand?): MpvReferenceRequest? {
        val operation = synchronized(lock) {
            val originalLease = lease
            if (closing || closed != null || pending != null || originalLease?.isOwnerCurrent != true) return null
            val nativeCommand = command() ?: return null
            val identifier = transport.register(this) ?: return null
            Pending(identifier, nativeCommand, MpvReferenceRequest { cancelRequest(identifier) }, callback).also { pending = it }
        }
        // No session monitor crosses JNI. The temporary submission lease protects reply-before-return.
        val originalLease = synchronized(lock) { lease }
        val status = try {
            originalLease?.submit(Int.MIN_VALUE) { handle -> native.begin(handle, operation.identifier, operation.command) }
                ?: Int.MIN_VALUE
        } catch (_: Throwable) { Int.MIN_VALUE }
        val shouldAbort = synchronized(lock) {
            operation.enqueueReturned = true
            pending === operation && operation.cancelRequested && status >= 0
        }
        if (status < 0) transport.reply(operation.identifier, status, null)
        else if (shouldAbort) abort(operation.identifier) // abort-before-enqueue has no native effect
        return operation.request
    }

    private fun cancelRequest(identifier: Long) {
        val operation = synchronized(lock) {
            val original = pending?.takeIf { it.identifier == identifier } ?: return
            closing = true
            original.cancelRequested = true
            original.takeIf { it.enqueueReturned }
        }
        if (operation != null) abort(operation.identifier)
        maybeCleanup()
    }

    private fun abort(identifier: Long) {
        val originalLease = synchronized(lock) { lease } ?: return
        try { originalLease.cleanup(Unit) { handle -> native.abort(handle, identifier) } }
        catch (_: Throwable) {
            // Cancellation is still not terminal. Keep the lease and await the real bounded command;
            // a broken cleanup bridge requires context teardown after that original request drains.
            val unknown = synchronized(lock) {
                (pending?.identifier == identifier).also { if (it) unknownGrant = true }
            }
            if (unknown) requestContextTeardown()
        }
    }

    internal fun terminal(identifier: Long, error: Int, node: MpvReferenceNode?) {
        val completed = synchronized(lock) {
            val operation = pending?.takeIf { it.identifier == identifier } ?: return
            val cancelled = closing || operation.cancelRequested || lease?.isOwnerCurrent != true
            val reply = if (error < 0) MpvReferenceReply.Rejected(error) else when (operation.command.operation) {
                MpvReferenceCommand.READ -> {
                    val original = MpvReferenceProtocol.read(node, capture)
                    if (original == null) {
                        unknownGrant = true // a successful but unreadable READ may have allocated a grant
                        MpvReferenceReply.Unconfirmed
                    } else {
                        receipt = original
                        MpvReferenceReply.Read(original)
                    }
                }
                MpvReferenceCommand.PREPARE -> {
                    val original = receipt
                    val prepared = if (original != null) MpvReferenceProtocol.prepared(node, original) else null
                    if (original == null || prepared == null) MpvReferenceReply.Unconfirmed else {
                        ticket = prepared
                        MpvReferenceReply.Prepared(original.grant, prepared)
                    }
                }
                MpvReferenceCommand.COMMIT -> {
                    val original = receipt
                    val originalTicket = ticket
                    if (original != null && originalTicket != null &&
                        MpvReferenceProtocol.committed(node, original, originalTicket)) {
                        MpvReferenceReply.Committed(original.grant, originalTicket)
                    } else MpvReferenceReply.Unconfirmed
                }
                else -> MpvReferenceReply.Unconfirmed
            }
            if (reply is MpvReferenceReply.Rejected || reply === MpvReferenceReply.Unconfirmed ||
                lease?.isOwnerCurrent != true) closing = true
            pending = null
            operation.request.finish() // internal terminal bookkeeping precedes every client callback
            Triple(operation, if (cancelled) MpvReferenceReply.Cancelled else reply, unknownGrant)
        }
        if (completed.third) requestContextTeardown() // close ordinary admission before client fallback
        maybeCleanup()
        try { completed.first.callback(completed.second) } catch (_: Throwable) {
            close() // client failure must not leak a request or a successful grant
        }
    }

    /** A real reply arrived, but its internal copy/decoder could not finish. Never invent a grant. */
    internal fun failedTerminal(identifier: Long) {
        val completed = synchronized(lock) {
            val original = pending?.takeIf { it.identifier == identifier } ?: return
            unknownGrant = unknownGrant || original.command.operation == MpvReferenceCommand.READ
            closing = true
            pending = null
            original.request.finish()
            original to unknownGrant
        }
        if (completed.second) requestContextTeardown()
        maybeCleanup()
        runCatching { completed.first.callback(MpvReferenceReply.Unconfirmed) }
    }

    private fun requestContextTeardown() {
        val first = synchronized(lock) {
            if (teardownRequested) false else { teardownRequested = true; true }
        }
        if (first) transport.failClosed()
    }

    private fun maybeCleanup() {
        val cleanup = synchronized(lock) {
            val originalLease = lease
            if (!closing || cleaning || closed != null || pending != null || originalLease == null) return
            cleaning = true // one-way fence before revoke/force-destroy can reenter this session
            Triple(originalLease, receipt?.grant, unknownGrant)
        }
        val finish: (MpvReferenceClose) -> Unit = { result ->
            try { cleanup.first.close() } finally {
                transport.closed(this)
                val callbacks = synchronized(lock) {
                    closed = result
                    lease = null
                    closedCallbacks.toList().also { closedCallbacks.clear() }
                }
                for (callback in callbacks) runCatching { callback(result) }
            }
        }
        transport.cleanup(work = {
            var retired = false
            try {
                val grant = cleanup.second
                retired = !cleanup.third && (grant == null || cleanup.first.cleanup(false) { handle ->
                    native.revoke(handle, grant)
                })
                if (!retired) requestContextTeardown()
            } catch (_: Throwable) {
                requestContextTeardown()
            } finally {
                finish(if (retired) MpvReferenceClose.RETIRED else MpvReferenceClose.TEARDOWN_REQUESTED)
            }
        }, fallback = {
            try { requestContextTeardown() } finally { finish(MpvReferenceClose.TEARDOWN_REQUESTED) }
        })
    }
}
