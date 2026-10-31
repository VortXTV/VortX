// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file
// libmpv/src/main/java/dev/jdtech/mpv/MPVLib.kt, then:
//   1. renamed to com.vortx.android.player.mpv.seam.MpvSeam so it can live NEXT TO (not instead of)
//      the upstream AAR artifact, and
//   2. extended with THE W1-B TERMINAL SEAM: `EventObserver.eventEndFile(reason, error)` + the
//      matching dispatcher, fed by this fork's patched native event loop from MPV_EVENT_END_FILE's
//      mpv_event_end_file payload. Upstream 1.0.0 delivers END_FILE only as a bare event id through
//      `event(int)`, which is exactly why VortX audit AND-PLY-01 required this source-built fork.
//
// Valid-call behavior mirrors upstream v1.0.0 (create/init/destroy/attachSurface/detachSurface/command/
// options/properties/observe/log fan-out). VortX additionally gates every native-handle lease against
// destruction and serializes surface ownership, preventing use-after-free during rapid Back/surface churn.
// Provenance + license: see README.md / LICENSE in the module root.
package com.vortx.android.player.mpv.seam

import android.content.Context
import android.view.Surface

@Suppress("unused")
class MpvSeam private constructor() {
    @Volatile
    private var handleGate: MpvNativeHandleGate? = null
    private val destroyDispatcher = MpvNativeDestroyDispatcher()
    private val surfaceLock = Any()
    // Lease outermost, filter monitor innermost; never acquire a player-generation monitor here.
    private val audioFilterLock = Any()
    private val observers = MpvObserverRegistry<EventObserver>()
    private val logObservers = MpvObserverRegistry<LogObserver>()
    private val referenceTransport = MpvReferenceTransport(
        gate = { handleGate },
        native = object : MpvReferenceNative {
            override fun property(handle: Long, property: Int): MpvReferenceNode? = try {
                nativeGetReferenceNode(handle, property)
            } catch (_: UnsatisfiedLinkError) { null }
            override fun begin(handle: Long, identifier: Long, command: MpvReferenceCommand): Int =
                nativeBeginReference(handle, identifier, command.operation, command.integers, command.origin, command.payload)
            override fun abort(handle: Long, identifier: Long) = nativeAbortReference(handle, identifier)
            override fun revoke(handle: Long, grant: Long): Boolean = nativeRevokeReference(handle, grant)
        },
        forceDestroy = ::destroy,
    )

    companion object {
        private const val NATIVE_CALL_UNAVAILABLE = Int.MIN_VALUE
        init {
            // "mpv" first (libmpv.so + its ffmpeg deps come from the dev.jdtech.mpv:libmpv AAR), then
            // THIS module's own source-built glue. The AAR's own "player" glue is intentionally NOT
            // loaded here: this class replaces it, and the app packaging excludes libplayer.so.
            val libs = arrayOf("mpv", "vortx_mpv_seam")
            for (lib in libs) {
                System.loadLibrary(lib)
            }
        }

        @JvmStatic
        fun create(context: Context): MpvSeam? {
            val appCtx = context.applicationContext

            val instance = MpvSeam()

            val ptr = instance.nativeCreate(instance, appCtx)
            if (ptr == 0L) {
                return null
            }

            instance.handleGate = MpvNativeHandleGate(ptr)
            return instance
        }
    }

    private external fun nativeCreate(thiz: MpvSeam, appctx: Context): Long

    fun init() {
        val initialized = handleGate?.withHandle(false) { instance ->
            nativeInit(instance)
            true
        } ?: false
        check(initialized) { "MpvSeam is not initialized" }
    }
    private external fun nativeInit(instance: Long)

    /** No callout: the existing handle gate reads this original one-way cell at each lease admission. */
    fun bindOriginalOwner(liveness: java.util.concurrent.atomic.AtomicBoolean): Boolean =
        handleGate?.bindOriginalOwner(liveness) == true

