package com.vortx.android.player.extras

import kotlin.math.roundToInt

/**
 * Pure decisions for the in-player skip-segment editor (the "contribute a skip time" affordance), the
 * Android port of Apple `app/SourcesShared/SkipEditPolicy.swift`. No player or Android types, so the rules
 * are the real ones a test could call.
 *
 * The editor is offered on EVERY engine (libmpv AND the Dolby Vision / ExoPlayer lane): contribution is
 * never gated to one engine. The single property that decides visibility is CONTENT liveness (a live-TV /
 * IPTV feed has no fixed episode timeline to submit against), NOT the player's reported duration or
 * seekability, and a submittable IMDb id (the skip worker keys off `imdb:S:E`).
 */
object SkipEditPolicy {

    private val TT_ID = Regex("^tt\\d{7,8}$")

    /** IMDb `tt#######` shape: only an IMDb id has something to submit against (add-on / kitsu / tmdb ids
     * have no key). */
    fun isSubmittableContentId(contentId: String): Boolean = TT_ID.matches(contentId)

    /** Whether to OFFER the skip editor for the current title: not live content, and a submittable id. */
    fun canEdit(isLiveContent: Boolean, contentId: String): Boolean =
        !isLiveContent && isSubmittableContentId(contentId)

    /**
     * The `duration_ms` to attach to a submission: the player's duration when finite and positive, else the
     * title's synthesized runtime, else null (the worker bounds the span itself). Mirrors Apple
     * `submissionDurationMs`.
     */
    fun submissionDurationMs(playerDurationSeconds: Double, fallbackRuntimeSeconds: Double?): Int? {
        if (playerDurationSeconds.isFinite() && playerDurationSeconds > 0) {
            return (playerDurationSeconds * 1000).roundToInt()
        }
        val runtime = fallbackRuntimeSeconds
        if (runtime != null && runtime.isFinite() && runtime > 0) {
            return (runtime * 1000).roundToInt()
        }
        return null
    }
}
