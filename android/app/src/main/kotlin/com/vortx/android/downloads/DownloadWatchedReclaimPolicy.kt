package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.PlaybackContext

/**
 * Immutable evidence handed back by a LOCAL player session only after its exact watched write has
 * committed and its decoder has released the file. This is deliberately not a timer/progress heuristic:
 * the history owner owns the durable-watch decision; downloads only validates that the requested local
 * row is the same media before reclaiming its bytes.
 *
 * [localFileUri] must be the `file:` URI passed to the player. It binds the request to one physical
 * managed file as well as the title identity, so a delayed event for one episode cannot select another
 * completed row with coincidentally similar metadata.
 */
data class WatchedDownloadReclaimRequest(
    val owner: PlaybackContext.Owner,
    val contentId: String,
    val videoId: String,
    val type: String,
    val title: String,
    val season: Int?,
    val episode: Int?,
    val localFileUri: String,
) {
    companion object {
        fun from(context: PlaybackContext, localFileUri: String): WatchedDownloadReclaimRequest =
            WatchedDownloadReclaimRequest(
                owner = context.owner,
                contentId = context.contentId,
                videoId = context.videoId,
                type = context.type,
                title = context.title,
                season = context.season,
                episode = context.episode,
                localFileUri = localFileUri,
            )
    }
}

/** Observable result for the one destructive operation. Callers must not retry a failed result blindly. */
enum class WatchedDownloadReclaimResult {
    DISABLED,
    INVALID_REQUEST,
    NO_MATCHING_COMPLETED_DOWNLOAD,
    FILE_RENAME_FAILED,
    INDEX_WRITE_FAILED_ROLLED_BACK,
    INDEX_WRITE_FAILED_RECOVERY_REQUIRED,
    RECLAIMED,
}

/** Side-effect-free selector; every identity field is deliberately exact (including nullable episode fields). */
internal object DownloadWatchedReclaimPolicy {
    fun matchingCompletedRecord(
        enabled: Boolean,
        request: WatchedDownloadReclaimRequest,
        records: List<DownloadRecord>,
        hasMatchingManagedFile: (DownloadRecord) -> Boolean,
    ): DownloadRecord? {
        if (!enabled || request.owner.profileId.isBlank() || !request.localFileUri.startsWith("file:")) return null
        return records.singleOrNull { record ->
            record.state == DownloadState.COMPLETED &&
                record.contentId == request.contentId &&
                record.videoId == request.videoId &&
                record.type == request.type &&
                record.name == request.title &&
                record.season == request.season &&
                record.episode == request.episode &&
                hasMatchingManagedFile(record)
        }
    }
}
