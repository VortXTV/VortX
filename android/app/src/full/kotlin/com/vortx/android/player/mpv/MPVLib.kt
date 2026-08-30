package com.vortx.android.player.mpv

import android.content.Context
import android.view.Surface
import com.vortx.android.player.mpv.seam.MpvSeam

/// The VortX libmpv CONTRACT. This is the single surface every Android player phase codes against
/// (Phase 1a defines it, Phase 1b + the player screen implement against it), mirroring the shape of
/// the official mpv-android `MPVLib` JNI class so the seam is familiar and portable.
///
/// It is a THIN wrapper over `:mpv-seam`'s `MpvSeam` -- the SOURCE-BUILT fork of the upstream JNI
/// glue (jarnedemeulemeester/libmpv-android v1.0.0, MIT; see android/mpv-seam/README.md) that, unlike
/// the prebuilt artifact glue it replaces since W1-B, delivers MPV_EVENT_END_FILE's real
/// mpv_event_end_file payload (reason + error) instead of a bare event id. The heavy mpv/ffmpeg .so
/// binaries still come exclusively from the `dev.jdtech.mpv:libmpv:1.0.0` AAR; only the thin bridge
/// is compiled from audited in-tree source. We do NOT re-declare `external fun`s here: the native
/// symbols belong to `com.vortx.android.player.mpv.seam.MpvSeam`
/// (`System.loadLibrary("mpv")` + `System.loadLibrary("vortx_mpv_seam")` happen in that class's
/// initializer), so this wrapper only adapts its instance API to the VortX contract and keeps the
/// option/config surface in ONE place (see [MpvConfig]).
///
/// Why a wrapper instead of using the seam class directly:
///   1. It pins the VortX contract independent of the native layer's exact callback shape, so a
///      future seam change does not ripple into every caller. Only this file changes.
///   2. The seam's `MpvSeam` is a per-instance class created via `MpvSeam.create(context)`; VortX
///      wants the mpv-android-style contract (create / init / destroy / attachSurface / command /
///      setOptionString / get*Property / observeProperty / addObserver(EventObserver)) with the
///      [EventObserver] callback shape both phases build on -- including the TYPED
///      [EventObserver.eventTerminal] path translated from the raw `(reason, error)` ints by
///      [MpvSeamBridge].
///
/// Threading: [EventObserver] callbacks are delivered on a native mpv worker thread (the same as the
/// Apple wakeup callback). Implementations must be thread-safe and must not touch the UI directly.
///
/// Lifecycle (mirrors the Apple `MPVMetalViewController` order):
///   1. [create] with the app context (loads native libs, builds the mpv handle).
///   2. apply options via [setOptionString] (feed it [MpvConfig.baseOptions]) BEFORE [init].
///   3. [init] to `mpv_initialize` the handle.
///   4. [attachSurface] once the Android `Surface` is ready (the Android analogue of Apple's `wid`).
///   5. [command] `["loadfile", url, "replace"]` to play; [observeProperty] / [addObserver] for events.
///   6. [destroy] on teardown. It owns final cleanup of any still-attached surface; a later holder
///      detach is an idempotent no-op.
class MPVLib private constructor(private val delegate: MpvSeam) {

    private val observers = mutableListOf<EventObserver>()

    /// Snapshot getter handed to [MpvSeamBridge]: the live observer list under the same lock
    /// add/remove use, materialized as an immutable list so fan-out never iterates a mutating list.
    private val observerSink: () -> List<EventObserver> =
        { synchronized(observers) { observers.toList() } }

    /// Bridges the seam's raw observer surface to the VortX [EventObserver]. Registered ONCE with the
    /// delegate; fans out to every VortX observer added via [addObserver]. END_FILE arrives through
    /// eventEndFile(reason, error) and is translated to [EventObserver.eventTerminal]; every other
    /// lifecycle event keeps its raw id on [EventObserver.event].
    private val delegateObserver = MpvSeamBridge(observerSink)

    init {
        delegate.addObserver(delegateObserver)
    }

    fun init() = delegate.init()

    fun destroy() {
        delegate.removeObserver(delegateObserver)
        synchronized(observers) { observers.clear() }
        delegate.destroy()
    }

    fun attachSurface(surface: Surface) = delegate.attachSurface(surface)

    fun detachSurface() = delegate.detachSurface()

    /// Run an mpv command as an argv array, e.g. `["loadfile", url, "replace"]` or
    /// `["sub-add", subUrl]`. The array form (never a joined string) is required so a URL containing
    /// mpv's list/escape characters is passed as one argument (the same reason the Apple `loadFile`
    /// uses `change-list append`).
    fun command(cmd: Array<String>) = delegate.command(cmd)

