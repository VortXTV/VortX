package com.vortx.android.cast

import com.google.android.gms.cast.CastMediaControlIntent

/// Static configuration for the Google Cast lane (Android's AirPlay equivalent). The receiver id is the
/// ONE thing a branded custom receiver would change; every other cast file reads it from here so there is a
/// single source of truth (the options provider that registers the framework, and the route chooser that
/// filters routes to this receiver's control category).
object CastConfig {
    /// Google's Default Media Receiver (app id `CC1AD845`). It plays generic HTTP progressive (MP4/WebM),
    /// HLS, and WebVTT sidecar subtitles with NO Cast developer registration, which is exactly the
    /// direct / debrid / HLS class VortX casts. Torrents never reach a receiver -- they are gated out as
    /// loopback streaming-server URLs by [CastEligibility] before a cast is ever offered, the same way the
    /// Apple `PlayerEngineRouter` keeps loopback torrents off AVPlayer (and therefore off AirPlay). If
    /// VortX ever ships its own styled receiver, only this constant changes.
    val RECEIVER_APP_ID: String = CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID
}
