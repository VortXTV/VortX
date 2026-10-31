package com.vortx.android.engine

import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.LocalLibraryMutationAuthority
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.foryou.ForYouInterests
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

// Collaborators only: actual production adapter and exact coordinator capture method are compiled.
internal data class VortxNativeOwner(val profileID: String, val revision: Long)
internal data class VortxNativeRead(val owner: VortxNativeOwner, val state: JSONObject)
internal class VortxNativeSession(var owner: VortxNativeOwner = VortxNativeOwner("A", 1)) {
    val updates = MutableStateFlow(0L)
    val fields = JSONObject()
    var commits = 0
    var retired = false
    var beforeDurability: (() -> Unit)? = null
    var rejectCandidate = false
    var genericDispatches = 0
    var lastField: String? = null
    var isTyped = false // Conservation case deliberately uses the ordinary route.
    @Synchronized fun read() = VortxNativeRead(owner,
        JSONObject().put("nativeHostPreferenceState", JSONObject().put("document", JSONObject().put("profiles",
            JSONObject().put(owner.profileID, JSONObject().put("fields", JSONObject(fields.toString())))))))
    @Synchronized fun accepts(expected: VortxNativeOwner) = !retired && owner == expected
    @Synchronized fun <T> owned(expected: VortxNativeOwner, action: () -> T): T {
        check(accepts(expected)) { "Native owner changed" }; return action()
    }
    @Synchronized fun <T> withCurrentRead(action: (VortxNativeRead) -> T): T {
        check(!retired); return action(read())
    }
    @Synchronized fun dispatch(actions: List<JSONObject>, owner: VortxNativeOwner,
        profileFieldChanges: JSONObject?, beforeCommit: () -> Unit): List<String> = owned(owner) {
        check(actions.isEmpty()); val changes = checkNotNull(profileFieldChanges)
        check(changes.length() == 1)
        genericDispatches++
        beforeDurability?.invoke()
        beforeCommit() // The synthetic durability boundary exercises the actual adapter predicate.
        check(!rejectCandidate) { "Candidate checkpoint rejected by collaborator" }
        val field = changes.keys().next(); lastField = field
        fields.put(field, JSONObject().put("clock", 99).put("actor", "fixture").put("value", changes.get(field)))
        commits++; updates.value += 1
        emptyList()
    }
    fun seed(field: String = ForYouInterests.FIELD, value: Any = ForYouInterests().toJson(), clock: Int = 1) {
        fields.put(field, JSONObject().put("clock", clock).put("actor", "fixture").put("value", value))
    }
}

internal class Publication(private val allowed: () -> Boolean) {
    fun publishIfCurrent(action: () -> Unit): Boolean = if (allowed()) { action(); true } else false
}

internal class NativeAccountCoordinator {
    internal data class Mounted(val session: VortxNativeSession, val account: SessionOwnerSnapshot.Account)
    internal val mounted = AtomicReference(Mounted(VortxNativeSession(), SessionOwnerSnapshot.Account("account-A", 1)))
    internal val lifecycleLock = Any()
    internal val authLock = Any()
    internal var authenticated = mounted.get().account
    internal val ownCredentials: Any? = Any()
    val changes = MutableStateFlow(0L)
    fun session() = mounted.get().session
    internal fun accountCurrent(account: SessionOwnerSnapshot.Account) = authenticated == account
    internal val auth = VortXSyncManager().apply {
        sessionState.value=Any(); _sessionUiState.value=VortXSyncManager.SessionUiState.SignedIn
    }
    internal fun captureForYouAccountAuthority(account: SessionOwnerSnapshot.Account): LocalLibraryMutationAuthority? {
        val expected=authenticated
        if(expected!=account) return null
        val authority=auth.captureLocalLibraryMutationAuthority() ?: return null
        return LocalLibraryMutationAuthority(authority.identity) { action -> synchronized(authLock) {
            authenticated==expected && authority.admit(action)
        } }
    }
    fun captureProfilePresentation(session: VortxNativeSession): Publication {
        val installation = mounted.get(); val version = session.updates.value
        return Publication { mounted.get() === installation && authenticated == installation.account && session.updates.value == version }
    }

    internal class ForYouMutationAdmission(val identity: Any, private val admission: (() -> Boolean) -> Boolean) {
        fun admit(action: () -> Boolean): Boolean = admission(action)
    }

    /** Capture under Session. Retain full account generation, exact mount and auth/session/operation scope. */
    internal fun captureForYouMutationAdmission(session: VortxNativeSession): ForYouMutationAdmission {
        check(Thread.holdsLock(session)) { "For You capture must hold Session" }
        val current = checkNotNull(mounted.get()) { "Native account changed" }
        check(current.session === session && accountCurrent(current.account)) { "Native account changed" }
        val account = current.account
        val authenticated = captureForYouAccountAuthority(account)
        check(authenticated != null || ownCredentials == null) { "For You authentication unavailable" }
        val identity = listOf(com.vortx.android.foryou.ForYouIdentityRef(current), account,
            authenticated?.identity ?: com.vortx.android.foryou.ForYouIdentityRef(current))
        return ForYouMutationAdmission(identity) { action ->
            val mountedAction = {
                synchronized(lifecycleLock) { if (mounted.get() === current) action() else false }
            }
            if (authenticated != null) authenticated.admit(mountedAction)
            else accountCurrent(account) && mountedAction() // deterministic fixtures only
        }
    }
}
