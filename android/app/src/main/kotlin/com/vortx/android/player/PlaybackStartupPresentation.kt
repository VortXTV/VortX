package com.vortx.android.player

/** Rendering receipts and weaker MPV evidence are deliberately distinct. None is inferred from READY. */
enum class PlaybackStartupEvidence {
    UNAVAILABLE, AWAITING, MEDIA3_RENDERED_FIRST_FRAME, SAME_MEDIA_REMOUNT,
    MPV_CONFIGURED_SETTLED_CLOCK, AUDIO_ONLY,
}

/** Once dismissed, a healthy rebuffer/seek cannot rearm the same load. Only an explicit load resets it. */
internal fun settledStartupEvidence(
    current: PlaybackStartupEvidence, accepted: PlaybackStartupEvidence,
): PlaybackStartupEvidence = if (current == PlaybackStartupEvidence.AWAITING &&
    accepted != PlaybackStartupEvidence.AWAITING) accepted else current

/** UI deadline/owner dismissal only: never manufactures a renderer or engine receipt. */
internal class StartupCoverWindow(private val startedAtMs: Long) {
    private var retired = false
    fun pending(nowMs: Long, evidence: PlaybackStartupEvidence, ownerCurrent: Boolean,
        allowed: Boolean = true): Boolean {
        if (!allowed || !ownerCurrent || evidence != PlaybackStartupEvidence.AWAITING ||
            nowMs < startedAtMs || nowMs - startedAtMs >= TIMEOUT_MS) retired = true
        return !retired
    }
    companion object { const val TIMEOUT_MS = 12_000L }
}

/** Callback-triggered reads are finite even if the UI has already failed open. No active polling job. */
internal class StartupSampleBudget(private val startedAtMs: Long) {
    private var nextAtMs = startedAtMs
    private var remaining = 64
    fun take(nowMs: Long): Boolean {
        if (nowMs < startedAtMs || nowMs - startedAtMs >= StartupCoverWindow.TIMEOUT_MS) remaining = 0
        if (remaining == 0 || nowMs < nextAtMs) return false
        remaining -= 1
        nextAtMs = nowMs + 200L
        return true
    }
}

/** Fresh native facts only, read under one admitted loaded-entry witness. Not pixel visibility. */
internal data class MpvStartupSample(
    val clockSeconds: Double,
    val audioClockSeconds: Double?,
    val hasVideoTracks: Boolean,
    val selectedVideo: Boolean,
    val selectedAudio: Boolean,
    val videoWidth: Int,
    val videoHeight: Int,
    val seeking: Boolean,
    val cachePaused: Boolean,
)

internal fun mpvStartupEvidence(previous: MpvStartupSample?, current: MpvStartupSample): PlaybackStartupEvidence? {
    if (previous == null || previous.seeking || previous.cachePaused || current.seeking || current.cachePaused ||
        !current.clockSeconds.isFinite() || current.clockSeconds < 0.0 ||
        !previous.clockSeconds.isFinite() || previous.clockSeconds < 0.0 ||
        current.clockSeconds <= previous.clockSeconds) return null
    if (previous.hasVideoTracks && previous.selectedVideo && previous.videoWidth > 0 && previous.videoHeight > 0 &&
        current.hasVideoTracks && current.selectedVideo && current.videoWidth > 0 && current.videoHeight > 0)
        return PlaybackStartupEvidence.MPV_CONFIGURED_SETTLED_CLOCK
    val priorAudio = previous.audioClockSeconds
    val audio = current.audioClockSeconds
    return if (!current.hasVideoTracks && !previous.hasVideoTracks && previous.selectedAudio && current.selectedAudio &&
        priorAudio != null && audio != null && priorAudio.isFinite() && audio.isFinite() &&
        priorAudio >= 0.0 && audio > priorAudio) PlaybackStartupEvidence.AUDIO_ONLY else null
}

/** Production choke point for fresh native reads. The caller supplies its existing identity gate. */
internal fun <R : Any, S : Any> withAdmittedStartupRead(
    read: R?, accepts: (R) -> Boolean, sample: () -> S?,
): S? {
    if (read == null || !accepts(read)) return null
    val fresh = sample() ?: return null
    return fresh.takeIf { accepts(read) }
}
