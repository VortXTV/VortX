package com.vortx.android.player.audio

import com.vortx.android.player.PlayerTrack
import com.vortx.android.player.TrackSelector

/**
 * Refines an already language-chosen audio pick toward the channel LAYOUT the active output route can
 * actually render, the fidelity dimension Apple's picker deliberately skips: `TrackSelector.swift` notes
 * `MPVTrack` "carries no channel counts to break ties on", so when a title ships several audio tracks in
 * the SAME preferred language -- e.g. a 5.1 and a 2.0 English track -- Apple takes whichever the container
 * lists first. This picks the best one for where you are listening:
 *   - a multichannel-capable route (HDMI receiver, USB DAC, Bluetooth / spatial sink) keeps the HIGHEST
 *     channel layout, so a 5.1 / 7.1 mix plays bit-perfect / passthrough instead of a stereo dub;
 *   - a stereo-only route takes the LOWEST layout at or above stereo, so a native 2.0 track plays directly
 *     instead of a lossy 5.1 -> 2.0 downmix (and never risks the multichannel-into-stereo silence).
 *
 * Pure and fail-soft: it only ever swaps the pick for ANOTHER track in the same language whose channel
 * count is known and better for the route, and it keeps the original pick on a tie so an automatic pass
 * never turns a no-op into a needless re-select. If channel counts are unknown (all 0) or nothing beats
 * the original, it returns [pickedId] unchanged, so a container with no channel metadata behaves exactly
 * as before (parity with Apple's first-match). Runs AFTER [TrackSelector.select], on both engines.
 */
object AudioTrackFidelity {
    /**
     * The audio track id to actually select, given the full [audio] list, the language-chosen [pickedId]
     * (from [TrackSelector.select], may be null when the engine default is kept), the [reject] terms, and
     * the live [route]. Never selects a rejected or lower-fidelity-for-the-route track; returns [pickedId]
     * unchanged when no better same-language candidate exists.
     */
    fun refine(
        audio: List<PlayerTrack>,
        pickedId: Int?,
        reject: List<String>,
        route: AudioRoute,
    ): Int? {
        val picked = audio.firstOrNull { it.id == pickedId } ?: return pickedId
        // Same-language candidates whose channel count is known and whose title is not rejected. The picked
        // track itself qualifies (it matched the language chain), so the result is never worse than it.
        val candidates = audio.filter { track ->
            track.channels > 0 &&
                TrackSelector.matches(track.lang, picked.lang) &&
                !isRejected(track, reject)
        }
        if (candidates.isEmpty()) return pickedId
        val targetChannels = if (route.isStereoOnly) {
            candidates.map { it.channels }.filter { it >= STEREO_CHANNELS }.minOrNull()
                ?: candidates.minOf { it.channels }
        } else {
            candidates.maxOf { it.channels }
        }
        // Keep the language pick when it already has the target layout (no needless re-select); otherwise
        // take the first same-language track at the target layout.
        if (picked.channels == targetChannels) return pickedId
        return candidates.firstOrNull { it.channels == targetChannels }?.id ?: pickedId
    }

    private const val STEREO_CHANNELS = 2

    private fun isRejected(track: PlayerTrack, reject: List<String>): Boolean {
        val title = track.title.lowercase()
        return reject.any { it.isNotEmpty() && title.contains(it.lowercase()) }
    }
}
