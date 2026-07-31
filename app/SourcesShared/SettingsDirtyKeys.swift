import Foundation

/// LOCAL-WINS bookkeeping for the settings sync: which syncable `UserDefaults` keys hold a change the user
/// made on THIS device that has NOT yet been confirmed onto the account.
///
/// WHY THIS EXISTS. `SettingsBackup.mergedSyncBlob` already makes a LOCAL value win on the PUSH side, but that
/// only helps once a push actually lands. The window between a user's edit and its (2.5s-debounced) push is
/// unprotected across a process restart: `VortXSyncManager.hasPendingPush` is an in-memory boolean, so a
/// relaunch (or an offline/crashed push) drops it, and the next pull that clears the version guard re-applies
/// the account's OLD value straight over the just-made local change (the historical "the toggle would not
/// stay" interplay documented at VortXSyncManager.swift:1175-1182). This is the durable, PER-KEY analogue of
/// that guard: a key is marked dirty the instant it changes locally, the mark survives a relaunch (persisted
/// by VortXSyncManager under its per-account `vortx.sync.` slot), the pull-apply SKIPS a dirty key, and the
/// mark clears only after a confirmed successful push carried that key's value up.
///
/// This type is DELIBERATELY pure Foundation with no app-type references (like `ExternalSyncToggleSync`), so
/// its logic is exercised verbatim by a standalone `swiftc` test. VortXSyncManager owns the `UserDefaults`
/// persistence, the per-account scoping, and the shadow snapshot; this enum owns only the decisions.
enum SettingsDirtyKeys {
    /// Value equality for two `UserDefaults` plist values (Bool/Int/Double/String/Data/Date/array/dict).
    /// Uses `isEqual:` on the bridged `NSObject`, which is deep, type-correct value equality for every plist
    /// type (order-insensitive for dictionaries, order-sensitive for arrays: exactly the right semantics). A
    /// present-vs-absent key is a change; two absent values are equal. The safe direction matters here: this
    /// must NEVER report two genuinely different values as equal (that would fail to protect a real edit).
    /// `isEqual:` cannot: different content is never equal. At worst it OVER-reports a change for a logically
    /// equal collection rebuilt differently, which only costs an unnecessary (harmless) dirty mark + push.
    static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return (x as AnyObject).isEqual(y)
        default: return false
        }
    }

    /// The SYNCABLE keys whose value differs between two snapshots of the app's defaults domain (added,
    /// removed, or changed). `isSyncable` is passed in (SettingsBackup owns the real predicate) so a
    /// device-local key (cache size, server URL), a secret, or an OS key is never tracked as a settings edit.
    static func changedSyncableKeys(
        from old: [String: Any],
        to new: [String: Any],
        isSyncable: (String) -> Bool
    ) -> Set<String> {
        var changed: Set<String> = []
        for key in Set(old.keys).union(new.keys) where isSyncable(key) {
            if !valuesEqual(old[key], new[key]) { changed.insert(key) }
        }
        return changed
    }

    /// Mark keys dirty at `now` (an epoch stamp), overwriting any prior stamp. A re-edit ADVANCES the stamp,
    /// which is what lets `clearPushed` tell a key that was carried up by a push from one re-dirtied after the
    /// push blob was built.
    static func mark(_ keys: Set<String>, at now: Double, into map: inout [String: Double]) {
        for key in keys { map[key] = now }
    }

    /// Clear the keys a confirmed push carried up, but ONLY the ones whose stamp is unchanged since the
    /// `snapshot` taken when that push began. A key re-edited while the push was in flight has a NEWER stamp,
    /// so it is left dirty (its newer value was not necessarily in the pushed blob) and heals on the next push.
    static func clearPushed(_ snapshot: [String: Double], from map: inout [String: Double]) {
        for (key, stamp) in snapshot where map[key] == stamp { map.removeValue(forKey: key) }
    }
}