    /// Set an mpv OPTION before [init] (the pre-`mpv_initialize` window). Returns mpv's status code
    /// (< 0 on error). This is how [MpvConfig.baseOptions] is applied. After [init], prefer
    /// [setPropertyString] for options that are also runtime-settable properties (matching the Apple
    /// `mpv_set_option_string` vs `mpv_set_property_string` split).
    fun setOptionString(name: String, value: String): Int = delegate.setOptionString(name, value)

    fun setPropertyString(name: String, value: String) = delegate.setPropertyString(name, value)

    fun getPropertyString(name: String): String? = delegate.getPropertyString(name)

    fun getPropertyInt(name: String): Int? = delegate.getPropertyInt(name)

    fun getPropertyDouble(name: String): Double? = delegate.getPropertyDouble(name)

    /// Ask mpv to emit an `eventProperty` callback (in the given [format]) whenever [name] changes.
    /// Use the [Format] constants; e.g. observe `time-pos` as [Format.DOUBLE], `pause` as
    /// [Format.FLAG]. Mirrors the Apple `mpv_observe_property` calls in `setupMpv`.
    fun observeProperty(name: String, format: Int) = delegate.observeProperty(name, format)

    fun addObserver(o: EventObserver) {
        synchronized(observers) { observers.add(o) }
    }

    fun removeObserver(o: EventObserver) {
        synchronized(observers) { observers.remove(o) }
    }

    /// Property + lifecycle-event sink, delivered on a native mpv worker thread. The overloads map to
    /// mpv's observed-property formats (STRING / INT64 -> Long / DOUBLE / FLAG -> Boolean) plus the
    /// format-less "changed" signal. [eventTerminal] is the typed END_FILE path carrying the REAL
    /// mpv_event_end_file reason/error since W1-B; [event] carries every other raw `MPV_EVENT_*` id
    /// (see [Event]).
    interface EventObserver {
        fun eventProperty(name: String)
        fun eventProperty(name: String, value: Long)
        fun eventProperty(name: String, value: Double)
        fun eventProperty(name: String, value: Boolean)
        fun eventProperty(name: String, value: String)
        fun eventTerminal(event: MpvTerminalEvent)
        fun event(id: Int)
    }

    /// mpv property formats for [observeProperty] (the `MPV_FORMAT_*` values, re-exported from the
    /// seam so callers depend only on this contract).
    object Format {
        const val NONE = MpvSeam.MpvFormat.MPV_FORMAT_NONE
        const val STRING = MpvSeam.MpvFormat.MPV_FORMAT_STRING
        const val FLAG = MpvSeam.MpvFormat.MPV_FORMAT_FLAG
        const val INT64 = MpvSeam.MpvFormat.MPV_FORMAT_INT64
        const val DOUBLE = MpvSeam.MpvFormat.MPV_FORMAT_DOUBLE
    }

    /// `MPV_EVENT_*` ids delivered to [EventObserver.event], re-exported from the seam. END_FILE is
    /// NOT delivered through [EventObserver.event]: the seam routes it (with its real payload) to
    /// [EventObserver.eventTerminal]. The player also uses START_FILE to close the narrow replacement
    /// window in which the old source's final terminal callback is expected.
    object Event {
        const val START_FILE = MpvSeam.MpvEvent.MPV_EVENT_START_FILE
        const val END_FILE = MpvSeam.MpvEvent.MPV_EVENT_END_FILE
        const val FILE_LOADED = MpvSeam.MpvEvent.MPV_EVENT_FILE_LOADED
        const val PLAYBACK_RESTART = MpvSeam.MpvEvent.MPV_EVENT_PLAYBACK_RESTART
        const val VIDEO_RECONFIG = MpvSeam.MpvEvent.MPV_EVENT_VIDEO_RECONFIG
        const val AUDIO_RECONFIG = MpvSeam.MpvEvent.MPV_EVENT_AUDIO_RECONFIG
        const val SHUTDOWN = MpvSeam.MpvEvent.MPV_EVENT_SHUTDOWN
    }

    companion object {
        /// Create the mpv handle. Loads the native libmpv `.so` set (from the AAR) + the source-built
        /// seam `.so` (via the seam class initializer) and builds the underlying mpv context. Returns
        /// null if native creation fails (out of memory, missing `.so` for the running ABI), so the
        /// caller can fall back to the Media3/ExoPlayer engine rather than crash (the mandatory
        /// mpv <-> Exo runtime fallback in the Android plan). Pass any [Context]; the application
        /// context is used internally.
        fun create(appContext: Context): MPVLib? {
            val delegate = MpvSeam.create(appContext) ?: return null
            return MPVLib(delegate)
        }
    }
}
