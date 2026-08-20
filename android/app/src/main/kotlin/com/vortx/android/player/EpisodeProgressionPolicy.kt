package com.vortx.android.player

/**
 * Pure, host-owned policy for an episode's Up Next transaction.
 *
 * The media resolver remains the authority for source changes. This policy only fences the viewer's
 * intent against the playback generation that produced it, so an old final-credits tick cannot advance
 * a replacement episode after an in-place switch.
 */
internal class EpisodeProgressionPolicy {
    data class Target(val episodeId: String, val generation: Long)

    enum class Trigger { FINAL_STRETCH, EOF }

    enum class Intent { PLAY_NOW, AUTO_ADVANCE, WATCH_CREDITS, CANCEL }

    enum class Decision { ADVANCE, WATCH_CREDITS, CANCEL, STALE }

    private var target: Target? = null
    private var offered = false
    private var cancelled = false
    private var watchingCredits = false
    private var terminalDecision = false

    /** Returns one offer per final stretch, then (only after Watch Credits) one EOF offer. */
    fun offer(requested: Target, positionMs: Long, durationMs: Long, ended: Boolean): Trigger? {
        if (target != requested) reset(requested)
        if (cancelled) return null
        if (ended) {
            if (watchingCredits) {
                watchingCredits = false
                offered = true
                return Trigger.EOF
            }
            return if (offered) null else Trigger.EOF.also { offered = true }
        }
        if (offered || watchingCredits || durationMs <= 0L || positionMs < 0L) return null
        if (durationMs - positionMs > FINAL_STRETCH_MS) return null
        offered = true
        return Trigger.FINAL_STRETCH
    }

    fun decide(requested: Target, intent: Intent): Decision {
        if (target != requested || terminalDecision) return Decision.STALE
        return when (intent) {
            Intent.PLAY_NOW, Intent.AUTO_ADVANCE -> {
                terminalDecision = true
                Decision.ADVANCE
            }
            Intent.WATCH_CREDITS -> {
                watchingCredits = true
                offered = false
                Decision.WATCH_CREDITS
            }
            Intent.CANCEL -> {
                cancelled = true
                Decision.CANCEL
            }
        }
    }

    fun invalidate() {
        target = null
        offered = false
        cancelled = false
        watchingCredits = false
        terminalDecision = false
    }

    private fun reset(requested: Target) {
        target = requested
        offered = false
        cancelled = false
        watchingCredits = false
        terminalDecision = false
    }

    companion object {
        const val FINAL_STRETCH_MS = 20_000L
    }
}