    fun destroy() {
        val gate = handleGate
        // Close admission synchronously so no observer/thread can race in after destroy. With no active
        // lease, defer the returned action until this callback unwinds. With an active lease, its last
        // releaser owns finalization, so this callback still returns without waiting.
        // Gate admission closes BEFORE any fast cleanup can invoke a whenClosed callback. An async
        // lease may make the immediate action null; its independent registry must still be retired.
        val destroyAction = gate?.requestDestroy(::nativeDestroy)
        referenceTransport.retire()
        if (destroyAction != null) destroyDispatcher.dispatchDestroy(destroyAction)
    }
    private external fun nativeDestroy(instance: Long)

    fun attachSurface(surface: Surface) {
        val result = handleGate?.withSerializedHandle(
            monitor = surfaceLock,
            defaultValue = NATIVE_CALL_UNAVAILABLE,
        ) { instance ->
            nativeAttachSurface(instance, surface)
        } ?: NATIVE_CALL_UNAVAILABLE
        if (result == NATIVE_CALL_UNAVAILABLE) return
        check(result >= 0) { "mpv surface attach failed ($result)" }
    }
    private external fun nativeAttachSurface(instance: Long, surface: Surface): Int

    fun detachSurface() {
        val result = handleGate?.withSerializedHandle(
            monitor = surfaceLock,
            defaultValue = NATIVE_CALL_UNAVAILABLE,
            call = ::nativeDetachSurface,
        ) ?: NATIVE_CALL_UNAVAILABLE
        if (result == NATIVE_CALL_UNAVAILABLE) return
        check(result >= 0) { "mpv surface detach failed ($result)" }
    }
    private external fun nativeDetachSurface(instance: Long): Int

    fun command(cmd: Array<String>) {
        handleGate?.withSerializedHandle(audioFilterLock, Unit) { instance -> nativeCommand(instance, cmd) }
    }
    private external fun nativeCommand(instance: Long, cmd: Array<String>)

    /** Full-only v2 reference effect; an older/mismatched component returns unavailable. */
    fun openSubtitleReference(expectedEntryID: Long): MpvReferenceSession? = referenceTransport.open(expectedEntryID)
    private external fun nativeGetReferenceNode(instance: Long, property: Int): MpvReferenceNode?
    private external fun nativeBeginReference(instance: Long, identifier: Long, operation: Int,
        integers: LongArray, origin: Double, payload: ByteArray?): Int
    private external fun nativeAbortReference(instance: Long, identifier: Long)
    private external fun nativeRevokeReference(instance: Long, grant: Long): Boolean

    /** Actual loadfile result, not a later read of whichever entry is current. No retry on null. */
    fun loadFileWithEntryID(url: String): Long? = handleGate?.withSerializedHandle(audioFilterLock, -1L) { instance ->
        nativeLoadFileWithEntryID(instance, url)
    }?.takeIf { it >= 0L }
    private external fun nativeLoadFileWithEntryID(instance: Long, url: String): Long

    /** No arbitrary filter text: native owns the label, recipes, typed snapshot and exact rollback. */
    fun setSessionAudioPreset(preset: Int, expectedEntryID: Long): IntArray {
        if (preset !in 0..2 || expectedEntryID < 0L) return intArrayOf(4, -1)
        return handleGate?.withSerializedHandle(audioFilterLock, intArrayOf(4, -1)) { instance ->
            try {
                nativeSetSessionAudioPreset(instance, preset, expectedEntryID)
            } catch (_: UnsatisfiedLinkError) {
                // Old packaged glue must be explicitly unavailable, never an optimistic selection.
                intArrayOf(4, -1)
            }
        } ?: intArrayOf(4, -1)
    }
    private external fun nativeSetSessionAudioPreset(instance: Long, preset: Int, expectedEntryID: Long): IntArray

    fun setOptionString(name: String, value: String): Int {
        return handleGate?.withSerializedHandle(audioFilterLock, NATIVE_CALL_UNAVAILABLE) { instance ->
            nativeSetOptionString(instance, name, value)
        } ?: NATIVE_CALL_UNAVAILABLE
    }
    private external fun nativeSetOptionString(instance: Long, name: String, value: String): Int

