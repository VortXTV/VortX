// SettingsBackupSecretsTests: verification that a Keychain fallback secret can never enter the synced
// settings blob or the user-facing backup export (#145 pre-land, manager items A and B).
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so this
// follows the same standalone-executable shape as HouseholdCryptoTests. It differs from that file in one way
// that matters: HouseholdCryptoTests re-implements the primitives it checks, whereas this COMPILES THE REAL
// SettingsBackup.swift AND Keychain.swift in. A re-typed copy of a filter would only ever prove the copy is
// right, which for a security control is worth nothing.
//
// RUN (positive: every assertion must pass, exit 0):
//
//     xcrun swiftc -o /tmp/sbtest \
//         app/SourcesShared/SettingsBackup.swift \
//         app/SourcesShared/Keychain.swift \
//         app/Tests/SettingsBackupSecretsTests.swift && /tmp/sbtest
//
// RUN (NEGATIVE CONTROL: mandatory, and the actual point of the file). A guard that has never been shown to
// FAIL is indistinguishable from a guard that CANNOT fail, so break it on purpose and confirm the tests
// notice. Emptying `secretKeyPrefixes` must turn T1.1/T1.2/T1.3/T2.1/T3.1/T3.3/T5.4 RED and exit 1:
//
//     mkdir -p /tmp/sbctrl && cp app/SourcesShared/Keychain.swift /tmp/sbctrl/
//     sed 's|static let secretKeyPrefixes: \[String\] = \[Keychain.fallbackKeyPrefix\]|static let secretKeyPrefixes: [String] = []|' \
//         app/SourcesShared/SettingsBackup.swift > /tmp/sbctrl/SettingsBackup.swift
//     xcrun swiftc -o /tmp/sbctrl/bin /tmp/sbctrl/SettingsBackup.swift /tmp/sbctrl/Keychain.swift \
//         app/Tests/SettingsBackupSecretsTests.swift && /tmp/sbctrl/bin   # expect exit 1
//
// When last run, that control printed the plaintext token and dataKey straight out of the backup blob, which
// is what upgraded the leak from "plausible" to "demonstrated on the pre-fix code path".
//
// NOTE for whoever wires up a real test target: the stubs below are top-level types that SHADOW the real
// app types of the same name. They exist only so the file under test links standalone. This file is not in
// VortX.xcodeproj (nothing under app/Tests is), and if it is ever added to a target these will collide with
// the real definitions. That collision is a loud compile error rather than silent breakage, but move the
// stubs behind the target's own doubles at that point.

import Foundation

// MARK: - Stubs (only for what SettingsBackup.reloadLiveStores touches; no test calls it)

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

// MARK: - Tests

