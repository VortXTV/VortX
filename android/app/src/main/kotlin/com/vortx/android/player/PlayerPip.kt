package com.vortx.android.player

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/// Picture-in-Picture for the player (issue #77). The player is a COMPOSABLE inside the shared
/// activity (MainActivity's touch shell / TvActivity's 10-foot shell), not its own activity, so PiP
/// here means "shrink the hosting activity while the player is the visible surface". That shape
/// drives every rule in this file:
///
///   - PiP params (aspect ratio, auto-enter, the play/pause RemoteAction) are set ONLY while the
///     player is composed, and auto-enter is EXPLICITLY revoked when it leaves composition or stops
///     actively playing. A stale auto-enter would PiP the browse grid on a plain Home press, which
///     is the one regression this integration must never ship.
///   - Auto-enter on Home uses the S+ (API 31) [PictureInPictureParams.Builder.setAutoEnterEnabled]
///     when available (a seamless transition, no flicker); on 26-30 the same intent is served by
///     [MainActivity]'s `onUserLeaveHint` override calling [PlayerPipBridge.onUserLeaveHint], the
///     documented pre-S pattern. The bridge is the one seam the Activity needs, so the Activity
///     stays free of player types.
///   - Both engines keep rendering in PiP for free: a PiP'd activity is PAUSED but never STOPPED
///     while visible, and the player's lifecycle observer only drops decode at ON_STOP (see
///     [PlayerScreen]'s observer; mpv `vid=no` / ExoPlayer pause both key off ON_STOP). Closing the
///     PiP window stops the activity, which pauses playback through the same path, exactly the
///     YouTube-style contract a player without background audio wants.
///
/// Fail-soft everywhere: no PiP system feature, an activity that does not declare
/// `supportsPictureInPicture`, or an OEM that throws on params all leave [PlayerPipHandle.supported]
/// false and the player behaves exactly as before this file existed.
internal class PlayerPipHandle(
    /// True when this device + hosting activity can PiP at all; gates the chrome's PiP button.
    val supported: Boolean,
    private val isInPipState: State<Boolean>,
    private val enterAction: () -> Unit,
) {
    /// Live PiP mode. While true the host hides ALL touch chrome (controls, gestures, skip pill):
    /// a PiP window receives no app touch input, so any chrome in it is dead pixels over video.
    val isInPip: Boolean get() = isInPipState.value

    /// Enter PiP now (the chrome's PiP button). No-op when unsupported.
    fun enter() = enterAction()
}

/// The pre-S Home-press seam: [MainActivity.onUserLeaveHint] calls [onUserLeaveHint], and the live
/// player (registered by [rememberPlayerPip] while composed) enters PiP if it is actively playing.
/// Volatile single-slot registry: at most one player is ever composed, and both writes and the
/// Activity's read happen on the main thread (volatile is belt-and-suspenders for lint/tooling).
internal object PlayerPipBridge {
    internal class Entry(
        val isActivelyPlaying: () -> Boolean,
        val enter: () -> Unit,
    )

    @Volatile
    private var active: Entry? = null

    internal fun register(entry: Entry) {
        active = entry
    }

    internal fun unregister(entry: Entry) {
        if (active === entry) active = null
    }

    /// Called from the hosting activity's `onUserLeaveHint`. On S+ this is a no-op: auto-enter
    /// params already cover the Home press (and doing both would double-enter).
    fun onUserLeaveHint() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        val entry = active ?: return
        if (entry.isActivelyPlaying()) entry.enter()
    }
}

/// Pure aspect-ratio math for the PiP window, kept off android.util.Rational so it unit-tests on
/// the JVM. The framework REJECTS ratios outside [0.418410, 2.390000] (throws at
/// setPictureInPictureParams), so out-of-band video clamps to the nearest legal bound and unknown
/// video falls back to 16:9. Returns width to height.
internal fun pipAspect(width: Int, height: Int): Pair<Int, Int> {
    if (width <= 0 || height <= 0) return PIP_DEFAULT_ASPECT
    val ratio = width.toDouble() / height.toDouble()
    return when {
        ratio > PIP_MAX_RATIO -> PIP_WIDEST_ASPECT
        ratio < PIP_MIN_RATIO -> PIP_TALLEST_ASPECT
        else -> width to height
    }
}

