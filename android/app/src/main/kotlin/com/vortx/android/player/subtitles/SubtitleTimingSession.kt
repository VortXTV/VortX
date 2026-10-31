package com.vortx.android.player.subtitles

/**
 * One source-session's constant subtitle offset, not speech/FPS/drift alignment. The host owns current
 * source/profile/account admission and live engine support. This policy has no Android classes or IO.
 */
internal class SubtitleTimingSession(savedManualSeconds: Double?) {
    private val initial = SubtitleAutoResync.resolve(savedManualSeconds, null, false)
    private var seeded = initial.seeded
    private var offsetSource = initial.source
    private var retired = false
    private var alignment: Any? = null

    /** A pending cue correction fences late community-only writes, including a same-value write. */
    @Synchronized fun beginAlignment(): Any? {
        if (retired) return null
        return Any().also { alignment = it }
    }

    /** Reset ONLY an applied community offset, before capturing the native reference capability. */
    fun prepareAlignment(attempt: Any, admit: ((() -> Boolean) -> Boolean), applyZero: () -> Boolean): Boolean = admit {
        synchronized(this) {
            if (retired || alignment !== attempt) return@synchronized false
            if (offsetSource != SubtitleAutoResync.OffsetSource.COMMUNITY) return@synchronized true
            if (!applyZero()) return@synchronized false
            offsetSource = SubtitleAutoResync.OffsetSource.NONE
            seeded = false
            true
        }
    }

    /** A stale completion cannot release a newer pending choice or seed its timing state. */
    @Synchronized fun finishAlignment(attempt: Any, aligned: Boolean): Boolean {
        if (retired || alignment !== attempt) return false
        alignment = null
        if (aligned) seeded = true
        return true
    }

    @Synchronized fun retire() { retired = true }

    /** At most one community application per source scope; a saved/manual decision always wins. */
    fun applyCommunity(
        poolOffsetMs: Int?,
        delaySupported: Boolean,
        admit: ((() -> Boolean) -> Boolean),
        apply: (Double) -> Unit,
    ): Boolean = applyCommunityAccepted(poolOffsetMs, delaySupported, admit) { seconds ->
        apply(seconds)
        true
    }

    /** Seed only when the actual original-source native operation was admitted. */
    fun applyCommunityAccepted(
        poolOffsetMs: Int?,
        delaySupported: Boolean,
        admit: ((() -> Boolean) -> Boolean),
        apply: (Double) -> Boolean,
    ): Boolean {
        if (!delaySupported) return false // Media3 has no supported live subtitle-delay operation.
        return admit {
            synchronized(this) {
                if (retired || seeded || alignment != null) return@synchronized false
                val resolved = SubtitleAutoResync.resolve(null, poolOffsetMs, alreadySeeded = false)
                if (resolved.source != SubtitleAutoResync.OffsetSource.COMMUNITY) return@synchronized false
                if (!apply(resolved.seconds)) return@synchronized false
                seeded = true
                offsetSource = resolved.source
                true
            }
        }
    }

    /** Zero reset seeds immediately, even though the existing durable memory deliberately forgets zero. */
    fun applyManual(
        seconds: Double,
        delaySupported: Boolean,
        admit: ((() -> Boolean) -> Boolean),
        apply: (Double) -> Unit,
    ): Boolean = applyManualAccepted(seconds, delaySupported, admit) { resolved ->
        apply(resolved)
        true
    }

    /** A rejected final native write must not consume a manual/community seeding opportunity. */
    fun applyManualAccepted(
        seconds: Double,
        delaySupported: Boolean,
        admit: ((() -> Boolean) -> Boolean),
        apply: (Double) -> Boolean,
    ): Boolean {
        if (!delaySupported || !SubtitleAutoResync.captureIsValid(seconds)) return false
        return admit {
            synchronized(this) {
                if (retired) return@synchronized false
                val resolved = SubtitleAutoResync.resolve(seconds, null, alreadySeeded = false)
                if (!apply(resolved.seconds)) return@synchronized false
                alignment = null
                seeded = true
                offsetSource = resolved.source
                true
            }
        }
    }
}

/** Immutable identity used by both the actual pool request and the completion applying its offset. */
internal data class SubtitlePoolPlaybackQuery(val contentKey: String, val fingerprint: String)

internal fun subtitlePoolPlaybackQuery(
    contentKey: String?,
    durationMs: Long,
    releaseName: String?,
): SubtitlePoolPlaybackQuery? {
    if (contentKey.isNullOrBlank() || durationMs <= 0L) return null
    return SubtitlePoolPlaybackQuery(contentKey, SubtitleReleaseFingerprint.releaseFingerprint(
        durationSecs = durationMs / 1000.0, releaseName = releaseName))
}
