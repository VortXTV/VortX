package com.vortx.android.player

import android.media.AudioManager

/// The audio-focus DECISION CORE, split out of the player's AudioManager wiring so it is pure and
/// unit-testable (no Android objects, only the framework's int constants, which are compile-time
/// inlined). [PlayerScreen] owns the actual AudioFocusRequest and calls [onFocusChange] from the
/// AudioManager listener; this class answers ONE question: what should the engine do now.
///
/// The rule it fixes over the previous inline listener (which paused on every loss and played on
/// every gain): GAIN must only resume playback that THIS policy paused. Without the latch, a
/// transient interruption (a navigation prompt, a call ringing) arriving over a film the viewer had
/// ALREADY paused would auto-un-pause it on GAIN, playing the film at the viewer while their intent
/// was "paused". The latch [pausedByFocusLoss] records "we paused it, we owe the resume", and is the
/// only path to [Action.RESUME].
///
/// Transient-with-duck ([AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK]) deliberately PAUSES
/// rather than ducking: this is long-form dialog content, and film dialog under a navigation prompt
/// at 20% volume is unintelligible, so the viewer loses those seconds either way. Pausing loses
/// nothing (matches the Apple player's interruption behavior, and the pre-policy behavior here).
///
/// A PERMANENT loss ([AudioManager.AUDIOFOCUS_LOSS], another media app started playing) pauses and
/// does NOT arm the resume latch: the viewer switched apps, and VortX barging back in over the new
/// app's audio when the system hands focus back would be a fight, not a resume. They resume by hand.
internal class AudioFocusPolicy {

    /// What the engine should do for a focus transition. [NONE] means leave the transport alone.
    enum class Action { NONE, PAUSE, RESUME }

    /// True while a focus loss (transient class only) is the reason playback is paused, i.e. a
    /// subsequent GAIN owes the viewer a resume.
    private var pausedByFocusLoss = false

    /// Decide the transport action for [focusChange] (an AudioManager.AUDIOFOCUS_* constant), given
    /// whether the engine is currently paused. Call from the focus listener with the LIVE paused
    /// state so a viewer's own pause (before the interruption landed) is never overridden.
    fun onFocusChange(focusChange: Int, isPaused: Boolean): Action = when (focusChange) {
        AudioManager.AUDIOFOCUS_LOSS -> {
            // Permanent handover: never auto-resume from this, even if a GAIN arrives later.
            pausedByFocusLoss = false
            if (isPaused) Action.NONE else Action.PAUSE
        }
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
            if (isPaused) {
                // Already paused by the viewer: nothing to do now, and nothing owed on GAIN.
                Action.NONE
            } else {
                pausedByFocusLoss = true
                Action.PAUSE
            }
        }
        AudioManager.AUDIOFOCUS_GAIN -> {
            if (pausedByFocusLoss) {
                pausedByFocusLoss = false
                Action.RESUME
            } else {
                Action.NONE
            }
        }
        else -> Action.NONE
    }
}
