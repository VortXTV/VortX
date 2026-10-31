package com.vortx.android.integrations
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
// Provider payload/secure admission collaborators only; no encrypted persistence is claimed here.
internal object NativeProviderCredentials { val GROUPS=listOf(setOf("trakt")) }
internal object TraktAuth { var currentSessionEpoch:Long?=1 }
internal object ScrobbleService { const val KEY_TRAKT_CONTINUE_WATCHING="legacy.trakt" }
internal object NativeProviderAccess {
    data class Guard(val owner:SessionOwnerSnapshot.Account,val revision:Long)
    val revision=MutableStateFlow(0L)
    var owner=SessionOwnerSnapshot.Account("A",1)
    var available=true
    fun <T> capture(keys:Set<String>,read:()->T):Pair<Guard,T>? =
        if(available) Guard(owner,revision.value) to read() else null
    fun current(guard:Guard)=available && owner==guard.owner && guard.revision==revision.value
    fun <T> guarded(guard:Guard,action:()->T):T? = if(current(guard)) action() else null
}
