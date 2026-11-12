package com.vortx.android.tv

import android.content.Context
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.home.continueWatchingOwnerIsKnown
import com.vortx.android.model.MediaType

internal data class WatchNextPublication(
    val owner: ContinueWatchingOwner,
    val items: List<WatchNextPublisher.Item>,
)

/** A failed local read leaves the launcher alone. An authoritative empty read can clear it. */
internal fun watchNextPublication(
    expectedOwner: ContinueWatchingOwner,
    snapshot: Result<ContinueWatchingSnapshot>,
): WatchNextPublication? {
    if (!continueWatchingOwnerIsKnown(expectedOwner, expectedOwner.profileId)) return null
    val current = snapshot.getOrNull()?.takeIf { it.owner == expectedOwner } ?: return null
    val items = current.items.filterNot { it.watched }.map {
        WatchNextPublisher.Item(it.type, it.id, it.name, it.poster, it.resumeSeconds, it.progress)
    }
    return WatchNextPublication(expectedOwner, items)
}

/**
 * Publishes profile-aware Continue Watching onto the Android TV home "Play Next" row (TV-2), the Android
 * analogue of Apple's Top Shelf `TopShelfSnapshotWriter`. The rows are WatchNext programs written into the
 * system TvProvider; clicking one fires the app's own `vortx://open` deep link (TV-1), which resumes the
 * title.
 *
 * FAIL-SOFT IS THE WHOLE CONTRACT. Every ContentResolver call is wrapped: on a phone (no system TvProvider),
 * on a locked-down device, or on any provider error, publishing degrades to a no-op and never crashes the
 * caller. It is safe to call from any device; the caller does not gate on "is this a TV".
 *
 * RECONCILE, NOT APPEND. Each [publish] computes the desired row set (capped at [MAX_ROWS], newest first),
 * upserts each by its stable [internalId], and DELETES any row this app previously owned that is no longer in
 * the set. Turning the setting off, or an empty Continue Watching list, clears every owned row. Rows authored
 * by anything other than this app (a different `internalProviderId` prefix) are never touched.
 */
object WatchNextPublisher {

    private const val MAX_ROWS = 8
    private val mutationLock = Any()

    /** The `internalProviderId` namespace for the rows this app owns, so reconcile never touches foreign rows. */
    private const val INTERNAL_ID_PREFIX = "vortx-cw:"

    /** One Continue Watching entry to mirror onto the Play Next row. */
    data class Item(
        val type: MediaType,
        val id: String,
        val title: String,
        val poster: String?,
        val resumeSeconds: Double?,
        val progress: Float?,
    )

    /**
     * Reconcile on a worker. Query before entering the owner fence, then admit each provider write
     * independently. A profile change during a slow query cannot authorize that query's old rows.
     */
    internal fun publish(context: Context, items: List<Item>, admit: (() -> Boolean) -> Boolean): Boolean =
        runCatching {
            fun mutate(write: () -> Boolean): Boolean = synchronized(mutationLock) {
                TopShelfSettings.showContinueWatching(context) && admit(write)
            }
            if (!TopShelfSettings.showContinueWatching(context)) return false
            val desired = items
                .filter { it.id.isNotBlank() && (it.type == MediaType.MOVIE || it.type == MediaType.SERIES) }
                .distinctBy(::internalId)
                .take(MAX_ROWS)
            val owned = synchronized(mutationLock) { ownedRows(context) } ?: return false
            val desiredIds = desired.mapTo(HashSet(), ::internalId)
            owned.forEach { (providerId, rowId) ->
                if (providerId !in desiredIds && !mutate { deleteRow(context, rowId) }) return false
            }
            // Decreasing engagement time preserves the incoming order (most-recent first) on the home row.
            val now = System.currentTimeMillis()
            desired.forEachIndexed { index, item ->
                if (!mutate { upsert(context, item, owned[internalId(item)], engagementTime = now - index) }) return false
            }
            true
        }.getOrDefault(false)

