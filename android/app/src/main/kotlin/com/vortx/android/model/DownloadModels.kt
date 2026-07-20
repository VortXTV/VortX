package com.vortx.android.model

import java.util.UUID

/**
 * Offline downloads: the device-local data model. The Android port of Apple
 * `app/SourcesShared/DownloadModels.swift`. A download is a physical file on ONE device plus a row in the
 * local index: it is NEVER account-synced and NEVER written into a `libraryItem` document.
 *
 * The iOS-only HLS `.movpkg` branch (`hlsRelativePath` / `isHLSOffline`) is intentionally omitted (Android
 * has no `AVAssetDownloadTask`). The Apple `playbackMeta` convenience is also omitted for now because
 * `PlaybackMeta` is not yet ported to Android; the ids needed to rebuild it (`contentId` / `videoId` /
 * `type` / `season` / `episode`) are all retained so a later round can add it without a schema change.
 */

/** Lifecycle of one download. Wire strings match Apple's `DownloadState` rawValues. */
enum class DownloadState(val wireValue: String) {
    QUEUED("queued"),
    DOWNLOADING("downloading"),
    PAUSED("paused"),
    COMPLETED("completed"),
    FAILED("failed");

    companion object {
        fun fromWire(raw: String?): DownloadState = entries.firstOrNull { it.wireValue == raw } ?: QUEUED
    }
}

/**
 * One offline download. All playback-relevant ids ([contentId] / [videoId] / [type] / [season] / [episode])
 * are the SAME values the streaming play path uses, so the engine records progress against the right library
 * item and Continue Watching keeps working for a downloaded title exactly as for a streamed one.
 */
data class DownloadRecord(
    /** Stable id; also the on-disk filename stem (`<id>.<ext>`). */
    val id: String = UUID.randomUUID().toString(),

    /** The movie/series id (the libraryItem `_id`). For a movie this equals [videoId]; for an episode it is the series id. */
    val contentId: String,
    /** The movie id, or `imdbId:season:episode` for an episode. */
    val videoId: String,
    /** "movie" | "series" (an episode download carries "series", matching the streaming episode play path). */
    val type: String,

    val name: String,
    val poster: String? = null,
    val season: Int? = null,
    val episode: Int? = null,

    /** The add-on / source label this download came from (`stream.name`), for display. */
    val sourceName: String? = null,
    /** Quality signature shown on the row + re-recorded on play, so a CW resume keeps quality continuity. */
    val qualityText: String? = null,

    /**
     * True when this was a torrent-to-disk download. A *finished* download always plays from the LOCAL file;
     * this flag only records HOW it was fetched.
     */
    val isTorrent: Boolean = false,

    /** `behaviorHints.proxyHeaders.request` the source declared, applied to the download request (some CDNs 403 without them). */
    val headers: Map<String, String>? = null,

    /** The resolved remote URL the download fetched. Kept for diagnostics; playback never uses it once completed. */
    val remoteURL: String,

    /** On-disk filename (`<id>.<ext>`), relative to the Downloads directory. The absolute path is rebuilt on demand. */
    val localFilename: String,

    val bytesTotal: Long = 0,
    val bytesDone: Long = 0,
    val state: DownloadState = DownloadState.QUEUED,
    /** Creation time, epoch millis (device-local; never cross-platform-synced). */
    val addedAt: Long = System.currentTimeMillis(),
    /** Human-readable failure reason when [state] == [DownloadState.FAILED]; null otherwise. */
    val errorText: String? = null,
    /** Honest note that this record is a batch auto-retry (an earlier source failed and the next-best was swapped in). */
    val retryNote: String? = null,
    /** The live transfer task id filling this record, persisted so a relaunch can re-wire pause/cancel. A RECONNECT HINT only. */
    val taskIdentifier: Int? = null,
) {
    /** Display title, episode-aware (matches the streaming episode title format). */
    val displayTitle: String
        get() = if (type == "series" && season != null && episode != null) "$name  ·  S${season}E$episode" else name

    /** 0..1 download progress; 0 until a total is known (a torrent's total is unknown up front). */
    val fractionComplete: Double
        get() = if (bytesTotal > 0) (bytesDone.toDouble() / bytesTotal.toDouble()).coerceIn(0.0, 1.0) else 0.0
}
