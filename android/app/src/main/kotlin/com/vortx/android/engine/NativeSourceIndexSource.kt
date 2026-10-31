package com.vortx.android.engine

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexAuthorization
import com.vortx.android.singularity.SourceIndexClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** One application-owned participant; it cannot attach arbitrary UI streams or issue playback tokens. */
internal class NativeSourceIndexSource(
    private val scope: CoroutineScope,
    private val captureAuthorization: (VortxNativeSession, VortxNativeOwner) -> SourceIndexAuthorization?,
    private val fetch: suspend (String, SourceIndexAuthorization) -> List<SourceIndexClient.PooledSource> =
        SourceIndexClient::fetchPooledAuthorized,
    private val contribute: suspend (String, List<SourceIndexClient.Descriptor>, SourceIndexAuthorization) -> Unit =
        SourceIndexClient::hoardAuthorized,
) {
    fun capture(session: VortxNativeSession, owner: VortxNativeOwner): SourceIndexAuthorization? =
        runCatching { captureAuthorization(session, owner)?.takeIf { it.isCurrent() } }.getOrNull()

    fun launch(start: CoroutineStart = CoroutineStart.DEFAULT, action: suspend () -> Unit): Job =
        scope.launch(Dispatchers.IO, start = start) { action() }
    fun retire(authorization: SourceIndexAuthorization?) { authorization?.closeDeferred() }

    suspend fun load(target: NativeSourceIndexTarget, authorization: SourceIndexAuthorization): NativeSourceIndexResult? {
        if (!authorization.isCurrent()) return null
        val pooled = fetch(target.contentId, authorization)
        if (!authorization.isCurrent()) return null
        val streams = SourceIndexClient.streams(pooled)
        if (!authorization.isCurrent()) return null
        return NativeSourceIndexResult(target, authorization, streams)
    }

    suspend fun hoard(target: NativeSourceIndexTarget, descriptors: List<SourceIndexClient.Descriptor>, authorization: SourceIndexAuthorization) {
        if (authorization.isCurrent()) contribute(target.contentId, descriptors, authorization)
    }
}

/** Canonical query identity comes only from fresh, policy-approved metadata for this exact request. */
internal data class NativeSourceIndexTarget(
    val type: MediaType, val id: String, val episodeId: String?, val contentId: String,
    val season: Int? = null, val episode: Int? = null,
)

internal fun nativeSourceIndexTarget(detail: MetaDetail?, type: MediaType, id: String,
    episodeId: String?, expectedEpisode: Episode? = null): NativeSourceIndexTarget? {
    if (detail == null || detail.id != id || detail.type != type ||
        !Regex("^(tt[0-9]{6,10}|tmdb:[0-9]{1,10})$").matches(id)) return null
    return when (type) {
        MediaType.MOVIE -> if (episodeId != null && episodeId != id) null
            else NativeSourceIndexTarget(type, id, episodeId, id)
        MediaType.SERIES -> {
            val selected = detail.videos.singleOrNull { it.id == episodeId } ?: return null
            if (expectedEpisode != null && (selected.id != expectedEpisode.id || selected.season != expectedEpisode.season ||
                    selected.episode != expectedEpisode.episode)) return null
            val canonical = SourceIndexClient.canonicalContentId("$id:${selected.season}:${selected.episode}") ?: return null
            NativeSourceIndexTarget(type, id, episodeId, canonical, selected.season, selected.episode)
        }
        else -> null
    }
}

/** The admission stays private to its source context, including after its finite loading flow completes. */
internal class NativeSourceIndexResult(
    val target: NativeSourceIndexTarget,
    private val authorization: SourceIndexAuthorization,
    private val sources: List<StreamSource>,
) {
    private val membership = sources.toHashSet()
    fun isCurrent(expected: NativeSourceIndexTarget?): Boolean = expected == target && authorization.isCurrent()
    fun isRetired(expected: NativeSourceIndexTarget?): Boolean = expected != target || authorization.isRetired()
    fun groups(): List<StreamGroup> = if (sources.isEmpty()) emptyList() else
        listOf(StreamGroup(SourceIndexClient.GROUP_ADDON, sources, SourceIndexClient.GROUP_ID))
    fun binding(source: StreamSource): NativeSourceIndexBinding? =
        source.takeIf { it in membership }?.let { NativeSourceIndexBinding(this, it) }
}

/** Presentation/cache decoration is allowed; all transport, selector and provenance fields stay exact. */
internal class NativeSourceIndexBinding(private val result: NativeSourceIndexResult, private val expected: StreamSource) {
    fun isRetired(): Boolean = result.isRetired(result.target)
    fun accepts(source: StreamSource, target: NativeSourceIndexTarget?): Boolean = result.isCurrent(target) &&
        source.copy(title = expected.title, description = expected.description, quality = expected.quality,
            accountConfirmedCacheRevision = null, nativePlaybackToken = null) == expected
}
