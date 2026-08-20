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
     * Fold remote state before applying the pulled plist. Dirty local entries always win this merge;
     * otherwise a newer stamp wins, with device id as a deterministic equal-clock tiebreak.
     */
    fun mergeRemote(accountId: String, remote: Map<String, Stamp>): MergeResult {
        if (accountId.isBlank()) return MergeResult(emptySet(), emptySet(), emptySet())
        synchronized(lock) {
            val local = read(accountId)
            val folded = foldRecords(local, remote)
            write(accountId, folded.records)
            return resultFor(folded.records, folded.applyRemote)
        }
    }

    /** Return the currently-local records that must be carried on a push. */
    fun pending(accountId: String): MergeResult = synchronized(lock) {
        resultFor(read(accountId), emptySet())
    }

    /** A successful account-document PUT acknowledges every dirty record in this account scope. */
    fun acknowledgePublished(accountId: String) {
        if (accountId.isBlank()) return
        synchronized(lock) {
            val all = read(accountId)
            val acknowledged = all.mapValues { (_, stamp) -> stamp.copy(dirty = false) }
            write(accountId, acknowledged)
        }
    }

    fun encodeForDocument(accountId: String): JSONObject = synchronized(lock) {
        JSONObject().also { out ->
            for ((key, stamp) in read(accountId)) {
                out.put(key, JSONObject().apply {
                    put("clock", stamp.clock)
                    put("device", stamp.device)
                    put("tombstone", stamp.tombstone)
                })
            }
        }
    }

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
        return decodeDocument(objectValue).toMutableMap()
    }

    private fun write(accountId: String, records: Map<String, Stamp>) {
        prefs.edit().putString(KEY_RECORDS_PREFIX + accountId, JSONObject().also { out ->
            for ((key, stamp) in records) {
                out.put(key, JSONObject().apply {
                    put("clock", stamp.clock)
                    put("device", stamp.device)
                    put("tombstone", stamp.tombstone)
                })
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
    }
}
