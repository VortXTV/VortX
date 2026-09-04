package com.vortx.android.player.mpv

internal enum class MpvAudioOutputHealthAction {
    NONE,
    RETRY_DECODED_STEREO,
    FAIL_SOURCE,
}

/**
 * `FILE_LOADED` is allowed to precede mpv's first usable `track-list` property notification. Until a
 * track list has actually arrived, an empty published track collection means "not known yet", not
 * "this file has no audio". The caller waits for one bounded interval before accepting the latter.
 */
internal enum class MpvAudioTrackListHealthAction {
    PENDING_TRACK_LIST,
    NO_AUDIO_TRACK,
    CHECK_AUDIO_OUTPUT,
}

internal fun mpvAudioTrackListHealthAction(
    trackListObserved: Boolean,
    hasAudioTrack: Boolean,
    timedOut: Boolean,
): MpvAudioTrackListHealthAction = when {
    !trackListObserved && !timedOut -> MpvAudioTrackListHealthAction.PENDING_TRACK_LIST
    !trackListObserved || !hasAudioTrack -> MpvAudioTrackListHealthAction.NO_AUDIO_TRACK
    else -> MpvAudioTrackListHealthAction.CHECK_AUDIO_OUTPUT
}

/** A late property callback may only rearm health work for the active file generation, once per audio arrival. */
internal fun shouldRearmMpvAudioHealthForTrackList(
    loadedGeneration: Long,
    callbackGeneration: Long,
    trackListPreviouslyObserved: Boolean,
    trackListPreviouslyHadAudio: Boolean,
    hasAudioTrack: Boolean,
): Boolean = loadedGeneration == callbackGeneration && hasAudioTrack &&
    (!trackListPreviouslyObserved || !trackListPreviouslyHadAudio)

/** Teardown owns terminal state once release begins; late coroutine cleanup must not publish into the UI. */
internal fun shouldPublishMpvFailureResolution(released: Boolean): Boolean = !released

/**
 * Decide whether an audio-bearing file has a real output, needs one bounded safe retry, or must be
 * handed to the existing source-failure ladder. A named AO or positive output channel count is proof
 * that mpv opened an output. Advancing video is deliberately not proof of working audio.
 */
internal fun mpvAudioOutputHealthAction(
    hasAudioTrack: Boolean,
    currentAo: String?,
    outputChannelCount: Int?,
    recoveryAttempted: Boolean,
): MpvAudioOutputHealthAction {
    if (!hasAudioTrack) return MpvAudioOutputHealthAction.NONE
    val normalizedAo = currentAo?.trim()?.lowercase()
    val outputOpen = (!normalizedAo.isNullOrEmpty() && normalizedAo != "null") ||
        (outputChannelCount ?: 0) > 0
    if (outputOpen) return MpvAudioOutputHealthAction.NONE
    return if (recoveryAttempted) {
        MpvAudioOutputHealthAction.FAIL_SOURCE
    } else {
        MpvAudioOutputHealthAction.RETRY_DECODED_STEREO
    }
}

/** Clear every silence-prone override before reopening Android's conservative AO chain. */
internal fun safeMpvAudioRecoveryProperties(): List<Pair<String, String>> = listOf(
    "audio-spdif" to "",
    "audio-channels" to "stereo",
    "ao" to MpvConfig.SAFE_AUDIO_OUTPUTS,
    "aid" to "auto",
)

/**
 * Surface-direct hardware decode does not expose a CPU-readable frame and must never enter mpv's
 * synchronous screenshot command. Software and explicit copy-back decoders are readable.
 */
internal fun canSafelyCaptureMpvFrame(hwdecCurrent: String?): Boolean {
    val decoder = hwdecCurrent?.trim()?.lowercase() ?: return false
    return decoder == "no" || decoder.endsWith("-copy")
}
