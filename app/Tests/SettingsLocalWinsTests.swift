// SettingsLocalWinsTests: a standalone, runnable proof that a LOCAL, user-made settings change is never
// silently overwritten by a cross-device PULL before it has been pushed (the "toggle would not stay through a
// restart" defect class). It exercises the REAL logic on both sides of the fix:
//   - SettingsDirtyKeys.swift ....... the pure dirty-key decisions (differ / mark / clear-on-confirmed-push).
//   - SettingsBackup.swift .......... restore(from:skipping:) actually skipping a dirty key on pull-apply, and
//                                     mergedSyncBlob preserving the #145 absence-is-not-deletion guarantee.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per repo convention), so
// this follows the SettingsBackupSecretsTests / ExternalSyncToggleSyncTests convention: a self-contained executable
// compiled with the system toolchain, with the REAL sources compiled in and only the app types SettingsBackup
// transitively references (Keychain aside) stubbed so the file links standalone.
//
//     xcrun swiftc -o /tmp/slwtest \
//         app/SourcesShared/SettingsDirtyKeys.swift \
//         app/SourcesShared/SettingsBackup.swift \
//         app/SourcesShared/Keychain.swift \
//         app/Tests/SettingsLocalWinsTests.swift && /tmp/slwtest
//
// The stubs below SHADOW the real app types of the same name (exactly as SettingsBackupSecretsTests notes):
// they exist only so SettingsBackup.swift links standalone, and no test calls into them.

import Foundation

// MARK: - Stubs (only what SettingsBackup.restore / .reloadLiveStores reference; no test calls them)

enum MoatConsent { static let key = "stremiox.moat.consent" }
enum SourceIndexClient { static let serveKey = "stremiox.sourceindex.serve" }
final class SourceIndexLifecycleScope {
    static let shared = SourceIndexLifecycleScope()
    func preferencesWillApply(consent: Bool?, serve: Bool?) {}
}
enum AppLanguage { static func reapplyOverride() {} }
final class ThemeManager { static let shared = ThemeManager(); func reloadFromDefaults() {} }
final class HomeRailPreferences { static let shared = HomeRailPreferences(); func reloadFromDefaults() {} }
final class CatalogPreferences { static let shared = CatalogPreferences(); func reloadFromDefaults() {} }
final class IPTVPlaylistStore { static let shared = IPTVPlaylistStore(); func reloadFromDefaults() {} }
final class MediaServerStore { static let shared = MediaServerStore(); func reloadFromDefaults() {} }
final class SourcePreferences { static let shared = SourcePreferences(); func reload() {} }
final class SourcePinStore { static let shared = SourcePinStore(); func reload() {} }
enum LastStreamStore { static func invalidateCache() {} }
enum SavedLinksStore { static func invalidate() {} }

// MARK: - Harness

var failures: [String] = []
var checks = 0
func expect(_ cond: Bool, _ what: String) { checks += 1; if !cond { failures.append(what) } }
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want { failures.append("\(what): got \(got), want \(want)") }
}

// The realistic keys under test: the ratings-on-posters toggle and a sibling, both plain syncable app prefs.
let kToggle = "stremiox.xrdb.enabled"
let kSibling = "stremiox.xrdb.baseURL"
let kDeviceLocal = "stremiox.diskCacheBytes"   // in SettingsBackup.deviceLocalKeys: must never be tracked

func accountBlob(_ domain: [String: Any]) -> Data {
    // The exact serialization the account's doc["settings"] carries (a base64 binary-plist envelope).
    try! SettingsBackup.encode(domain: domain, bundleID: "unknown", app: "VortX")
}

// MARK: - 1. SettingsDirtyKeys: value equality (the safe-direction primitive)

