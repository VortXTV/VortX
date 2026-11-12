package com.vortx.android.tv

import android.content.Context
import android.media.tv.TvContract.BaseTvColumns.COLUMN_PACKAGE_NAME
import android.media.tv.TvContract.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID
import android.net.Uri
import android.provider.BaseColumns._ID
import android.util.AtomicFile
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.home.continueWatchingOwnerIsKnown
import com.vortx.android.model.MediaType
import java.io.DataInputStream
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.SecureRandom

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
 * Provider errors leave the in-app history untouched. The publisher owns only its own package's
 * namespaced rows. A durable owner stamp lets account changes retire old rows before native opens,
 * and lets an exact native mount retire rows for a prior profile or account binding before reading CW.
 */
object WatchNextPublisher {
    private const val MAX_ROWS = 8
    private const val KEY_BYTES = 32
    private val mutationLock = Any()
    private var preparedOwner: WatchNextOwnerStamp? = null

    /** One Continue Watching entry to mirror onto the Play Next row. */
    data class Item(
        val type: MediaType,
        val id: String,
        val title: String,
        val poster: String?,
        val resumeSeconds: Double?,
        val progress: Float?,
    )

    /** Account truth is sufficient only for a recognized, same-installation account stamp. */
    internal fun retireOtherAccounts(
        context: Context, accountId: String, admit: (() -> Boolean) -> Boolean,
    ): Boolean = synchronized(mutationLock) {
        runCatching {
            val key = readKey(context) ?: return@synchronized true
            val account = try { WatchNextRowIdentity.account(key, accountId) } finally { key.fill(0) }
            val rows = ownedRows(context) ?: return@synchronized false
            for (row in rows) {
                if (WatchNextRowIdentity.belongsToOtherAccount(row.providerId, account) &&
                    !admit { deleteRow(context, row.id) }
                ) return@synchronized false
            }
            true
        }.getOrDefault(false)
    }

    /**
     * Prune before reading Continue Watching. Without a readable key, a completed mount may retire
     * unbound rows, but an unreadable key is never overwritten. Creation follows confirmed absence.
     */
    internal fun prepareMountedOwner(
        context: Context, identity: WatchNextOwnerIdentity, admit: (() -> Boolean) -> Boolean,
    ): WatchNextOwnerStamp? = synchronized(mutationLock) {
        runCatching {
            if (!TopShelfSettings.showContinueWatching(context)) return@synchronized null
            val stored = runCatching { readKey(context) }
            val key = stored.getOrNull()
            var owner = key?.let {
                try { WatchNextRowIdentity.owner(it, identity) } finally { it.fill(0) }
            }
            if (owner != null && preparedOwner == owner) return@synchronized owner
            val rows = ownedRows(context) ?: return@synchronized null
            for (row in rows) {
                if (WatchNextRowIdentity.belongsOutsideMount(row.providerId, owner) &&
                    !admit { deleteRow(context, row.id) }
                ) return@synchronized null
            }
            if (owner == null) {
                if (stored.isFailure || !admit {
                        val created = createKey(context)
                        owner = try { WatchNextRowIdentity.owner(created, identity) } finally { created.fill(0) }
                        true
                    }
                ) return@synchronized null
            }
            preparedOwner = owner
            owner
        }.getOrNull()
    }

    /** Query before entering owner fences, then admit each provider write independently. */
    internal fun publish(
        context: Context, owner: WatchNextOwnerStamp, items: List<Item>, admit: (() -> Boolean) -> Boolean,
    ): Boolean = synchronized(mutationLock) {
        runCatching {
            fun mutate(write: () -> Boolean): Boolean = TopShelfSettings.showContinueWatching(context) && admit(write)
            fun providerId(item: Item): String = WatchNextRowIdentity.providerId(owner, item.type.id, item.id)
            if (!TopShelfSettings.showContinueWatching(context)) return@synchronized false
            val desired = items
                .filter { it.id.isNotBlank() && (it.type == MediaType.MOVIE || it.type == MediaType.SERIES) }
                .distinctBy(::providerId)
                .take(MAX_ROWS)
            val owned = ownedRows(context) ?: return@synchronized false
            val desiredIds = desired.mapTo(HashSet(), ::providerId)
            val existing = HashMap<String, Long>()
            for (row in owned) {
                val remove = WatchNextRowIdentity.belongsOutsideMount(row.providerId, owner) ||
                    (row.providerId in desiredIds && existing.putIfAbsent(row.providerId, row.id) != null) ||
                    (WatchNextRowIdentity.belongsToMount(row.providerId, owner) && row.providerId !in desiredIds)
                if (remove && !mutate { deleteRow(context, row.id) }) return@synchronized false
            }
            // Decreasing engagement time preserves the incoming order (most-recent first).
            val now = System.currentTimeMillis()
            desired.forEachIndexed { index, item ->
                val id = providerId(item)
                if (!mutate { upsert(context, item, id, existing[id], engagementTime = now - index) }) {
                    return@synchronized false
                }
            }
            true
        }.getOrDefault(false)
    }

