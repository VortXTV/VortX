package com.vortx.android.cast

import com.vortx.android.model.Playable
import java.net.URI

/// Pure, engine-free gating logic that decides whether a [Playable] can be handed to a Google Cast
/// receiver, plus the MIME guesses the load request needs. Kept as pure functions (no Android / Cast SDK
/// types) so it is unit-testable in isolation and mirrors the Apple `PlayerEngineRouter` gate: a Cast
/// receiver is a SEPARATE device that refetches the URL itself, so the exact same streams that can never
/// leave the phone on Apple (the in-process streaming server's loopback torrent URL) can never be cast
/// here either.
object CastEligibility {

    /// True when this stream can be cast. Castable = a direct / debrid / HLS HTTP(S) URL a remote receiver
    /// can actually reach. Excluded:
    ///   - torrents (`isTorrent`): the URL is the in-process streaming server's loopback address, which a
    ///     Cast device on the LAN cannot resolve -- exactly the loopback gate the Apple router applies
    ///     before AVPlayer/AirPlay.
    ///   - trailers (`isTrailer`): a client-resolved googlevideo URL bound to a specific User-Agent (often a
    ///     two-leg adaptive video+audio pair). The default receiver cannot replay the UA lockstep or merge
    ///     two legs, so a trailer is never offered for casting.
    ///   - anything that is not a plain remote HTTP(S) URL (a file path, a data URI, a loopback host).
    fun isCastable(playable: Playable): Boolean {
        if (playable.isTorrent) return false
        if (playable.isTrailer) return false
        return isRemoteHttpUrl(playable.url)
    }

    /// True for an `http://` / `https://` URL whose host is a real remote host (not a loopback / any-address
    /// alias the in-process streaming server binds to).
    fun isRemoteHttpUrl(url: String): Boolean {
        val lower = url.trim().lowercase()
        if (!(lower.startsWith("http://") || lower.startsWith("https://"))) return false
        val host = hostOf(url) ?: return false
        return host !in LOOPBACK_HOSTS
    }

    /// The lower-cased host of [url], or null when it cannot be parsed.
    fun hostOf(url: String): String? =
        runCatching { URI(url.trim()).host }.getOrNull()?.lowercase()?.takeIf { it.isNotBlank() }

    /// A best-effort content-type for the receiver, guessed from the URL path extension. The Default Media
    /// Receiver keys its playback pipeline off this MIME, so an HLS playlist MUST be typed as
    /// `application/x-mpegURL` (else it is treated as a progressive download and fails). Unknown extensions
    /// fall back to `video/mp4`, the receiver's most broadly supported progressive container.
    fun contentType(url: String): String {
        val path = pathOf(url)
        return when {
            path.endsWith(".m3u8", ignoreCase = true) -> "application/x-mpegURL"
            path.endsWith(".mpd", ignoreCase = true) -> "application/dash+xml"
            path.endsWith(".webm", ignoreCase = true) -> "video/webm"
            path.endsWith(".mkv", ignoreCase = true) -> "video/x-matroska"
            path.endsWith(".mov", ignoreCase = true) -> "video/quicktime"
            path.endsWith(".m4v", ignoreCase = true) -> "video/mp4"
            else -> "video/mp4"
        }
    }

    /// A best-effort content-type for a sidecar subtitle track. The Default Media Receiver renders WebVTT
    /// natively; other formats are typed correctly for a custom receiver but may not display on the default
    /// one (the same practical limit AirPlay hits with non-WebVTT sidecars).
    fun subtitleContentType(url: String): String {
        val path = pathOf(url)
        return when {
            path.endsWith(".srt", ignoreCase = true) -> "application/x-subrip"
            path.endsWith(".ttml", ignoreCase = true) || path.endsWith(".dfxp", ignoreCase = true) -> "application/ttml+xml"
            path.endsWith(".ssa", ignoreCase = true) || path.endsWith(".ass", ignoreCase = true) -> "text/x-ssa"
            else -> "text/vtt"
        }
    }

    private fun pathOf(url: String): String =
        runCatching { URI(url.trim()).path }.getOrNull()?.takeIf { it.isNotBlank() } ?: url

    private val LOOPBACK_HOSTS = setOf("127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0")
}
