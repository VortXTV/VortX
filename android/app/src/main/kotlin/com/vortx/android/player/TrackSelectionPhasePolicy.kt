package com.vortx.android.player

/**
 * Per-loaded-engine admission for the initial automatic track choices.
 *
 * Engines are allowed to publish the audio and subtitle inventories at different times.  A single
 * "tracks selected" bit therefore makes the first audio-only snapshot decide that subtitles are Off
 * forever.  Keep the two inventories independent, while making a viewer's explicit choice terminal for
 * that track type until this engine is replaced.
 *
 * This deliberately models *selectable* inventory, rather than a guessed media-ready event.  An empty
 * subtitle list is a valid final result, so add-on fallback is allowed once audio is settled instead of
 * waiting indefinitely for an embedded subtitle that does not exist.
 */
internal data class TrackSelectionPhases(
    val audio: DefaultTrackPhase = DefaultTrackPhase.WAITING_FOR_INVENTORY,
    val subtitle: DefaultTrackPhase = DefaultTrackPhase.WAITING_FOR_INVENTORY,
    val addonAttempted: Boolean = false,
) {
    fun automaticDefaults(
        hasSelectableAudio: Boolean,
        hasSelectableSubtitle: Boolean,
    ): AutomaticTrackDefaults = AutomaticTrackDefaults(
        selectAudio = audio == DefaultTrackPhase.WAITING_FOR_INVENTORY && hasSelectableAudio,
        selectSubtitle = subtitle == DefaultTrackPhase.WAITING_FOR_INVENTORY && hasSelectableSubtitle,
    )

    fun apply(defaults: AutomaticTrackDefaults): TrackSelectionPhases = copy(
        audio = if (defaults.selectAudio) DefaultTrackPhase.DEFAULT_APPLIED else audio,
        subtitle = if (defaults.selectSubtitle) DefaultTrackPhase.DEFAULT_APPLIED else subtitle,
    )

    fun holdAudio(): TrackSelectionPhases = copy(audio = DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION)

    fun holdSubtitle(): TrackSelectionPhases = copy(subtitle = DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION)

    /**
     * The automatic add-on fallback may proceed after audio's default is settled.  It must not replace a
     * manual Off, an embedded manual pick, or a user-selected external track.  If the embedded inventory
     * is already selectable, its default has to run first; if it is empty, there is nothing to wait for.
     */
    fun mayAttemptAddon(hasSelectableSubtitle: Boolean): Boolean =
        !addonAttempted &&
            audio != DefaultTrackPhase.WAITING_FOR_INVENTORY &&
            subtitle != DefaultTrackPhase.HELD_BY_EXPLICIT_SELECTION &&
            (subtitle != DefaultTrackPhase.WAITING_FOR_INVENTORY || !hasSelectableSubtitle)

    fun recordAddonAttempt(): TrackSelectionPhases = copy(addonAttempted = true)

    /** An automatic add-on was selected to fulfil the profile preference, so preserve it like a user pick. */
    fun recordAddonSelection(): TrackSelectionPhases = holdSubtitle().recordAddonAttempt()
}

internal enum class DefaultTrackPhase {
    WAITING_FOR_INVENTORY,
    DEFAULT_APPLIED,
    HELD_BY_EXPLICIT_SELECTION,
}

internal data class AutomaticTrackDefaults(
    val selectAudio: Boolean,
    val selectSubtitle: Boolean,
) {
    val isEmpty: Boolean get() = !selectAudio && !selectSubtitle
}
