import Foundation

@main
struct HomeContinueWatchingSelectionTests {
    private static var checks = 0
    private static var failures: [String] = []
    private static let profileA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let profileB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let sessionA = TraktSessionID(rawValue: "fixture-trakt-A")
    private static let sessionB = TraktSessionID(rawValue: "fixture-trakt-B")

    static func main() {
#if CW_BASELINE
        let core = configure()
        _ = shadow()
        let tv = BaselineTVHomeSelection(core: core, profiles: .shared).continueWatchingSelection
        let ios = BaselineIOSHomeSelection(core: core, profiles: .shared).continueWatchingSelection
        require(tv.source == .trakt, "native TV retains the selected Trakt source")
        require(ios.source == .trakt, "native iOS/macOS retains the selected Trakt source")
#else
        nativeEligibleProfileRetainsTrakt()
        nativeSharedProfileUsesCore()
        remoteFallbacksAndEmptyTruth()
        unavailableNativeNeverBorrowsLegacy()
        nativeContextRetirement()
        selectionRetiresDuringProjection()
        traktSessionRetirement()
        legacySharedProfileKeepsOverlay()
        topShelfLateCommitDenial()
        if CommandLine.arguments.count > 1 { surfaceWiring(root: CommandLine.arguments[1]) }
#endif
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS: \(checks) offline Apple Continue Watching selection/projection checks")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    @discardableResult
    private static func configure(native: Bool = true, eligible: Bool = true) -> CoreBridge {
        let core = CoreBridge.shared
        core.beforeNativeCurrentCheck = nil
        core.usesNativeProfileState = native
        core.nativeBinding = binding()
        core.continueWatching = [item("native-local")]
        core.library = CoreLibrary(catalog: [item("tmdb:movie:42", poster: "https://catalog.invalid/cached.jpg")])
        ProfileStore.shared.activeID = profileA
        ProfileStore.shared.activeUsesEngineHistory = eligible
        UserDefaults.standard.reset()
        UserDefaults.standard.set("trakt", forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set("20", forKey: ContinueWatchingPreferences.windowKey)
        ProfileStore.shared.active = .init(id: profileA, usesEngineHistory: eligible,
            discovery: .init(continueWatchingSource: "trakt", continueWatchingWindow: "20"))
        ProfileStore.shared.cwItems = [item("legacy-overlay")]
        ExternalSyncToggle.enabled = true
        TraktAuth.storedSessionID = sessionA
        return core
    }

    private static func binding(
        profile: UUID = profileA,
        account: String = "fixture-account-A",
        credentialGeneration: UInt64 = 1,
        nativeGeneration: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        accountGeneration: UUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    ) -> PlaybackMutationOwnershipPolicy.NativeBinding {
        .init(profileID: profile, credential: .init(namespace: account, generation: credentialGeneration),
              sessionGeneration: nativeGeneration, accountGeneration: accountGeneration)
    }

    private static func item(_ id: String, poster: String? = nil) -> CoreCWItem {
        .init(id: id, type: "movie", name: id, poster: poster,
              state: .init(timeOffset: 120_000, duration: 600_000, videoId: nil))
    }

    private static func shadow(hasSnapshot: Bool = true, empty: Bool = false) -> TraktPlaybackShadow {
        TraktPlaybackCacheStorage.snapshot = .init(
            sessionID: sessionA, progress: [:], stamp: nil, activity: nil,
            items: empty ? [] : [.init(id: "trakt-movie", type: "movie", name: "Trakt fixture", progress: 40,
                pausedAt: "2026-10-09T00:00:00Z", runtimeMinutes: 100, videoID: nil, poster: nil,
                aliases: ["tmdb:movie:42"])], hasSnapshot: hasSnapshot
        )
        return TraktPlaybackShadow()
    }

    private static func selected(_ core: CoreBridge, _ shadow: TraktPlaybackShadow) -> HomeContinueWatchingSelection.Snapshot {
        HomeContinueWatchingSelection.current(core: core, profiles: .shared, shadow: shadow)
    }

    private static func nativeEligibleProfileRetainsTrakt() {
        let result = selected(configure(), shadow()).selection
        require(result.source == .trakt && result.sessionID == sessionA, "native eligible profile retains certified Trakt provenance")
        require(result.items.map(\.id) == ["trakt-movie"], "native selected Trakt rows replace the local read rail")
        require(result.items.first?.resumeSeconds == 2400, "production shadow preserves the displayed Trakt offset")
        require(result.items.first?.poster == "https://catalog.invalid/cached.jpg", "production shadow joins artwork from the native library by alias")
    }

    private static func nativeSharedProfileUsesCore() {
        let result = selected(configure(eligible: false), shadow()).selection
        require(result.source == .local && result.sessionID == nil, "native shared profile stays local")
        require(result.items.map(\.id) == ["native-local"], "native shared profile uses its core bucket rather than legacy overlay")
    }

    private static func remoteFallbacksAndEmptyTruth() {
        let core = configure()
        let loaded = shadow()
        ExternalSyncToggle.enabled = false
        UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
        ProfileStore.shared.active?.discovery?.continueWatchingSource = "local"
        require(selected(core, loaded).selection.items.map(\.id) == ["native-local"], "toggle-off retains native local fallback")
        ExternalSyncToggle.enabled = true
        UserDefaults.standard.set("trakt", forKey: ContinueWatchingPreferences.sourceKey)
        ProfileStore.shared.active?.discovery?.continueWatchingSource = "trakt"
        TraktAuth.storedSessionID = nil
        require(selected(core, loaded).selection.source == .trakt && selected(core, loaded).selection.items.isEmpty,
                "explicit Trakt without certified session is truthfully unavailable, not a disguised local rail")
        TraktAuth.storedSessionID = sessionA
        let first = selected(core, shadow(hasSnapshot: false)).selection
        require(first.source == .trakt && first.items.isEmpty && first.status != nil, "first unsuccessful snapshot remains explicitly loading")
        let empty = selected(core, shadow(empty: true)).selection
        require(empty.source == .trakt && empty.items.isEmpty && empty.sessionID == sessionA, "successful empty Trakt snapshot stays truthfully empty")
    }

    private static func unavailableNativeNeverBorrowsLegacy() {
        let core = configure(eligible: false)
        core.nativeBinding = nil
        let result = selected(core, shadow()).selection
        require(result.source == .local && result.items.isEmpty, "unavailable native binding cannot read core residue or legacy overlay")
    }

    private static func nativeContextRetirement() {
        let core = configure()
        let context = selected(core, shadow()).context
        require(context.isCurrent(core: core, profiles: .shared), "captured native context initially holds")
        ProfileStore.shared.activeID = profileB
        require(!context.isCurrent(core: core, profiles: .shared), "profile switch retires captured selection")
        ProfileStore.shared.activeID = profileA
        core.nativeBinding = binding(account: "fixture-account-B")
        require(!context.isCurrent(core: core, profiles: .shared), "account switch retires captured selection")
        core.nativeBinding = binding(credentialGeneration: 2)
        require(!context.isCurrent(core: core, profiles: .shared), "same-account credential generation retires captured selection")
        core.nativeBinding = binding(nativeGeneration: UUID())
        require(!context.isCurrent(core: core, profiles: .shared), "native session reopen retires captured selection")
        core.nativeBinding = binding(accountGeneration: UUID())
        require(!context.isCurrent(core: core, profiles: .shared), "native account generation retires captured selection")
    }

    private static func selectionRetiresDuringProjection() {
        let core = configure()
        let loaded = shadow()
        var reads = 0
        core.beforeNativeCurrentCheck = {
            reads += 1
            if reads == 2 { core.nativeBinding = binding(nativeGeneration: UUID()) }
        }
        require(selected(core, loaded).selection.items.isEmpty, "target retired during production shadow projection cannot publish remote rows")
        core.beforeNativeCurrentCheck = nil
    }

    private static func traktSessionRetirement() {
        let core = configure()
        let loaded = shadow()
        TraktAuth.storedSessionID = sessionB
        let result = selected(core, loaded).selection
        require(result.source == .trakt && result.items.isEmpty, "replacement Trakt session cannot read the prior account snapshot")
    }

    private static func legacySharedProfileKeepsOverlay() {
        let result = selected(configure(native: false, eligible: false), shadow()).selection
        require(result.items.map(\.id) == ["legacy-overlay"], "legacy shared profile retains its established overlay history")
    }

    private static func topShelfLateCommitDenial() {
        let core = configure()
        let context = selected(core, shadow()).context
        func commitAllowed() -> Bool {
            HomeContinueWatchingSelection.permitsPrivateArtworkCommit(context: context, sessionID: sessionA,
                core: core, profiles: .shared)
        }
        require(commitAllowed(), "current Top Shelf artwork storage/publication is admitted")
        core.nativeBinding = binding(nativeGeneration: UUID())
        require(!commitAllowed(), "late Top Shelf artwork storage is denied after native target retirement")
        require(!commitAllowed(), "late Top Shelf final publication is denied after native target retirement")
        core.nativeBinding = binding()
        ProfileStore.shared.activeID = profileB
        require(!commitAllowed(), "late Top Shelf profile switch is denied with the same Trakt session")
        ProfileStore.shared.activeID = profileA
        ExternalSyncToggle.enabled = false
        UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
        require(!commitAllowed(), "late Top Shelf toggle-off is denied before reseed")
        ExternalSyncToggle.enabled = true
        UserDefaults.standard.set("trakt", forKey: ContinueWatchingPreferences.sourceKey)
        TraktAuth.storedSessionID = sessionB
        require(!commitAllowed(), "late Top Shelf replacement Trakt session is denied")
    }

    private static func surfaceWiring(root: String) {
        func read(_ path: String) -> String { (try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? "" }
        let tv = read("app/SourcesTV/HomeView.swift")
        let ios = read("app/SourcesiOS/iOSRootView.swift")
        let shelf = read("app/SourcesTV/TopShelfSnapshotWriter.swift")
        let call = "HomeContinueWatchingSelection.current(core: core, profiles: profiles)"
        require(tv.contains(call) && ios.contains(call), "TV and iOS/macOS consume the production shared selector")
        require(shelf.contains("HomeContinueWatchingSelection.current(core: CoreBridge.shared, profiles: profiles)"), "Top Shelf consumes the production shared selector")
        require(shelf.components(separatedBy: "HomeContinueWatchingSelection.permitsPrivateArtworkCommit(").count == 3,
                "both actual Top Shelf storage and final publication call the exercised commit guard")
        require(shelf.contains("lastPrivateContext == context"), "private artwork reuse remains bound to the captured native context")
    }
}
