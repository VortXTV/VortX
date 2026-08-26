package com.vortx.android.player.mpv

import com.vortx.android.player.mpv.seam.MpvSeam

/// THE W1-B CALLBACK MAPPING: translates the raw :mpv-seam observer surface to the VortX
/// [MPVLib.EventObserver] contract. This is the object actually registered with the native event
/// loop in production ([MPVLib] hands it a snapshot of its live observers), and it is internal +
/// injectable precisely so JVM tests can drive the real translation -- raw `(reason, error)` ints in,
/// typed terminal events out -- without any native handle.
///
/// Threading: invoked on the mpv event worker thread (the same thread the upstream glue used). The
/// sink is expected to return an immutable snapshot of the currently-registered observers.
internal class MpvSeamBridge(
    private val sink: () -> List<MPVLib.EventObserver>,
) : MpvSeam.EventObserver {

    override fun eventProperty(property: String) {
        sink().forEach { it.eventProperty(property) }
    }

    override fun eventProperty(property: String, value: Long) {
        sink().forEach { it.eventProperty(property, value) }
    }

    override fun eventProperty(property: String, value: Double) {
        sink().forEach { it.eventProperty(property, value) }
    }

    override fun eventProperty(property: String, value: Boolean) {
        sink().forEach { it.eventProperty(property, value) }
    }

    override fun eventProperty(property: String, value: String) {
        sink().forEach { it.eventProperty(property, value) }
    }

    /// MPV_EVENT_END_FILE with the REAL payload from the forked native loop:
    ///   - [reason]: mpv_event_end_file.reason verbatim (EOF=0 / STOP=2 / QUIT=3 / ERROR=4 /
    ///     REDIRECT=5 per the vendored client.h; anything else arrives unchanged),
    ///   - [error]: mpv's error code for ERROR terminations, 0 otherwise.
    /// The typed mapping lives in [MpvTerminalEvent.fromNative]; this bridge only forwards.
    override fun eventEndFile(reason: Int, error: Int) {
        val event = MpvTerminalEvent.fromNative(reason, error)
        sink().forEach { it.eventTerminal(event) }
    }

    /// Every non-END_FILE lifecycle event. END_FILE never reaches [event] anymore: the patched
    /// native loop routes it exclusively through [eventEndFile].
    override fun event(eventId: Int) {
        sink().forEach { it.event(eventId) }
    }
}
