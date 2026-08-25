package com.vortx.android.player

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.WindowManager
import kotlin.math.abs

/**
 * The live source's frame rate (fps) plus its pixel size, read back from whichever [PlayerEngine] is
 * playing. This is the input the AFR ([AfrController]) needs: fps to pick a matching display mode, and
 * width/height so the picked mode keeps the current resolution (only the refresh rate should change).
 * Null until the engine has decoded enough to know its own rate.
 */
data class VideoFrameProfile(
    val fps: Double,
    val width: Int,
    val height: Int,
)

/**
 * "Match Frame Rate" preference. Byte-for-byte the SAME key and default as the Apple app
 * (`HDRDisplayMode.matchFrameRateKey = "vortx.player.matchFrameRate"`, default `false`), so the toggle
 * rides the exact same cross-device settings blob as every other `vortx.*` / `stremiox.*` player key and
 * the account restores ONE key, not one per platform (the settings-parity mandate). Stored in the shared
 * `vortx_settings` file, the same store the sibling player settings use.
 *
 * There is no bespoke Settings UI wired here yet (the key is flippable via the shared settings file and
 * the account restore), exactly like [BadSourceAutoRetrySetting] / [BufferTuningSetting] shipped their
 * kill switches. Read fresh per play so a change applies to the next title without an app restart, which
 * is what Apple gets for free from `@AppStorage`.
 */
object MatchFrameRateSetting {
    const val KEY = "vortx.player.matchFrameRate"

    /** Apple `HDRDisplayMode.defaultMatchFrameRate`. OFF until the viewer opts in. */
    const val DEFAULT = false

    private const val SETTINGS_FILE = "vortx_settings"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

    /** Whether AFR is armed. Read at player start, per play. Defaults to [DEFAULT] (OFF). */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, DEFAULT)

    /** Persist the viewer's choice. The write side of [isEnabled]. */
    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}

/**
 * Android "Match Frame Rate" (AFR): detect the source video's frame rate and switch the Activity's
 * display mode to one that carries that rate, so a 24p film runs at a 24Hz-family mode instead of being
 * pulled to the panel's default 60Hz (the 3:2-pulldown judder in pans). Reverts on player exit. This is
 * the Android mirror of the Apple TV `HDRDisplayMode` Match-Frame-Rate path
 * (`app/Sources/Player/HDRDisplayMode.swift`), which on tvOS assigns an SDR `AVDisplayCriteria` carrying
 * the content rate; the Android analogue is a `Window.preferredDisplayModeId` chosen from
 * `Display.getSupportedModes()`, which renegotiates the HDMI link on an Android TV exactly the same way.
 *
 * WHY preferredDisplayModeId (and not `Surface.setFrameRate`): the render Surface is owned by the
 * engine's `SurfaceView`/`PlayerView` and is not reachable from here, whereas the window-level display
 * mode is a property of the hosting Activity and IS the documented Android-TV AFR lever. Setting a
 * preferred mode whose resolution equals the current mode's and whose refresh rate matches the content
 * makes the platform switch only the refresh rate, so the panel drops its pulldown. `Surface.setFrameRate`
 * (API 30+) is the per-surface hint and would live inside the engine; this window-level switch is the
 * stronger, cross-engine equivalent and needs no engine plumbing.
 *
 * FAIL-SOFT everywhere: a phone (or any panel) that exposes no alternate mode at the content rate simply
 * keeps its current mode, so this is a no-op on hardware that cannot honor it and never blocks playback.
 * All window writes hop to the main thread; frame-rate readback polls the live engine until the rate is
 * known (the demuxer reports it a beat after the first frames), then applies once.
 */
class AfrController(private val activity: Activity) {

    private val handler = Handler(Looper.getMainLooper())

    /** The mode id the window carried before AFR touched it, restored on [stop]. 0 == platform default. */
    private var originalPreferredModeId: Int = 0
    private var captured = false
    private var applied = false
    private var stopped = false
    private var pollAttempts = 0

    /**
     * Begin matching: poll [engine] for its [VideoFrameProfile] and, once the rate is known, switch the
     * window to a matching display mode. Idempotent per instance; call [stop] to revert. Safe to call with
     * an engine that never reports a rate (it just polls out and does nothing).
     */
    // SETTLE GATE (audit 05.6): a display-mode switch is not instant. The panel takes up to a couple of
    // seconds to relock at the new rate, and during that transition the compositor delivers no new frames
    // and the clock can appear frozen. Anything sampling playback health in that window (the stall/start
    // watchdog, trickplay capture) would misread hardware transition as a dead source or bank an
    // unrendered frame. Apple gets this for free: AVDisplayManager coordinates the switch with playback.
    // Android has no such coordination, so the controller publishes a short settling window instead.
    @Volatile
    private var settlingUntilElapsedMs = 0L

    /** True from a mode switch until [SETTLE_WINDOW_MS] elapses; see the settle-gate note above. */
    fun isSettling(): Boolean = SystemClock.elapsedRealtime() < settlingUntilElapsedMs

