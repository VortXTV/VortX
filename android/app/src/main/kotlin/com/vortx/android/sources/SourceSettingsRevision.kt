package com.vortx.android.sources

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.player.PlaybackBehaviorSettings
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-wide, monotonic observation of settings that change source filtering or ranking. The listener sees
 * direct writes from Settings, profile application, and settings restore, including writes that bypass a
 * [SourcePreferencesStore] instance.
 */
object SourceSettingsRevision {
    private val lock = Any()
    private val _revision = MutableStateFlow(0L)
    private var installedPrefs: SharedPreferences? = null
    private var listener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    val revision: StateFlow<Long> = _revision.asStateFlow()

    fun observe(context: Context): StateFlow<Long> {
        synchronized(lock) {
            if (installedPrefs == null) {
                val prefs = context.applicationContext.getSharedPreferences(
                    SourcePreferencesStore.PREFS_FILE,
                    Context.MODE_PRIVATE,
                )
                val installed = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                    if (affectsSourceResults(key)) synchronized(lock) {
                        _revision.value = _revision.value + 1L
                    }
                }
                prefs.registerOnSharedPreferenceChangeListener(installed)
                installedPrefs = prefs
                listener = installed
            }
            return revision
        }
    }

    /**
     * Complete source-result mutation surface in this preferences file: flat ranking/filter/playback keys,
     * active-profile identity and safety mirrors, plus every per-profile source-pin blob. Kept pure so a
     * missing channel can be caught without an Android SharedPreferences runtime.
     */
    internal fun affectsSourceResults(key: String?): Boolean =
        key == null || key in RESULT_KEYS || key.startsWith(SourcePinStore.PREFS_KEY_PREFIX)

    private val RESULT_KEYS = setOf(
        SourcePreferencesStore.ORDER_KEY,
        SourcePreferencesStore.ADDON_ORDER_KEY,
        SourcePreferencesStore.EXCLUDE_KEY,
        SourcePreferencesStore.INCLUDE_KEY,
        SourcePreferencesStore.SAFETY_KEY,
        SourcePreferencesStore.HIDE_DEAD_KEY,
        SourcePreferencesStore.INSTANT_ONLY_KEY,
        SourcePreferencesStore.MAX_RESOLUTION_KEY,
        SourcePreferencesStore.MIN_RESOLUTION_KEY,
        SourcePreferencesStore.HIDE_UNKNOWN_RES_KEY,
        SourcePreferencesStore.PREFERRED_AUDIO_KEY,
        SourcePreferencesStore.MAX_FILE_SIZE_KEY,
        SourcePreferencesStore.HDR_ONLY_KEY,
        SourcePreferencesStore.EXCLUDE_AV1_KEY,
        SourcePreferencesStore.REGEX_KEY,
        SourcePreferencesStore.PREFER_KEY,
        SourcePreferencesStore.AVOID_BEHAVIOR_KEY,
        SourcePreferencesStore.AUTO_PICK_BEST_KEY,
        SourcePreferencesStore.DEFAULT_SORT_KEY,
        PlaybackBehaviorSettings.DIRECT_LINKS_ONLY_KEY,
        TrackPreferencesStore.KEY_AUDIO,
        ProfileStore.ACTIVE_PROFILE_KEY,
        ProfileStore.ACTIVE_DISABLED_ADDONS_KEY,
        ProfileStore.ACTIVE_KIDS_KEY,
    )
}
