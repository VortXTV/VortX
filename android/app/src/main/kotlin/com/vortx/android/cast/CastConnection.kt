package com.vortx.android.cast

/// Coarse Cast availability, derived from the framework's `CastState`. Drives whether the chrome shows a
/// Cast button at all (mirrors the Apple AirPlay route-picker button, which only appears when a route
/// exists) and which glyph it shows.
enum class CastAvailability {
    /// Cast is not usable at all: no Google Play services, or the framework failed to initialize. The
    /// button never shows.
    UNAVAILABLE,

    /// The framework is up but no Cast receivers are on the network. The button self-hides, exactly like the
    /// Cast SDK's own `MediaRouteButton` and the AirPlay picker.
    NO_DEVICES,

    /// Receivers are reachable but none is connected: the button shows the idle Cast glyph.
    AVAILABLE,

    /// A session is being established (device picked, handshake in flight).
    CONNECTING,

    /// A receiver is connected and playing our media: the button shows the connected glyph and the casting
    /// overlay takes over the player surface.
    CONNECTED,
}

/// The immutable snapshot the cast UI renders. The [CastManager] copies-on-write and republishes this
/// through its `StateFlow`; the composables never read the manager (or the RemoteMediaClient) directly.
/// This is the cast-side analogue of `PlayerState` -- position / duration / paused for the remote receiver
/// instead of the local engine.
data class CastPlaybackState(
    val availability: CastAvailability = CastAvailability.UNAVAILABLE,
    /// The connected receiver's friendly name (e.g. "Living Room TV"), or null when not connected.
    val deviceName: String? = null,
    val isConnected: Boolean = false,
    val isPlaying: Boolean = false,
    val isPaused: Boolean = false,
    val isBuffering: Boolean = false,
    /// Receiver playhead + media duration in milliseconds (0 until the receiver reports them).
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
)
