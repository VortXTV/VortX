package com.vortx.android.sync

/**
 * LOCAL-WINS bookkeeping for the settings sync: which syncable `SharedPreferences` keys hold a change the
 * user made on THIS device that has NOT yet been confirmed onto the account.
 *
 * WHY THIS EXISTS. The push side (`mergeLocalIntoDoc`) makes a LOCAL value win only once a push actually
 * lands, and `hasPendingPush` is an in-memory guard: a relaunch (or an offline/crashed push) drops it, and
 * the next pull re-applies the account's OLD value straight over the just-made local change (the historical
 * "the toggle would not stay" bug). This is the durable, PER-KEY analogue: a key is marked dirty the instant
 * it changes locally, the mark survives a relaunch (persisted by [VortXSyncManager] under its per-account
 * slot), the pull-apply SKIPS a dirty key, and the mark clears only after a confirmed successful push
 * carried that key's value up.
 *
 * The Android port of Apple `app/SourcesShared/SettingsDirtyKeys.swift`. DELIBERATELY pure logic with no
 * Android framework types beyond kotlin stdlib, so unit tests exercise it verbatim;
 * [VortXSyncManager] owns the persistence, the per-account scoping, and the shadow snapshot.
 */
internal object SettingsDirtyKeys {

    /**
     * Value equality for two `SharedPreferences` domain values (Boolean / Int / Long / Float / String /
     * Set<String>). Boxed-number equality is type-strict (Int 1 != Long 1), which can only OVER-report a
     * change when a writer switches storage types for one key - that costs a harmless extra dirty mark +
     * push, never a lost edit. A present-vs-absent key is a change; two absent values are equal.
     */
    fun valuesEqual(a: Any?, b: Any?): Boolean = a == b

    /**
     * The SYNCABLE keys whose value differs between two snapshots of the app's settings domain (added,
     * removed, or changed). [isSyncable] is passed in (SettingsBackup owns the real predicate) so a
     * device-local key, a secret, or an OS key is never tracked as a settings edit.
     */
    fun changedSyncableKeys(
        from: Map<String, *>,
        to: Map<String, *>,
        isSyncable: (String) -> Boolean,
    ): Set<String> {
        val changed = linkedSetOf<String>()
        for (key in from.keys + to.keys) {
            if (!isSyncable(key)) continue
            if (!valuesEqual(from[key], to[key])) changed.add(key)
        }
        return changed
    }

    /**
     * Mark keys dirty at [now] (an epoch stamp), overwriting any prior stamp. A re-edit ADVANCES the stamp,
     * which is what lets [clearPushed] tell a key that was carried up by a push from one re-dirtied after
     * the push blob was built.
     */
    fun mark(keys: Set<String>, at: Double, into: MutableMap<String, Double>) {
        for (key in keys) into[key] = at
    }

    /**
     * Clear the keys a confirmed push carried up, but ONLY the ones whose stamp is unchanged since the
     * [snapshot] taken when that push began. A key re-edited while the push was in flight has a NEWER
     * stamp, so it is left dirty (its newer value was not necessarily in the pushed blob) and heals on
     * the next push.
     */
    fun clearPushed(snapshot: Map<String, Double>, from: MutableMap<String, Double>) {
        for ((key, stamp) in snapshot) {
            if (from[key] == stamp) from.remove(key)
        }
    }
}
