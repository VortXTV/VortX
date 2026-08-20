package com.vortx.android.search

import android.net.Uri
import java.util.Locale

/// A classified "Play a link" input (SD-1), the Android port of Apple's `iOSOpenLinkView.play()` +
/// `OpenLinkMagnet.parse` (iOSRootView.swift:3643-3684, 3823-3845). The sheet classifies the raw text
/// with [classifyPlayLink] and dispatches on the result: a magnet resolves through the torrent/debrid
/// path (by its info hash), a direct/debrid/usenet http(s) link plays as-is, and anything else is a clear
/// error before any resolve is attempted.
sealed interface PlayLinkTarget {
    /// A magnet link with a usable BitTorrent info hash. [name] is the magnet `dn` when present (the
    /// display name), else null.
    data class Magnet(val link: String, val infoHash: String, val name: String?) : PlayLinkTarget

    /// A direct/debrid/usenet http(s) link (already resolved by the user's service). [title] is the last
    /// path component or host, for the player title bar.
    data class Direct(val url: String, val title: String) : PlayLinkTarget

    /// Not playable. [reason] is a short user-facing message.
    data class Invalid(val reason: String) : PlayLinkTarget
}

/// Classify a raw pasted string. [directLinksOnly] mirrors Apple's `PlaybackSettings.directLinksOnly`:
/// when set, a magnet is rejected outright (the error text omits the magnet option too).
fun classifyPlayLink(raw: String, directLinksOnly: Boolean = false): PlayLinkTarget {
    val text = raw.trim()
    if (text.isEmpty()) return PlayLinkTarget.Invalid("Enter a link to play.")

    if (text.lowercase(Locale.ROOT).startsWith("magnet:")) {
        if (directLinksOnly) {
            return PlayLinkTarget.Invalid("Magnet links are turned off. Use a direct or debrid http(s) link.")
        }
        val magnet = parseMagnet(text)
            ?: return PlayLinkTarget.Invalid("That magnet link has no usable info hash.")
        return PlayLinkTarget.Magnet(link = text, infoHash = magnet.infoHash, name = magnet.name)
    }

    // Bare host/path (no scheme but looks like a domain): assume https, matching Apple.
    val candidate = if (!text.contains("://") && text.contains(".")) "https://$text" else text
    val uri = runCatching { Uri.parse(candidate) }.getOrNull()
    val scheme = uri?.scheme?.lowercase(Locale.ROOT)
    if (uri == null || (scheme != "http" && scheme != "https")) {
        val hint = if (directLinksOnly) "Not a playable link. Paste a direct or debrid http(s) link."
        else "Not a playable link. Paste an http(s) link or a magnet."
        return PlayLinkTarget.Invalid(hint)
    }
    val title = uri.lastPathSegment?.takeIf { it.isNotBlank() } ?: uri.host ?: candidate
    return PlayLinkTarget.Direct(url = candidate, title = title)
}

/// The parsed pieces of a magnet link (the ones this port uses). Trackers are intentionally not carried:
/// the pasted magnet resolves through the existing torrent/debrid path, which forms the swarm itself.
data class ParsedMagnet(val infoHash: String, val name: String?)

/// Parse a `magnet:?xt=urn:btih:...` link. Accepts a 40-char hex hash (lowercased) or a 32-char RFC 4648
/// base32 hash (decoded to hex), mirroring Apple `OpenLinkMagnet.parse`. Returns null when no usable info
/// hash is present.
fun parseMagnet(link: String): ParsedMagnet? {
    val uri = runCatching { Uri.parse(link) }.getOrNull() ?: return null
    if (!uri.scheme.equals("magnet", ignoreCase = true)) return null
    val xtValues = uri.getQueryParameters("xt")
    val infoHash = xtValues.firstNotNullOfOrNull { infoHashFromXt(it) } ?: return null
    val name = uri.getQueryParameter("dn")?.takeIf { it.isNotBlank() }
    return ParsedMagnet(infoHash = infoHash, name = name)
}

private fun infoHashFromXt(xt: String): String? {
    val prefix = "urn:btih:"
    if (!xt.lowercase(Locale.ROOT).startsWith(prefix)) return null
    val value = xt.substring(prefix.length)
    return when {
        value.length == 40 && value.all { it.isHexDigit() } -> value.lowercase(Locale.ROOT)
        value.length == 32 -> base32ToHex(value)
        else -> null
    }
}

private fun Char.isHexDigit(): Boolean = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

/// Decode a 32-char RFC 4648 base32 info hash to a 40-char lowercase hex string. Null on any invalid
/// character. Mirrors Apple `OpenLinkMagnet.base32ToHex`.
private fun base32ToHex(base32: String): String? {
    val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    var buffer = 0L
    var bitsLeft = 0
    val out = StringBuilder()
    for (raw in base32) {
        val idx = alphabet.indexOf(raw.uppercaseChar())
        if (idx < 0) return null
        buffer = (buffer shl 5) or idx.toLong()
        bitsLeft += 5
        if (bitsLeft >= 8) {
            bitsLeft -= 8
            val byte = ((buffer shr bitsLeft) and 0xFF).toInt()
            out.append("%02x".format(byte))
        }
    }
    return out.toString().takeIf { it.length == 40 }
}
