package com.vortx.android.trailer

import android.content.Context
import android.content.SharedPreferences

/// The kill switch for the client-side trailer resolver, the Android home of the SAME flag key as Apple
/// (`trailerClientResolverV2`). ON (the default) lets [TrailerCoordinator] try the on-device
/// [YouTubeDirectResolver] + [VXTrailerProxy] FIRST, so a trailer plays free 1080p from the user's own IP
/// with no worker round trip; OFF forces the worker-only path (`trailer.vortx.tv/yt/{id}`), the exact
/// behavior a build with the flag disabled has. Either path is net-new on Android (there was no
/// trailer -> player path before), so flipping the flag can never regress an existing feature.
///
/// PERSISTENCE + REMOTE CONFIG: backed by [SharedPreferences] (user-preference storage, the same pattern
/// [com.vortx.android.skip.SkipConfig] uses), so it is togglable locally today and, once the Android
/// remote-config dial lands (Apple reads this from `RemoteConfig`; Android has no dial yet, see
/// [com.vortx.android.trickplay.TmdbImdbResolver]'s note), a fetched value can be written through [setEnabled]
/// to flip every installed build without a store update. Read is cheap + network-free; call it at each
/// resolve. Never throws.
object TrailerFlags {

    /// The persisted key, parallel to the Apple `RemoteConfig`/`UserDefaults` key so a synced value lines up.
    const val CLIENT_RESOLVER_KEY = "stremiox.trailerClientResolverV2"

    private const val PREFS_FILE = "vortx_trailer"

    @Volatile private var prefs: SharedPreferences? = null

    private fun prefs(context: Context): SharedPreferences {
        prefs?.let { return it }
        val store = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        prefs = store
        return store
    }

    /// Whether the on-device client resolver is enabled. Default ON: the client path is the product (free
    /// 1080p from the user's IP); the worker fallback still catches every miss. A stored value (set locally
    /// or pushed by a future remote-config fetch) overrides the default.
    fun clientResolverEnabled(context: Context): Boolean =
        prefs(context).getBoolean(CLIENT_RESOLVER_KEY, true)

    /// Flip the client resolver on/off (a Settings toggle, or a remote-config fetch writing the pushed value).
    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(CLIENT_RESOLVER_KEY, enabled).apply()
    }
}