    fun getPropertyInt(property: String): Int? {
        return handleGate?.withHandle<Int?>(null) { instance -> nativeGetPropertyInt(instance, property) }
    }
    private external fun nativeGetPropertyInt(instance: Long, property: String): Int?

    fun setPropertyInt(property: String, value: Int) {
        handleGate?.withHandle(Unit) { instance -> nativeSetPropertyInt(instance, property, value) }
    }
    private external fun nativeSetPropertyInt(instance: Long, property: String, value: Int)

    fun getPropertyDouble(property: String): Double? {
        return handleGate?.withHandle<Double?>(null) { instance -> nativeGetPropertyDouble(instance, property) }
    }
    private external fun nativeGetPropertyDouble(instance: Long, property: String): Double?

    fun setPropertyDouble(property: String, value: Double) {
        handleGate?.withHandle(Unit) { instance -> nativeSetPropertyDouble(instance, property, value) }
    }
    private external fun nativeSetPropertyDouble(instance: Long, property: String, value: Double)

    fun getPropertyBoolean(property: String): Boolean? {
        return handleGate?.withHandle<Boolean?>(null) { instance -> nativeGetPropertyBoolean(instance, property) }
    }
    private external fun nativeGetPropertyBoolean(instance: Long, property: String): Boolean?

    fun setPropertyBoolean(property: String, value: Boolean) {
        handleGate?.withHandle(Unit) { instance -> nativeSetPropertyBoolean(instance, property, value) }
    }
    private external fun nativeSetPropertyBoolean(instance: Long, property: String, value: Boolean)

    fun getPropertyString(property: String): String? {
        return handleGate?.withHandle<String?>(null) { instance -> nativeGetPropertyString(instance, property) }
    }
    private external fun nativeGetPropertyString(instance: Long, property: String): String?

    fun setPropertyString(property: String, value: String) {
        // Includes options/ and file-local-options/ aliases; one write order, no AF alias bypass.
        handleGate?.withSerializedHandle(audioFilterLock, Unit) { instance ->
            nativeSetPropertyString(instance, property, value)
        }
    }
    private external fun nativeSetPropertyString(instance: Long, property: String, value: String)

    fun observeProperty(property: String, format: Int) {
        handleGate?.withHandle(Unit) { instance -> nativeObserveProperty(instance, property, format) }
    }
    private external fun nativeObserveProperty(instance: Long, property: String, format: Int)

    fun addObserver(o: EventObserver) {
        observers.add(o)
    }

    fun removeObserver(o: EventObserver) {
        observers.remove(o)
    }

    // ---- Native dispatch surface (called by libvortx_mpv_seam.so on the mpv event thread). ----

    private fun dispatchEvent(callback: (EventObserver) -> Unit) {
        destroyDispatcher.withinNativeCallback {
            observers.dispatch(callback)
        }
    }

    private fun dispatchLog(callback: (LogObserver) -> Unit) {
        destroyDispatcher.withinNativeCallback {
            logObservers.dispatch(callback)
        }
    }

    fun eventProperty(property: String, value: Long) {
        dispatchEvent { it.eventProperty(property, value) }
    }

    fun eventProperty(property: String, value: Double) {
        dispatchEvent { it.eventProperty(property, value) }
    }

    fun eventProperty(property: String, value: Boolean) {
        dispatchEvent { it.eventProperty(property, value) }
    }

    fun eventProperty(property: String, value: String) {
        dispatchEvent { it.eventProperty(property, value) }
    }

    fun eventProperty(property: String) {
        dispatchEvent { it.eventProperty(property) }
    }

    /// THE W1-B SEAM DISPATCHER. Called by the patched native event loop with
    /// mpv_event_end_file.reason verbatim (client.h MPV_END_FILE_REASON_* values; unknown future
    /// codes pass through untouched) and .error when reason == MPV_END_FILE_REASON_ERROR else 0.
    fun eventEndFile(reason: Int, error: Int) {
        dispatchEvent { it.eventEndFile(reason, error) }
    }

    fun eventReferenceReply(identifier: Long, error: Int, node: MpvReferenceNode?) {
        destroyDispatcher.withinNativeCallback { referenceTransport.reply(identifier, error, node) }
    }

