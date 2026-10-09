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

/** One monitor covers all handle calls, replacement and close, including failed cold hydration. */
internal class VortxNativeRuntime private constructor(
    private val bindings: VortxRuntimeBindings,
    private var handle: Long,
) : AutoCloseable {
    companion object {
        fun create(bindings: VortxRuntimeBindings, ownerId: String, ownerName: String): VortxNativeRuntime =
            VortxNativeRuntime(bindings, bindings.create(ownerId, ownerName).also { check(it != 0L) { "Native engine unavailable" } })

        fun hydrate(bindings: VortxRuntimeBindings, snapshot: String): VortxNativeRuntime =
            VortxNativeRuntime(bindings, bindings.hydrate(snapshot).also { require(it != 0L) { "Invalid native snapshot" } })
    }

    @Synchronized override fun close() {
        val retired = handle
        handle = 0
        if (retired != 0L) bindings.free(retired)
    }

    @Synchronized fun replaceFromSnapshot(snapshot: String) {
        check(handle != 0L) { "Native engine closed" }
        val replacement = bindings.hydrate(snapshot)
        require(replacement != 0L) { "Invalid native snapshot" }
        val retired = handle
        handle = replacement
        bindings.free(retired)
    }

    @Synchronized fun dispatch(action: String): String = call { bindings.dispatch(it, action) }
    @Synchronized fun resolve(request: String): String = call { bindings.resolve(it, request) }
    @Synchronized fun stateJson(): String = call(bindings::state)
    /** Drains dirty state; the caller owns durable application before requesting another delta. */
    @Synchronized fun takeDeltaJson(): String = call(bindings::delta)

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
