package com.vortx.android.ui

import com.vortx.android.ui.prefs.TabSlot

internal const val CINEMA_TOP_NAVIGATION_MIN_WIDTH_DP = 760f

/** Existing installs save names rather than ordinals; adding a destination cannot renumber them. */
internal fun cinemaStoredTabSlot(savedName: String?): TabSlot =
    TabSlot.entries.firstOrNull { it.name == savedName } ?: TabSlot.HOME

internal data class CinemaWindowNavigation(
    val topNavigation: Boolean,
    val primary: List<TabSlot>,
    val overflow: List<TabSlot>,
) {
    fun selectsOverflow(destination: TabSlot): Boolean = destination in overflow

    /** Add-ons already owns a local toolbar for Back/Reorder; compact chrome must not duplicate it. */
    fun usesCompactTitleBar(destination: TabSlot): Boolean = !topNavigation && destination != TabSlot.ADDONS
}

/** Width is the shell's measured available space, including tablet split windows and phone rotation. */
internal fun cinemaWindowNavigation(
    availableWidthDp: Float,
    visible: List<TabSlot>,
): CinemaWindowNavigation {
    if (availableWidthDp.isFinite() && availableWidthDp >= CINEMA_TOP_NAVIGATION_MIN_WIDTH_DP) {
        return CinemaWindowNavigation(topNavigation = true, primary = visible, overflow = emptyList())
    }
    if (visible.size <= 5) {
        return CinemaWindowNavigation(topNavigation = false, primary = visible, overflow = emptyList())
    }
    val preferred = setOf(TabSlot.HOME, TabSlot.DISCOVER, TabSlot.LIBRARY, TabSlot.SEARCH)
    val primary = visible.filter { it in preferred }.take(4)
    return CinemaWindowNavigation(
        topNavigation = false,
        primary = primary,
        overflow = visible.filter { it !in primary },
    )
}

internal data class CinemaNavigationSelection(val destination: TabSlot, val popToRoot: Boolean)

/** More is presentation only: its items select real destinations and use the same reselect behavior. */
internal fun cinemaNavigationSelection(current: TabSlot, requested: TabSlot): CinemaNavigationSelection =
    CinemaNavigationSelection(destination = requested, popToRoot = current == requested)
