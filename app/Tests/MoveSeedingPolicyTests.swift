// RUN:
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/MoveSeeding.swift \
//     app/SourcesShared/SettingsBackup.swift \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/Keychain.swift \
//     app/Tests/MoveSeedingPolicyTests.swift \
//     -o /tmp/vortx-move-seeding-policy-tests && /tmp/vortx-move-seeding-policy-tests

import Foundation

@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    var hasCompletedFirstSync = false
}

@MainActor
final class ProfileStore {
    static let shared = ProfileStore()
    var needsPicker = false
}

// Minimal link stubs for SettingsBackup dependencies outside this focused policy.
@MainActor enum MoatConsent { static let key = "stremiox.moat.consent" }
@MainActor enum SourceIndexClient { static let serveKey = "stremiox.sourceindex.serve" }
@MainActor
final class SourceIndexLifecycleScope {
    static let shared = SourceIndexLifecycleScope()
    func preferencesWillApply(consent: Bool?, serve: Bool?) {}
}
@MainActor enum AppLanguage { static func reapplyOverride() {} }
@MainActor final class ThemeManager {
    static let shared = ThemeManager()
    func reloadFromDefaults() {}
}
@MainActor final class HomeRailPreferences {
    static let shared = HomeRailPreferences()
    func reloadFromDefaults() {}
}
@MainActor final class CatalogPreferences {
    static let shared = CatalogPreferences()
    func reloadFromDefaults() {}
}
@MainActor final class IPTVPlaylistStore {
    static let shared = IPTVPlaylistStore()
    func reloadFromDefaults() {}
}
@MainActor final class MediaServerStore {
    static let shared = MediaServerStore()
    func reloadFromDefaults() {}
}
@MainActor final class SourcePreferences {
    static let shared = SourcePreferences()
    func reload() {}
}
@MainActor final class SourcePinStore {
    static let shared = SourcePinStore()
    func reload() {}
}
@MainActor enum LastStreamStore { static func invalidateCache() {} }
@MainActor enum SavedLinksStore { static func invalidate() {} }

