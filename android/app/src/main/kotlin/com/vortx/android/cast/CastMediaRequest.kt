package com.vortx.android.cast

import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaTrack
import com.vortx.android.model.Playable

/// Assembles the Cast SDK `MediaLoadRequestData` that tells a receiver what to play: the stream URL, its
/// content type, the title metadata, any sidecar subtitle tracks, and the start position. This is the
/// Android analogue of the Apple external-handoff `HandoffIdentity` -- the payload that reproduces the
/// current playback on another device. The pure MIME / gating decisions live in [CastEligibility]; this
/// file only marshals them into Cast SDK objects.
object CastMediaRequest {

    /// Base id for generated subtitle tracks. Cast `MediaTrack` ids must be unique longs; the index is
    /// added so a title's N sidecar subtitles get ids BASE, BASE+1, ...
    private const val SUBTITLE_TRACK_BASE_ID = 1L

    /// Build the receiver load request for [playable], resuming at [startPositionMs] (clamped to >= 0).
    fun build(playable: Playable, startPositionMs: Long): MediaLoadRequestData {
        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, playable.title)
        }

        val subtitleTracks = playable.externalSubtitles.mapIndexed { index, url ->
            MediaTrack.Builder(SUBTITLE_TRACK_BASE_ID + index, MediaTrack.TYPE_TEXT)
                .setSubtype(MediaTrack.SUBTYPE_SUBTITLES)
                .setContentId(url)
                .setContentType(CastEligibility.subtitleContentType(url))
                .setName(subtitleName(index))
                .build()
        }

        val mediaInfo = MediaInfo.Builder(playable.url)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(CastEligibility.contentType(playable.url))
            .setMetadata(metadata)
            .apply { if (subtitleTracks.isNotEmpty()) setMediaTracks(subtitleTracks) }
            .build()

        return MediaLoadRequestData.Builder()
            .setMediaInfo(mediaInfo)
            .setAutoplay(true)
            .setCurrentTime(startPositionMs.coerceAtLeast(0L))
            .build()
    }

    private fun subtitleName(index: Int): String = "Subtitle ${index + 1}"
}
