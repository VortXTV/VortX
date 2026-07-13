package com.stremiox.android.player

import android.content.Context
import androidx.media3.common.util.UnstableApi
import com.stremiox.android.model.Playable

/// Decides which engine plays a given [Playable]: libmpv (`MpvPlayer`, the PRIMARY) for everything, or
/// the Media3/ExoPlayer engine (`ExoPlayerEngine`) for a Dolby Vision or Atmos-passthrough stream that
/// benefits from ExoPlayer's `DefaultRenderersFactory` codec fallback + `DefaultAudioSink` passthrough.
///
/// This mirrors the Apple `PlayerEngineRouter` (`app/Sources/Player/PlayerEngineRouter.swift`), inverted
/// for Android's engine capabilities:
///   - Apple routes DV to AVFoundation (true DV passthrough) because its libmpv/MoltenVK only tone-maps
///     DV. On Android the analogue is ExoPlayer's `MediaCodec` DV path; mpv's gpu-next also only
///     tone-maps DV to SDR here. So DV -> ExoPlayer.
///   - Atmos / bitstream passthrough is ExoPlayer's `DefaultAudioSink` job (it negotiates
///     E-AC3-JOC/TrueHD passthrough against `AudioCapabilities`); mpv's Android AO decodes to PCM. So
///     Atmos -> ExoPlayer.
///   - Everything else, torrents included, stays on libmpv (arbitrary MP4/MKV/HEVC demux + per-stream
///     headers), matching the Apple default.
///
/// Pure decision logic (no Android UI types beyond [Context] for the factory). The [choose] function is
/// unit-testable in isolation; [engine] performs the fail-soft build + fallback.
object PlayerEngineRouter {

    enum class Engine { MPV, EXOPLAYER }

    /// User override, persisted by the settings layer (defaults to [Override.AUTO]). `AUTO` applies the
    /// rules; `MPV` forces libmpv for every stream (an escape hatch for a stream ExoPlayer mishandles);
    /// `EXOPLAYER` forces ExoPlayer (advanced / testing, or a device with no libmpv variant). Mirrors the
    /// Apple `Override` enum.
    enum class Override { AUTO, MPV, EXOPLAYER }

    /// The EXACT DV/Atmos fallback condition, kept as pure logic so it is testable and mirrors the Apple
    /// router's rule ordering.
    ///
    /// Order:
    ///   1. Explicit override wins (`MPV` / `EXOPLAYER`). `AUTO` falls through.
    ///   2. AUTO: a Dolby Vision OR Atmos-passthrough stream routes to [Engine.EXOPLAYER] (ExoPlayer's
    ///      renderer/audio-sink handle the DV codec fallback + Atmos bitstream that mpv on Android does
    ///      not). This is the DV/Atmos fallback condition.
    ///   3. AUTO: everything else (including torrents / loopback streams) stays on [Engine.MPV], the
    ///      primary. Torrents in particular MUST stay on mpv.
    fun choose(playable: Playable, override: Override = Override.AUTO): Engine {
        when (override) {
            Override.MPV -> return Engine.MPV
            Override.EXOPLAYER -> return Engine.EXOPLAYER
            Override.AUTO -> Unit
        }
        // A torrent always plays on libmpv regardless of any DV/Atmos label: the loopback streaming
        // server URL + warm-up is the mpv engine's job, and belt-and-suspenders matches the Apple rule
        // that torrents never leave libmpv.
        if (playable.isTorrent) return Engine.MPV
        // DV or Atmos passthrough -> ExoPlayer (the Android engine that can present them). This is the
        // fallback route; libmpv on Android tone-maps DV to SDR and decodes Atmos to PCM.
        if (playable.isDolbyVision || playable.isAtmos) return Engine.EXOPLAYER
        return Engine.MPV
    }

    /// Build the chosen [PlayerEngine], fail-soft. Resolves the engine via [choose], then:
    ///   - [Engine.MPV]: ask [MpvEngineFactory] to build the libmpv engine. If it returns null (mpv init
    ///     or surface attach failed, or this is the `play` flavor with no libmpv), fall back to the
    ///     ExoPlayer engine so playback never dead-ends in a black crash.
    ///   - [Engine.EXOPLAYER]: build the ExoPlayer engine directly.
    /// The caller (PlayerScreen) treats the result as an opaque [PlayerEngine]; the chrome stays
    /// engine-agnostic.
    // androidx.annotation.OptIn (not just kotlin.OptIn) so Android Lint's UnsafeOptInUsageError accepts
    // this as an opt-in site too -- see the matching note in PlayerScreen.kt (S01 lint-config baseline).
    @androidx.annotation.OptIn(markerClass = [UnstableApi::class])
    fun engine(
        context: Context,
        playable: Playable,
        override: Override = Override.AUTO,
    ): PlayerEngine {
        return when (choose(playable, override)) {
            Engine.MPV -> MpvEngineFactory.create(context) ?: ExoPlayerEngine(context)
            Engine.EXOPLAYER -> ExoPlayerEngine(context)
        }
    }
}