    fun start(engine: PlayerEngine) {
        if (stopped) return
        pollAttempts = 0
        pollForRate(engine)
    }

    private fun pollForRate(engine: PlayerEngine) {
        if (stopped || applied) return
        val profile = runCatching { engine.videoFrameProfile() }.getOrNull()
        if (profile != null && profile.fps > 0.0) {
            applyMatch(profile)
            return
        }
        pollAttempts += 1
        if (pollAttempts >= MAX_POLL_ATTEMPTS) return
        handler.postDelayed({ pollForRate(engine) }, POLL_INTERVAL_MS)
    }

    private fun applyMatch(profile: VideoFrameProfile) {
        if (stopped || applied) return
        val display = displayOf(activity) ?: return
        val current = display.mode ?: return
        val target = bestModeFor(display.supportedModes.toList(), current, profile.fps) ?: run {
            Log.i(TAG, "AFR: no display mode matches ${"%.3f".format(profile.fps)}fps; leaving panel as-is")
            return
        }
        if (target.modeId == current.modeId) return
        if (!captured) {
            originalPreferredModeId = activity.window.attributes.preferredDisplayModeId
            captured = true
        }
        setPreferredModeId(target.modeId)
        applied = true
        settlingUntilElapsedMs = SystemClock.elapsedRealtime() + SETTLE_WINDOW_MS
        Log.i(
            TAG,
            "AFR: switched to mode ${target.modeId} " +
                "(${target.physicalWidth}x${target.physicalHeight}@${"%.3f".format(target.refreshRate)}) " +
                "for source ${"%.3f".format(profile.fps)}fps",
        )
    }

    /** Revert to the display mode the window had before AFR touched it. Safe to call repeatedly. */
    fun stop() {
        stopped = true
        handler.removeCallbacksAndMessages(null)
        if (captured && applied) {
            setPreferredModeId(originalPreferredModeId)
            Log.i(TAG, "AFR: reverted to mode $originalPreferredModeId")
        }
        applied = false
    }

    private fun setPreferredModeId(modeId: Int) {
        val write = Runnable {
            runCatching {
                val params = activity.window.attributes
                params.preferredDisplayModeId = modeId
                activity.window.attributes = params
            }.onFailure { Log.w(TAG, "AFR: could not set preferredDisplayModeId=$modeId (${it.message})") }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) write.run() else handler.post(write)
    }

    companion object {
        private const val TAG = "VortxAfr"

        /** Poll cadence + ceiling while waiting for the demuxer to report the container rate (~5s total). */
        private const val POLL_INTERVAL_MS = 250L

        /** Generous panel-relock budget; expiring early only re-opens verdicts, it never fakes progress. */
        private const val SETTLE_WINDOW_MS = 2_500L
        private const val MAX_POLL_ATTEMPTS = 20

        /** How close a mode's refresh rate must be to an integer multiple of the content rate to count. */
        private const val RATE_TOLERANCE_HZ = 0.30

        /** The largest multiple of the content rate a panel mode may run at and still be a clean match. */
        private const val MAX_RATE_MULTIPLE = 4

        /**
         * The display that hosts [activity]. `Activity.getDisplay()` is API 30+; below that the window
         * manager's default display is the correct (single) display for the Activity. Never throws.
         */
        private fun displayOf(activity: Activity): Display? = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity.display
            } else {
                @Suppress("DEPRECATION")
                (activity.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)?.defaultDisplay
            }
        }.getOrNull()

        /**
         * Pick the display mode that best matches [fps] while keeping the CURRENT resolution: only a mode
         * whose pixel size equals [current]'s is eligible (AFR changes the refresh rate, never the
         * resolution). A mode qualifies when its refresh rate is within [RATE_TOLERANCE_HZ] of an integer
         * multiple (1..[MAX_RATE_MULTIPLE]) of the content rate, so 23.976p matches a 24/48/72Hz mode,
         * 25p a 50Hz mode, 30p a 60Hz mode. Among qualifiers the closest exact match wins, then the lowest
         * multiple (a native 24Hz beats 48Hz for a 24p film). Returns null when nothing qualifies, which
         * keeps the panel on its current mode. Pure over the mode list, so it is unit-testable.
         */
        internal fun bestModeFor(
            modes: List<Display.Mode>,
            current: Display.Mode,
            fps: Double,
        ): Display.Mode? {
            if (fps <= 0.0) return null
            data class Scored(val mode: Display.Mode, val error: Double, val multiple: Int)
            return modes
                .asSequence()
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .mapNotNull { mode ->
                    var best: Scored? = null
                    for (k in 1..MAX_RATE_MULTIPLE) {
                        val error = abs(mode.refreshRate - fps * k)
                        if (error <= RATE_TOLERANCE_HZ && (best == null || error < best.error)) {
                            best = Scored(mode, error, k)
                        }
                    }
                    best
                }
                .minWithOrNull(compareBy({ it.error }, { it.multiple }))
                ?.mode
        }
    }
}
