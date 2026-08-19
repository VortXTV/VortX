package com.vortx.android.tv

import android.content.Context
import com.vortx.android.profile.ProfileStore

/**
 * The one preference behind the Android TV "Play Next" Continue Watching row (TV-2). Persisted under Apple's
 * EXACT key in the shared `vortx_settings` file, so it is the SAME key on every platform (the same-key
 * mandate) and rides the settings backup like any other syncable preference.
 *
 * Default ON: with nothing set, the row publishes, matching Apple's `vortx.topShelf.showContinueWatching`
 * default. A Show/Hide toggle on the TV Settings screen flips it; turning it off clears the published rows.
 */
object TopShelfSettings {

    /** Apple's exact key. Read at publish time by [WatchNextPublisher]. */
    const val SHOW_CONTINUE_WATCHING_KEY = "vortx.topShelf.showContinueWatching"

    fun showContinueWatching(context: Context): Boolean =
        prefs(context).getBoolean(SHOW_CONTINUE_WATCHING_KEY, true)

    fun setShowContinueWatching(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(SHOW_CONTINUE_WATCHING_KEY, value).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
}
