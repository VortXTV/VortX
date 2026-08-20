package com.vortx.android.sync

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.backup.SettingsBackup
import org.json.JSONObject
import java.util.UUID

/**
 * Account-scoped, replay-safe ownership records for the syncable settings domain.
 *
 * The settings plist alone cannot represent an intentional clear: a missing key could mean either
 * "this client has never seen it" or "the user deliberately removed it".  This ledger carries that
 * distinction alongside a total-order stamp.  A local dirty entry wins while it is waiting to be
 * published; once acknowledged, normal stamp ordering converges every device on the same value or
 * tombstone.  It is deliberately separate from the plist so older clients can safely ignore it.
 */
internal class SettingsSyncLedger(context: Context) {
    data class Stamp(
        val clock: Long,
        val device: String,
        val tombstone: Boolean,
        val dirty: Boolean,
    ) {
        init {
            require(clock >= 0L)
            require(device.isNotBlank())
        }
    }

    data class MergeResult(
        /** Remote records that won and therefore must be applied to the local preference file. */
        val applyRemote: Set<String>,
        /** Local values that must be overlaid on the pulled plist before this push. */
        val publishValues: Set<String>,
        /** Effective clear records that must be removed from the pulled plist before this push. */
        val publishTombstones: Set<String>,
    )

