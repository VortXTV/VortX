package com.vortx.android.engine

/** Explicit native-store boundary. No account selection, credential lookup or persistence here. */
internal interface VortxRuntimeBindings {
    fun create(ownerId: String, ownerName: String): Long
    fun hydrate(snapshot: String): Long
    fun dispatch(handle: Long, action: String): String?
    fun resolve(handle: Long, request: String): String?
    fun state(handle: Long): String?
    fun delta(handle: Long): String?
    fun free(handle: Long)
}

/** A typed Session view, never a generic Engine handle. Its owner retains the one writer. */
internal interface VortxRuntimeDelegate : AutoCloseable {
    fun fork(): VortxRuntimeDelegate
    fun dispatch(action: String): String
    fun resolve(request: String): String
    fun stateJson(): String
    /** Commit the full adjacent local state through the original typed checkpoint authority. */
    fun commitCheckpoint(snapshot: String, archiveChanges: Map<String, ByteArray>)
}

/** One monitor covers all handle calls, replacement and close, including failed cold hydration. */
internal class VortxNativeRuntime private constructor(
    private val bindings: VortxRuntimeBindings?,
    private var handle: Long,
    private val delegate: VortxRuntimeDelegate? = null,
) : AutoCloseable {
    private var closed = false
    companion object {
        fun create(bindings: VortxRuntimeBindings, ownerId: String, ownerName: String): VortxNativeRuntime =
            VortxNativeRuntime(bindings, bindings.create(ownerId, ownerName).also { check(it != 0L) { "Native engine unavailable" } })

        fun hydrate(bindings: VortxRuntimeBindings, snapshot: String): VortxNativeRuntime =
            VortxNativeRuntime(bindings, bindings.hydrate(snapshot).also { require(it != 0L) { "Invalid native snapshot" } })

        fun delegated(delegate: VortxRuntimeDelegate): VortxNativeRuntime = VortxNativeRuntime(null, 0, delegate)
    }

    @Synchronized override fun close() {
        if (closed) return
        // A failed typed close is not a successful retirement and must remain retry-visible.
        delegate?.close()
        val retired = handle
        handle = 0
        if (retired != 0L) requireNotNull(bindings).free(retired)
        closed = true
    }

    @Synchronized fun fork(): VortxNativeRuntime {
        check(!closed) { "Native engine closed" }
        return delegate?.let { delegated(it.fork()) } ?: hydrate(requireNotNull(bindings), stateJson())
    }

    @Synchronized fun commitTypedCheckpoint(snapshot: String, archiveChanges: Map<String, ByteArray> = emptyMap()): Boolean {
        check(!closed) { "Native engine closed" }
        val target = delegate ?: return false
        target.commitCheckpoint(snapshot, archiveChanges)
        return true
    }

    val isTyped: Boolean get() = delegate != null

    @Synchronized fun replaceFromSnapshot(snapshot: String) {
        check(delegate == null && !closed) { "Typed state requires its checkpoint authority" }
        check(handle != 0L) { "Native engine closed" }
        val native = requireNotNull(bindings)
        val replacement = native.hydrate(snapshot)
        require(replacement != 0L) { "Invalid native snapshot" }
        val retired = handle
        handle = replacement
        native.free(retired)
    }

    @Synchronized fun dispatch(action: String): String {
        check(!closed) { "Native engine closed" }
        return delegate?.dispatch(action) ?: call { requireNotNull(bindings).dispatch(it, action) }
    }
    @Synchronized fun resolve(request: String): String {
        check(!closed) { "Native engine closed" }
        return delegate?.resolve(request) ?: call { requireNotNull(bindings).resolve(it, request) }
    }
    @Synchronized fun stateJson(): String {
        check(!closed) { "Native engine closed" }
        return delegate?.stateJson() ?: call(requireNotNull(bindings)::state)
    }
    /** Drains dirty state; the caller owns durable application before requesting another delta. */
    @Synchronized fun takeDeltaJson(): String {
        check(delegate == null && !closed) { "Typed deltas require their checkpoint authority" }
        return call(requireNotNull(bindings)::delta)
    }

    private fun call(operation: (Long) -> String?): String {
        check(handle != 0L) { "Native engine closed" }
        return checkNotNull(operation(handle)) { "Native engine unavailable" }
    }
}

internal object VortxJniBindings : VortxRuntimeBindings {
    override fun create(ownerId: String, ownerName: String): Long {
        check(VortxCore.isAvailable()) { "Native engine unavailable" }
        return VortxCore.nativeInitRuntime(org.json.JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
    }
    override fun hydrate(snapshot: String): Long {
        check(VortxCore.isAvailable()) { "Native engine unavailable" }
        return VortxCore.nativeInitFromStateJson(snapshot)
    }
    override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
    override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
    override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
    override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
    override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
}
