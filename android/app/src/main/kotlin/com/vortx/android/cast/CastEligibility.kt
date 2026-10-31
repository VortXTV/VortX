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

    /// The receiver refetches the final resolved URL. Torrent identity is not a transport veto: a
    /// chosen remote streaming server may serve it. Ordinary self-hosted LAN/Tailscale URLs retain
    /// their existing receiver route; only a torrent requires selected-server origin/path authority.
    fun isCastable(playable: Playable): Boolean {
        if (playable.isTrailer || playable.headers.isNotEmpty() || playable.audioUrl != null ||
            playable.userAgent != null || playable.playbackLease != null) return false
        if (!isRemoteHttpUrl(playable.url)) return false
        if (playable.isTorrent) {
            // The actual resolver captures this exact server/hash/file before I/O. Neither a caller's
            // current preference nor an add-on URL can grant a torrent a receiver lifetime.
            val route = playable.streamingServerRoute ?: return false
            if (!playable.viaStreamingServer || route.contentType == null || !route.permits(playable.url)) return false
        }
        return true
    }

    /** Receiver URL policy only. A selected streaming server is required by the torrent branch above. */
    fun isRemoteHttpUrl(url: String): Boolean {
        val media = parse(url) ?: return false
        return when (hostScope(media.host)) {
            Scope.PUBLIC, Scope.LAN -> true
            Scope.FORBIDDEN -> false
        }
    }

    private enum class Scope { PUBLIC, LAN, FORBIDDEN }
    private fun parse(raw: String): URI? = runCatching { URI(raw.trim()) }.getOrNull()?.takeIf {
        it.scheme?.lowercase() in setOf("http", "https") && !it.host.isNullOrBlank()
            && it.rawUserInfo == null && it.fragment == null && (it.port == -1 || it.port in 1..65535)
    }

    private fun hostScope(raw: String): Scope {
        val host = raw.lowercase().removePrefix("[").removeSuffix("]").trimEnd('.')
        if (host.isBlank() || '%' in host || host == "localhost" || host.endsWith(".localhost")
            || host == "metadata.google.internal" || host.endsWith(".metadata.google.internal")
            || host == "instance-data.ec2.internal") return Scope.FORBIDDEN
        if (':' in host) {
            val bytes = runCatching { java.net.InetAddress.getByName(host).address }.getOrNull() ?: return Scope.FORBIDDEN
            if (bytes.size == 4) return ipv4Scope(bytes.map { it.toInt() and 255 })
            val b = bytes.map { it.toInt() and 255 }
            if (b.size != 16 || b.take(15).all { it == 0 } && b[15] <= 1) return Scope.FORBIDDEN
            if (b[0] == 255 || b[0] == 254 && b[1] and 192 == 128) return Scope.FORBIDDEN
            if (b.take(4) in listOf(listOf(253,0,14,194), listOf(253,32,0,206)) && b.subList(4,14).all { it == 0 } && b[14] == 2 && b[15] == 84) return Scope.FORBIDDEN
            if (b[0] and 254 == 252) return Scope.LAN
            if (b.take(12).all { it == 0 } || b.take(4) == listOf(0, 100, 255, 155)) return Scope.FORBIDDEN
            return Scope.PUBLIC
        }
        val parts = host.split('.')
        if (parts.size == 4 && parts.all { it.isNotEmpty() && it.all(Char::isDigit) }) {
            if (parts.any { it.length > 1 && it.startsWith('0') }) return Scope.FORBIDDEN
            val octets = parts.map { it.toIntOrNull() ?: return Scope.FORBIDDEN }
            if (octets.any { it !in 0..255 }) return Scope.FORBIDDEN
            return ipv4Scope(octets)
        }
        if (host.all { it.isDigit() || it == '.' } || host.startsWith("0x")) return Scope.FORBIDDEN
        if ('.' !in host || host.endsWith(".local") || host.endsWith(".internal")) return Scope.LAN
        return Scope.PUBLIC
    }
    private fun ipv4Scope(b: List<Int>): Scope {
        val a = b[0]; val second = b[1]
        if (b == listOf(168,63,129,16) || b == listOf(100,100,100,200)) return Scope.FORBIDDEN
        if (a == 0 || a == 127 || a >= 224 || a == 169 && second == 254) return Scope.FORBIDDEN
        if (a == 10 || a == 172 && second in 16..31 || a == 192 && second == 168 || a == 100 && second in 64..127) return Scope.LAN
        if (a == 198 && second in 18..19) return Scope.FORBIDDEN
        return Scope.PUBLIC
    }

    /// The lower-cased host of [url], or null when it cannot be parsed.
    fun hostOf(url: String): String? =
        runCatching { URI(url.trim()).host }.getOrNull()?.lowercase()?.takeIf { it.isNotBlank() }

    /** The hash/file endpoint has no extension; use its original resolver-owned file metadata. */
    fun receiverContentType(playable: Playable): String {
        val route = playable.streamingServerRoute
        if (playable.isTorrent && route?.permits(playable.url) == true)
            return route.contentType ?: "application/octet-stream"
        return contentType(playable.url)
    }

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

}
