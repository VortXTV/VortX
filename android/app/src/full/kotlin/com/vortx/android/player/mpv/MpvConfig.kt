package com.vortx.android.player.mpv

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.security.KeyChain
import androidx.core.content.ContextCompat
import com.vortx.android.player.DiskCacheSetting
import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.Collections
import java.util.concurrent.Executors

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

    /// Conservative AO list used only after mpv proves that no output opened for a file with audio.
    /// AudioTrack is Android's primary mpv output, OpenSL ES is the compatibility fallback, and the
    /// trailing comma keeps mpv's normal auto-probe fallback available if neither can initialize.
    const val SAFE_AUDIO_OUTPUTS = "audiotrack,opensles,"

    /// HDR -> SDR tone curve, used only when DV/HDR is force-mapped to SDR. IDENTICAL to Apple.
    const val TONE_MAPPING = "bt.2446a"

    /// A Safari-like User-Agent so debrid/CDN resolvers that 500 on ffmpeg's default `Lavf/*` UA serve
    /// the stream (the exact Apple UA, kept byte-for-byte so both engines present the same identity).
    const val USER_AGENT =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    const val NETWORK_TIMEOUT_SECS = "30"

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

        // Networking identity and timeout. Trust-critical options are applied last through
        // [requiredSecurityOptions], after every ordinary setting, so nothing can overwrite them.
        "user-agent" to USER_AGENT,
        "network-timeout" to NETWORK_TIMEOUT_SECS,

        // Read-ahead cache. `cache=yes` + 300s readahead + the jetsam-safe byte defaults (the per-file
        // `demuxer-max-bytes` cap is applied per load as a property, device-scaled, like Apple).
        "cache" to "yes",
        "demuxer-readahead-secs" to DEMUXER_READAHEAD_SECS,
        "demuxer-max-back-bytes" to DEMUXER_MAX_BACK_BYTES,
        "demuxer-max-bytes" to DEMUXER_MAX_BYTES,

        // Adaptive HLS: take the highest-bitrate rendition. Identical to Apple.
        "hls-bitrate" to HLS_BITRATE,
    )

    /**
     * HDR output policy for the gpu-next / libplacebo pipeline. When [forceSDR] is true the output transfer
     * + primaries are pinned to SDR (bt.1886 gamma, bt.709 gamut), so libplacebo tone-maps HDR/DV down using
     * the [TONE_MAPPING] curve already in [baseOptions]; when false both are left on `auto`, so mpv requests
     * HDR passthrough and lets the panel present it. Always returns BOTH keys so a live mode switch fully
     * overwrites the previous one (mpv retains a property that is omitted from a later update). The Android
     * analogue of Apple's `target-trc` / `target-prim` application, driven by `stremiox.hdrToneMapMode`.
     */
    fun hdrOutputOptions(forceSDR: Boolean): List<Pair<String, String>> =
        if (forceSDR) {
            listOf("target-trc" to "bt.1886", "target-prim" to "bt.709")
        } else {
            listOf("target-trc" to "auto", "target-prim" to "auto")
        }

    /**
     * App-owned trust policy. [MpvPlayer] applies these after every ordinary preference and treats
     * any rejected option as a hard initialization failure, which safely demotes to the platform
     * player instead of starting libmpv with unknown certificate behavior.
     *
     * Config, script, and watch-later loading are disabled because each is a late option channel
     * that could otherwise replace the trust policy after this list is applied.
     */
    fun requiredSecurityOptions(caBundlePath: String): List<Pair<String, String>> {
        require(caBundlePath.isNotBlank()) { "TLS CA bundle path must not be blank" }
        require('\u0000' !in caBundlePath) { "TLS CA bundle path must not contain NUL" }
        require(',' !in caBundlePath) { "TLS CA bundle path must not contain commas" }

        return listOf(
            "config" to "no",
            "load-scripts" to "no",
            "resume-playback" to "no",
            "tls-verify" to "yes",
            "tls-ca-file" to caBundlePath,
            "stream-lavf-o" to
                "tls_verify=1,ca_file=$caBundlePath,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7",
            "demuxer-lavf-o" to "tls_verify=1,ca_file=$caBundlePath",
            "demuxer-lavf-propagate-opts" to "yes",
        )
    }

    /**
     * Export Android's current system trust anchors into the PEM bundle required by the packaged
     * FFmpeg mbedTLS backend. Only `system:` aliases are used, matching the app's network-security
     * policy: user-installed roots must not silently expand native-player trust.
     *
     * A failure returns null so [MpvPlayer] can demote to the platform player. The prior bundle is
     * invalidated before every refresh so a revoked root cannot remain usable after publication
     * fails.
     */
    fun provisionSystemCaBundle(context: Context): String? = synchronized(this) {
        val directory = context.noBackupFilesDir
        runCatching {
            invalidateSystemCaBundle(directory)
            val keyStore = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val aliases = Collections.list(keyStore.aliases())
                .filter { alias -> alias.startsWith(SYSTEM_CA_ALIAS_PREFIX) }
                .sorted()
            val certificates = aliases.mapNotNull { alias ->
                keyStore.getCertificate(alias) as? X509Certificate
            }
            writeCaBundle(directory, certificates).absolutePath
        }.getOrNull()
    }

    /**
     * Keep the native PEM aligned with Android trust-store changes while the process remains alive.
     * The system broadcast is protected, and rebuilding only rereads AndroidCAStore and atomically
     * republishes app-private data. Failure leaves the known bundle path absent, making later child
     * TLS opens fail closed.
     */
    fun ensureSystemTrustStoreObserver(context: Context): Boolean = synchronized(this) {
        if (trustStoreObserver != null) return@synchronized true

        val appContext = context.applicationContext
        runCatching {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(receiverContext: Context?, intent: Intent?) {
                    if (intent?.action == KeyChain.ACTION_TRUST_STORE_CHANGED) {
                        val pendingResult = goAsync()
                        runCatching {
                            trustStoreRefreshExecutor.execute {
                                try {
                                    provisionSystemCaBundle(appContext)
                                } finally {
                                    pendingResult.finish()
                                }
                            }
                        }.onFailure {
                            runCatching { invalidateSystemCaBundle(appContext.noBackupFilesDir) }
                            pendingResult.finish()
                        }
                    }
                }
            }
            ContextCompat.registerReceiver(
                appContext,
                receiver,
                IntentFilter(KeyChain.ACTION_TRUST_STORE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            trustStoreObserver = receiver
        }.isSuccess
    }

    /**
     * Deterministic, atomic PEM publication seam. Internal for JVM regression tests.
     */
    internal fun writeCaBundle(
        directory: File,
        certificates: List<X509Certificate>,
    ): File {
        require(certificates.isNotEmpty()) { "Android system CA store is empty" }
        if (!directory.isDirectory && !directory.mkdirs()) {
            error("Unable to create TLS CA directory")
        }

        val digest = MessageDigest.getInstance("SHA-256")
        val unique = LinkedHashMap<String, X509Certificate>()
        for (certificate in certificates) {
            val fingerprint = digest.digest(certificate.encoded).hex()
            unique.putIfAbsent(fingerprint, certificate)
        }
        require(unique.isNotEmpty()) { "Android system CA store has no encodable certificates" }

        val target = File(directory, SYSTEM_CA_BUNDLE_FILENAME)
        val temporary = File.createTempFile("$SYSTEM_CA_BUNDLE_FILENAME.", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { output ->
                for (certificate in unique.values) {
                    output.write("-----BEGIN CERTIFICATE-----\n".toByteArray(Charsets.US_ASCII))
                    output.write(
                        Base64.getMimeEncoder(64, byteArrayOf('\n'.code.toByte()))
                            .encode(certificate.encoded),
                    )
                    output.write("\n-----END CERTIFICATE-----\n".toByteArray(Charsets.US_ASCII))
                }
                output.flush()
                output.fd.sync()
            }

            val parsed = temporary.inputStream().use { input ->
                CertificateFactory.getInstance("X.509")
                    .generateCertificates(input)
                    .filterIsInstance<X509Certificate>()
            }
            val parsedFingerprints = parsed.map { certificate ->
                digest.digest(certificate.encoded).hex()
            }
            require(parsedFingerprints == unique.keys.toList()) {
                "Published TLS CA bundle failed validation"
            }

            try {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            return target
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    /**
     * Invalidate the last trust snapshot before rebuilding it. This intentionally prefers a
     * temporary playback failure over continuing to trust an anchor Android has just revoked.
     */
    internal fun replaceCaBundle(
        directory: File,
        certificates: List<X509Certificate>,
    ): File {
        invalidateSystemCaBundle(directory)
        return writeCaBundle(directory, certificates)
    }

    /// The OPT-IN on-disk cache options (`cache-on-disk=yes` + `cache-dir=<path>`), applied pre-init
    /// ALONGSIDE [baseOptions] when the viewer has enabled the disk cache in Settings. Empty (the default)
    /// keeps mpv on its in-memory read-ahead, so shipping behavior is unchanged until opted in. The large
    /// `demuxer-max-bytes` that actually fills the disk cache is set per-file by the player (device- and
    /// free-disk-clamped via [DiskCacheSetting.resolvedMaxBytes]), mirroring the Apple loadFile split. This
    /// is the "cache-on-disk toggle in MpvConfig" the Android parity map called for; the persistence +
    /// free-disk safety math lives in [DiskCacheSetting].
    fun diskCacheOptions(context: Context): List<Pair<String, String>> =
        DiskCacheSetting.mpvOptions(context)

    private fun invalidateSystemCaBundle(directory: File) {
        Files.deleteIfExists(File(directory, SYSTEM_CA_BUNDLE_FILENAME).toPath())
    }

    @Volatile
    private var trustStoreObserver: BroadcastReceiver? = null

    private val trustStoreRefreshExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vortx-trust-store-refresh").apply { isDaemon = true }
    }

    private fun ByteArray.hex(): String =
        joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private const val SYSTEM_CA_ALIAS_PREFIX = "system:"
    private const val SYSTEM_CA_BUNDLE_FILENAME = "mpv-system-ca-bundle.pem"
}
