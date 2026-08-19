package com.vortx.android.tv

import android.content.Context
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import com.vortx.android.model.MediaType

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
     * Reconcile the Play Next row with [items]. When the Show Continue Watching setting is off, this clears
     * every owned row instead. Only movie/series entries with a non-blank id are published (the deep link and
     * WatchNext type are defined for those); channels and blanks are dropped.
     */
    fun publish(context: Context, items: List<Item>) {
        runCatching {
            if (!TopShelfSettings.showContinueWatching(context)) {
                clearOwnedRows(context)
                return
            }
            val desired = items
                .filter { it.id.isNotBlank() && (it.type == MediaType.MOVIE || it.type == MediaType.SERIES) }
                .distinctBy(::internalId)
                .take(MAX_ROWS)
            val owned = ownedRows(context)
            val desiredIds = desired.mapTo(HashSet(), ::internalId)
            owned.forEach { (providerId, rowId) -> if (providerId !in desiredIds) deleteRow(context, rowId) }
            // Decreasing engagement time preserves the incoming order (most-recent first) on the home row.
            val now = System.currentTimeMillis()
            desired.forEachIndexed { index, item ->
                upsert(context, item, owned[internalId(item)], engagementTime = now - index)
            }
        }
    }

    /** Remove every Play Next row this app owns (used on disable and on an empty Continue Watching list). */
    fun clearOwnedRows(context: Context) {
        runCatching { ownedRows(context).values.forEach { deleteRow(context, it) } }
    }

    // ---- internals ----

    private fun internalId(item: Item): String = "$INTERNAL_ID_PREFIX${item.type.id}:${item.id}"

    private fun deepLink(item: Item): String =
        "vortx://open?type=${item.type.id}&id=${Uri.encode(item.id)}"

    /** internalProviderId -> WatchNext row id, for the rows this app authored. */
    private fun ownedRows(context: Context): Map<String, Long> {
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
        }
        return out
    }

    private fun upsert(context: Context, item: Item, existingRowId: Long?, engagementTime: Long) {
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
        if (existingRowId != null) {
            context.contentResolver.update(
                TvContractCompat.buildWatchNextProgramUri(existingRowId),
                values,
                null,
                null,
            )
        } else {
            context.contentResolver.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, values)
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

    private fun deleteRow(context: Context, rowId: Long) {
        runCatching {
            context.contentResolver.delete(TvContractCompat.buildWatchNextProgramUri(rowId), null, null)
        }
    }
}
