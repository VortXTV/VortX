package com.vortx.android.ui.prefs

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The four hideable phone tabs. Home and Settings intentionally have no key or setter. */
class TabBarPrefs(context: Context) {
    data class State(
        val hideDiscover: Boolean,
        val hideLive: Boolean,
        val hideLibrary: Boolean,
        val hideSearch: Boolean,
    )

    private val prefs =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(readState())
    val state = _state.asStateFlow()

    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key in KEYS) _state.value = readState()
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
    }

    fun setDiscoverVisible(visible: Boolean) = setHidden(HIDE_DISCOVER_KEY, !visible)
    fun setLiveVisible(visible: Boolean) = setHidden(HIDE_LIVE_KEY, !visible)
    fun setLibraryVisible(visible: Boolean) = setHidden(HIDE_LIBRARY_KEY, !visible)
    fun setSearchVisible(visible: Boolean) = setHidden(HIDE_SEARCH_KEY, !visible)

    private fun setHidden(key: String, hidden: Boolean) {
        prefs.edit().putBoolean(key, hidden).apply()
        _state.value = readState()
    }

    private fun readState() = State(
        hideDiscover = prefs.getBoolean(HIDE_DISCOVER_KEY, false),
        hideLive = prefs.getBoolean(HIDE_LIVE_KEY, false),
        hideLibrary = prefs.getBoolean(HIDE_LIBRARY_KEY, false),
        hideSearch = prefs.getBoolean(HIDE_SEARCH_KEY, false),
    )

    companion object {
        const val HIDE_DISCOVER_KEY = "vortx.tabs.hide.discover"
        const val HIDE_LIVE_KEY = "vortx.tabs.hide.live"
        const val HIDE_LIBRARY_KEY = "vortx.tabs.hide.library"
        const val HIDE_SEARCH_KEY = "vortx.tabs.hide.search"

        private val KEYS =
            setOf(HIDE_DISCOVER_KEY, HIDE_LIVE_KEY, HIDE_LIBRARY_KEY, HIDE_SEARCH_KEY)
    }
}

internal enum class TabSlot {
    HOME,
    DISCOVER,
    LIVE,
    LIBRARY,
    SEARCH,
    SETTINGS,
}

internal fun TabBarPrefs.State.isVisible(tab: TabSlot): Boolean = when (tab) {
    TabSlot.HOME, TabSlot.SETTINGS -> true
    TabSlot.DISCOVER -> !hideDiscover
    TabSlot.LIVE -> !hideLive
    TabSlot.LIBRARY -> !hideLibrary
    TabSlot.SEARCH -> !hideSearch
}

internal fun TabBarPrefs.State.resolveSelected(tab: TabSlot): TabSlot =
    if (isVisible(tab)) tab else TabSlot.HOME
