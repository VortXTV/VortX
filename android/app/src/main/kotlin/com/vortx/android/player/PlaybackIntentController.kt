package com.vortx.android.player

/** Reasons playback must remain paused independently of the viewer's PLAY/PAUSE choice. */
internal enum class PlaybackBlocker {
    BACKGROUND,
    CAST,
    AUDIO_FOCUS,
    STILL_WATCHING,
    SYSTEM,
}

internal data class PlaybackIntentState(
    val userWantsPlay: Boolean = true,
    val blockers: Set<PlaybackBlocker> = emptySet(),
    val sourceTerminal: Boolean = false,
) {
    val shouldPlay: Boolean get() = userWantsPlay && blockers.isEmpty() && !sourceTerminal
}

/**
 * Single owner of transport intent for one player session. Resource lifecycle remains on
 * [PlayerEngine.onEnterBackground]/[PlayerEngine.onEnterForeground]; this class decides only whether
 * the currently bound engine is allowed to play.
 */
internal class PlaybackIntentController(
    initialState: PlaybackIntentState = PlaybackIntentState(),
) {
    private var state = initialState
    private var engine: PlayerEngine? = null

    @Synchronized
    fun bind(replacement: PlayerEngine) {
        engine = replacement
        apply()
    }

    @Synchronized
    fun userPlay() = update(state.copy(userWantsPlay = true))

    @Synchronized
    fun userPause() = update(state.copy(userWantsPlay = false))

    @Synchronized
    fun userToggle() = update(state.copy(userWantsPlay = !state.userWantsPlay))

    @Synchronized
    fun setBlocked(blocker: PlaybackBlocker, blocked: Boolean) {
        val next = if (blocked) state.blockers + blocker else state.blockers - blocker
        update(state.copy(blockers = next))
    }

    @Synchronized
    fun setSourceTerminal(terminal: Boolean) = update(state.copy(sourceTerminal = terminal))

    @Synchronized
    fun snapshot(): PlaybackIntentState = state

    private fun update(next: PlaybackIntentState) {
        if (next == state) return
        state = next
        apply()
    }

    private fun apply() {
        engine?.let { if (state.shouldPlay) it.play() else it.pause() }
    }
}

/** Orders lifecycle and route reconciliation around a newly constructed async engine. */
internal fun prepareAndLoadEngine(
    engine: PlayerEngine,
    playable: com.vortx.android.model.Playable,
    lifecycleStarted: Boolean,
    playbackIntent: PlaybackIntentController,
    refreshAudioRoute: () -> Unit = {},
) {
    playbackIntent.setBlocked(PlaybackBlocker.BACKGROUND, !lifecycleStarted)
    playbackIntent.bind(engine)
    if (!lifecycleStarted) engine.onEnterBackground()
    refreshAudioRoute()
    engine.load(playable)
    refreshAudioRoute()
    playbackIntent.bind(engine)
}