    // A JNI copy/callback failure still names the original registered request, never a successor.
    fun eventReferenceFailure(identifier: Long) { referenceTransport.failedDelivery(identifier) }

    fun event(eventId: Int) {
        dispatchEvent { it.event(eventId) }
    }

    fun eventStartFile(entryID: Long) {
        dispatchEvent { it.eventStartFile(entryID) }
    }

    fun addLogObserver(o: LogObserver) {
        logObservers.add(o)
    }

    fun removeLogObserver(o: LogObserver) {
        logObservers.remove(o)
    }

    fun logMessage(prefix: String, level: Int, text: String) {
        dispatchLog { it.logMessage(prefix, level, text) }
    }

    interface EventObserver {
        fun eventProperty(property: String)
        fun eventProperty(property: String, value: Long)
        fun eventProperty(property: String, value: Double)
        fun eventProperty(property: String, value: Boolean)
        fun eventProperty(property: String, value: String)

        /// MPV_EVENT_END_FILE with the real payload: [reason] is mpv_event_end_file.reason verbatim
        /// (see [MpvEndFileReason]); [error] is the mpv error code when reason ==
        /// MPV_END_FILE_REASON_ERROR, else 0.
        fun eventEndFile(reason: Int, error: Int)
        fun eventStartFile(entryID: Long) {}
        fun event(eventId: Int)
    }

    interface LogObserver {
        fun logMessage(prefix: String, level: Int, text: String)
    }

    object MpvFormat {
        const val MPV_FORMAT_NONE: Int = 0
        const val MPV_FORMAT_STRING: Int = 1
        const val MPV_FORMAT_OSD_STRING: Int = 2
        const val MPV_FORMAT_FLAG: Int = 3
        const val MPV_FORMAT_INT64: Int = 4
        const val MPV_FORMAT_DOUBLE: Int = 5
        const val MPV_FORMAT_NODE: Int = 6
        const val MPV_FORMAT_NODE_ARRAY: Int = 7
        const val MPV_FORMAT_NODE_MAP: Int = 8
        const val MPV_FORMAT_BYTE_ARRAY: Int = 9
    }

    object MpvEvent {
        const val MPV_EVENT_NONE: Int = 0
        const val MPV_EVENT_SHUTDOWN: Int = 1
        const val MPV_EVENT_LOG_MESSAGE: Int = 2
        const val MPV_EVENT_GET_PROPERTY_REPLY: Int = 3
        const val MPV_EVENT_SET_PROPERTY_REPLY: Int = 4
        const val MPV_EVENT_COMMAND_REPLY: Int = 5
        const val MPV_EVENT_START_FILE: Int = 6
        const val MPV_EVENT_END_FILE: Int = 7
        const val MPV_EVENT_FILE_LOADED: Int = 8
        @Deprecated("")
        const val MPV_EVENT_IDLE: Int = 11
        @Deprecated("")
        const val MPV_EVENT_TICK: Int = 14
        const val MPV_EVENT_CLIENT_MESSAGE: Int = 16
        const val MPV_EVENT_VIDEO_RECONFIG: Int = 17
        const val MPV_EVENT_AUDIO_RECONFIG: Int = 18
        const val MPV_EVENT_SEEK: Int = 20
        const val MPV_EVENT_PLAYBACK_RESTART: Int = 21
        const val MPV_EVENT_PROPERTY_CHANGE: Int = 22
        const val MPV_EVENT_QUEUE_OVERFLOW: Int = 24
        const val MPV_EVENT_HOOK: Int = 25
    }

    /// mpv_end_file_reason values from the vendored client.h (mpv v0.41.0): EOF=0, STOP=2, QUIT=3,
    /// ERROR=4, REDIRECT=5. Value 1 is undefined in this enum version; client.h says unknown values
    /// must be treated as unknown, so consumers MUST handle any other code fail-safe.
    object MpvEndFileReason {
        const val EOF: Int = 0
        const val STOP: Int = 2
        const val QUIT: Int = 3
        const val ERROR: Int = 4
        const val REDIRECT: Int = 5
    }

}
