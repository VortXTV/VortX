package com.vortx.android.player.subtitles

import android.content.Context
import com.vortx.android.model.MediaRef
import com.vortx.android.moat.MoatToken
import com.vortx.android.player.AddonSubtitle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/**
 * The consumer that turns the community-subtitle FOUNDATION units (SubtitlePoolClient, SubtitleReleaseFingerprint,
 * SubtitleAutoResync, SubtitleEmbeddedExtractor, SubtitleImageOcr) into the pool CONTRIBUTION + SYNC flow the
 * player drives. The Android port of the community-subtitle half of Apple `app/Sources/PlayerScreen.swift`
 * (`uploadEmbeddedSubtitlesIfNeeded`, `hoardAddonSubtitle`, `captureSubOffset`, the pooled-offset seed inside
 * `fetchPooledSubtitles`, and the moat provider wiring Apple does at app start).
 *
 * WHY a coordinator object rather than inline player code: the player screen is a large shared Compose file
 * owned across several parity lanes, and this codebase already ships the subtitle-pool logic as self-contained,
 * unit-tested foundation units that a later integration pass calls (see the "A later update wires this into the
 * subtitle picker" note the client and CHANGELOG carry). This is that logic gathered into ONE callable,
 * fail-soft surface: the pure decisions (content key, release fingerprint, format inference, upload gating,
 * offset validity) are JVM-testable here, and each network call delegates to the already-tested client. The
 * player then only has to call these methods, exactly as the Apple screen calls its private twins.
 *
 * FAIL-SOFT, gated: every method is a hard no-op / empty result on any error and honours the same feature gates
 * the underlying client enforces. Nothing here throws to the caller or blocks playback.
 */
object SubtitlePoolContribution {

    /** Matches SubtitlePoolClient.SUBTITLE_BODY_MAX_BYTES: the worker's fixed 1 MiB text ceiling. */
    private const val ADDON_TEXT_MAX_BYTES = 1024 * 1024
    private const val ADDON_FETCH_TIMEOUT_MS = 15_000

    private val subtitleFormats = setOf("srt", "vtt", "ass")

    @Volatile
    private var moatWired = false

    /**
     * Wire the pool client's reserved `moatTokenProvider` hook to the live VortX account moat token, the direct
     * analog of `VortXApplication.wireMoatGroundwork` doing `SourceIndexClient.moatTokenProvider = { MoatToken
     * .current(...) }` for the source pool, and of Apple threading `MoatToken.shared` into the subtitle client.
     * Idempotent: safe to call from the player's LaunchedEffect on every mount; only the first call installs it.
     * With no account session the token mint returns null, so a signed-out device stays fully dormant.
     */
    fun ensureMoatProviderWired() {
        if (moatWired) return
        synchronized(this) {
            if (moatWired) return
            SubtitlePoolClient.moatTokenProvider = { signedIn -> MoatToken.current(isSignedIn = signedIn) }
            moatWired = true
        }
    }

    // MARK: - Identity (pure)

    /**
     * The pool `content_key` for [ref], or null when it carries no usable IMDb identity (a magnet, a tmdb-only
     * catalog entry) -- the whole community path no-ops without a content key. Mirrors Apple `communityContentKey`.
     */
    fun contentKey(ref: MediaRef?): String? {
        val imdb = ref?.imdb?.takeIf { it.isNotBlank() } ?: return null
        if (imdb.trim().lowercase().startsWith("tmdb:")) return null
        return if (ref.isSeries) {
            val season = ref.season ?: return null
            val episode = ref.episode ?: return null
            SubtitleReleaseFingerprint.contentKey(imdb, season, episode)
        } else {
            SubtitleReleaseFingerprint.contentKey(imdb)
        }
    }

    /**
     * The release fingerprint that scopes a learned sync offset to this exact rip. Delegates to
     * [SubtitleReleaseFingerprint.releaseFingerprint]; mirrors Apple `refreshSubFingerprint`. Every input is
     * optional, so a caller that knows only the release name still gets a stable, if coarser, fingerprint.
     */
    fun fingerprint(frameRate: Double? = null, durationSecs: Double? = null, releaseName: String? = null): String =
        SubtitleReleaseFingerprint.releaseFingerprint(
            frameRate = frameRate?.takeIf { it > 0 },
            durationSecs = durationSecs?.takeIf { it > 0 },
            releaseName = releaseName,
        )

    /** Whether [input] is eligible for embedded-text extraction (a finished local file only). Pure gate. */
    fun canUploadEmbedded(input: String): Boolean = SubtitleEmbeddedExtractor.isLocalFileInput(input)

    /** Infer the pool subtitle format from a URL extension; default "srt" (the worker treats unknowns as srt). */
    fun subtitleFormatFromUrl(url: String): String {
        val ext = runCatching { URI(url).path }.getOrNull()
            ?.substringAfterLast('.', "")
            ?.lowercase()
            ?: ""
        return if (ext in subtitleFormats) ext else "srt"
    }

    // MARK: - Contribution: embedded text (Apple uploadEmbeddedSubtitlesIfNeeded)

    /**
     * Extract [input]'s own embedded TEXT subtitle tracks off-thread and upload each non-empty track to the
     * pool (origin "embedded"), so a viewer on a different rip benefits. LOCAL FILES ONLY (see
     * [SubtitleEmbeddedExtractor]). Best-effort, fail-soft; the caller latches "once per session". Mirrors Apple
     * `uploadEmbeddedSubtitlesIfNeeded`.
     */
    suspend fun uploadEmbedded(contentKey: String, fingerprint: String?, input: String) {
        if (!canUploadEmbedded(input)) return
        val tracks = withContext(Dispatchers.IO) {
            runCatching { SubtitleEmbeddedExtractor.extractTextSubtitles(input) }.getOrDefault(emptyList())
        }
        for (track in tracks) {
            if (track.cueCount <= 0) continue
            SubtitlePoolClient.upload(
                contentKey = contentKey,
                lang = track.lang,
                fingerprint = fingerprint,
                origin = "embedded",
                format = track.format,
                text = track.srt,
            )
        }
    }

