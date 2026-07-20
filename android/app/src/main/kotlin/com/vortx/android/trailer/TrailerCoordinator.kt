package com.vortx.android.trailer

import android.content.Context
import com.vortx.android.model.Playable
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.model.TrailerRequest
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.withTimeoutOrNull

/// Turns a YouTube trailer id into a directly-playable [Playable], the ONE place the client resolver, the
/// loopback range-proxy, and the worker fallback are wired together (the Android analogue of the trailer play
/// path the Apple `MPVMetalViewController` / `iOSDetailView` assemble). Detail/hero UI calls [trailerPlayable]
/// and hands the result to the existing player pipeline; it never talks to [YouTubeDirectResolver] or
/// [VXTrailerProxy] directly.
///
/// TWO PATHS, one contract:
///   * CLIENT (flag ON, resolve HIT): [YouTubeDirectResolver] returns googlevideo URLs from the user's OWN IP;
///     both legs are wrapped in [VXTrailerProxy] (127.0.0.1) so the player defeats googlevideo's Range-403, and
///     the minting client's UA rides on the [Playable] for the UA/URL lockstep. Free 1080p, no worker.
///   * WORKER (flag OFF, or a resolve MISS/timeout): fall back to the remote resolver `trailer.vortx.tv/yt/{id}`
///     (via [TrailerRequest]), a single muxed remote stream. The worker host is NOT range-proxied (it serves a
///     clean stream), matching Apple's fallback.
///
/// The whole client resolve is bounded (~8s) so a slow InnerTube ladder can never hang the trailer tap; on the
/// timeout it degrades to the worker path. Fail-soft throughout: returns null only when there is no trailer id
/// at all (nothing to play).
object TrailerCoordinator {

    /// Bound the entire client resolve (config scrape + the 4-client ladder). On timeout, fall to the worker.
    private const val RESOLVE_BUDGET_MS = 8_000L

    /// Build the [Playable] for [youTubeId]. [title] labels the player; [imdbId]/[year]/[mediaType] feed the
    /// worker fallback's `/clip` matching (mirrors [TrailerRequest]). Returns null only for a blank id.
    suspend fun trailerPlayable(
        context: Context,
        youTubeId: String,
        title: String,
        imdbId: String? = null,
        year: String? = null,
        mediaType: String = "movie",
    ): Playable? {
        val id = youTubeId.trim()
        if (id.isEmpty()) return null
        val prefLangs = TrackPreferencesStore(context.applicationContext).trailerAudioLanguages

        if (TrailerFlags.clientResolverEnabled(context)) {
            val resolved = withTimeoutOrNull(RESOLVE_BUDGET_MS) {
                YouTubeDirectResolver.resolve(id, prefLangs)
            }
            if (resolved != null) {
                // Proxy BOTH googlevideo legs to 127.0.0.1 (the Range-403 fix). Fall back to the raw URL if the
                // loopback listener will not start, matching Apple's `?? url`.
                val ua = resolved.userAgent
                val video = VXTrailerProxy.proxied(resolved.videoUrl, "video/mp4", ua) ?: resolved.videoUrl
                val audio = resolved.audioUrl?.let { VXTrailerProxy.proxied(it, "audio/mp4", ua) ?: it }
                return Playable(
                    url = video,
                    title = title,
                    isTrailer = true,
                    audioUrl = audio,
                    userAgent = ua,
                )
            }
        }

        // Worker fallback (flag OFF, or a client miss/timeout). A single remote muxed stream, edge-signed so it
        // verifies at the gated `trailer.vortx.tv` worker (VortXEdgeAuth.signedUrl fails open on an
        // unprovisioned build). No audioUrl, no client UA -- it is not a googlevideo URL.
        val request = TrailerRequest(title = title, youTubeID = id, year = year, mediaType = mediaType, imdbID = imdbId)
        val workerUrl = request.nativeFullTrailerURL(languageCode = prefLangs.firstOrNull()) ?: return null
        return Playable(
            url = VortXEdgeAuth.signedUrl(workerUrl),
            title = title,
            isTrailer = true,
        )
    }
}
