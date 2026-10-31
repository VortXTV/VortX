package com.vortx.android.data

import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.flow.Flow

/** Optional isolated source consumer. Never implement this with concurrent ordinary streams/resolve. */
interface SourcePreparation : AutoCloseable {
    val owner: ContinueWatchingOwner
    val groups: List<StreamGroup>
    /** Stable repository-owned identity retained when this exact context is adopted by the foreground. */
    val sourcePublicationId: String? get() = null
    fun isCurrent(): Boolean
    /** Single collection; the caller supplies its complete preparation timeout. */
    fun updates(): Flow<StreamLoadUpdate>
    suspend fun resolve(source: StreamSource): Result<Playable>
    /** Transfers bindings to the foreground without refetching; null means expired/already consumed. */
    fun adopt(): SourcePreparationAdoption?
    /** Discards only unadopted context. An adopted context belongs to the repository. */
    override fun close()
}

/** Exact rollback for a host rejection before publication; never invoke after host acknowledgment. */
interface SourcePreparationAdoption {
    val groups: List<StreamGroup>
    val sourcePublicationId: String? get() = null
    fun rollback()
    /** Non-throwing cleanup after the host has acknowledged the adopted playback publication. */
    fun commitPublished() {}
}
