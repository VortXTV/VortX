package com.vortx.android.usenet

import com.vortx.android.debrid.DebridOwnerToken

/** Pure authorization boundary for the Android-backed credential store. */
internal object UsenetCredentialOwnerPolicy {
    fun storageKey(prefix: String, owner: DebridOwnerToken): String =
        "$prefix${owner.scope.storageSuffix}"

    /** An owner token includes both identity and generation, so A -> B -> A is still rejected. */
    fun permits(captured: DebridOwnerToken?, current: DebridOwnerToken?): Boolean =
        captured != null && captured == current
}
