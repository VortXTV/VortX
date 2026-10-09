package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.nzb.NzbIndexerClient
import com.vortx.android.nzb.NzbIndexerConfig
import com.vortx.android.nzb.NzbIndexerStore
import com.vortx.android.nzb.NzbRelease
import com.vortx.android.nzb.NzbSearch
import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import kotlinx.coroutines.async
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/**
 * Direct Newznab source seam. It is intentionally independent of native
 * stremio-core: external indexer groups are appended after the user's normal add-on order, and their
 * streams use the existing CoreStream-equivalent NZB fields so the ordinary Usenet resolver decides
 * availability. A search result is not a cache/readiness assertion.
 */
internal class NzbSourceAggregator(
    private val captureScope: () -> NzbIndexerStore.Scope?,
    private val readScope: (NzbIndexerStore.Scope) -> NzbIndexerStore.Read,
    private val keyFor: (String, NzbIndexerStore.Scope) -> String?,
    private val scopeCurrent: (NzbIndexerStore.Scope) -> Boolean,
    private val searchReleases: suspend (NzbIndexerConfig, String, NzbSearch) -> Result<List<NzbRelease>>,
) {
    constructor(store: NzbIndexerStore, client: NzbIndexerClient = NzbIndexerClient()) :
        this(store::captureScope, store::read, store::keyFor, store::isCurrent, client::search)

    /** Native callers capture once, before resource suspension; a null scope must never retarget. */
    fun captureNativeScope(owner: VortxNativeOwner): NzbIndexerStore.Scope? =
        captureScope()?.takeIf { nativeNzbScopeMatches(it, owner) && scopeCurrent(it) }

    suspend fun aggregate(search: NzbSearch): NzbSourceAggregation = aggregate(search, captureScope())

    suspend fun aggregate(search: NzbSearch, capturedScope: NzbIndexerStore.Scope?): NzbSourceAggregation = coroutineScope {
        val scope = capturedScope ?: return@coroutineScope NzbSourceAggregation.empty()
        val document = (readScope(scope) as? NzbIndexerStore.Read.Ready)?.document
            ?: return@coroutineScope NzbSourceAggregation.empty()
        val revision = document.revision
        val admission = NzbSearchAdmission(scope, revision)
        val indexed = document.indexers.filter { it.enabled }.map { config ->
            async {
                try {
                    val key = keyFor(config.id, scope) ?: return@async null
                    val releases = searchReleases(config, key, search).getOrNull() ?: return@async null
                    config to releases
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    null
                }
            }
        }.awaitAll().filterNotNull()
        coroutineContext.ensureActive()
        // A late result cannot admit across account/profile/config mutations.
        val current = (readScope(scope) as? NzbIndexerStore.Read.Ready)?.document
        if (!admission.accepts(scopeCurrent(scope), current?.revision, coroutineContext.isActive)) {
            return@coroutineScope NzbSourceAggregation.empty(admission)
        }
        NzbSourceAggregation(
            groups = indexed.mapNotNull { (config, releases) ->
                releases.takeIf(List<NzbRelease>::isNotEmpty)?.let { releaseList ->
                    StreamGroup(
                        addon = config.name,
                        base = "$BASE${config.id}",
                        streams = releaseList.map { release -> release.toStream(config.id, config.name) },
                    )
                }
            },
            admission = admission,
        )
    }

    /** Re-check immediately before the terminal update reaches a visible/prewarm consumer. */
    fun isAdmitted(result: NzbSourceAggregation, coroutineActive: Boolean = true): Boolean {
        val admission = result.admission ?: return result.groups.isEmpty()
        val current = (readScope(admission.scope) as? NzbIndexerStore.Read.Ready)?.document
        return admission.accepts(scopeCurrent(admission.scope), current?.revision, coroutineActive)
    }

    private fun NzbRelease.toStream(indexerId: String, indexerName: String): StreamSource {
        val handle = sha256(enclosureUrl)
        return StreamSource(
            id = "nzbindexer:$indexerId:$handle#${title.take(128)}",
            addon = indexerName,
            title = title,
            description = sizeBytes?.let(::formatSize),
            // No URL/cache state: existing `isUsenet` + nzbUrl route retains the resolver's real policy.
            // `handle` is UI identity only, never a claimed NZB/content hash or cache-readiness signal.
            nzbUrl = enclosureUrl,
            filename = title,
        )
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1_073_741_824L -> "%.1f GB".format(bytes / 1_073_741_824.0)
        bytes >= 1_048_576L -> "%.1f MB".format(bytes / 1_048_576.0)
        else -> "${bytes / 1024} KB"
    }

    private companion object { const val BASE = "nzbindexer:" }
}

/** Native account namespaces are authenticated VortX account IDs, not the currently selected streaming UID. */
internal fun nativeNzbScopeMatches(scope: NzbIndexerStore.Scope, owner: VortxNativeOwner): Boolean {
    val account = scope.owner.scope as? DebridOwnerScope.Account ?: return false
    return scope.profileId == owner.profileID && owner.scope.accountID == "account.${account.id.lowercase()}"
}

/** Only an identity-matching, approved detail and exact selected episode can authorize a direct query. */
internal fun nativeNzbSearch(detail: MetaDetail?, type: MediaType, id: String, episodeId: String?): NzbSearch? {
    if (detail == null || detail.id != id || detail.type != type || detail.name.isBlank()) return null
    val imdb = id.takeIf { NzbSearch.imdbDigits(it) != NzbSearch.INVALID_IMDB }
    val search = when (type) {
        MediaType.MOVIE -> {
            if (episodeId != null && episodeId != id) return null
            NzbSearch(detail.name, movieImdbId = imdb, year = detail.releaseInfo?.let {
                Regex("\\b(18|19|20)\\d{2}\\b").find(it)?.value?.toIntOrNull()
            })
        }
        MediaType.SERIES -> {
            val episode = detail.videos.singleOrNull { it.id == episodeId } ?: return null
            NzbSearch(detail.name, seriesImdbId = imdb, season = episode.season, episode = episode.episode)
        }
        else -> return null
    }
    return search.takeIf(NzbSearch::isValid)
}

/** A direct-source result carries the exact scope/config receipt which authorized its groups. */
internal data class NzbSourceAggregation(
    val groups: List<StreamGroup>,
    val admission: NzbSearchAdmission?,
) {
    companion object {
        fun empty(admission: NzbSearchAdmission? = null) = NzbSourceAggregation(emptyList(), admission)
    }
}

/** Pure ordering seam: core/add-on group order is never re-sorted by a direct-indexer tail. */
internal fun mergeNzbGroups(normalGroups: List<StreamGroup>, indexerGroups: List<StreamGroup>): List<StreamGroup> =
    normalGroups + indexerGroups

/** Captured source requests may publish only while their owner/profile/config and coroutine remain current. */
internal data class NzbSearchAdmission(val scope: NzbIndexerStore.Scope, val configRevision: Long) {
    fun accepts(scopeCurrent: Boolean, currentRevision: Long?, coroutineActive: Boolean): Boolean =
        scopeCurrent && currentRevision == configRevision && coroutineActive
}

/** The terminal snapshot is what CatalogRepository.streams().last() returns to NEXT prewarm. */
internal fun appendNzbGroupsAtTerminal(
    update: StreamLoadUpdate,
    result: NzbSourceAggregation,
    admissionCurrent: Boolean,
): StreamLoadUpdate = if (update.terminal && admissionCurrent && result.groups.isNotEmpty()) {
    update.copy(groups = mergeNzbGroups(update.groups, result.groups))
} else {
    update
}
