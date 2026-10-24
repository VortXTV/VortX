package com.vortx.android.player

/** Session memory only. These numbers are the narrow :mpv-seam JNI contract, not saved preferences. */
enum class SessionAudioPreset(val nativeValue: Int) {
    NORMAL(0), DIALOGUE(1), NIGHT(2);

    companion object {
        internal fun fromNative(value: Int): SessionAudioPreset? = entries.singleOrNull { it.nativeValue == value }
    }
}

enum class SessionAudioPresetAvailability { UNSUPPORTED, NOT_READY, READY, PASSTHROUGH, SAFETY_UNAVAILABLE, UNKNOWN }
enum class SessionAudioPresetNotice { NONE, REJECTED_RESTORED, UNAVAILABLE, UNKNOWN }

/** One engine-owned automatic route request. The player generation monitor owns every access. */
internal class SessionAudioRouteRequest<Mode : Any> {
    private var pending: Mode? = null

    fun defer(mode: Mode) { pending = mode }

    fun take(): Mode? {
        val mode = pending
        pending = null
        return mode
    }

    fun clear() { pending = null }
}

/** selected is a checked native filter receipt, never an optimistic UI selection or an audible claim. */
data class SessionAudioPresetState(
    val selected: SessionAudioPreset? = null,
    val availability: SessionAudioPresetAvailability = SessionAudioPresetAvailability.UNSUPPORTED,
    val notice: SessionAudioPresetNotice = SessionAudioPresetNotice.NONE,
) {
    fun canSelect(preset: SessionAudioPreset): Boolean = when (availability) {
        SessionAudioPresetAvailability.UNSUPPORTED, SessionAudioPresetAvailability.NOT_READY -> false
        SessionAudioPresetAvailability.READY -> selected != null || preset == SessionAudioPreset.NORMAL
        else -> preset == SessionAudioPreset.NORMAL
    }
}

/** Pure production reducer; the MPV owner serializes every call with its load/teardown generation gate. */
internal class SessionAudioPresetSession {
    var wanted = SessionAudioPreset.NORMAL
        private set
    var state = SessionAudioPresetState(availability = SessionAudioPresetAvailability.NOT_READY)
        private set

    fun loading() {
        state = SessionAudioPresetState(availability = SessionAudioPresetAvailability.NOT_READY)
    }

    fun reset() {
        wanted = SessionAudioPreset.NORMAL
        loading()
    }

    fun refuse(availability: SessionAudioPresetAvailability): Boolean {
        state = state.copy(availability = availability, notice = SessionAudioPresetNotice.UNAVAILABLE)
        return false
    }

    fun receive(requested: SessionAudioPreset, native: IntArray?, passthrough: Boolean): Boolean {
        // A missing/new ABI, invalid payload, or impossible acceptance must never manufacture a checkmark.
        val status = native?.takeIf { it.size == 2 }?.get(0) ?: -1
        val observed = native?.takeIf { it.size == 2 }?.get(1)?.let { SessionAudioPreset.fromNative(it) }
        val valid = status in 0..4 && native != null && native[1] in -1..2 &&
            (status != 2 || observed != null) // A restored receipt requires an observed prior preset.
        val accepted = valid && status in 0..1 && observed == requested
        state = when {
            !valid || status == 3 || (status in 0..1 && !accepted) -> SessionAudioPresetState(
                availability = SessionAudioPresetAvailability.UNKNOWN, notice = SessionAudioPresetNotice.UNKNOWN)
            status == 4 -> SessionAudioPresetState(observed,
                SessionAudioPresetAvailability.SAFETY_UNAVAILABLE, SessionAudioPresetNotice.UNAVAILABLE)
            else -> SessionAudioPresetState(observed,
                if (observed == null) SessionAudioPresetAvailability.UNKNOWN
                else if (passthrough) SessionAudioPresetAvailability.PASSTHROUGH
                else SessionAudioPresetAvailability.READY,
                if (status == 2) SessionAudioPresetNotice.REJECTED_RESTORED else SessionAudioPresetNotice.NONE)
        }
        if (accepted) wanted = requested
        return accepted
    }
}