func testValuesEqual() {
    expect(SettingsDirtyKeys.valuesEqual(nil, nil), "two absent values are equal")
    expect(!SettingsDirtyKeys.valuesEqual(nil, true), "present vs absent is a change")
    expect(!SettingsDirtyKeys.valuesEqual(false, nil), "absent vs present is a change")
    expect(!SettingsDirtyKeys.valuesEqual(false, true), "a real Bool flip is a change (the whole point)")
    expect(SettingsDirtyKeys.valuesEqual(true, true), "equal Bools are equal")
    // JSON booleans bridge to NSNumber, @AppStorage writes a Swift Bool: these MUST compare equal or every
    // toggle would look changed every launch (the dangerous false-positive is harmless here, but assert anyway).
    expect(SettingsDirtyKeys.valuesEqual(NSNumber(value: true), true), "NSNumber true equals Bool true")
    expect(!SettingsDirtyKeys.valuesEqual(NSNumber(value: false), true), "NSNumber false differs from Bool true")
    expect(SettingsDirtyKeys.valuesEqual("poster.vortx.tv", "poster.vortx.tv"), "equal strings are equal")
    expect(!SettingsDirtyKeys.valuesEqual("a", "b"), "different strings are a change")
    expect(SettingsDirtyKeys.valuesEqual([1, 2, 3], [1, 2, 3]), "equal arrays are equal")
    expect(!SettingsDirtyKeys.valuesEqual([1, 2], [2, 1]), "reordered arrays are a change (order-sensitive)")
}

// MARK: - 2. SettingsDirtyKeys: the differ (only USER-facing syncable keys are tracked)

func testDifferTracksOnlySyncableChanges() {
    // A toggle flip on a syncable key is caught; an equal key is not; a device-local key is NEVER tracked even
    // when it changed (the differ must not mark a per-device key dirty, or a pull would stop applying peers').
    let old: [String: Any] = [kToggle: false, kSibling: "poster.vortx.tv", kDeviceLocal: 1000]
    let new: [String: Any] = [kToggle: true,  kSibling: "poster.vortx.tv", kDeviceLocal: 9999]
    let changed = SettingsDirtyKeys.changedSyncableKeys(from: old, to: new, isSyncable: SettingsBackup.isSyncable)
    expect(changed.contains(kToggle), "a flipped syncable toggle is a change")
    expect(!changed.contains(kSibling), "an unchanged sibling is not a change")
    expect(!changed.contains(kDeviceLocal), "a device-local key is NEVER tracked, even when it changed")
    expectEqual(changed, [kToggle], "exactly the one user-changed syncable key")

    // A newly-added key and a removed key both count.
    let added = SettingsDirtyKeys.changedSyncableKeys(from: [:], to: [kToggle: true], isSyncable: SettingsBackup.isSyncable)
    expectEqual(added, [kToggle], "an added syncable key is a change")
    let removed = SettingsDirtyKeys.changedSyncableKeys(from: [kToggle: true], to: [:], isSyncable: SettingsBackup.isSyncable)
    expectEqual(removed, [kToggle], "a removed syncable key is a change")

    // No change at all -> empty set (the common per-notification case: must be cheap and quiet).
    let none = SettingsDirtyKeys.changedSyncableKeys(from: old, to: old, isSyncable: SettingsBackup.isSyncable)
    expect(none.isEmpty, "an identical snapshot yields no dirty keys")
}

// MARK: - 3. SettingsDirtyKeys: mark + clear-only-after-confirmed-push, guarded by the stamp

func testMarkAndClearPushed() {
    var dirty: [String: Double] = [:]
    SettingsDirtyKeys.mark([kToggle], at: 100, into: &dirty)
    expectEqual(dirty[kToggle], 100, "mark records key -> dirtyAt")

    // A confirmed push whose snapshot matches clears the key.
    let snapshot = dirty
    SettingsDirtyKeys.clearPushed(snapshot, from: &dirty)
    expect(dirty[kToggle] == nil, "a confirmed push clears a key whose stamp is unchanged")

    // A key RE-EDITED while the push was in flight (newer stamp than the push snapshot) is NOT cleared: its
    // newer value was not necessarily in the pushed blob, so it must stay protected until its own push.
    var dirty2: [String: Double] = [:]
    SettingsDirtyKeys.mark([kToggle], at: 100, into: &dirty2)
    let inflight = dirty2                                   // push begins with stamp 100
    SettingsDirtyKeys.mark([kToggle], at: 200, into: &dirty2)  // user edits again mid-push -> stamp 200
    SettingsDirtyKeys.clearPushed(inflight, from: &dirty2)
    expectEqual(dirty2[kToggle], 200, "a key re-edited mid-push stays dirty (stamp guard)")
}

