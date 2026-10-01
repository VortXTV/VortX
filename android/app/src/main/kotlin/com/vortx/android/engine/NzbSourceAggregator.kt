package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.nzb.NzbIndexerClient
import com.vortx.android.nzb.NzbIndexerStore
import com.vortx.android.nzb.NzbRelease
import com.vortx.android.nzb.NzbSearch
import kotlinx.coroutines.async
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
    private val store: NzbIndexerStore,
    private val client: NzbIndexerClient = NzbIndexerClient(),
) {
    suspend fun aggregate(search: NzbSearch): NzbSourceAggregation = coroutineScope {
        val scope = store.captureScope() ?: return@coroutineScope NzbSourceAggregation.empty()
        val document = (store.read(scope) as? NzbIndexerStore.Read.Ready)?.document
            ?: return@coroutineScope NzbSourceAggregation.empty()
        val revision = document.revision
        val admission = NzbSearchAdmission(scope, revision)
        val indexed = document.indexers.filter { it.enabled }.map { config ->
            async {
                val key = store.keyFor(config.id, scope) ?: return@async null
                val releases = client.search(config, key, search).getOrNull() ?: return@async null
                config to releases
            }
        }.awaitAll().filterNotNull()
        coroutineContext.ensureActive()
        // A late result cannot admit across account/profile/config mutations.
        val current = (store.read(scope) as? NzbIndexerStore.Read.Ready)?.document
        if (!admission.accepts(store.isCurrent(scope), current?.revision, coroutineContext.isActive)) {
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
        val current = (store.read(admission.scope) as? NzbIndexerStore.Read.Ready)?.document
        return admission.accepts(store.isCurrent(admission.scope), current?.revision, coroutineActive)
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
