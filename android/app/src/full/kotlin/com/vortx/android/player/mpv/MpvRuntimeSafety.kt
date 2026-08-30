package com.vortx.android.player.mpv

internal enum class MpvAudioOutputHealthAction {
    NONE,
    RETRY_DECODED_STEREO,
    FAIL_SOURCE,
}

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
