package com.vortx.android.catalog

import android.content.Context
import com.vortx.android.ui.prefs.HomeDiscoverPreferences
import java.util.Locale

/// The region used for TMDB region-scoped detail calls (watch providers, release dates). Honours the user's
/// Discover region OVERRIDE first (Settings, the same `vortx.discover.regionPreference` key Apple's
/// `CatalogPreferences.regionKey` reads and that syncs cross-device), else the device region, else "US".
/// The Android analogue of Apple `TMDBClient.deviceRegion`, kept in one place so every region-scoped detail
/// client picks up the same preference.
object DiscoverRegion {

    /// Apple's EXACT override key so a region set on any platform rides the same cross-device carriage. Lives
    /// in the shared `vortx_settings` file, alongside the rest of the Home/Discover preferences.
    const val KEY = "vortx.discover.regionPreference"

    fun effective(context: Context): String {
        val override = context.applicationContext
            .getSharedPreferences(HomeDiscoverPreferences.PREFS_FILE, Context.MODE_PRIVATE)
            .getString(KEY, null)
            ?.trim()
        if (!override.isNullOrEmpty()) return override
        return Locale.getDefault().country.ifBlank { "US" }
    }
}