/// Wire PiP for the composed player. Returns the handle [PlayerScreen] gates its chrome on.
///
/// [isActivelyPlaying] means "rolling, not paused/ended/errored": it arms auto-enter (S+), gates the
/// pre-S Home-press bridge, and is deliberately NOT gated on the touch-lock (a locked player is
/// still a playing player; Home over it should still PiP).
/// [isPaused] drives the RemoteAction's play/pause icon flip.
@Composable
internal fun rememberPlayerPip(
    engine: PlayerEngine,
    isActivelyPlaying: Boolean,
    isPaused: Boolean,
    durationKnown: Boolean,
): PlayerPipHandle {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }
    val supported = remember(activity) {
        activity != null &&
            runCatching { activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }
                .getOrDefault(false) &&
            activityDeclaresPip(activity)
    }

    // Live PiP mode, from the hosting ComponentActivity's listener (both shells host on
    // ComponentActivity). Seeded from the current mode so a recomposition inside PiP starts true.
    var inPip by remember { mutableStateOf(activity?.isInPictureInPictureMode == true) }
    val inPipState = rememberUpdatedState(inPip)
    val componentActivity = activity as? ComponentActivity
    DisposableEffect(componentActivity) {
        if (componentActivity == null) return@DisposableEffect onDispose {}
        val listener = androidx.core.util.Consumer<androidx.core.app.PictureInPictureModeChangedInfo> { info ->
            inPip = info.isInPictureInPictureMode
        }
        componentActivity.addOnPictureInPictureModeChangedListener(listener)
        onDispose { componentActivity.removeOnPictureInPictureModeChangedListener(listener) }
    }

    // The PiP window's play/pause RemoteAction fires this app-internal broadcast; the receiver
    // drives the LIVE engine. Registered not-exported: only VortX's own PendingIntent may drive
    // playback. Keyed on the engine so a mid-session ExoPlayer fallback rebinds to the new engine.
    DisposableEffect(engine, supported) {
        if (!supported) return@DisposableEffect onDispose {}
        val appContext = context.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (intent?.action == PIP_ACTION_TOGGLE_PLAY) engine.togglePause()
            }
        }
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(PIP_ACTION_TOGGLE_PLAY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        onDispose { runCatching { appContext.unregisterReceiver(receiver) } }
    }

    // Keep the activity's PiP params current: aspect ratio (re-derived when the engine learns its
    // video size, which lands with the duration), auto-enter armed only while actively playing, and
    // the RemoteAction icon tracking the live paused state (it is what the PiP window shows).
    LaunchedEffect(supported, isActivelyPlaying, isPaused, durationKnown, engine) {
        if (!supported || activity == null) return@LaunchedEffect
        runCatching {
            activity.setPictureInPictureParams(
                buildPipParams(context, engine, autoEnter = isActivelyPlaying, paused = isPaused),
            )
        }
    }

    // Registration + teardown. On dispose: revoke auto-enter and drop the actions, so leaving the
    // player NEVER leaves the browse shell one Home press away from a bogus PiP (see file doc).
    //
    // Both explicit entries build their params from the LIVE state (the rememberUpdatedState pair),
    // never a frozen snapshot: setPictureInPictureParams MERGES, so entering with a hardcoded
    // autoEnter=false would silently disarm the standing auto-enter until the next transport flip
    // re-ran the refresh effect above.
    val currentActive = rememberUpdatedState(isActivelyPlaying)
    val currentPaused = rememberUpdatedState(isPaused)
    DisposableEffect(supported, engine) {
        if (!supported || activity == null) return@DisposableEffect onDispose {}
        val entry = PlayerPipBridge.Entry(
            isActivelyPlaying = { currentActive.value },
            enter = {
                runCatching {
                    activity.enterPictureInPictureMode(
                        buildPipParams(context, engine, autoEnter = currentActive.value, paused = currentPaused.value),
                    )
                }
            },
        )
        PlayerPipBridge.register(entry)
        onDispose {
            PlayerPipBridge.unregister(entry)
            runCatching {
                val clear = PictureInPictureParams.Builder().setActions(emptyList())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) clear.setAutoEnterEnabled(false)
                activity.setPictureInPictureParams(clear.build())
            }
        }
    }

    return remember(supported, engine) {
        PlayerPipHandle(
            supported = supported,
            isInPipState = inPipState,
            enterAction = {
                if (supported && activity != null) {
                    runCatching {
                        activity.enterPictureInPictureMode(
                            buildPipParams(context, engine, autoEnter = currentActive.value, paused = currentPaused.value),
                        )
                    }
                }
            },
        )
    }
}