@main
@MainActor
struct MoveSeedingPolicyTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func rawPayload(_ data: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encodedPayload = object["payloadBase64"] as? String,
              let payload = Data(base64Encoded: encodedPayload),
              let domain = try? PropertyListSerialization.propertyList(
                  from: payload,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return [:] }
        return domain
    }

    static func main() {
        let current = MoveSeeding.buildIdentifier(shortVersion: "0.3.9", buildNumber: "201")
        let prior = MoveSeeding.buildIdentifier(shortVersion: "0.3.9", buildNumber: "200")

        check(
            "an unsynced device with no dismissal receives the launch reminder",
            MoveSeeding.shouldPresentLaunchNag(
                needsSeeding: true,
                presentedThisLaunch: false,
                currentBuildIdentifier: current,
                dismissedBuildIdentifier: nil
            )
        )
        check(
            "dismissal suppresses later launches of the same build",
            !MoveSeeding.shouldPresentLaunchNag(
                needsSeeding: true,
                presentedThisLaunch: false,
                currentBuildIdentifier: current,
                dismissedBuildIdentifier: current
            )
        )
        check(
            "a newer build may remind once",
            MoveSeeding.shouldPresentLaunchNag(
                needsSeeding: true,
                presentedThisLaunch: false,
                currentBuildIdentifier: current,
                dismissedBuildIdentifier: prior
            )
        )
        check(
            "the in-process latch still prevents duplicate sheets",
            !MoveSeeding.shouldPresentLaunchNag(
                needsSeeding: true,
                presentedThisLaunch: true,
                currentBuildIdentifier: current,
                dismissedBuildIdentifier: nil
            )
        )
        check(
            "a real completed sync suppresses every launch reminder",
            !MoveSeeding.shouldPresentLaunchNag(
                needsSeeding: false,
                presentedThisLaunch: false,
                currentBuildIdentifier: current,
                dismissedBuildIdentifier: nil
            )
        )

        let suite = "MoveSeedingPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            print("FAIL: could not create isolated defaults")
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        MoveSeeding.recordLaunchNagDismissal(buildIdentifier: current, defaults: defaults)
        check(
            "dismissal persists the exact current build receipt",
            MoveSeeding.dismissedBuildIdentifier(defaults: defaults) == current
        )

        let dismissalKey = MoveSeeding.launchNagDismissedBuildKey
        let controlKey = "vortx.tests.moveSeedingTransferControl"
        let standard = UserDefaults.standard
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let previousDomain = standard.persistentDomain(forName: bundleID)
        let previousDismissal = standard.object(forKey: dismissalKey)
        let previousControl = standard.object(forKey: controlKey)
        defer {
            if let previousDomain {
                standard.setPersistentDomain(previousDomain, forName: bundleID)
            } else {
                standard.removePersistentDomain(forName: bundleID)
            }
            if let previousDismissal {
                standard.set(previousDismissal, forKey: dismissalKey)
            } else {
                standard.removeObject(forKey: dismissalKey)
            }
            if let previousControl {
                standard.set(previousControl, forKey: controlKey)
            } else {
                standard.removeObject(forKey: controlKey)
            }
        }

        check(
            "the launch dismissal receipt is device-local",
            !SettingsBackup.isSyncable(dismissalKey)
        )

        standard.setPersistentDomain(
            [dismissalKey: current, controlKey: "local-control"],
            forName: bundleID
        )
        let backup = try? SettingsBackup.makeBackup()
        let backupDomain = backup.map(rawPayload) ?? [:]
        check(
            "portable backup excludes the device-local launch dismissal",
            backup != nil
                && backupDomain[dismissalKey] == nil
                && backupDomain[controlKey] as? String == "local-control"
        )

        let localMerge = SettingsBackup.mergedSyncBlob(onto: nil)
        let localMergeDomain = localMerge.map(rawPayload) ?? [:]
        check(
            "account merge excludes a locally recorded launch dismissal",
            localMerge != nil
                && localMergeDomain[dismissalKey] == nil
                && localMergeDomain[controlKey] as? String == "local-control"
        )

        let poisoned = try? SettingsBackup.encode(
            domain: [dismissalKey: current, controlKey: "remote-control"],
            bundleID: bundleID,
            app: "VortX"
        )
        let scrubbedMerge = poisoned.flatMap {
            SettingsBackup.mergedSyncBlob(onto: $0.base64EncodedString())
        }
        let scrubbedDomain = scrubbedMerge.map(rawPayload) ?? [:]
        check(
            "account merge scrubs a launch dismissal received from an older peer",
            scrubbedMerge != nil
                && scrubbedDomain[dismissalKey] == nil
                && scrubbedDomain[controlKey] != nil
        )

        standard.removePersistentDomain(forName: bundleID)
        standard.removeObject(forKey: dismissalKey)
        standard.removeObject(forKey: controlKey)
        let restoredCount = poisoned.flatMap { try? SettingsBackup.restore(from: $0) }
        check(
            "restore cannot transfer a launch dismissal to this device",
            restoredCount == 1
                && standard.object(forKey: dismissalKey) == nil
                && standard.string(forKey: controlKey) == "remote-control"
        )

        VortXSyncManager.shared.hasCompletedFirstSync = false
        check(
            "launch dismissal does not hide the Settings seeding state",
            MoveSeeding.needsSeeding
        )
        VortXSyncManager.shared.hasCompletedFirstSync = true
        check(
            "only a real sync clears the Settings seeding state",
            !MoveSeeding.needsSeeding
        )

        let testFile = URL(fileURLWithPath: #filePath)
        let tvSource = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesTV/MoveSeedingNagTV.swift")
        let tvText = (try? String(contentsOf: tvSource, encoding: .utf8)) ?? ""
        let rootSource = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesTV/RootTabView.swift")
        let rootText = (try? String(contentsOf: rootSource, encoding: .utf8)) ?? ""
        let iosNagSource = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesiOS/MoveSeedingNagView.swift")
        let iosNagText = (try? String(contentsOf: iosNagSource, encoding: .utf8)) ?? ""
        let iosRootSource = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesiOS/iOSRootView.swift")
        let iosRootText = (try? String(contentsOf: iosRootSource, encoding: .utf8)) ?? ""
        check(
            "the tvOS Not now action records the build dismissal before closing",
            tvText.contains("MoveSeeding.recordLaunchNagDismissal()")
        )
        check(
            "the tvOS sheet boundary records every actual dismissal path",
            rootText.contains(".sheet(isPresented: $showSeedingNag, onDismiss:")
                && rootText.contains("MoveSeeding.recordLaunchNagDismissal()")
        )
        check(
            "the tvOS copy no longer promises a reminder on every launch",
            !tvText.contains("returns on the next launch")
        )
        check(
            "the iOS and Mac Not now action records the build dismissal before closing",
            iosNagText.contains("MoveSeeding.recordLaunchNagDismissal()")
        )
        check(
            "the iOS and Mac sheet boundary records every actual dismissal path",
            iosRootText.contains(".sheet(isPresented: $showSeedingNag, onDismiss:")
                && iosRootText.contains("MoveSeeding.recordLaunchNagDismissal()")
        )
        check(
            "the iOS and Mac copy no longer promises a reminder on every launch",
            !iosNagText.contains("returns on the next launch")
        )

        if failures > 0 {
            print("\n\(failures) MoveSeeding policy test(s) FAILED.")
            exit(1)
        }
        print("\nALL PASS")
    }
}
