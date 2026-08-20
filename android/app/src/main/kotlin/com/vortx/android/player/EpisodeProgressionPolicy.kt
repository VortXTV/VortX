package com.vortx.android.player

/** Pure, generation-fenced state for a single episode's Up Next interaction. */
internal class EpisodeProgressionPolicy {
    data class Target(val episodeId: String, val generation: Long)

    enum class Phase { FINAL_STRETCH, EOF }
    enum class Intent { PLAY_NOW, AUTO_ADVANCE, WATCH_CREDITS, CANCEL }
    enum class Decision { ADVANCE, SUPPRESS, STALE }
    data class Offer(val target: Target, val phase: Phase, val remainingMs: Long)

    private var activeTarget: Target? = null
    private var offer: Offer? = null
    private var terminal = false

    /** Updates the live offer; seeking out retracts it and only natural EOF admits unattended advance. */
    fun observe(target: Target, positionMs: Long, durationMs: Long, ended: Boolean): Offer? {
        if (activeTarget != target) {
            activeTarget = target
            offer = null
            terminal = false
        }
        if (terminal) return null
        if (ended) return Offer(target, Phase.EOF, 0L).also { offer = it }
        val remaining = durationMs - positionMs
        if (durationMs <= 0L || positionMs < 0L || remaining > FINAL_STRETCH_MS) {
            offer = null
            return null
        }
        return Offer(target, Phase.FINAL_STRETCH, remaining.coerceAtLeast(0L)).also { offer = it }
    }

    /** First valid action wins. Play Now is pre-EOF only; automatic advance is EOF only. */
    fun decide(target: Target, intent: Intent): Decision {
        val active = offer
        if (terminal || active == null || active.target != target) return Decision.STALE
        return when (intent) {
            Intent.PLAY_NOW -> if (active.phase == Phase.FINAL_STRETCH) advance() else Decision.STALE
            Intent.AUTO_ADVANCE -> if (active.phase == Phase.EOF) advance() else Decision.STALE
            Intent.WATCH_CREDITS, Intent.CANCEL -> {
                terminal = true
                offer = null
                Decision.SUPPRESS
            }
        }
    }

    fun invalidate() {
        activeTarget = null
        offer = null
        terminal = false
    }

    private fun advance(): Decision {
        terminal = true
        offer = null
        return Decision.ADVANCE
    }

    companion object {
        const val FINAL_STRETCH_MS = 20_000L
    }
}
