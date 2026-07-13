package com.stremiox.android.player.mpv

import android.content.Context
import android.view.Surface
import dev.jdtech.mpv.MPVLib as JdtechMPVLib

/// The VortX libmpv CONTRACT. This is the single surface every Android player phase codes against
/// (Phase 1a defines it, Phase 1b + the player screen implement against it), mirroring the shape of
/// the official mpv-android `MPVLib` JNI class so the seam is familiar and portable.
///
/// It is a THIN wrapper over `dev.jdtech.mpv.MPVLib` (the maintained maven artifact
/// `dev.jdtech.mpv:libmpv:1.0.0`, which ships the libmpv/ffmpeg/player `.so` set built from the
/// mpv-android buildscripts: mpv 0.41.0, ffmpeg 8.1, libplacebo 7.360.1, dav1d 1.5.3, GPLv3). We do
/// NOT re-declare `external fun`s here: the native symbols belong to `dev.jdtech.mpv.MPVLib`
/// (`System.loadLibrary("mpv")` + `System.loadLibrary("player")` happen in that class's initializer),
/// so this wrapper only adapts its instance API to the VortX contract and keeps the option/config
/// surface in ONE place (see [MpvConfig]).
///
/// Why a wrapper instead of using the artifact class directly:
///   1. It pins the VortX contract independent of the upstream artifact's exact method shape, so a
///      future artifact bump (or a swap to vendored `.so` + our own JNI) does not ripple into every
///      caller. Only this file changes.
///   2. The artifact's `MPVLib` is a per-instance class created via `MPVLib.create(context)`; VortX
///      wants the mpv-android-style contract (create / init / destroy / attachSurface / command /
///      setOptionString / get*Property / observeProperty / addObserver(EventObserver)) with the
///      [EventObserver] callback shape both phases build on.
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
///   6. [detachSurface] then [destroy] on teardown.
class MPVLib private constructor(private val delegate: JdtechMPVLib) {

    private val observers = mutableListOf<EventObserver>()

    /// Bridges the artifact's `EventObserver` to the VortX [EventObserver]. Registered once with the
    /// delegate; fans out to every VortX observer added via [addObserver]. The five `eventProperty`
    /// overloads + `event(id)` match the artifact's callback surface one-for-one.
    private val delegateObserver = object : JdtechMPVLib.EventObserver {
        override fun eventProperty(property: String) {
            synchronized(observers) { observers.forEach { it.eventProperty(property) } }
        }
        override fun eventProperty(property: String, value: Long) {
            synchronized(observers) { observers.forEach { it.eventProperty(property, value) } }
        }
        override fun eventProperty(property: String, value: Double) {
            synchronized(observers) { observers.forEach { it.eventProperty(property, value) } }
        }
        override fun eventProperty(property: String, value: Boolean) {
            synchronized(observers) { observers.forEach { it.eventProperty(property, value) } }
        }
        override fun eventProperty(property: String, value: String) {
            synchronized(observers) { observers.forEach { it.eventProperty(property, value) } }
        }
        override fun event(eventId: Int) {
            synchronized(observers) { observers.forEach { it.event(eventId) } }
        }
    }

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
    /// format-less "changed" signal; [event] carries a raw `MPV_EVENT_*` id (see [Event]).
    interface EventObserver {
        fun eventProperty(name: String)
        fun eventProperty(name: String, value: Long)
        fun eventProperty(name: String, value: Double)
        fun eventProperty(name: String, value: Boolean)
        fun eventProperty(name: String, value: String)
        fun event(id: Int)
    }

    /// mpv property formats for [observeProperty] (the `MPV_FORMAT_*` values, re-exported from the
    /// artifact so callers depend only on this contract).
    object Format {
        const val NONE = JdtechMPVLib.MpvFormat.MPV_FORMAT_NONE
        const val STRING = JdtechMPVLib.MpvFormat.MPV_FORMAT_STRING
        const val FLAG = JdtechMPVLib.MpvFormat.MPV_FORMAT_FLAG
        const val INT64 = JdtechMPVLib.MpvFormat.MPV_FORMAT_INT64
        const val DOUBLE = JdtechMPVLib.MpvFormat.MPV_FORMAT_DOUBLE
    }

    /// `MPV_EVENT_*` ids delivered to [EventObserver.event], re-exported from the artifact. The ones
    /// the player actually acts on: file load, end-of-file, and video reconfig (the Android analogue
    /// of the Apple `MPV_EVENT_VIDEO_RECONFIG` that re-drives HDR/DV tagging).
    object Event {
        const val END_FILE = JdtechMPVLib.MpvEvent.MPV_EVENT_END_FILE
        const val FILE_LOADED = JdtechMPVLib.MpvEvent.MPV_EVENT_FILE_LOADED
        const val PLAYBACK_RESTART = JdtechMPVLib.MpvEvent.MPV_EVENT_PLAYBACK_RESTART
        const val VIDEO_RECONFIG = JdtechMPVLib.MpvEvent.MPV_EVENT_VIDEO_RECONFIG
        const val SHUTDOWN = JdtechMPVLib.MpvEvent.MPV_EVENT_SHUTDOWN
    }

    companion object {
        /// Create the mpv handle. Loads the native libmpv/player `.so` (via the artifact's class
        /// initializer) and builds the underlying mpv context. Returns null if native creation fails
        /// (out of memory, missing `.so` for the running ABI), so the caller can fall back to the
        /// Media3/ExoPlayer engine rather than crash (the mandatory mpv <-> Exo runtime fallback in
        /// the Android plan). Pass any [Context]; the application context is used internally.
        fun create(appContext: Context): MPVLib? {
            val delegate = JdtechMPVLib.create(appContext) ?: return null
            return MPVLib(delegate)
        }
    }
}
