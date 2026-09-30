package com.vortx.android.downloads

import java.io.File

/**
 * Carries whether an index was actually decoded. Empty records are trustworthy only after [Loaded]; an absent,
 * unreadable, or malformed index must never authorize cleanup of recoverable media artifacts.
 */
internal object DownloadIndexHydration {
    sealed class Receipt<out T> {
        data object Missing : Receipt<Nothing>()
        data object Unreadable : Receipt<Nothing>()
        data class Loaded<T>(val value: T) : Receipt<T>()
    }

    fun <T> read(indexFile: File, readAndDecode: (File) -> T): Receipt<T> {
        if (!indexFile.exists()) return Receipt.Missing
        if (!indexFile.isFile) return Receipt.Unreadable
        return runCatching { Receipt.Loaded(readAndDecode(indexFile)) }
            .getOrElse { Receipt.Unreadable }
    }
}
