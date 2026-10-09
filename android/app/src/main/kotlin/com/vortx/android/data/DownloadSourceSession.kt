package com.vortx.android.data

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource

/** One owner-captured batch fetch channel. Closing it does not retire already pinned transfers. */
interface DownloadSourceSession : AutoCloseable {
    val owner: ContinueWatchingOwner

    suspend fun streams(
        type: MediaType,
        id: String,
        episode: Episode? = null,
        rememberedQuality: String? = null,
        wantedAddon: String? = null,
    ): Result<List<StreamGroup>>

    /** Only the exact source object emitted by this session can be pinned, while the session is open. */
    fun pin(source: StreamSource, episode: Episode? = null): DownloadSourceResolver?

    override fun close()
}

/**
 * Immutable source and owner authority retained by one queue item, including across pause/resume.
 * Every resolution owns its returned playback lease; the transfer must close it when finished.
 */
interface DownloadSourceResolver {
    val owner: ContinueWatchingOwner
    suspend fun resolve(): Result<Playable>
    fun isCurrent(): Boolean

    /** Atomically admit a synchronous queue mutation; action failures propagate, stale ownership returns false. */
    fun admit(action: () -> Unit): Boolean
}
