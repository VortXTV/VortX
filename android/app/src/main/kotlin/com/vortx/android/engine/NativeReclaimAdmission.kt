package com.vortx.android.engine

import com.vortx.android.sync.SessionOwnerSnapshot

/** Capture account/epoch authority without reversing the established native Session -> auth lock
 * order. The returned gate is usable only while the caller already owns the native session monitor. */
internal fun captureNativeReclaimAdmission(
    coordinator: NativeAccountCoordinator,
    session: VortxNativeSession,
    owner: VortxNativeOwner,
    currentAccount: () -> SessionOwnerSnapshot,
    captureAccountAdmission: () -> ((() -> Boolean) -> Boolean)?,
): ((() -> Boolean) -> Boolean)? {
    check(Thread.holdsLock(session)) { "Native reclaim must capture under the session fence" }
    val account = coordinator.accountFor(session) ?: return null
    val accountAdmission = captureAccountAdmission() ?: return null
    val gate: (() -> Boolean) -> Boolean = { action ->
        check(Thread.holdsLock(session)) { "Native reclaim requires the session fence" }
        accountAdmission {
            currentAccount() == account && coordinator.withMountedSession(session, account, action)
        }
    }
    return if (gate { session.accepts(owner) }) gate else null
}
