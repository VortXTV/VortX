package com.vortx.android.player.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Audit 08.1: observes live output-route changes after the policy was applied at init or an explicit pick.
 * Without this bridge, Bluetooth, WiFi, or headphone changes during playback leave the old mode active, so
 * the bitstream-over-stereo silence guard can miss the newly active sink.
 */
class AudioRouteMonitor(
    context: Context,
    private val onRouteChanged: () -> Unit,
) : DefaultLifecycleObserver {
    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var started = false
    private var callbackRegistered = false
    private var receiverRegistered = false

    private val notifyRouteChanged = Runnable {
        if (started) runCatching(onRouteChanged)
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = debounce()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = debounce()
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) debounce()
        }
    }

    override fun onStart(owner: LifecycleOwner) = start()

    override fun onStop(owner: LifecycleOwner) = stop()

    override fun onDestroy(owner: LifecycleOwner) = stop()

    /** Starts listening. Repeated calls are harmless and registration failures leave playback unchanged. */
    fun start() {
        if (started) return
        started = true
        callbackRegistered = runCatching {
            audioManager?.registerAudioDeviceCallback(deviceCallback, handler)
            audioManager != null
        }.getOrDefault(false)
        receiverRegistered = runCatching {
            ContextCompat.registerReceiver(
                appContext,
                noisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            true
        }.getOrDefault(false)
    }

    /** Stops listening and cancels any pending coalesced transaction. Repeated calls are harmless. */
    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(notifyRouteChanged)
        if (callbackRegistered) runCatching { audioManager?.unregisterAudioDeviceCallback(deviceCallback) }
        if (receiverRegistered) runCatching { appContext.unregisterReceiver(noisyReceiver) }
        callbackRegistered = false
        receiverRegistered = false
    }

    private fun debounce() {
        if (!started) return
        // WHY: one physical route switch emits several device events; apply policy once after they settle.
        handler.removeCallbacks(notifyRouteChanged)
        handler.postDelayed(notifyRouteChanged, ROUTE_DEBOUNCE_MS)
    }

    private companion object {
        const val ROUTE_DEBOUNCE_MS = 500L
    }
}
