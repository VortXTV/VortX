package com.stremiox.android.player.mpv

/// The SINGLE source of the libmpv option set for VortX Android, ported line-for-line from the Apple
/// reference `app/Sources/Player/MPVMetalViewController.swift` (`setupMpv`). This is the Android mirror
/// of that 60-line `mpv_set_option` block: a change to the shared player behavior should land here AND
/// in the Swift file so the two engines stay in lockstep (the whole point of "ONE mpv player layer
/// everywhere", per the Android plan §1.3).
///
/// HOW IT IS APPLIED: [baseOptions] is a list of (name, value) pairs applied via
/// `MPVLib.setOptionString(name, value)` BEFORE `MPVLib.init()` (mpv options are set pre-init, exactly
/// like the Swift side sets them before `mpv_initialize`). Per-file / runtime-only values
/// (`demuxer-max-bytes`, live-mode tuning, per-stream headers, audio route policy) are NOT here; they
/// are applied per load via `setPropertyString` by the player, matching the Apple `loadFile` /
/// `configureLiveMode` split.
///
/// APPLE-ONLY vs ANDROID EQUIVALENT (the divergences, all documented inline below):
///   - `gpu-api=vulkan` + `gpu-context=moltenvk` (Apple, Metal via MoltenVK) -> `gpu-context=android`
///     (Android, OpenGL ES over the Surface). `vo=gpu-next` is IDENTICAL on both. See [baseOptions].
///   - `hwdec=videotoolbox` (Apple) -> `hwdec=mediacodec` (Android hardware decode; the same option
///     name, different accelerator; `mediacodec` is what lets DV/HDR pass through to the display).
///   - `sub-fonts-dir` / `embeddedfonts` point at the iOS/tvOS app bundle's `fonts/` folder on Apple;
///     on Android the equivalent is an assets/-extracted fonts dir, wired by the player when the font
///     assets are packaged (left OUT of [baseOptions] for now so a missing path never breaks init;
///     `embeddedfonts=yes` still ships so in-container fonts render).
///   - The audio-session / route-aware channel + samplerate policy (Apple `configureAudioSession` /
///     `channelPolicy` / `sampleRatePolicy`) is NOT ported here: on Android that is Media3
///     `AudioCapabilities` + `DefaultAudioSink` territory on the ExoPlayer fallback path, and mpv's
///     own AO negotiates the Android route. Those are player-side, not part of the static option set.
object MpvConfig {

    // ---- Individual option constants, so callers and tests can reference an exact value without
    //      re-typing the string. Grouped to mirror the Swift ordering. ----

    /// Video output: libplacebo's next-gen renderer. IDENTICAL to Apple (`vo=gpu-next`). Carries the
    /// sharp default upscalers (lanczos), debanding, and the HDR tone-mapping pipeline.
    const val VO = "gpu-next"

    /// GPU context. APPLE uses `gpu-api=vulkan` + `gpu-context=moltenvk` (Metal via MoltenVK). ANDROID
    /// EQUIVALENT: `gpu-context=android`, which drives gpu-next over OpenGL ES on the attached Surface.
    /// We deliberately do NOT set `gpu-api=vulkan` on Android: the shipped libmpv artifact
    /// (`dev.jdtech.mpv:libmpv:1.0.0`) builds libplacebo with `-Dvulkan=disabled`, so forcing the
    /// Vulkan API would fail VO init. `gpu-context=android` is the GL ES path that this artifact
    /// supports and is the mpv-android-standard Android context.
    const val GPU_CONTEXT = "android"

    /// Hardware decode. APPLE: `videotoolbox`. ANDROID EQUIVALENT: `mediacodec`, which decodes on the
    /// device's hardware codecs and, rendered direct to the Surface, passes HDR/Dolby Vision through to
    /// the display (the Android plan's DV-via-mediacodec path). `mediacodec-copy` would round-trip
    /// frames through CPU memory and lose the passthrough, so use plain `mediacodec`.
    const val HWDEC = "mediacodec"

    /// HDR -> SDR tone curve, used only when DV/HDR is force-mapped to SDR. IDENTICAL to Apple.
    const val TONE_MAPPING = "bt.2446a"

    /// A Safari-like User-Agent so debrid/CDN resolvers that 500 on ffmpeg's default `Lavf/*` UA serve
    /// the stream (the exact Apple UA, kept byte-for-byte so both engines present the same identity).
    const val USER_AGENT =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    const val NETWORK_TIMEOUT_SECS = "30"

