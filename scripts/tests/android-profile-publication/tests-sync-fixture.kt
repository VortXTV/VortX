package com.vortx.android.sync
internal sealed interface SessionOwnerSnapshot {
    data class Account(val id:String,val generation:Long):SessionOwnerSnapshot
}
