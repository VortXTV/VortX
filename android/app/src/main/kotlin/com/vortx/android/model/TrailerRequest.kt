package com.vortx.android.model

import java.net.URLEncoder

/**
 * Cross-platform "resolve a trailer to a playable URL" value type. The Android port of Apple
 * `app/SourcesShared/TrailerRequest.swift`. A meta's trailer is either a direct (non-YouTube) stream URL or a
 * YouTube id; this collapses both into one [playableURL] the player can hand to libmpv/ExoPlayer.
 *
 * YouTube trailers resolve through the always-remote resolver `trailer.vortx.tv/yt/{id}` (Apple
 * `StremioServer.trailerResolverBase`), so a YouTube-only trailer has a [playableURL] on every build.
 * [watchURL] is the public youtube.com link for surfaces that open an external player.
 *
 * URLs are modeled as `String` (what the player engines consume, and what keeps this trivially testable).
 * The Apple `from(meta:)` factory is not ported here: the Android meta model does not yet carry
 * `trailerStreams` / `trailerYouTubeID` (a partial tier-1 model gap owned by a later round). Callers build a
 * `TrailerRequest` directly from resolved trailer fields until then.
 */
data class TrailerRequest(
    val title: String,
    val youTubeID: String? = null,
    /** A non-YouTube `trailerStreams` url, if the meta carried a direct stream. */
    val directURL: String? = null,
    /** Release year (4 digits): the key the `/clip` resolver matches a trailer on (title+year). */
    val year: String? = null,
    /** "movie" | "series". */
    val mediaType: String = "movie",
    /** IMDb id (`tt...`) when known; null for tmdb:/kitsu: catalog ids. */
    val imdbID: String? = null,
) {
    /** The libmpv/ExoPlayer-playable URL for the trailer. Fail-soft: null when neither a direct stream nor a YouTube id exists. */
    val playableURL: String?
        get() = nativeFullTrailerURL()

    /** The public YouTube watch link, for surfaces that open trailers externally. */
    val watchURL: String?
        get() = youTubeID?.takeIf { it.isNotEmpty() }?.let { "https://www.youtube.com/watch?v=$it" }

    /**
     * The FULL-trailer native playback URL: a direct (non-YouTube) trailer stream when the meta carried one,
     * else the remote resolver's `/yt/{id}` route (which yields a directly-playable media URL). A direct
     * stream is always preferred. [preferredYouTubeID] lets a caller pass a language-selected id that
     * overrides the default [youTubeID]; [languageCode] adds the `?lang=` hint the resolver's fallback chain
     * uses. Returns null when there is no direct stream and no usable YouTube id.
     */
    fun nativeFullTrailerURL(preferredYouTubeID: String? = null, languageCode: String? = null): String? {
        directURL?.let { return it }
        val yt = preferredYouTubeID?.takeIf { it.isNotEmpty() } ?: youTubeID
        if (yt.isNullOrEmpty()) return null
        val base = "$TRAILER_RESOLVER_BASE/yt/$yt"
        val lang = languageCode?.takeIf { it.isNotEmpty() } ?: return base
        return "$base?lang=${URLEncoder.encode(lang, "UTF-8")}"
    }

    companion object {
        /** Apple `StremioServer.trailerResolverBase` -- the public, always-remote YouTube-trailer resolver. */
        const val TRAILER_RESOLVER_BASE = "https://trailer.vortx.tv"
    }
}
