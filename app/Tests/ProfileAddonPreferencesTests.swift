import Foundation

// The harness compiles the shipping UserProfile and extracts the actual ProfileStore methods.
// These minimal dependencies keep the test away from the app, Keychain and media lifecycle.
enum SourceType: String { case debrid, torrent }
final class SourcePreferences {
    static let shared = SourcePreferences()
    static let defaultTypeOrder: [SourceType] = [.debrid, .torrent]
    static let defaultUseAddonOrder = false
    static let orderKey = "test.profileAddons.types.\(UUID())"
    static let addonOrderKey = "test.profileAddons.useOrder.\(UUID())"
    func reload() {}
}
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    static var appliedAddonOrder: [String] = []
    var accountWrites = 0
    func applyInAppAddonOrder(_ urls: [String]) { accountWrites += 1; Self.appliedAddonOrder = urls }
    static func orderedByApplied<T>(_ items: [T], url: (T) -> String) -> [T] {
        ProfileAddonPreferencesPolicy.sorted(items,
            order: ProfileStore.activeAddonOrder(accountOrder: appliedAddonOrder), key: url)
    }
}
struct TestAddon { var transportUrl: String }
final class CoreBridge {
    static let shared = CoreBridge()
    var addons: [TestAddon] = []
    var nativeOrderWrites = 0
    func reorderAddonsForActiveProfile(_ urls: [String], profileID: UUID) { nativeOrderWrites += 1 }
}
final class ProfileStore {
    var profiles: [UserProfile] = []
    var activeID: UUID?
    var active: UserProfile? { profiles.first { $0.id == activeID } }
    static let activeDisabledAddonsKey = "test.profileAddons.disabled.\(UUID())"
    static let activeAddonOrderOverrideKey = "test.profileAddons.order.\(UUID())"
    var writes = 0
    func update(_ profile: UserProfile) {
        profiles[profiles.firstIndex(where: { $0.id == profile.id })!] = profile
        writes += 1
        if let active { applyAddonPreferences(active) }
    }
    func currentPlaybackPrefs() -> UserProfile.PlaybackPrefs {
        var prefs = active?.playback ?? Self.playback()
        prefs.sourceTypeOrder = UserDefaults.standard.string(forKey: SourcePreferences.orderKey)?.components(separatedBy: ",")
        prefs.useAddonOrder = UserDefaults.standard.bool(forKey: SourcePreferences.addonOrderKey)
        return prefs
    }
    func selectForTest(_ profile: UserProfile) {
        if active != nil { capturePlayback() }
        activeID = profile.id
        applyAddonPreferences(active!)
    }
    static func playback(types: [String] = ["debrid", "torrent"], useOrder: Bool = false) -> UserProfile.PlaybackPrefs {
        UserProfile.PlaybackPrefs(audioLang: "en", subtitleLang: "en", forcedPolicy: "forced", subFont: "system",
            subSize: "medium", subColor: "white", subBackground: "none", sourceTypeOrder: types, useAddonOrder: useOrder)
    }
}