    /** Remove app-owned rows for an explicit opt-out, even when account storage is unavailable. */
    internal fun clearWhenDisabled(context: Context) {
        synchronized(mutationLock) {
            runCatching {
                if (!TopShelfSettings.showContinueWatching(context)) {
                    preparedOwner = null
                    ownedRows(context)?.forEach { runCatching { deleteRow(context, it.id) } }
                }
            }
        }
    }

    /** A completed sign-out retires prior app-owned rows even when a native roster is absent. */
    internal fun clearAfterSignOut(context: Context, admit: (() -> Boolean) -> Boolean) {
        runCatching {
            val owned = synchronized(mutationLock) { ownedRows(context) } ?: return
            for (row in owned) {
                val current = synchronized(mutationLock) {
                    admit {
                        // One failed row must not prevent retirement of other old-owner rows.
                        preparedOwner = null
                        runCatching { deleteRow(context, row.id) }
                        true
                    }
                }
                if (!current) return
            }
        }
    }

    // ---- internals ----

    private fun deepLink(item: Item): String =
        "vortx://open?type=${item.type.id}&id=${Uri.encode(item.id)}"

    private data class OwnedRow(val providerId: String, val id: Long)

    private fun ownedRows(context: Context): List<OwnedRow>? {
        val columns = arrayOf(_ID, COLUMN_PACKAGE_NAME, COLUMN_INTERNAL_PROVIDER_ID)
        return context.contentResolver.query(TvContractCompat.WatchNextPrograms.CONTENT_URI, columns,
            null, null, null)?.use { cursor ->
            val rowId = cursor.getColumnIndexOrThrow(_ID)
            val rowPackage = cursor.getColumnIndexOrThrow(COLUMN_PACKAGE_NAME)
            val rowProviderId = cursor.getColumnIndexOrThrow(COLUMN_INTERNAL_PROVIDER_ID)
            buildList {
                while (cursor.moveToNext()) {
                    val id = cursor.getString(rowProviderId)
                    if (cursor.getString(rowPackage) == context.packageName && id != null &&
                        id.startsWith(WatchNextRowIdentity.PREFIX) && !cursor.isNull(rowId)
                    ) add(OwnedRow(id, cursor.getLong(rowId)))
                }
            }
        }
    }

    private fun keyFile(context: Context) = AtomicFile(File(context.noBackupFilesDir, "watch-next-owner-key-v1"))

    /** An inaccessible file is not absent. AtomicFile may recover its committed .bak on open. */
    private fun readKey(context: Context): ByteArray? {
        val file = keyFile(context)
        return try {
            file.openRead().use { input ->
                val key = ByteArray(KEY_BYTES)
                try {
                    DataInputStream(input).readFully(key)
                    check(input.read() == -1) { "Invalid Play Next owner key" }
                    key
                } catch (error: Exception) {
                    key.fill(0)
                    throw error
                }
            }
        } catch (error: FileNotFoundException) {
            if (!Files.notExists(file.baseFile.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                !Files.notExists(File(file.baseFile.path + ".bak").toPath(), LinkOption.NOFOLLOW_LINKS)
            ) throw error
            null
        }
    }

    private fun createKey(context: Context): ByteArray {
        val file = keyFile(context)
        val key = ByteArray(KEY_BYTES).also(SecureRandom()::nextBytes)
        try {
            val output = file.startWrite()
            try {
                output.write(key)
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            val observed = checkNotNull(readKey(context))
            if (!observed.contentEquals(key)) {
                observed.fill(0)
                error("Play Next owner key could not be verified")
            }
            return observed
        } finally {
            key.fill(0)
        }
    }

    private fun upsert(
        context: Context, item: Item, providerId: String, existingRowId: Long?, engagementTime: Long,
    ): Boolean {
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
            .setInternalProviderId(providerId)
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
