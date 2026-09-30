package com.vortx.android.downloads

import java.io.File

/**
 * Small, injectable file/index transaction used by watched-download reclaim.
 *
 * The completed media first moves to an adjacent tombstone. Only after the reduced index has been
 * atomically persisted is the tombstone unlinked. If the index write fails the media is renamed back;
 * a failed rollback is intentionally left as a recoverable tombstone for the next store hydration.
 */
internal class DownloadReclaimTransaction(
    private val fileOps: FileOps = SystemFileOps,
) {
    interface FileOps {
        fun exists(file: File): Boolean
        fun isFile(file: File): Boolean
        fun rename(source: File, destination: File): Boolean
        fun delete(file: File): Boolean
    }

    object SystemFileOps : FileOps {
        override fun exists(file: File): Boolean = file.exists()
        override fun isFile(file: File): Boolean = file.isFile
        override fun rename(source: File, destination: File): Boolean = source.renameTo(destination)
        override fun delete(file: File): Boolean = file.delete()
    }

    enum class Result {
        RECLAIMED,
        FILE_RENAME_FAILED,
        INDEX_WRITE_FAILED_ROLLED_BACK,
        INDEX_WRITE_FAILED_RECOVERY_REQUIRED,
    }

    fun reclaim(
        mediaFile: File,
        tombstoneFile: File,
        stalePartFile: File,
        persistIndexWithoutRecord: () -> Boolean,
    ): Result {
        val movedToTombstone = fileOps.exists(mediaFile)
        if (movedToTombstone) {
            if (!fileOps.isFile(mediaFile) || fileOps.exists(tombstoneFile) || !fileOps.rename(mediaFile, tombstoneFile)) {
                return Result.FILE_RENAME_FAILED
            }
        }

        if (!persistIndexWithoutRecord()) {
            if (!movedToTombstone || fileOps.rename(tombstoneFile, mediaFile)) {
                return Result.INDEX_WRITE_FAILED_ROLLED_BACK
            }
            return Result.INDEX_WRITE_FAILED_RECOVERY_REQUIRED
        }

        // These are bounded, same-record cleanup attempts. A failure leaves only a hidden tombstone/part;
        // hydration will retry it and never recreates a playable index row for either artifact.
        if (movedToTombstone) fileOps.delete(tombstoneFile)
        if (fileOps.exists(stalePartFile)) fileOps.delete(stalePartFile)
        return Result.RECLAIMED
    }

    /** Complete an interrupted transaction during store hydration. Returns false only for retryable I/O failure. */
    fun recoverTombstone(mediaFile: File, tombstoneFile: File, indexStillHasRecord: Boolean): Boolean {
        if (!fileOps.exists(tombstoneFile)) return true
        return if (indexStillHasRecord && !fileOps.exists(mediaFile)) {
            fileOps.rename(tombstoneFile, mediaFile)
        } else {
            fileOps.delete(tombstoneFile)
        }
    }
}
