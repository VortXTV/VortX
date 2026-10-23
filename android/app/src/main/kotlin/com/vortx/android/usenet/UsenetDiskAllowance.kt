package com.vortx.android.usenet

import android.content.Context
import com.vortx.android.player.DiskCacheSetting
import com.vortx.android.profile.ProfileStore

/**
 * How much of a usenet release the engine may download ahead of playback to disk, from the Streaming cache
 * setting (the player's own key, with its never-more-than-half-of-free-space safety). Null when the setting
 * was never touched, so the engine keeps its own 2 GB default; 0 when the viewer chose Off; Unlimited is half
 * of the free space, enough for a whole film on most devices. Mirrors Apple `UsenetDiskAllowance`.
 */
internal object UsenetDiskAllowance {
    private const val UNKNOWN_FREE_SPACE_CEILING = 2L * 1024 * 1024 * 1024

    fun bytes(stored: Long?, freeDisk: Long?): Long? {
        if (stored == null) return null
        if (stored == 0L) return 0L
        val ceiling = freeDisk?.let { maxOf(0L, it / 2) } ?: UNKNOWN_FREE_SPACE_CEILING
        return if (stored == DiskCacheSetting.UNLIMITED_SENTINEL) ceiling else minOf(maxOf(stored, 0L), ceiling)
    }

    fun current(context: Context): Long? {
        val prefs = context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
        val stored = if (prefs.contains(DiskCacheSetting.KEY)) prefs.getLong(DiskCacheSetting.KEY, 0L) else null
        return bytes(stored, DiskCacheSetting.freeDiskBytes(context))
    }
}
