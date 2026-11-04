package com.vortx.android.sync
internal sealed interface SessionOwnerSnapshot {
    data class Account(val id:String,val generation:Long):SessionOwnerSnapshot
}
// This fixture has no Android preference backing. Only the synchronous capture shape is modeled.
internal object NativeSettingsFence {
    fun <T> capture(read: () -> T): Pair<Unit, T> = Unit to read()
}