    /** Remove app-owned rows for an explicit opt-out, even when account storage is unavailable. */
    internal fun clearWhenDisabled(context: Context) {
        synchronized(mutationLock) {
            runCatching {
                if (!TopShelfSettings.showContinueWatching(context)) {
                    ownedRows(context)?.values?.forEach { runCatching { deleteRow(context, it) } }
                }
            }
        }
    }

    /** A completed sign-out retires prior app-owned rows even when a native roster is absent. */
    internal fun clearAfterSignOut(context: Context, admit: (() -> Boolean) -> Boolean) {
        runCatching {
            val owned = synchronized(mutationLock) { ownedRows(context) } ?: return
            for (rowId in owned.values) {
                val current = synchronized(mutationLock) {
                    admit {
                        // One failed row must not prevent retirement of other old-owner rows.
                        runCatching { deleteRow(context, rowId) }
                        true
                    }
                }
                if (!current) return
            }
        }
    }

    // ---- internals ----

    private fun internalId(item: Item): String = "$INTERNAL_ID_PREFIX${item.type.id}:${item.id}"

    private fun deepLink(item: Item): String =
        "vortx://open?type=${item.type.id}&id=${Uri.encode(item.id)}"

    /** internalProviderId -> WatchNext row id, for the rows this app authored. */
    private fun ownedRows(context: Context): Map<String, Long>? {
        val out = LinkedHashMap<String, Long>()
        context.contentResolver.query(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            WatchNextProgram.PROJECTION,
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                do {
                    val program = WatchNextProgram.fromCursor(cursor)
                    val providerId = program.internalProviderId
                    if (providerId != null && providerId.startsWith(INTERNAL_ID_PREFIX)) {
                        out[providerId] = program.id
                    }
                } while (cursor.moveToNext())
            }
        } ?: return null
        return out
    }

    private fun upsert(context: Context, item: Item, existingRowId: Long?, engagementTime: Long): Boolean {
        val builder = WatchNextProgram.Builder()
            .setType(
                if (item.type == MediaType.MOVIE) {
                    TvContractCompat.WatchNextPrograms.TYPE_MOVIE
                } else {
                    TvContractCompat.WatchNextPrograms.TYPE_TV_SERIES
                },
            )
            .setWatchNextType(TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
            .setTitle(item.title.ifBlank { "Continue watching" })
            .setInternalProviderId(internalId(item))
            .setIntentUri(Uri.parse(deepLink(item)))
            .setLastEngagementTimeUtcMillis(engagementTime)

        item.poster?.takeIf { it.isNotBlank() }?.let { builder.setPosterArtUri(Uri.parse(it)) }

        // The resume stripe needs BOTH a position and a duration. MetaItem carries the position (resumeSeconds)
        // and the fraction (progress), so the duration is derived; when either is missing the row still shows,
        // just without the stripe.
        val positionMillis = item.resumeSeconds?.takeIf { it > 0.0 }?.let { (it * 1000).toLong() }
        val durationMillis = resumeDurationMillis(item)
        if (positionMillis != null && durationMillis != null && positionMillis < durationMillis) {
            builder.setLastPlaybackPositionMillis(positionMillis.toInt())
            builder.setDurationMillis(durationMillis.toInt())
        }

        val values = builder.build().toContentValues()
        return if (existingRowId != null) {
            context.contentResolver.update(
                TvContractCompat.buildWatchNextProgramUri(existingRowId),
                values,
                null,
                null,
            ) > 0
        } else {
            context.contentResolver.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, values) != null
        }
    }

    private fun resumeDurationMillis(item: Item): Long? {
        val seconds = item.resumeSeconds ?: return null
        val progress = item.progress ?: return null
        if (progress <= 0f || progress >= 1f) return null
        val total = seconds / progress
        if (!total.isFinite() || total <= 0.0) return null
        return (total * 1000).toLong()
    }

    private fun deleteRow(context: Context, rowId: Long): Boolean {
        context.contentResolver.delete(TvContractCompat.buildWatchNextProgramUri(rowId), null, null)
        return true
    }
}
