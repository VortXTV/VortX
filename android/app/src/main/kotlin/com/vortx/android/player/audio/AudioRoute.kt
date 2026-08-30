package com.vortx.android.player.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * The live audio OUTPUT route, classified into a [kind] plus the two facts the channel-layout policy
 * needs: whether the route can render only plain stereo PCM ([isStereoOnly]) and whether it can take a
 * compressed Dolby/DTS bitstream ([canBitstream]). The Android analogue of what Apple reads off
 * `AVAudioSession.currentRoute` in `app/Sources/Player/MPVMetalViewController.swift` (`outputPortType`
 * driving `routeIsStereoOnly` / `routeIsAirPods`), feeding the same SILENCE GUARD: a multichannel
 * (5.1 / Atmos) stream must never be forced onto a sink that can only play 2.0, or it renders as silence
 * (the "UI sounds play but the movie is silent" report).
 *
 * This is a pure value type; the Android inspection lives in [current] and is fail-soft (any read failure
 * returns [STEREO_DEFAULT], the never-silent choice). [AudioRoutePolicy] consumes it and stays free of
 * Android types so both are unit-testable in isolation, mirroring Apple's split (a pure `AudioRoutePolicy`
 * enum fed by the view controller's live session reads).
 */
enum class AudioRouteKind { SPEAKER, WIRED, BLUETOOTH, HDMI, USB, CAST, UNKNOWN }

data class AudioRoute(
    val kind: AudioRouteKind,
    /** Best channel count the active route advertises, floored at 2 (stereo). */
    val maxChannels: Int,
) {
    /**
     * True when the route can render only plain stereo PCM and must NOT be handed a native multichannel /
     * spdif config. Mirrors Apple `routeIsStereoOnly` (built-in speaker / AirPlay), widened for Android to
     * fold in Bluetooth and cast sinks, which are stereo for mpv's AudioTrack AO (there is no in-AO
     * spatializer on the libmpv Android lane). A wired or USB endpoint is stereo-only unless it actually
     * advertises more than two channels.
     */
    val isStereoOnly: Boolean
        get() = when (kind) {
            AudioRouteKind.SPEAKER, AudioRouteKind.BLUETOOTH, AudioRouteKind.CAST, AudioRouteKind.UNKNOWN -> true
            AudioRouteKind.WIRED, AudioRouteKind.USB -> maxChannels <= 2
            AudioRouteKind.HDMI -> false
        }

    /**
     * True for a Bluetooth (A2DP / LE) sink. It can play a system-spatialized multichannel PCM but can NEVER
     * take a raw Dolby/DTS bitstream, so passthrough is never armed on it. Mirrors Apple `routeIsAirPods`.
     */
    val isBluetooth: Boolean get() = kind == AudioRouteKind.BLUETOOTH

    /**
     * True when the route can take a compressed Dolby/DTS bitstream: HDMI (ARC / eARC) or a multichannel
     * USB DAC / receiver. A speaker, headphone, Bluetooth, or cast sink cannot, so spdif is never armed on
     * one. Mirrors the routes Apple leaves eligible for `audio-spdif`.
     */
    val canBitstream: Boolean
        get() = when (kind) {
            AudioRouteKind.HDMI -> true
            AudioRouteKind.USB -> maxChannels > 2
            else -> false
        }

    companion object {
        /** Fail-soft default: a stereo speaker, the safe never-silent classification. */
        val STEREO_DEFAULT = AudioRoute(AudioRouteKind.SPEAKER, 2)

        /**
         * Inspect the current media route via [AudioManager]. Android 13+ exposes the route anticipated for
         * media [AudioAttributes], which distinguishes the active Shield HDMI sink from merely connected
         * Bluetooth or wired devices. Older Android only exposes the connected-device inventory. That
         * fallback promotes an external route only when its kind is unambiguous; multiple external kinds
         * fail closed to stereo rather than arming multichannel or bitstream against the wrong sink.
         */
        fun current(context: Context): AudioRoute {
            val manager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return STEREO_DEFAULT

            val routed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                runCatching {
                    val mediaAttributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                    manager.getAudioDevicesForAttributes(mediaAttributes)
                }
                    .getOrNull()
                    .orEmpty()
                    .mapNotNull(::classify)
            } else {
                emptyList()
            }
            val connected = if (routed.isEmpty()) {
                runCatching { manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS) }
                    .getOrNull()
                    .orEmpty()
                    .mapNotNull(::classify)
            } else {
                emptyList()
            }
            return selectRoute(routed, connected)
        }

        /** Pure route-selection seam for policy tests. [routed] is already ordered by Android preference. */
        internal fun selectRoute(
            routed: List<AudioRoute>,
            connected: List<AudioRoute>,
        ): AudioRoute {
            routed.firstOrNull()?.let { return it.copy(maxChannels = it.maxChannels.coerceAtLeast(2)) }

            val external = connected.filter { route ->
                route.kind != AudioRouteKind.SPEAKER && route.kind != AudioRouteKind.UNKNOWN
            }
            val externalKinds = external.map(AudioRoute::kind).distinct()
            if (externalKinds.size != 1) return STEREO_DEFAULT

            val selected = external.maxByOrNull(AudioRoute::maxChannels) ?: return STEREO_DEFAULT
            return selected.copy(maxChannels = selected.maxChannels.coerceAtLeast(2))
        }

        private fun classify(device: AudioDeviceInfo): AudioRoute? {
            val kind = kindFor(device.type) ?: return null
            return AudioRoute(kind, maxChannelsOf(device, kind).coerceAtLeast(2))
        }

        /** Map an [AudioDeviceInfo] type to a route kind, or null for a non-media output (telephony, FM, ...). */
        private fun kindFor(type: Int): AudioRouteKind? = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
            -> AudioRouteKind.SPEAKER

            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_AUX_LINE,
            -> AudioRouteKind.WIRED

            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST,
            AudioDeviceInfo.TYPE_HEARING_AID,
            -> AudioRouteKind.BLUETOOTH

            AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_HDMI_ARC,
            AudioDeviceInfo.TYPE_HDMI_EARC,
            AudioDeviceInfo.TYPE_LINE_DIGITAL,
            -> AudioRouteKind.HDMI

            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
            -> AudioRouteKind.USB

            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> AudioRouteKind.CAST

            else -> null
        }

        /**
         * Best advertised channel count for a device. An empty `channelCounts` array means the device
         * accepts arbitrary counts, so infer a capable default for HDMI / USB endpoints and stereo for the
         * rest, matching how the [isStereoOnly] / [canBitstream] classification wants to read an unknown.
         */
        private fun maxChannelsOf(device: AudioDeviceInfo, kind: AudioRouteKind): Int {
            val advertised = runCatching { device.channelCounts }.getOrNull()?.maxOrNull() ?: 0
            if (advertised > 0) return advertised
            return when (kind) {
                AudioRouteKind.HDMI, AudioRouteKind.USB -> 8
                else -> 2
            }
        }
    }
}