    // MARK: - Contribution: recognised image subtitles (Apple VortXPGSSubtitleOCR -> pool)

    /**
     * Upload OCR'd image-subtitle cues for one language to the pool (origin "embedded", the same origin Apple
     * uses for its PGS-recognised text). No-op when OCR is unavailable in this build or there is nothing to
     * upload. Best-effort, fail-soft.
     */
    suspend fun uploadRecognizedImageSubtitles(
        contentKey: String,
        fingerprint: String?,
        lang: String,
        cues: List<SubtitleImageOcr.RecognizedCue>,
    ) {
        if (!SubtitleImageOcr.isAvailable) return
        val srt = SubtitleImageOcr.serializeSrt(cues)
        if (srt.isEmpty()) return
        SubtitlePoolClient.upload(
            contentKey = contentKey,
            lang = lang.ifBlank { "und" },
            fingerprint = fingerprint,
            origin = "embedded",
            format = "srt",
            text = srt,
        )
    }

    // MARK: - Contribution: hoard an add-on subtitle (Apple hoardAddonSubtitle)

    /**
     * Download a successfully-loaded ADD-ON subtitle's text once and upload it to the pool (origin "addon") so
     * the next viewer gets it without hitting the add-on. Best-effort, off-thread, size-capped, fail-soft;
     * never blocks playback. Mirrors Apple `hoardAddonSubtitle`.
     */
    suspend fun hoardAddon(contentKey: String, fingerprint: String?, sub: AddonSubtitle) {
        if (!isSafeAddonTextUrl(sub.url)) return
        val text = downloadAddonText(sub.url) ?: return
        if (text.isEmpty()) return
        SubtitlePoolClient.upload(
            contentKey = contentKey,
            lang = sub.lang,
            fingerprint = fingerprint,
            origin = "addon",
            format = subtitleFormatFromUrl(sub.url),
            text = text,
        )
    }

    /** Bounded GET of an add-on subtitle URL as UTF-8 text, or null on any failure. */
    private suspend fun downloadAddonText(url: String): String? = withContext(Dispatchers.IO) {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = ADDON_FETCH_TIMEOUT_MS
                readTimeout = ADDON_FETCH_TIMEOUT_MS
                useCaches = false
                // Do not follow an otherwise safe public URL to an unvalidated redirect target. The optional
                // contribution path can skip a redirected sidecar; normal subtitle playback is unchanged.
                instanceFollowRedirects = false
            }
            if (conn.responseCode !in 200..299) return@withContext null
            conn.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > ADDON_TEXT_MAX_BYTES) return@withContext null
                    out.write(buffer, 0, read)
                }
                out.toString(Charsets.UTF_8.name())
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    /**
     * A subtitle may be mounted from a user-installed add-on, but contribution must never turn that choice
     * into a request to a loopback or private-network service and then copy its response to the pool.
     * Only public HTTPS URLs are eligible for the optional hoard step; playback itself remains unchanged.
     */
    internal fun isSafeAddonTextUrl(raw: String): Boolean {
        val uri = runCatching { URI(raw) }.getOrNull() ?: return false
        if (!uri.scheme.equals("https", ignoreCase = true) || uri.userInfo != null) return false
        val host = uri.host?.lowercase() ?: return false
        if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return false
        val numeric = host.removePrefix("[").removeSuffix("]")
        if (numeric == "::1" || numeric == "0:0:0:0:0:0:0:1") return false
        if (numeric.startsWith("127.") || numeric.startsWith("10.") || numeric.startsWith("192.168.")) return false
        if (numeric.startsWith("169.254.") || numeric.startsWith("0.")) return false
        val parts = numeric.split('.')
        if (parts.size == 4) {
            val first = parts[0].toIntOrNull()
            val second = parts[1].toIntOrNull()
            if (first == 172 && second != null && second in 16..31) return false
        }
        return true
    }

    // MARK: - Sync: seed + capture (Apple restoreSubtitleTimingOffsetIfReady + captureSubOffset)

    /**
     * Resolve the subtitle delay to apply at load, layering the viewer's own saved manual offset over the
     * community-learned [poolOffsetMs]. Manual always wins; the community offset applies only when there is no
     * manual offset and the session is unseeded. Delegates to [SubtitleAutoResync]; the caller applies the
     * resolved seconds to the engine (`setSubtitleDelay`) only when it advertises live delay support.
     */
    fun resolveOffset(
        context: Context,
        contentKey: String?,
        poolOffsetMs: Int?,
        alreadySeeded: Boolean,
    ): SubtitleAutoResync.Resolution =
        SubtitleAutoResync.resolveForPlayback(context, contentKey, poolOffsetMs, alreadySeeded)

    /**
     * Submit a viewer's manually-adjusted sync offset to the pool for [contentKey] + [fingerprint], so the pool
     * learns the right offset for this rip. No-op for an invalid/out-of-bounds offset (the same
     * `abs(seconds) <= 120` guard Apple applies). Best-effort, fail-soft. Mirrors Apple `captureSubOffset`.
     */
    suspend fun captureOffset(contentKey: String, fingerprint: String?, offsetSeconds: Double) {
        val offsetMs = SubtitleAutoResync.captureOffsetMs(offsetSeconds) ?: return
        SubtitlePoolClient.postOffset(contentKey = contentKey, lang = "", fingerprint = fingerprint, offsetMs = offsetMs)
    }
}
