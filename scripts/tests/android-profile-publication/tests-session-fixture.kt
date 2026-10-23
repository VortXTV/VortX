package com.vortx.android.engine

import com.vortx.android.profile.NativeProfileGateway
import java.util.concurrent.atomic.AtomicInteger

internal data class VortxNativeOwner(val epoch: Long, val profileID: String)
internal data class VortxNativeRead(val owner: VortxNativeOwner, val projected: NativeProfileGateway.Projection)

// Synthetic collaborator only. The real Session has a synchronized read and the owned method below.
internal class VortxNativeSession(
    var owner: VortxNativeOwner,
    private var projected: NativeProfileGateway.Projection,
) {
    @Volatile var beforeReadLock: (() -> Unit)? = null
    @Volatile var closed = false
    @Volatile var recovering = false
    @Volatile var accountCurrent = true
    val fullReads = AtomicInteger()
    private fun isAccountCurrent(): Boolean = accountCurrent
    fun read(): VortxNativeRead {
        beforeReadLock?.invoke() // Instrumentation announces the attempt before blocking on Session.
        return synchronized(this) {
            check(!closed) { "Native session closed" }
            check(isAccountCurrent()) { "Native account changed" }
            fullReads.incrementAndGet()
            VortxNativeRead(owner, projected)
        }
    }
    @Synchronized fun replaceProjection(value: NativeProfileGateway.Projection) { projected = value }
    @Synchronized fun requiresRecovery(): Boolean = recovering
    @Synchronized fun accepts(owner: VortxNativeOwner): Boolean = !closed && !requiresRecovery() && isAccountCurrent() && read().owner == owner

    // Exact actual synchronized boundary; read payload and validity flags are synthetic collaborators.
    @Synchronized internal fun <T> withCurrentRead(action: (VortxNativeRead) -> T): T {
        check(!closed && !requiresRecovery()) { "Native owner changed" }
        return action(read()) // Validates account, active profile and current revision while Session is held.
    }

    // Exact actual synchronized owned method; accepts/read payloads remain synthetic collaborators.
    @Synchronized fun <T> owned(owner: VortxNativeOwner, action: () -> T): T {
        check(accepts(owner)) { "Native owner changed" }; return action()
    }
}
