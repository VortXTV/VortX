import Foundation

private struct PlaybackMutationTarget: Equatable {
    let generation: Int
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { generation == core.generation }
}
@MainActor private final class CoreBridge {
    static let shared = CoreBridge()
    var generation = 1
    var hasNativeSession = true
}
@MainActor private final class ThemeManager {
    static let shared = ThemeManager()
    var accentID = "ember"; var oled = false; var textScale = 1.0
}
private enum TabBarPrefs { static let hideLive = "hideLive", hideDiscover = "hideDiscover", hideLibrary = "hideLibrary", hideSearch = "hideSearch" }
private enum ContinueWatchingPreferences { static let sourceKey = "source", windowKey = "window" }
private enum ProfileDiscoveryPreferencesStore { static let activeProjectionKeys: Set<String> = ["stremiox.catalog.order"] }
private enum TraktAuth { static let storedSessionID: String? = nil }
private struct NativePlaybackProjectionSource: Equatable {
    let playback: UserProfile.PlaybackPrefs?
    let addonPreferences: ProfileAddonPreferences?
}
private struct NativeDiscoveryProjectionSource: Equatable {
    let discovery: ProfileDiscoveryPreferences?
}
private typealias ManagerNativePlaybackProjectionSource = NativePlaybackProjectionSource
private typealias ManagerNativeDiscoveryProjectionSource = NativeDiscoveryProjectionSource

@MainActor private final class PreferenceHarness {
    static let nativePlaybackProjectionKeys: Set<String> = ["audio", "fixture.playback"]
    static let nativeThemeProjectionKeys: Set<String> = ["theme", "stremiox.theme.accent"]
    var active: UserProfile? = UserProfile(name: "Fixture", avatar: "")
    var profiles: [UserProfile] { active.map { [$0] } ?? [] }
    var activeID: UUID? { active?.id }
    var nativeProjectionTarget: PlaybackMutationTarget? = .init(generation: 1)
    var nativePublishedPlayback: UserProfile.PlaybackPrefs?
    var nativePublishedDiscovery: ProfileDiscoveryPreferences?
    var nativePublishedPlaybackSource: ManagerNativePlaybackProjectionSource?
    var nativePublishedDiscoverySource: ManagerNativeDiscoveryProjectionSource?
    private var nativePublishedTheme: NativeThemeProjection?
    struct Witness { let profileID: UUID; let target: PlaybackMutationTarget; let session: String }
    var continueWatchingMigration: Witness?
    var activeSharesMainAddons = false
    var failSave = false
    var changeWhileSaving = false
    var retireWhileSaving = false
    var saves = 0
    var saveHandler: ((UserProfile) async -> Bool)?
    var nativeProfileError: String?
#if VORTX_NATIVE_DATA_ENGINE
    var capturedUpdateCount = 0
    var capturedUpdateProfile: UserProfile?
    var capturedUpdateGroups: Set<NativePreferenceIntentStore.Group>?
#endif
    var flatPlayback = UserProfile.PlaybackPrefs(audioLang: "en", subtitleLang: "en", forcedPolicy: "forced", subFont: "system",
        subSize: "medium", subColor: "white", subBackground: "none", subSizeScale: 1, sourceTypeOrder: ["debrid", "torrent"],
        useAddonOrder: false, safetyMode: "balanced", instantOnly: false)
    var flatDiscovery = ProfileDiscoveryPreferences(hiddenCatalogs: [], catalogOrder: [], hiddenHubCategories: [],
        regionOverrideCaptured: true, filtersCaptured: true, selectedProviders: [], providerOrder: [], tabVisibilityCaptured: true)
    func currentPlaybackPrefs() -> UserProfile.PlaybackPrefs { flatPlayback }
    func currentDiscoveryPrefs() -> ProfileDiscoveryPreferences { flatDiscovery }
#if VORTX_NATIVE_DATA_ENGINE
    func update(_ profile: UserProfile, editedPreferenceGroups: Set<NativePreferenceIntentStore.Group>? = nil) {
        capturedUpdateCount += 1
        capturedUpdateProfile = profile
        capturedUpdateGroups = editedPreferenceGroups
    }
#endif
    func effectiveAddonRanking(for profile: UserProfile) -> ProfileAddonRanking { .init(sourceTypeOrder: ["debrid", "torrent"], useAddonOrder: false) }
    func addonPreferences(for profile: UserProfile) -> ProfileAddonPreferences { profile.addonPreferences ?? .init() }
    func establishBaselines() {
        nativePublishedPlayback = flatPlayback; nativePublishedDiscovery = flatDiscovery
        nativePublishedPlaybackSource = .init(playback: active?.playback, addonPreferences: active?.addonPreferences)
        nativePublishedDiscoverySource = .init(discovery: active?.discovery)
        nativePublishedTheme = currentNativeThemeProjection()
    }
    func saveNative(_ profile: UserProfile, creating: Bool, target: PlaybackMutationTarget) async -> Bool {
        saves += 1
        if failSave { return false }
        if retireWhileSaving { CoreBridge.shared.generation += 1; return false }
        if let saveHandler { return await saveHandler(profile) }
        active = profile
        if changeWhileSaving { flatPlayback.audioLang = "fr" }
        return true
    }
}

@main private enum NativePreferenceAcknowledgementTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) { print("\(condition ? "PASS" : "FAIL") \(message)"); if !condition { failures += 1 } }
        let p = PreferenceHarness()
        p.active?.discovery = .init(catalogOrder: [])
        p.establishBaselines()
        check(p.nativePreferenceIsAcknowledged("audio"), "applied effective playback defaults acknowledge an optional native profile")
        check(p.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "represented discovery field uses applied effective projection rather than optional group equality")
        // The flat value matches its prior effective baseline, but the authenticated profile
        // carrier changed underneath it; this baseline alone cannot prove the carrier was applied.
        var peerPlayback = p.flatPlayback
        peerPlayback.audioLang = "fr"
        p.active?.playback = peerPlayback
        check(!p.nativePreferenceIsAcknowledged("audio"), "peer carrier fr is not acknowledged merely because flat playback returned to old effective en")
        p.active?.playback = nil
        p.active?.discovery = .init(catalogOrder: ["peer"])
        check(!p.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "peer discovery carrier is not acknowledged from the old effective flat baseline")
        p.active?.discovery = nil
        p.active?.accentID = "peer-accent"
        check(!p.nativePreferenceIsAcknowledged("stremiox.theme.accent"), "peer theme carrier is not acknowledged from the old effective flat baseline")
        p.active?.accentID = "ember"
        p.active?.discovery = nil
        check(!p.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "absent discovery carrier cannot acknowledge an incidental matching default")
        p.flatPlayback.audioLang = "hi"
        check(!p.nativePreferenceIsAcknowledged("audio"), "new local playback change remains unacknowledged")
        p.flatDiscovery.catalogOrder = ["local-edit"]
        check(!p.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "new local discovery change remains unacknowledged")
        p.nativePublishedPlayback = nil; p.nativePublishedDiscovery = nil
        check(!p.nativePreferenceIsAcknowledged("audio") && !p.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "missing projection baseline cannot acknowledge local values")
        CoreBridge.shared.generation = 2
        check(!p.nativePreferenceIsAcknowledged("theme"), "retired account/profile projection cannot acknowledge matching theme values")
        CoreBridge.shared.generation = 1
        let retry = PreferenceHarness(); retry.establishBaselines(); retry.activeSharesMainAddons = true
        retry.flatPlayback.audioLang = "hi"; retry.failSave = true
        check(!(await retry.retryNativePreferenceProjection(keys: ["audio"])) && retry.saves == 1
              && !retry.nativePreferenceIsAcknowledged("audio"), "failed native preference transaction retains dirty projection for retry")
        retry.failSave = false
        check(await retry.retryNativePreferenceProjection(keys: ["audio"]), "same-target preference retry succeeds")
        check(retry.active?.playback?.audioLang == "hi" && retry.nativePreferenceIsAcknowledged("audio"), "accepted preference replay acknowledges exact submitted flat values")
        check(retry.active?.playback?.sourceTypeOrder == nil && retry.active?.addonPreferences?.rankingOverride == nil,
              "retry preserves inherited ranking fields without materializing Main defaults")
        retry.flatDiscovery.catalogOrder = ["changed"]
        check(await retry.retryNativePreferenceProjection(keys: ["stremiox.catalog.order"]), "new local discovery preference becomes an explicit native profile field")
        check(retry.active?.discovery?.catalogOrder == ["changed"] && retry.nativePreferenceIsAcknowledged("stremiox.catalog.order"), "explicit discovery replay acknowledges only after durable acceptance")
        retry.flatPlayback.audioLang = "de"; retry.changeWhileSaving = true
        check(await retry.retryNativePreferenceProjection(keys: ["audio"]), "older local save may commit while a newer local preference arrives")
        check(!retry.nativePreferenceIsAcknowledged("audio") && retry.flatPlayback.audioLang == "fr", "new preference during suspended save remains pending")
        let cold = PreferenceHarness(); cold.nativeProjectionTarget = nil; cold.flatPlayback.audioLang = "hi"
        check(!(await cold.retryNativePreferenceProjection(keys: ["audio"])) && cold.saves == 0, "pre-mount values cannot acquire a new profile owner through retry")
        let retired = PreferenceHarness(); retired.establishBaselines(); retired.flatPlayback.audioLang = "hi"; retired.retireWhileSaving = true
        check(!(await retired.retryNativePreferenceProjection(keys: ["audio"])) && !retired.nativePreferenceIsAcknowledged("audio"), "retired binding cannot acknowledge a suspended preference retry")
        if failures > 0 { exit(1) }
    }
}
