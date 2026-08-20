package com.vortx.android.player.subtitles

import android.content.Context
import com.vortx.android.VortXApplication
import com.vortx.android.moat.MoatConsent
import com.vortx.android.sync.SessionOwnerSnapshot

/** Immutable permission to perform one community-subtitle operation. */
data class SubtitlePoolAuthority(
    val accountId: String,
    val accountGeneration: Long,
    val consent: MoatConsent.Snapshot,
) {
    companion object {
        fun capture(context: Context): SubtitlePoolAuthority? {
            val app = context.applicationContext as? VortXApplication ?: return null
            val owner = app.syncManager?.sessionOwnerSnapshot() as? SessionOwnerSnapshot.Account ?: return null
            val consent = MoatConsent.snapshot(context)
            if (!consent.enabled) return null
            return SubtitlePoolAuthority(owner.id, owner.generation, consent)
        }
    }

    fun isCurrent(context: Context): Boolean {
        val app = context.applicationContext as? VortXApplication ?: return false
        val owner = app.syncManager?.sessionOwnerSnapshot() as? SessionOwnerSnapshot.Account ?: return false
        return owner.id == accountId && owner.generation == accountGeneration && MoatConsent.isCurrent(context, consent)
    }

    fun cacheNamespace(): String = "${accountId.hashCode().toUInt().toString(16)}-$accountGeneration-${consent.generation}"
}