@main
struct SettingsBackupSecretsTests {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("  PASS  \(name)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL  \(name)\(d.isEmpty ? "" : "  [\(d)]")")
        }
    }

    // Shaped like the real thing: VortXSyncManager persists { token, account, dataKey } as ONE JSON blob in
    // ONE Keychain slot (VortXSyncManager.swift `Persisted` / `kcAccount`), so a single leaked fallback key
    // exposes the account token AND the E2E data key together.
    static let secretToken = "SECRET-TOKEN-8f3a91c2e4b7d6a5"
    static let secretDataKey = "SECRET-DATAKEY-aGVsbG8gd29ybGQgdGhpcyBpcyAzMiBieXRlcw=="
    static var sessionBlob: String {
        #"{"token":"\#(secretToken)","account":{"id":"acct_1"},"dataKey":"\#(secretDataKey)"}"#
    }

    // The exact key the leak produces. Built from the REAL constant, so if the prefix ever changes the test
    // follows it instead of asserting against a stale literal.
    static var leakedKey: String { Keychain.fallbackKeyPrefix + "vortx.sync.session.v1" }
    // A second slot, to prove the PREFIX generalises past the one that motivated it.
    static var leakedTraktKey: String { Keychain.fallbackKeyPrefix + "vortx.trakt.accessToken" }

    /// Raw decode that does NOT go through `decodeDomain`'s filter, so a test can see what was actually
    /// ENCODED rather than what the read side is willing to hand back. Without this, the read-side filter
    /// would mask a write-side leak and T1 would pass vacuously.
    static func rawPayload(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["payloadBase64"] as? String,
              let plist = Data(base64Encoded: b64),
              let dict = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return dict
    }

    static func containsSecret(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains(secretToken) || text.contains(secretDataKey) { return true }
        let flat = rawPayload(data).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return flat.contains(secretToken) || flat.contains(secretDataKey)
    }

    static func main() {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"

        let seeded: [String: Any] = [
            leakedKey: sessionBlob,
            leakedTraktKey: "SECRET-TOKEN-trakt-zzz",
            "stremiox.accentColor": "blue",
            "vortx.downloads.autoDeleteWatched": true,
            "vortx.downloads.queueOrder": ["11111111-1111-1111-1111-111111111111"],
            "vortx.downloads.maxConcurrent": 5,
            "stremiox.diskCacheBytes": 12_345,
            "vortx.sync.lastSyncedVersion.acct_1": 42,
        ]
        UserDefaults.standard.setPersistentDomain(seeded, forName: bundleID)

        print("\n=== T1: makeBackup() must not carry the secret (export + push write side) ===")
        guard let backup = try? SettingsBackup.makeBackup() else {
            print("  FAIL  T1.0 makeBackup threw"); exit(1)
        }
        let backupRaw = rawPayload(backup)
        check("T1.1 leaked session key absent from encoded payload", backupRaw[leakedKey] == nil,
              "found: \(String(describing: backupRaw[leakedKey]))")
        check("T1.2 leaked trakt key absent (prefix generalises)", backupRaw[leakedTraktKey] == nil)
        check("T1.3 token/dataKey bytes absent from blob", !containsSecret(backup))
        check("T1.4 ordinary pref still present (not over-filtering)",
              backupRaw["stremiox.accentColor"] as? String == "blue")

        print("\n=== T2: decodeDomain() must not APPLY a secret (restore + pull-apply read side) ===")
        // Encode a POISONED blob directly, bypassing the write-side filter. This is an account doc or backup
        // file written by a PRE-FIX build, which is the case that exists in the wild right now.
        guard let poisoned = try? SettingsBackup.encode(
            domain: [leakedKey: sessionBlob, "stremiox.accentColor": "red"], bundleID: bundleID, app: "VortX")
        else { print("  FAIL  T2.0 encode threw"); exit(1) }
        check("T2.0 poisoned blob really does contain the secret (test is honest)",
              rawPayload(poisoned)[leakedKey] != nil)
        let decoded = (try? SettingsBackup.decodeDomain(from: poisoned)) ?? [:]
        check("T2.1 secret filtered out on read", decoded[leakedKey] == nil,
              "found: \(String(describing: decoded[leakedKey]))")
        check("T2.2 ordinary pref still applied", decoded["stremiox.accentColor"] as? String == "red")

        print("\n=== T3: mergedSyncBlob() scrubs a secret already in the account doc (self-heal) ===")
        guard let merged = SettingsBackup.mergedSyncBlob(onto: poisoned.base64EncodedString()) else {
            print("  FAIL  T3.0 mergedSyncBlob returned nil"); exit(1)
        }
        let mergedRaw = rawPayload(merged)
        check("T3.1 stale secret not carried forward into the pushed blob", mergedRaw[leakedKey] == nil,
              "found: \(String(describing: mergedRaw[leakedKey]))")
        check("T3.2 account's own pref preserved by the merge", mergedRaw["stremiox.accentColor"] != nil)
        check("T3.3 secret bytes absent from pushed blob", !containsSecret(merged))

        print("\n=== T4: device-local download keys (manager item A) ===")
        check("T4.1 queueOrder excluded", !SettingsBackup.isSyncable("vortx.downloads.queueOrder"))
        check("T4.2 maxConcurrent excluded", !SettingsBackup.isSyncable("vortx.downloads.maxConcurrent"))
        check("T4.3 autoDeleteWatched STILL SYNCS (guards against over-filtering)",
              SettingsBackup.isSyncable("vortx.downloads.autoDeleteWatched"))
        check("T4.4 queueOrder absent from a real backup", backupRaw["vortx.downloads.queueOrder"] == nil)
        check("T4.5 maxConcurrent absent from a real backup", backupRaw["vortx.downloads.maxConcurrent"] == nil)
        check("T4.6 autoDeleteWatched present in a real backup",
              backupRaw["vortx.downloads.autoDeleteWatched"] != nil)

        print("\n=== T5: pre-existing guards still hold (no regression) ===")
        check("T5.1 diskCacheBytes still device-local", !SettingsBackup.isSyncable("stremiox.diskCacheBytes"))
        check("T5.2 vortx.sync.* bookkeeping still excluded",
              !SettingsBackup.isSyncable("vortx.sync.lastSyncedVersion.acct_1"))
        check("T5.3 Apple/OS keys still excluded", !SettingsBackup.isSyncable("AppleLanguages"))
        check("T5.4 isSyncable false for the leaked key", !SettingsBackup.isSyncable(leakedKey))

        UserDefaults.standard.removePersistentDomain(forName: bundleID)

        print("\n----------------------------------------")
        print("passes: \(passes)  failures: \(failures)")
        print("----------------------------------------")
        exit(failures == 0 ? 0 : 1)
    }
}