    internal data class RecordFold(
        val records: Map<String, Stamp>,
        val applyRemote: Set<String>,
    )

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private val deviceId: String = prefs.getString(KEY_DEVICE_ID, null)?.takeIf(String::isNotBlank)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString(KEY_DEVICE_ID, it).commit() }

    private val lock = Any()

    /** Record a user-originated mutation. Callers must exclude remote-apply writes. */
    fun recordLocal(accountId: String, key: String, present: Boolean, nowMs: Long = System.currentTimeMillis()) {
        if (accountId.isBlank() || !isLedgerable(key)) return
        synchronized(lock) {
            val all = read(accountId)
            val current = all[key]
            // Clock rollback cannot make a newer local edit look older than an existing record.
            val nextClock = maxOf(nowMs, (current?.clock ?: 0L) + 1L)
            all[key] = Stamp(nextClock, deviceId, tombstone = !present, dirty = true)
            write(accountId, all)
        }
    }

    /**
     * First-run migration: existing values become dirty local baselines, so upgrading a device does
     * not silently discard its configured settings before it has made one successful publish.
     */
    fun establishBaseline(accountId: String, settings: Map<String, *>, nowMs: Long = System.currentTimeMillis()) {
        if (accountId.isBlank()) return
        synchronized(lock) {
            val all = read(accountId)
            var changed = false
            for (key in SettingsBackup.SYNCABLE_SETTING_TYPES.keys) {
                if (!isLedgerable(key) || key !in settings || all.containsKey(key)) continue
                all[key] = Stamp(nowMs, deviceId, tombstone = false, dirty = true)
                changed = true
            }
            if (changed) write(accountId, all)
        }
    }

    /**
     * Preview remote state before applying the pulled plist. Dirty local entries always win this merge;
     * otherwise a newer stamp wins, with device id as a deterministic equal-clock tiebreak. The caller
     * must call [commitRemote] only after every selected remote value has been synchronously written.
     *
     * Keeping this side-effect free is intentional: persisting a winning remote revision before its value
     * has reached SharedPreferences lets a crash or malformed carrier suppress the only retry.
     */
    fun mergeRemote(accountId: String, remote: Map<String, Stamp>): MergeResult {
        if (accountId.isBlank()) return MergeResult(emptySet(), emptySet(), emptySet())
        synchronized(lock) {
            val local = read(accountId)
            val folded = foldRecords(local, remote)
            return resultFor(folded.records, folded.applyRemote)
        }
    }

    /**
     * Durably accept only remote revisions whose values (or clears) were committed by the caller.
     * A fresh local edit wins even if it occurs between preview and commit.
     */
    fun commitRemote(accountId: String, remote: Map<String, Stamp>, appliedKeys: Set<String>) {
        if (accountId.isBlank() || appliedKeys.isEmpty()) return
        synchronized(lock) {
            val local = read(accountId)
            var changed = false
            for (key in appliedKeys) {
                val candidate = remote[key] ?: continue
                if (!isLedgerable(key)) continue
                val current = local[key]
                if (current == null || (!current.dirty && compare(candidate, current) > 0)) {
                    local[key] = candidate.copy(dirty = false)
                    changed = true
                }
            }
            if (changed) write(accountId, local)
        }
    }

    /** Return the currently-local records that must be carried on a push. */
    fun pending(accountId: String): MergeResult = synchronized(lock) {
        resultFor(read(accountId), emptySet())
    }

    /** Snapshot the dirty revisions that are actually represented by a candidate document. */
    fun publicationSnapshot(accountId: String): Map<String, Stamp> = synchronized(lock) {
        read(accountId).filterValues { it.dirty }
    }

    /** Every locally-known revision, including acknowledged ones that must suppress legacy fallback. */
    fun knownKeys(accountId: String): Set<String> = synchronized(lock) { read(accountId).keys }

    /** Immutable record image used to construct both wire revisions and the matching PUT receipt. */
    fun recordsSnapshot(accountId: String): Map<String, Stamp> = synchronized(lock) { read(accountId).toMap() }

    /**
     * A successful PUT acknowledges only the dirty revisions encoded for that PUT. A later local edit has
     * a distinct stamp and remains dirty, even when it happened while the request was in flight.
     */
    fun acknowledgePublished(accountId: String, published: Map<String, Stamp>) {
        if (accountId.isBlank()) return
        synchronized(lock) {
            val all = read(accountId)
            val acknowledged = acknowledgeRecords(all, published)
            if (acknowledged != all) write(accountId, acknowledged)
        }
    }

    /**
     * Read-merge our known revisions onto the raw cloud block. Unknown/future revisions are retained verbatim;
     * known entries absent from an older partial ledger are preserved until this client has a local revision.
     */
    fun encodeForDocument(accountId: String, existing: JSONObject?): JSONObject = synchronized(lock) {
        mergeDocumentRevisions(existing, read(accountId))
    }

    fun encodeSnapshotForDocument(existing: JSONObject?, records: Map<String, Stamp>): JSONObject =
        mergeDocumentRevisions(existing, records)

    fun decodeDocument(raw: JSONObject?): Map<String, Stamp> {
        raw ?: return emptyMap()
        val result = linkedMapOf<String, Stamp>()
        val keys = raw.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!isLedgerable(key)) continue
            val entry = raw.optJSONObject(key) ?: continue
            val clock = entry.optLong("clock", -1L)
            val device = entry.optString("device", "")
            if (clock < 0L || device.isBlank()) continue
            result[key] = Stamp(
                clock = clock,
                device = device,
                tombstone = entry.optBoolean("tombstone", false),
                // Cloud revisions describe acknowledged state. A remote sender's local-pending bit, if one
                // appears from a future client, must never suppress local conflict resolution on this device.
                dirty = false,
            )
        }
        return result
    }

    private fun resultFor(records: Map<String, Stamp>, applyRemote: Set<String>): MergeResult {
        val values = linkedSetOf<String>()
        val tombstones = linkedSetOf<String>()
        for ((key, stamp) in records) {
            // Every effective tombstone must remove the matching key from a republished plist, even
            // after it was first authored by a remote device. Otherwise the accompanying ledger would
            // say "cleared" while the legacy settings carrier retained the old value for older peers.
            if (stamp.tombstone) tombstones += key
            else if (stamp.dirty) values += key
        }
        return MergeResult(applyRemote, values, tombstones)
    }

    private fun isLedgerable(key: String): Boolean =
        key in SettingsBackup.SYNCABLE_SETTING_TYPES && SettingsBackup.isSyncable(key)

    private fun read(accountId: String): MutableMap<String, Stamp> {
        val raw = prefs.getString(KEY_RECORDS_PREFIX + accountId, null) ?: return linkedMapOf()
        val objectValue = runCatching { JSONObject(raw) }.getOrNull() ?: return linkedMapOf()
        return decodeStored(objectValue).toMutableMap()
    }

    private fun write(accountId: String, records: Map<String, Stamp>) {
        prefs.edit().putString(KEY_RECORDS_PREFIX + accountId, JSONObject().also { out ->
            for ((key, stamp) in records) {
                out.put(key, encodeStamp(stamp, includeDirty = true))
            }
        }.toString()).commit()
    }

    internal companion object {
        const val PREFS_FILE = "vortx_settings_sync_ledger"
        const val KEY_DEVICE_ID = "deviceId"
        const val KEY_RECORDS_PREFIX = "records."

        /** Pure merge seam for conflict-matrix tests: dirty local records win; acknowledged records use LWW. */
        internal fun foldRecords(
            local: Map<String, Stamp>,
            remote: Map<String, Stamp>,
        ): RecordFold {
            val merged = local.toMutableMap()
            val applied = linkedSetOf<String>()
            for ((key, candidate) in remote) {
                if (key !in SettingsBackup.SYNCABLE_SETTING_TYPES || !SettingsBackup.isSyncable(key)) continue
                val current = merged[key]
                if (current == null || (!current.dirty && compare(candidate, current) > 0)) {
                    merged[key] = candidate.copy(dirty = false)
                    applied += key
                }
            }
            return RecordFold(merged, applied)
        }

        private fun compare(left: Stamp, right: Stamp): Int = when {
            left.clock != right.clock -> left.clock.compareTo(right.clock)
            left.device != right.device -> left.device.compareTo(right.device)
            left.tombstone != right.tombstone -> left.tombstone.compareTo(right.tombstone)
            else -> 0
        }

        internal fun acknowledgeRecords(
            records: Map<String, Stamp>,
            published: Map<String, Stamp>,
        ): Map<String, Stamp> = records.mapValues { (key, current) ->
            val sent = published[key]
            if (current.dirty && sent != null && sameRevision(current, sent)) current.copy(dirty = false) else current
        }

        internal fun decodeStored(raw: JSONObject?): Map<String, Stamp> {
            raw ?: return emptyMap()
            val result = linkedMapOf<String, Stamp>()
            val keys = raw.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (!isLedgerableStatic(key)) continue
                val entry = raw.optJSONObject(key) ?: continue
                val clock = entry.optLong("clock", -1L)
                val device = entry.optString("device", "")
                if (clock < 0L || device.isBlank()) continue
                result[key] = Stamp(
                    clock = clock,
                    device = device,
                    tombstone = entry.optBoolean("tombstone", false),
                    dirty = entry.optBoolean("dirty", false),
                )
            }
            return result
        }

        /** Preserve unknown document entries while replacing only revisions this client owns. */
        internal fun mergeDocumentRevisions(
            existing: JSONObject?,
            local: Map<String, Stamp>,
        ): JSONObject = JSONObject(existing?.toString() ?: "{}").also { out ->
            for ((key, stamp) in local) {
                // Forward-compatible fields belong to the entry, not just the top-level map. Preserve them
                // while updating only this protocol's three revision fields.
                val entry = out.optJSONObject(key)?.let { JSONObject(it.toString()) } ?: JSONObject()
                entry.put("clock", stamp.clock)
                entry.put("device", stamp.device)
                entry.put("tombstone", stamp.tombstone)
                entry.remove("dirty")
                out.put(key, entry)
            }
        }

        /** Keys not named by a partial revision map retain legacy set-only carrier behaviour. */
        internal fun unrevisionedKeys(
            carrierKeys: Set<String>,
            revisions: Map<String, Stamp>,
        ): Set<String> = carrierKeys.filterTo(linkedSetOf()) { it !in revisions && isLedgerableStatic(it) }

        private fun encodeStamp(stamp: Stamp, includeDirty: Boolean): JSONObject = JSONObject().apply {
            put("clock", stamp.clock)
            put("device", stamp.device)
            put("tombstone", stamp.tombstone)
            if (includeDirty) put("dirty", stamp.dirty)
        }

        private fun sameRevision(left: Stamp, right: Stamp): Boolean =
            left.clock == right.clock && left.device == right.device && left.tombstone == right.tombstone

        private fun isLedgerableStatic(key: String): Boolean =
            key in SettingsBackup.SYNCABLE_SETTING_TYPES && SettingsBackup.isSyncable(key)
    }
}
