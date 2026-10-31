package com.vortx.android.engine
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicReference
internal class ExtractedProfileCoordinator(session:VortxNativeSession, val account:SessionOwnerSnapshot.Account) {
    class Mounted(val account:SessionOwnerSnapshot.Account,val session:VortxNativeSession)
    val mounted=AtomicReference<Mounted?>(Mounted(account,session))
    val lifecycleLock=Any()
    val changes=MutableStateFlow(0L)
    var authenticatedEpoch=account.generation
    var available=true
    var managerIdentity:Any=Any()
    private val ownCredentials:Any?=Any()
    private fun accountCurrent(expected:SessionOwnerSnapshot.Account)=available && expected.generation==authenticatedEpoch
    private val captureProfilePresentationAdmission:(SessionOwnerSnapshot.Account)->((()->Boolean)->Boolean)? = { expected ->
        val originalManager=managerIdentity
        val captured=authenticatedEpoch
        if(!accountCurrent(expected)) null else { action ->
            synchronized(auth) { if(!available || managerIdentity!==originalManager || authenticatedEpoch!=captured) false else action() }
        }
    }
    val auth=Any()
    internal fun captureProfilePresentation(session: VortxNativeSession): com.vortx.android.profile.NativeProfileGateway.PreparedProjection =
        synchronized(session) {
            // Read-only failure handoff also retains a qualified migration witness after checkpoint
            // uncertainty. It never grants a command capability or reports recovery as success.
            val read = session.read()
            val current = checkNotNull(mounted.get()) { "Native account changed" }
            check(current.session === session && accountCurrent(current.account)) { "Native account changed" }
            val epoch = changes.value
            val version = session.updates.value
            val recovery = session.requiresRecovery()
            val authenticated = captureProfilePresentationAdmission(current.account)
            check(authenticated != null || ownCredentials == null) { "Native profile authentication unavailable" }
            com.vortx.android.profile.NativeProfileGateway.PreparedProjection(NativeProfileAccess.projection(read), recovery) { action ->
                val publish = {
                    synchronized(lifecycleLock) {
                        if (mounted.get() === current && changes.value == epoch && session.updates.value == version) {
                            action(); true
                        } else false
                    }
                }
                // Production admission is already captured. Neither secure persistence nor Session
                // is consulted in the Main window. The fallback is for deterministic fixtures only.
                if (authenticated != null) authenticated(publish) else accountCurrent(current.account) && publish()
            }
        }
}