// MARK: - 4. End-to-end: the pull-apply SKIP (the actual clobber the fix closes), needs @MainActor for restore

@MainActor
func testPullApplySkipsDirtyKey() {
    let d = UserDefaults.standard
    d.removeObject(forKey: kToggle); d.removeObject(forKey: kSibling)

    // The account's settings blob still carries the STALE value (ratings OFF) plus a sibling the user did NOT
    // change (a fresh account base value for the sibling).
    let blob = accountBlob([kToggle: false, kSibling: "acct-base"])

    // The user just turned the toggle ON locally; it has not been pushed yet, so it is marked dirty.
    d.set(true, forKey: kToggle)
    let dirty: Set<String> = [kToggle]

    // A restart PULL applies the account blob. With the dirty-key skip, the user's local ON survives while the
    // untouched sibling still adopts the account value (per-key: the protection is surgical, not a blanket bail).
    let applied = (try? SettingsBackup.restore(from: blob, skipping: dirty)) ?? -1
    expectEqual(d.object(forKey: kToggle) as? Bool, true, "local unpushed ON survives the pull (not clobbered)")
    expectEqual(d.object(forKey: kSibling) as? String, "acct-base", "an untouched sibling still adopts the account value")
    expectEqual(applied, 1, "restore reports only the one non-skipped key applied")

    // After a CONFIRMED push clears the dirty mark, a subsequent pull applies account values again (no key is
    // stuck local-forever): here the account value happens to still be false, and it now lands.
    let applied2 = (try? SettingsBackup.restore(from: blob, skipping: [])) ?? -1
    expectEqual(d.object(forKey: kToggle) as? Bool, false, "once no longer dirty, the account value applies again")
    expectEqual(applied2, 2, "with nothing skipped, the full blob applies")

    d.removeObject(forKey: kToggle); d.removeObject(forKey: kSibling)
}

// MARK: - 5. End-to-end: a FRESH install (no dirty set) restores everything, unchanged

@MainActor
func testFreshInstallRestoreIsUnchanged() {
    let d = UserDefaults.standard
    d.removeObject(forKey: kToggle); d.removeObject(forKey: kSibling)
    let blob = accountBlob([kToggle: false, kSibling: "acct-base"])

    // Empty dirty set == a fresh install / restored device: every key applies, identical to restore(from:) with
    // no skip argument at all (the default-parameter path the backup-FILE import and existing callers use).
    let applied = (try? SettingsBackup.restore(from: blob, skipping: [])) ?? -1
    expectEqual(applied, 2, "a fresh install restores the whole blob")
    expectEqual(d.object(forKey: kToggle) as? Bool, false, "toggle restored from account")
    expectEqual(d.object(forKey: kSibling) as? String, "acct-base", "sibling restored from account")

    d.removeObject(forKey: kToggle); d.removeObject(forKey: kSibling)
}

// MARK: - 6. End-to-end: mergedSyncBlob still honors #145 absence-is-not-deletion (fix must not disturb it)