@main enum ProfileAddonPreferencesTests {
    @MainActor static func main() throws {
        let a = "https://addons.example/Config/A/manifest.json"
        let b = "https://addons.example/Config/a/manifest.json"
        let c = "https://addons.example/other/manifest.json"
        let policy = ProfileAddonPreferencesPolicy.self
        precondition(policy.identity(" HTTPS://ADDONS.EXAMPLE/Config/A/manifest.json ") == a)
        precondition(policy.identity(a) != policy.identity(b), "configured path case is identity")
        precondition(policy.sorted([a, b, c], order: [b, a], key: { $0 }) == [b, a, c])
        precondition(policy.disabled(override: nil, inherited: [a]) == [a])
        precondition(policy.disabled(override: [], inherited: [a]).isEmpty, "empty override differs from inheritance")

        var owner = UserProfile(id: UserProfile.ownerID, name: "Main", avatar: "🍿", isOwner: true,
            playback: ProfileStore.playback(), disabledAddons: [a],
            addonPreferences: ProfileAddonPreferences(disabledAddonURLsOverride: [a]))
        let child = UserProfile(name: "Child", avatar: "🌙", playback: ProfileStore.playback())
        let store = ProfileStore()
        store.profiles = [owner, child]
        VortXSyncManager.appliedAddonOrder = [a, b, c]
        CoreBridge.shared.addons = [a, b, c].map { TestAddon(transportUrl: $0) }
        defer {
            for key in [SourcePreferences.orderKey, SourcePreferences.addonOrderKey,
                        ProfileStore.activeDisabledAddonsKey, ProfileStore.activeAddonOrderOverrideKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        store.selectForTest(child)
        precondition(store.activeInheritsAddonVisibility && store.activeInheritsAddonRanking)
        precondition(store.isAddonDisabledForActive(base: a) && !store.isAddonDisabledForActive(base: b))
        let beforeSwitch = store.active!.addonPreferences
        store.selectForTest(owner)
        store.selectForTest(child)
        precondition(store.active!.addonPreferences == beforeSwitch, "switching must not create overrides")

        // Main changes flow to an already selected child; account order remains a live read.
        owner.disabledAddons = [b]
        owner.addonPreferences?.disabledAddonURLsOverride = [b]
        owner.playback = ProfileStore.playback(types: ["torrent", "debrid"], useOrder: true)
        store.update(owner)
        VortXSyncManager.appliedAddonOrder = [c, b, a]
        #if VORTX_NATIVE_DATA_ENGINE
        let inheritedOrder: [String] = [] // the input descriptors already carry native kernel order
        #else
        let inheritedOrder = [c, b, a]
        #endif
        precondition(store.isAddonDisabledForActive(base: b) && !store.isAddonDisabledForActive(base: a))
        precondition(store.effectiveAddonRanking(for: store.active!).sourceTypeOrder == ["torrent", "debrid"])
        precondition(ProfileStore.activeAddonOrder(accountOrder: VortXSyncManager.appliedAddonOrder) == inheritedOrder)
        store.capturePlayback()
        precondition(store.active!.addonPreferences?.rankingOverride == nil, "capture inherited values without custom mode")

        let installedOrder = VortXSyncManager.appliedAddonOrder
        store.toggleAddon(base: a)
        precondition(!store.activeInheritsAddonVisibility && store.activeInheritsAddonRanking)
        precondition(Set(store.active!.addonPreferences!.disabledAddonURLsOverride!) == [a, b])
        precondition(store.profiles[0] == owner, "visibility override cannot mutate Main")
        store.setAddonOrder([b, a, c], for: child.id)
        precondition(!store.activeInheritsAddonRanking)
        precondition(VortXSyncManager.appliedAddonOrder == installedOrder && VortXSyncManager.shared.accountWrites == 0,
                     "shared-profile reorder never writes owner order or installed roster")
        precondition(ProfileStore.activeAddonOrder(accountOrder: installedOrder) == [b, a, c])
        let customWire = try JSONEncoder().encode(store.active!)
        let restored = try JSONDecoder().decode(UserProfile.self, from: customWire)
        precondition(restored == store.active!, "sync and backup round trip")
        store.resetAddonVisibilityToMain()
        precondition(store.activeInheritsAddonVisibility && !store.activeInheritsAddonRanking)
        precondition(store.isAddonDisabledForActive(base: b) && !store.isAddonDisabledForActive(base: a))
        store.resetAddonRankingToMain()
        precondition(store.activeInheritsAddonRanking)
        precondition(ProfileStore.activeAddonOrder(accountOrder: installedOrder) == inheritedOrder)
        let resetWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.active!)) as! [String: Any]
        let resetPrefs = resetWire["addonPreferences"] as! [String: Any]
        precondition(resetPrefs["rankingOverride"] == nil && resetPrefs["disabledAddonURLsOverride"] == nil,
                     "reset removes both optional overrides from the sync/backup wire")

        // A real edit to the existing Source Order controls creates a ranking-only override.
        UserDefaults.standard.set("debrid,torrent", forKey: SourcePreferences.orderKey)
        store.capturePlayback()
        precondition(!store.activeInheritsAddonRanking && store.activeInheritsAddonVisibility)
        precondition(store.active!.addonPreferences?.rankingOverride?.sourceTypeOrder == ["debrid", "torrent"])
        store.selectForTest(owner)
        let writesBeforeStale = store.writes
        store.setAddonOrder([b, a], for: child.id)
        precondition(store.writes == writesBeforeStale && VortXSyncManager.shared.accountWrites == 0,
                     "late reorder from outgoing profile is rejected")
        store.setAddonOrder([a, c, b], for: owner.id)
        #if VORTX_NATIVE_DATA_ENGINE
        precondition(CoreBridge.shared.nativeOrderWrites == 1 && VortXSyncManager.shared.accountWrites == 0,
                     "native Main reorder uses the explicit native boundary only")
        #else
        precondition(VortXSyncManager.shared.accountWrites == 1, "Main keeps account reorder behavior")
        #endif

        let own = UserProfile(name: "Separate", avatar: "🌻", usesOwnAccount: true,
            playback: ProfileStore.playback(types: ["debrid", "torrent"], useOrder: false))
        store.profiles.append(own)
        store.selectForTest(own)
        precondition(!store.activeSharesMainAddons && !store.isAddonDisabledForActive(base: b))
        precondition(store.effectiveAddonRanking(for: own).sourceTypeOrder == ["debrid", "torrent"],
                     "own-account profile does not inherit Main's ranking or visibility")

        let inherited = ProfileAddonRanking(sourceTypeOrder: ["debrid", "torrent"], useAddonOrder: false)
        let migrated = policy.migrated(legacyDisabled: [a], legacyTypes: ["torrent", "debrid"],
            legacyUseOrder: true, inheritedRanking: inherited)
        precondition(migrated.disabledAddonURLsOverride == [a] && migrated.rankingOverride?.useAddonOrder == true)
        precondition(migrated.rankingOverride?.addonOrder == nil, "legacy source customization preserves account order")
        precondition(policy.migrated(legacyDisabled: nil, legacyTypes: inherited.sourceTypeOrder,
            legacyUseOrder: false, inheritedRanking: inherited) == ProfileAddonPreferences())
        let legacy = try JSONDecoder().decode(UserProfile.self,
            from: Data("{\"name\":\"Legacy\",\"disabledAddons\":[\"\(a)\"]}".utf8))
        precondition(legacy.addonPreferences == nil && legacy.disabledAddons == [a])
        print("PASS actual profile add-on methods: inheritance, customization, independent resets, switching, URL identity, migration, wire round trip, stale-action fence and account isolation")
    }
}
