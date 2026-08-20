package com.vortx.android.player.audio

import com.vortx.android.player.AudioOutputMode

/**
 * The route-aware channel-layout + bitstream DECISION CORE for the libmpv lane. Pure and unit-testable
 * (no Android types): it takes the user's [AudioOutputMode] and the classified [AudioRoute] and answers
 * two questions -- what mpv `audio-channels` policy to use, and whether a Dolby/DTS bitstream may be armed
 * -- so a multichannel (5.1 / Atmos) stream is NEVER forced onto a sink that can only render stereo PCM
 * (the silence guard).
 *
 * The Android analogue of Apple `AudioRoutePolicy` (`app/Sources/Player/AudioOutputMode.swift`) as applied
 * route-aware in `MPVMetalViewController.swift` (`channelPolicy`, and the `audio-spdif` gate off
 * stereo-only / AirPods routes). The AVAudioSession channel-COUNT helpers Apple also carries
 * (`preferredOutputChannels` / `resolvedOutputChannels`) have no analogue here: mpv's Android AudioTrack AO
 * negotiates its own output count, so the `audio-channels` string below is the only lever, not a channel
 * number handed to a session.
 *
 * The ExoPlayer lane does NOT use this: its `DefaultAudioSink` self-negotiates channel layout and
 * passthrough against the device's `AudioCapabilities`, which is exactly why the router sends
 * Atmos/passthrough streams there. This policy governs the libmpv AO, where VortX owns the negotiation.
 */
object AudioRoutePolicy {
    /** The Dolby/DTS codecs handed to mpv `audio-spdif` when bitstreaming. Byte-for-byte Apple `spdifCodecs`. */
    const val SPDIF_CODECS = "ac3,dts,eac3,truehd,dts-hd"

    /**
     * Whether multichannel content may keep its native layout on this route + mode. Mirrors Apple
     * `AudioRoutePolicy.supportsMultichannelContent`: not in forced-Stereo mode, not on a stereo-only route,
     * and the route actually advertises more than two channels.
     */
    fun supportsMultichannelContent(mode: AudioOutputMode, route: AudioRoute): Boolean =
        mode != AudioOutputMode.STEREO && !route.isStereoOnly && route.maxChannels > 2

    /**
     * The mpv `audio-channels` value for this mode + route. Mirrors Apple `AudioRoutePolicy.channelPolicy`:
     * a stereo-only route ALWAYS forces a 2.0 downmix (the silence guard, checked before the mode switch);
     * otherwise Stereo forces 2.0, Surround / Passthrough force the full layout, and Auto keeps native
     * multichannel (`auto-safe`) on a capable route but downmixes an incapable one.
     */
    fun channelPolicy(mode: AudioOutputMode, route: AudioRoute): String {
        if (route.isStereoOnly) return "stereo"
        return when (mode) {
            AudioOutputMode.STEREO -> "stereo"
            AudioOutputMode.SURROUND, AudioOutputMode.PASSTHROUGH -> "auto"
            AudioOutputMode.AUTO -> if (route.maxChannels > 2) "auto-safe" else "stereo"
        }
    }

    /**
     * Whether a Dolby/DTS bitstream may be armed: Passthrough mode only, and only on a route that can take a
     * raw bitstream (never a stereo-only sink, never Bluetooth). Mirrors Apple gating `audio-spdif` off
     * `routeIsStereoOnly` / `routeIsAirPods`. When false the codec is decoded to PCM, never handed a sink
     * that would drop it to silence.
     */
    fun bitstreamAllowed(mode: AudioOutputMode, route: AudioRoute): Boolean =
        mode == AudioOutputMode.PASSTHROUGH && route.canBitstream && !route.isStereoOnly && !route.isBluetooth

    /**
     * Pre-init mpv option pairs, applied before mpv initialises (like Apple sets them before
     * `mpv_initialize`). `audio-spdif` is only present when bitstreaming is allowed; omitting it leaves mpv
     * on its default decode-to-PCM, matching the route-blind [AudioOutputMode.mpvOptions] baseline.
     */
    fun mpvOptions(mode: AudioOutputMode, route: AudioRoute): List<Pair<String, String>> {
        val options = mutableListOf("audio-channels" to channelPolicy(mode, route))
        if (bitstreamAllowed(mode, route)) options += "audio-spdif" to SPDIF_CODECS
        return options
    }

    /**
     * Live property pairs for an in-player mode / route change. Unlike the pre-init options, `audio-spdif`
     * is set EXPLICITLY (to "" when not bitstreaming) because mpv retains a property omitted from a later
     * update, so leaving Passthrough must actively clear it. Mirrors the route-blind
     * [AudioOutputMode.mpvLiveProperties], now route-aware.
     */
    fun mpvLiveProperties(mode: AudioOutputMode, route: AudioRoute): List<Pair<String, String>> = listOf(
        "audio-channels" to channelPolicy(mode, route),
        "audio-spdif" to if (bitstreamAllowed(mode, route)) SPDIF_CODECS else "",
    )
}