/// Whether the hosting activity declares `android:supportsPictureInPicture` in the manifest.
/// Calling setPictureInPictureParams on one that does not THROWS, so this is checked, not assumed
/// (the check keeps this composable safe even if a future host forgets the manifest attribute).
private fun activityDeclaresPip(activity: Activity): Boolean = runCatching {
    val info = activity.packageManager.getActivityInfo(activity.componentName, 0)
    (info.flags and ActivityInfo.FLAG_SUPPORTS_PICTURE_IN_PICTURE) != 0
}.getOrDefault(false)

/// Build the live PiP params: clamped video aspect, the play/pause RemoteAction, auto-enter on S+.
private fun buildPipParams(
    context: Context,
    engine: PlayerEngine,
    autoEnter: Boolean,
    paused: Boolean,
): PictureInPictureParams {
    val (w, h) = pipAspect(videoWidthOf(engine), videoHeightForPip(engine))
    val builder = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(w, h))
        .setActions(listOf(playPauseRemoteAction(context, paused)))
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        builder.setAutoEnterEnabled(autoEnter)
        // Seamless resize suits video surfaces (the system crossfades otherwise).
        builder.setSeamlessResizeEnabled(true)
    }
    return builder.build()
}

/// The single PiP action: play when paused, pause when playing. Platform media glyphs, immutable
/// broadcast PendingIntent scoped to this package.
private fun playPauseRemoteAction(context: Context, paused: Boolean): RemoteAction {
    val label = if (paused) "Play" else "Pause"
    val iconRes = if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
    val pendingIntent = PendingIntent.getBroadcast(
        context,
        PIP_TOGGLE_REQUEST_CODE,
        Intent(PIP_ACTION_TOGGLE_PLAY).setPackage(context.packageName),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    return RemoteAction(Icon.createWithResource(context, iconRes), label, label, pendingIntent)
}

/// The source video WIDTH from the engine-agnostic playbackStats "Resolution" entry ("1920x1080"),
/// the same seam [PlayerScreen]'s videoHeightOf uses for trickplay. 0 when unknown.
private fun videoWidthOf(engine: PlayerEngine): Int {
    val resolution = runCatching { engine.playbackStats() }.getOrNull()
        ?.firstOrNull { it.first == "Resolution" }?.second ?: return 0
    return resolution.substringBefore('x', "").trim().toIntOrNull() ?: 0
}

/// The source video HEIGHT for the PiP aspect (same parse as trickplay's videoHeightOf, private to
/// PlayerScreen, re-derived here to keep the two files decoupled). 0 when unknown.
private fun videoHeightForPip(engine: PlayerEngine): Int {
    val resolution = runCatching { engine.playbackStats() }.getOrNull()
        ?.firstOrNull { it.first == "Resolution" }?.second ?: return 0
    return resolution.substringAfter('x', "").trim().toIntOrNull() ?: 0
}

/// App-internal broadcast action for the PiP window's play/pause RemoteAction.
private const val PIP_ACTION_TOGGLE_PLAY = "com.vortx.android.player.PIP_TOGGLE_PLAY"

/// Stable request code so FLAG_UPDATE_CURRENT swaps the action's icon in place.
private const val PIP_TOGGLE_REQUEST_CODE = 4801

/// The framework's legal PiP aspect band and the clamps/fallback used by [pipAspect].
private const val PIP_MAX_RATIO = 2.39
private const val PIP_MIN_RATIO = 0.42
private val PIP_DEFAULT_ASPECT = 16 to 9
private val PIP_WIDEST_ASPECT = 239 to 100
private val PIP_TALLEST_ASPECT = 42 to 100