    /// Reconnect on dropped/stalled HTTP (debrid CDNs reset mid-stream); IDENTICAL to Apple's VOD value.
    const val STREAM_LAVF_O = "reconnect=1,reconnect_streamed=1,reconnect_delay_max=7"

    /// Read-ahead cache seconds. IDENTICAL to Apple (`demuxer-readahead-secs=300`), the proven VOD value.
    const val DEMUXER_READAHEAD_SECS = "300"

    /// Pre-load forward-cache default. Android is jetsam-bound like iOS/tvOS, so use the iOS/tvOS init
    /// default (`128MiB`), not the macOS `256MiB`. The REAL per-file cap is set per load via
    /// `demuxer-max-bytes` as a property (device-scaled), exactly like Apple `loadFile`.
    const val DEMUXER_MAX_BYTES = "128MiB"

    /// Back-buffer (already-played, for seek-back). iOS/tvOS init default; kept small for RAM.
    const val DEMUXER_MAX_BACK_BYTES = "24MiB"

    /// Pick the highest-bandwidth variant of an adaptive HLS master. IDENTICAL to Apple.
    const val HLS_BITRATE = "max"

    /// The static, pre-init option set, in the SAME order as the Apple `setupMpv` block. Applied via
    /// `MPVLib.setOptionString` before `MPVLib.init()`. Each pair is `(name, value)`.
    ///
    /// NOTE the intentional omissions vs Apple (all set elsewhere or platform-specific):
    ///   - `wid` (Apple sets the Metal layer as the window id): on Android the Surface is attached via
    ///     `MPVLib.attachSurface`, which the native `player` lib maps to mpv's `wid` internally. Do NOT
    ///     set `wid` here.
    ///   - `cache-on-disk` / `cache-dir`: opt-in disk-cache, wired later off a Settings toggle.
    ///   - `sub-fonts-dir`: needs a runtime-extracted assets path; wired by the player when present.
    ///   - `subs-fallback`, `video-rotate`: kept to match Apple exactly.
    val baseOptions: List<Pair<String, String>> = listOf(
        // Subtitles: prefer the OS language, fall back to any, render embedded fonts. Mirrors Apple
        // lines `subs-match-os-language` / `subs-fallback` / `embeddedfonts`.
        "subs-match-os-language" to "yes",
        "subs-fallback" to "yes",
        "embeddedfonts" to "yes",

        // Video output pipeline. `vo=gpu-next` is identical to Apple; the context is the Android
        // divergence (GL ES `android` instead of Apple's Metal `moltenvk`, and NO `gpu-api=vulkan`
        // because the shipped libplacebo has Vulkan disabled). See the constants above for the full
        // rationale.
        "vo" to VO,
        "gpu-context" to GPU_CONTEXT,

        // Hardware decode via mediacodec (Apple: videotoolbox). Surface-direct mediacodec is what
        // carries HDR/DV to the panel.
        "hwdec" to HWDEC,

        // Never let mpv auto-rotate; the container/display handles orientation. Identical to Apple.
        "video-rotate" to "no",

        // HDR -> SDR tone curve for the forced-SDR compatibility path. Identical to Apple.
        "tone-mapping" to TONE_MAPPING,

        // Networking: browser-like UA + timeout + mid-stream reconnect for debrid/CDN links. The UA
        // and reconnect string are byte-for-byte the Apple values.
        "user-agent" to USER_AGENT,
        "network-timeout" to NETWORK_TIMEOUT_SECS,
        "stream-lavf-o" to STREAM_LAVF_O,

        // Read-ahead cache. `cache=yes` + 300s readahead + the jetsam-safe byte defaults (the per-file
        // `demuxer-max-bytes` cap is applied per load as a property, device-scaled, like Apple).
        "cache" to "yes",
        "demuxer-readahead-secs" to DEMUXER_READAHEAD_SECS,
        "demuxer-max-back-bytes" to DEMUXER_MAX_BACK_BYTES,
        "demuxer-max-bytes" to DEMUXER_MAX_BYTES,

        // Adaptive HLS: take the highest-bitrate rendition. Identical to Apple.
        "hls-bitrate" to HLS_BITRATE,
    )
}
