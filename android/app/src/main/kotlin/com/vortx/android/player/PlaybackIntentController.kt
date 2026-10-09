package com.vortx.android.player

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Reasons playback must remain paused independently of the viewer's PLAY/PAUSE choice. */
internal enum class PlaybackBlocker {
    BACKGROUND,
    CAST,
    AUDIO_FOCUS,
    STILL_WATCHING,
    SYSTEM,
}

/** Session-owned audio-focus authority. Stale callbacks cannot mutate a successor request. */
internal class AudioFocusIntentAuthority(
    private val playbackIntent: PlaybackIntentController,
) {
    private var generation = 0L

    @Synchronized
    fun beginRequest(): Long {
        generation += 1L
        playbackIntent.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
        return generation
    }

    @Synchronized
    fun onGrantedOrGained(requestGeneration: Long) {
        if (requestGeneration == generation) {
            playbackIntent.setBlocked(PlaybackBlocker.AUDIO_FOCUS, false)
        }
    }

    @Synchronized
    fun onDeniedDelayedOrLost(requestGeneration: Long) {
        if (requestGeneration == generation) {
            playbackIntent.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
        }
    }

    @Synchronized
    fun abandon(requestGeneration: Long) {
        if (requestGeneration == generation) {
            playbackIntent.setBlocked(PlaybackBlocker.AUDIO_FOCUS, true)
            generation += 1L
        }
    }
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

    /** Preparation may configure a private candidate, but only publication may route user commands to it. */
    fun applyTo(candidate: PlayerEngine, blockForBackground: Boolean) {
        val candidateState = synchronized(this) {
            val blockers = if (blockForBackground) state.blockers + PlaybackBlocker.BACKGROUND
                else state.blockers - PlaybackBlocker.BACKGROUND
            state.copy(blockers = blockers)
        }
        // Never mutate the shared blocker or command the bound engine from a background constructor.
        // Native candidate calls also stay outside the intent monitor so they cannot block viewer input.
        if (candidateState.shouldPlay) candidate.play() else candidate.pause()
    }

    @Synchronized
    fun unbindIfCurrent(retired: PlayerEngine) {
        if (engine === retired) engine = null
    }

    @Synchronized
    fun userPlay() = update(state.copy(userWantsPlay = true))

    @Synchronized
    fun userPause() = update(state.copy(userWantsPlay = false))

    @Synchronized
    fun userToggle(currentlyPaused: Boolean) = update(state.copy(userWantsPlay = currentlyPaused))

    @Synchronized
    fun setBlocked(blocker: PlaybackBlocker, blocked: Boolean) {
        val next = if (blocked) state.blockers + blocker else state.blockers - blocker
        update(state.copy(blockers = next))
    }

    @Synchronized
    fun setSourceTerminal(terminal: Boolean) = update(state.copy(sourceTerminal = terminal))

    /**
     * Admit an already-accepted replacement source without changing the viewer's play/pause decision.
     *
     * A source failure makes the outgoing source terminal, but a successful retry or manual source pick
     * is a new transport opportunity. Clearing only that terminal verdict here deliberately preserves a
     * manual pause (and every independent lifecycle/focus blocker), so replacing a paused source cannot
     * unexpectedly start it.
     */
    @Synchronized
    fun beginReplacementSource() = update(state.copy(sourceTerminal = false))

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
    lifecycleStarted: () -> Boolean,
    pausePlaybackInBackground: () -> Boolean,
    playbackIntent: PlaybackIntentController,
    bindForCommands: Boolean = true,
    refreshAudioRoute: () -> Unit = {},
) {
    reconcileEngineLifecycle(
        engine,
        lifecycleStarted(),
        pausePlaybackInBackground(),
        playbackIntent,
        refreshAudioRoute,
        bindForCommands,
    )
    engine.load(playable)
    // Async/non-cancellable construction can cross START/STOP. The post-load sample is authoritative.
    reconcileEngineLifecycle(
        engine,
        lifecycleStarted(),
        pausePlaybackInBackground(),
        playbackIntent,
        refreshAudioRoute,
        bindForCommands,
    )
}

internal fun reconcileEngineLifecycle(
    engine: PlayerEngine,
    lifecycleStarted: Boolean,
    pausePlaybackInBackground: Boolean,
    playbackIntent: PlaybackIntentController,
    refreshAudioRoute: () -> Unit = {},
    bindForCommands: Boolean = true,
) {
    val blockForBackground = !lifecycleStarted && pausePlaybackInBackground
    if (bindForCommands) {
        playbackIntent.setBlocked(PlaybackBlocker.BACKGROUND, blockForBackground)
        playbackIntent.bind(engine)
    } else playbackIntent.applyTo(engine, blockForBackground)
    if (lifecycleStarted) {
        refreshAudioRoute()
        engine.onEnterForeground()
    } else {
        engine.onEnterBackground()
    }
    if (bindForCommands) playbackIntent.bind(engine) else playbackIntent.applyTo(engine, blockForBackground)
}

/**
 * Final publication gate for an asynchronously prepared engine. The caller invokes this on main;
 * lifecycle is sampled only after [beforePublication] returns, so a STOP during construction wins.
 */
internal suspend fun reconcileAndPublishEngine(
    engine: PlayerEngine,
    lifecycleStarted: () -> Boolean,
    pausePlaybackInBackground: () -> Boolean,
    playbackIntent: PlaybackIntentController,
    refreshAudioRoute: () -> Unit = {},
    beforePublication: suspend () -> Unit = {},
    publish: (PlayerEngine) -> Unit,
) {
    beforePublication()
    currentCoroutineContext().ensureActive()
    reconcileEngineLifecycle(
        engine = engine,
        lifecycleStarted = lifecycleStarted(),
        pausePlaybackInBackground = pausePlaybackInBackground(),
        playbackIntent = playbackIntent,
        refreshAudioRoute = refreshAudioRoute,
    )
    publish(engine)
}