func testAbsenceIsNotDeletionPreserved() {
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let kAcctOnly = "stremiox.someAcctOnlyKey"
    let kLocal = "stremiox.someLocalKey"

    // Local domain holds only kLocal; the account base holds kLocal (older) + kAcctOnly (a peer authored it).
    UserDefaults.standard.setPersistentDomain([kLocal: "L"], forName: bundleID)
    defer { UserDefaults.standard.removePersistentDomain(forName: bundleID) }
    let base = accountBlob([kLocal: "old", kAcctOnly: "A"]).base64EncodedString()

    // With an EMPTY baseline (a device that has not applied this account's doc, e.g. a fresh install), a key
    // absent locally is KEPT, never deleted: the reinstall guard. Local kLocal wins.
    guard let merged = SettingsBackup.mergedSyncBlob(onto: base, appliedBaseline: []),
          let decoded = try? SettingsBackup.decodeDomain(from: merged) else {
        failures.append("mergedSyncBlob/decodeDomain returned nil for the absence-not-deletion case")
        return
    }
    expectEqual(decoded[kAcctOnly] as? String, "A", "a key absent locally but not in the baseline is KEPT (absence is not deletion)")
    expectEqual(decoded[kLocal] as? String, "L", "a key present locally wins over the account's older value")

    // With the key IN the baseline AND absent locally, it is a genuine user clear -> dropped (the resurrection
    // fix). Assert the fix leaves this pre-existing behavior intact.
    guard let mergedDel = SettingsBackup.mergedSyncBlob(onto: base, appliedBaseline: [kAcctOnly]),
          let decodedDel = try? SettingsBackup.decodeDomain(from: mergedDel) else {
        failures.append("mergedSyncBlob returned nil for the baseline-delete case")
        return
    }
    expect(decodedDel[kAcctOnly] == nil, "a key absent locally AND in the baseline is dropped (a real user clear)")
}

// MARK: - 7. The full narrative, tying the two sides together

@MainActor
func testFullClobberSurvivalNarrative() {
    let d = UserDefaults.standard
    d.removeObject(forKey: kToggle)

    // Steady state: this device applied the account (ratings OFF), so local == account and the shadow matches.
    d.set(false, forKey: kToggle)
    var shadow: [String: Any] = [kToggle: false]
    var dirty: [String: Double] = [:]

    // The user flips ratings ON. The observer's differ catches it and marks it dirty; the shadow advances.
    d.set(true, forKey: kToggle)
    let current: [String: Any] = [kToggle: true]
    let changed = SettingsDirtyKeys.changedSyncableKeys(from: shadow, to: current, isSyncable: SettingsBackup.isSyncable)
    SettingsDirtyKeys.mark(changed, at: Date().timeIntervalSince1970, into: &dirty)
    shadow = current
    expect(dirty[kToggle] != nil, "the ON flip is recorded dirty before any push")

    // App is killed before the 2.5s debounced push -> the account still holds OFF. On relaunch a pull applies
    // the account blob, SKIPPING the still-dirty key. The user's ON must survive.
    let pushSnapshot = dirty
    let acctStillOff = accountBlob([kToggle: false])
    _ = try? SettingsBackup.restore(from: acctStillOff, skipping: Set(dirty.keys))
    expectEqual(d.object(forKey: kToggle) as? Bool, true, "after restart, the ON toggle STILL sticks through the pull")

    // The startup flush then pushes the dirty value up; on a confirmed push the mark clears (and the account
    // now holds ON, healing the fleet). A later pull may adopt account values again.
    SettingsDirtyKeys.clearPushed(pushSnapshot, from: &dirty)
    expect(dirty.isEmpty, "a confirmed push clears the dirty mark (the account has now healed to ON)")

    d.removeObject(forKey: kToggle)
}

// MARK: - Runner

@main
struct SettingsLocalWinsTests {
    static func main() async {
        testValuesEqual()
        testDifferTracksOnlySyncableChanges()
        testMarkAndClearPushed()
        testAbsenceIsNotDeletionPreserved()
        await MainActor.run {
            testPullApplySkipsDirtyKey()
            testFreshInstallRestoreIsUnchanged()
            testFullClobberSurvivalNarrative()
        }

        if failures.isEmpty {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAIL: \(failures.count) of \(checks) checks")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
