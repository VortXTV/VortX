import Foundation
import os

// Exact checked production value/currentness declarations are inserted without annotations removed.
// All surrounding bridge, row, provider and storage seams below are explicit RAM fixture collaborators.
// PRODUCTION_CW_DECLARATIONS

enum CWFixtureIDs {
    static let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
}
final class CWBox<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { get { state.withLock { $0 } } set { state.withLock { $0 = newValue } } }
    func update<Result: Sendable>(_ work: @Sendable (inout Value) -> Result) -> Result { state.withLock(work) }
}
final class UserDefaults: Sendable {
    static let standard = UserDefaults()
    private let values = CWBox<[String: String]>([:])
    func string(forKey key: String) -> String? { values.update { $0[key] } }
    func set(_ value: String?, forKey key: String) { values.update { $0[key] = value } }
    func reset() { values.value = [:] }
}
final class CredentialScopeRegistry: Sendable {
    // PRODUCTION_CREDENTIAL_CAPTURE
    static let shared = CredentialScopeRegistry()
    private let current = CWBox(Capture(scope: .account(UUID(uuidString: "11111111-0000-4000-8000-000000000001")!), generation: 1))
    func capture() -> Capture { current.value }
    func isCurrent(_ capture: Capture) -> Bool { current.value == capture }
    func retire() { current.update { $0 = Capture(scope: $0.scope, generation: $0.generation + 1) } }
}
enum TraktAuth {
    private static let value = CWBox<TraktSessionID?>(nil)
    static var storedSessionID: TraktSessionID? { get { value.value } set { value.value = newValue } }
    static let isConfigured = true
}
enum SIMKLAuth {
    private static let value = CWBox<SIMKLSessionID?>(nil)
    static var storedSessionID: SIMKLSessionID? { get { value.value } set { value.value = newValue } }
    static let isConfigured = true
}
enum ExternalSyncToggle {
    static let traktResumeSuggestion = "fixture.suggestion"
    private static let enabled = CWBox(true)
    static func isOn(_ key: String, default defaultOn: Bool = true) -> Bool { enabled.value }
}
enum CWMappingHook {
    private static let value = CWBox<(@Sendable () -> Void)?>(nil)
    static func set(_ hook: (@Sendable () -> Void)?) { value.value = hook }
    static func fire() {
        let hook = value.update { state in let old = state; state = nil; return old }
        hook?()
    }
}
struct CoreLibState: Sendable {
    let timeOffset: Double; let duration: Double; let videoId: String?; var lastWatched: String? = nil
}
struct CoreCWItem: Sendable {
    let id: String; let type: String; let name: String; private let storedPoster: String?; let state: CoreLibState
    init(id: String, type: String, name: String, poster: String?, state: CoreLibState) {
        self.id = id; self.type = type; self.name = name; storedPoster = poster; self.state = state
    }
    var poster: String? { CWMappingHook.fire(); return storedPoster }
}
struct CoreLibrary: Sendable { let catalog: [CoreCWItem] }
struct PlaybackMeta: Sendable {
    let id: String; let usesSeriesLifecycle: Bool; let season: Int?; let episode: Int?
    var libraryId: String { CWMappingHook.fire(); return id }
}
final class CoreBridge: Sendable {
    static let shared = CoreBridge()
    private struct State: Sendable {
        var native = true; var nativeBinding: PlaybackMutationOwnershipPolicy.NativeBinding?
        var legacyTarget: PlaybackMutationTarget?; var rows: [CoreCWItem] = []; var library: CoreLibrary?
        var beforeTarget: (@Sendable () -> Void)?
    }
    private let state = CWBox(State())
    var usesNativeProfileState: Bool { get { state.update { $0.native } } set { state.update { $0.native = newValue } } }
    var continueWatching: [CoreCWItem] { get { state.update { $0.rows } } set { state.update { $0.rows = newValue } } }
    var library: CoreLibrary? { get { state.update { $0.library } } set { state.update { $0.library = newValue } } }
    var nativeBinding: PlaybackMutationOwnershipPolicy.NativeBinding? { get { state.update { $0.nativeBinding } } set { state.update { $0.nativeBinding = newValue } } }
    var legacyTarget: PlaybackMutationTarget? { get { state.update { $0.legacyTarget } } set { state.update { $0.legacyTarget = newValue } } }
    var beforeTarget: (@Sendable () -> Void)? { get { state.update { $0.beforeTarget } } set { state.update { $0.beforeTarget = newValue } } }
    func captureNativePlaybackTarget() -> PlaybackMutationTarget {
        state.update { $0.native ? .native($0.nativeBinding) : ($0.legacyTarget ?? .overlay(profileID: UUID())) }
    }
    func nativePlaybackTargetIsCurrent(_ target: PlaybackMutationTarget) -> Bool {
        beforeTarget?()
        if usesNativeProfileState {
            guard let binding = nativeBinding, CredentialScopeRegistry.shared.isCurrent(binding.credential) else { return false }
            return PlaybackMutationOwnershipPolicy.allowsNative(target, binding: binding)
        }
        return target == legacyTarget
    }
}
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target
extension PlaybackMutationTarget {
    static func capture(core: CoreBridge) -> Self { core.captureNativePlaybackTarget() }
    func stillOwnsCurrentContext(core: CoreBridge) -> Bool { core.nativePlaybackTargetIsCurrent(self) }
}
struct UserProfile {
    let id: UUID; var isOwner: Bool; var usesOwnAccount: Bool; var discovery: ProfileDiscoveryPreferences?
    var usesEngineHistory: Bool { isOwner || usesOwnAccount }
}
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var profiles: [UserProfile] = [] {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    var activeID: UUID? {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var activeUsesEngineHistory: Bool { active?.usesEngineHistory ?? true }
    var cwItems: [CoreCWItem] = []
    static var beforeInitialPublication: ((ProfileStore) -> Void)?
    private init() {
        defer { ProfileSelectionRead.publishInitial(selectionReadSnapshot()) }
        profiles = [.init(id: CWFixtureIDs.a, isOwner: true, usesOwnAccount: false,
            discovery: .init(continueWatchingSource: "trakt", continueWatchingWindow: "20"))]
        activeID = CWFixtureIDs.a
        Self.beforeInitialPublication?(self)
    }
    // PRODUCTION_SELECTION_PROJECTOR
}
enum CWScalarFixture {
    // Explicit impossible-state seam for negative controls; real publication stays coherent.
    @MainActor static func install(_ value: ProfileSelectionRead.Snapshot) {
        ProfileSelectionRead.beginMutation(); ProfileSelectionRead.endMutation(value)
    }
    static func member(_ id: UUID, owner: Bool = true, own: Bool = false, source: String? = "trakt",
                       window: String? = "20") -> ProfileSelectionRead.Snapshot.Profile {
        .init(id: id, isOwner: owner, usesOwnAccount: own, continueWatchingSource: source, continueWatchingWindow: window)
    }
}
enum SIMKLContinueWatchingFold {
    static func unavailableReason(id: String, type: String, videoID: String?) -> String? { nil }
}
final class SIMKLContinueWatchingShadow: Sendable {
    static let shared = SIMKLContinueWatchingShadow()
    struct Seed { let id: String; let type: String; let name: String; let aliases: [String]; let videoID: String?; let activity: String?; let progress: Double?; let caption: String? }
    struct Snapshot { let items: [Seed] = []; let failed = false; let hasSnapshot = false }
    func snapshot(context: HomeContinueWatchingSelection.Context, session: SIMKLSessionID) -> Snapshot { .init() }
    func refresh(context: HomeContinueWatchingSelection.Context) { preconditionFailure("inert provider seam") }
}
struct TraktNextEpisodeOffer {}
final class TraktHomeNextEpisodeProducer: Sendable {
    static let shared = TraktHomeNextEpisodeProducer()
    func requestRefresh(intent: HomeContinueWatchingSelection.Intent, core: CoreBridge) { preconditionFailure("inert next-episode seam") }
    func offers(intent: HomeContinueWatchingSelection.Intent, paused: [CoreCWItem], now: Date) -> [TraktNextEpisodeOffer] { [] }
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
struct TraktPlaybackCacheStorage: Sendable {
    private struct State: Sendable {
        var snapshot: TraktPlaybackCacheSnapshot?; var fail = false; var saveCount = 0; var resets = 0
        var hook: (@Sendable () -> Void)?
    }
    private static let state = CWBox(State())
    static func live() throws -> Self { Self() }
    static func configure(fail: Bool = false, hook: (@Sendable () -> Void)? = nil) {
        state.value = State(snapshot: nil, fail: fail, hook: hook)
    }
    static var saves: Int { state.update { $0.saveCount } }
    static var resets: Int { state.update { $0.resets } }
    func save(_ snapshot: TraktPlaybackCacheSnapshot) throws {
        let (fail, hook) = Self.state.update { value in value.saveCount += 1; return (value.fail, value.hook) }
        hook?()
        if fail { throw TraktPlaybackCacheError.write }
        Self.state.update { $0.snapshot = snapshot }
    }
    func reset() throws { Self.state.update { $0.resets += 1; $0.snapshot = nil } }
}
final class TraktPlaybackShadow: Sendable {
    static let shared = TraktPlaybackShadow()
    private let lock = NSLock()
    private struct State: Sendable {
        var progressByID: [String: Double] = [:]; var continueWatchingSeeds: [TraktContinueWatchingSeed] = []
        var hasContinueWatchingSnapshot = false; var lastActivityStamps: TraktPlaybackActivityStamps?
        var lastRefresh: Date?; var stateSessionID: TraktSessionID?; var refreshingGeneration: Int?; var generation = 0
    }
    private let state = CWBox(State())
    // PRODUCTION_CACHE_PROPERTIES
    // PRODUCTION_TRAKT_METHODS
    func refreshIfStale() { preconditionFailure("whole Trakt singleton/transport excluded") }
    func fixtureSeed(session: TraktSessionID, progress: Double = 40) {
        state.value = State(progressByID: ["private-title": progress],
            continueWatchingSeeds: [.init(id: "private-title", type: "movie", name: "Private", progress: progress,
                pausedAt: "2026-10-24T00:00:00Z", runtimeMinutes: 60, videoID: nil, poster: nil)],
            hasContinueWatchingSnapshot: true, stateSessionID: session)
    }
    func fixtureCommit(_ context: HomeContinueWatchingSelection.Context, session: TraktSessionID) -> Bool {
        commitPlayback(progress: ["new-title": 50], activity: nil, items: [], generation: generation, sessionID: session, context: context)
    }
    func fixtureFinish(generation: Int, session: TraktSessionID, context: HomeContinueWatchingSelection.Context) {
        finishRefresh(generation: generation, sessionID: session, signedIn: true, context: context)
    }
    func fixtureRefresh(generation: Int, refreshing: Int?) { self.generation = generation; refreshingGeneration = refreshing; lastRefresh = nil }
    var fixtureRefreshState: (Int?, Bool) { (refreshingGeneration, lastRefresh != nil) }
    var fixtureProgress: [String: Double] { progressByID }
}


@MainActor @main enum CWWorkerCurrentnessTests {
    static var checks = 0
    static let trakt = TraktSessionID(rawValue: "fixture-trakt-A")
    static let simkl = SIMKLSessionID(rawValue: "fixture-simkl-A")
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1; precondition(value(), label)
    }
    static var fallback: [CoreCWItem] { [.init(id: "local", type: "movie", name: "Local", poster: nil,
        state: .init(timeOffset: 10_000, duration: 100_000, videoId: nil))] }
    static var meta: PlaybackMeta { .init(id: "private-title", usesSeriesLifecycle: false, season: nil, episode: nil) }
    static func setFlat(_ source: String = "trakt", _ window: String = "20") {
        UserDefaults.standard.set(source, forKey: ContinueWatchingPreferences.sourceKey)
        UserDefaults.standard.set(window, forKey: ContinueWatchingPreferences.windowKey)
    }
    static func nativeBinding(_ id: UUID = CWFixtureIDs.a) -> PlaybackMutationOwnershipPolicy.NativeBinding {
        .init(profileID: id, credential: CredentialScopeRegistry.shared.capture(), sessionGeneration: UUID(), accountGeneration: UUID())
    }
    static func configure(owner: Bool = true, own: Bool = false, source: String = "trakt", stored: String? = "trakt",
                          window: String = "20", storedWindow: String? = "20") {
        CoreBridge.shared.beforeTarget = nil; CWMappingHook.set(nil)
        setFlat(source, window)
        let p = UserProfile(id: CWFixtureIDs.a, isOwner: owner, usesOwnAccount: own,
            discovery: .init(continueWatchingSource: stored, continueWatchingWindow: storedWindow))
        ProfileStore.shared.profiles = [p]; ProfileStore.shared.activeID = p.id
        CoreBridge.shared.usesNativeProfileState = true
        CoreBridge.shared.nativeBinding = nativeBinding()
        CoreBridge.shared.legacyTarget = .engine(profileID: p.id, keychainAccount: "fixture",
            uid: "fixture", historyCapture: CredentialScopeRegistry.shared.capture())
        CoreBridge.shared.continueWatching = fallback
        TraktAuth.storedSessionID = trakt; SIMKLAuth.storedSessionID = simkl
        TraktPlaybackShadow.shared.fixtureSeed(session: trakt)
        TraktPlaybackCacheStorage.configure()
    }
    static func context() -> HomeContinueWatchingSelection.Context {
        guard let value = HomeContinueWatchingSelection.captureContext() else { preconditionFailure("positive context required") }
        return value
    }
    static func assertRejected(_ original: HomeContinueWatchingSelection.Context, profiles: ProfileStore, label: String) {
        let intent = HomeContinueWatchingSelection.Intent(context: original, source: .trakt, traktSessionID: trakt, simklSessionID: nil)
        check(!original.isCurrent(core: .shared), label + " worker context")
        check(!original.isCurrent(core: .shared, profiles: profiles), label + " UI context")
        check(!intent.isCurrent(), label + " worker intent")
        check(!intent.isCurrent(core: .shared, profiles: profiles), label + " UI intent")
        check(HomeContinueWatchingSelection.captureContext() == nil, label + " capture")
        check(!HomeContinueWatchingSelection.awaitsRecapture(intent, profiles: profiles), label + " retention")
        check(TraktPlaybackShadow.shared.suggestion(for: meta, localSeconds: 10, durationSeconds: 3600) == nil,
              label + " direct valid private resume cache denied")
        let selection = TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback)
        check(selection.source == .local && selection.items.map(\.id) == ["local"], label + " direct cache local fallback")
    }
    static func worker(_ operation: @escaping @Sendable () -> Bool, label: String) {
        let result = CWBox(false), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { result.value = operation(); done.signal() }
        check(done.wait(timeout: .now() + 5) == .success, label + " no MainActor wait")
        check(result.value, label)
    }
    static func main() {
        // A valid private cache is present before the owner finishes initialization.
        setFlat(); TraktAuth.storedSessionID = trakt; SIMKLAuth.storedSessionID = simkl
        CoreBridge.shared.nativeBinding = nativeBinding()
        TraktPlaybackShadow.shared.fixtureSeed(session: trakt)
        let initial = HomeContinueWatchingSelection.Context(profileID: CWFixtureIDs.a, usesNativeProfileState: true,
            usesEngineHistory: true, nativeTarget: CoreBridge.shared.captureNativePlaybackTarget())
        ProfileStore.beforeInitialPublication = { store in
            check(ProfileSelectionRead.snapshot() == nil, "unavailable through RAM initializer")
            assertRejected(initial, profiles: store, label: "uninitialized")
        }
        _ = ProfileStore.shared
        ProfileStore.beforeInitialPublication = nil
        configure()
        check(TraktPlaybackShadow.shared.suggestion(for: meta, localSeconds: 10, durationSeconds: 3600)?.seconds == 1440,
              "valid owner private resume positive control")
        let ownerRows = TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback)
        check(ownerRows.source == .trakt && ownerRows.sessionID == trakt
            && ownerRows.items.map(\.id) == ["private-title"], "valid owner direct private cache positive control")
        let original = context()
        let member = CWScalarFixture.member(CWFixtureIDs.a)
        let invalid: [(String, ProfileSelectionRead.Snapshot)] = [
            ("empty selection", .init(activeID: nil, activeProfile: nil)),
            ("selected missing row", .init(activeID: CWFixtureIDs.a, activeProfile: nil)),
            ("member but nil selected", .init(activeID: nil, activeProfile: member)),
            ("selected/member mismatch", .init(activeID: CWFixtureIDs.a, activeProfile: CWScalarFixture.member(CWFixtureIDs.b))),
        ]
        for (label, snapshot) in invalid {
            CWScalarFixture.install(snapshot)
            assertRejected(original, profiles: .shared, label: label)
        }
        configure()
        CoreBridge.shared.usesNativeProfileState = false
        let legacyOwner = context()
        let legacyRows = TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback)
        check(legacyRows.source == .trakt && legacyRows.sessionID == trakt
            && legacyRows.items.map(\.id) == ["private-title"], "valid legacy direct private cache positive control")
        for (label, snapshot) in invalid {
            CWScalarFixture.install(snapshot)
            assertRejected(legacyOwner, profiles: .shared, label: "legacy " + label)
        }
        configure(owner: false, own: true)
        check(TraktPlaybackShadow.shared.suggestion(for: meta, localSeconds: 10, durationSeconds: 3600) != nil, "own-account private positive")
        let ownRows = TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback)
        check(ownRows.source == .trakt && ownRows.sessionID == trakt
            && ownRows.items.map(\.id) == ["private-title"], "own-account direct private cache positive control")
        configure(owner: false, own: false)
        let sharedContext = context()
        check(sharedContext.isCurrent(core: .shared), "extant shared context retains captured false eligibility")
        let shared = HomeContinueWatchingSelection.current(core: .shared, profiles: .shared)
        check(shared.selection.source == .local && shared.selection.items.map(\.id) == ["local"], "extant shared native Local bucket positive")
        check(TraktPlaybackShadow.shared.suggestion(for: meta, localSeconds: 10, durationSeconds: 3600) == nil, "shared private suggestion denied")
        check(TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback).source == .local, "shared direct service cache denied")
        configure(source: "local", stored: nil, storedWindow: nil)
        check(context().isCurrent(core: .shared), "nil discovery defaults only after extant-member admission")
        configure(source: "trakt", stored: "local")
        check(HomeContinueWatchingSelection.captureContext() == nil, "flat-only pending/failed source is not acknowledged")
        check(TraktPlaybackShadow.shared.continueWatchingSelection(fallback: fallback).source == .local, "direct native cache respects acknowledged stored source")
        configure(source: "trakt", stored: "trakt", window: "40", storedWindow: "20")
        check(HomeContinueWatchingSelection.captureContext() == nil, "flat-only pending/failed window is not acknowledged")
        configure(source: "unknown", stored: "unknown")
        check(HomeContinueWatchingSelection.captureContext() == nil, "unsupported source unavailable")
        configure()
        let current = context()
        worker({
            current.isCurrent(core: .shared)
                && TraktPlaybackShadow.shared.suggestion(for: .init(id: "private-title", usesSeriesLifecycle: false, season: nil, episode: nil),
                    localSeconds: 10, durationSeconds: 3600) != nil
        }, label: "checked Context and direct predicate run on worker without owner access")
        let same = ProfileSelectionRead.snapshot()!
        for index in 0..<4 {
            configure()
            let captured = context()
            CoreBridge.shared.beforeTarget = {
                CoreBridge.shared.beforeTarget = nil
                switch index {
                case 0: CWScalarFixture.install(.init(activeID: CWFixtureIDs.a, activeProfile: nil))
                case 1: CWScalarFixture.install(.init(activeID: CWFixtureIDs.a,
                    activeProfile: CWScalarFixture.member(CWFixtureIDs.a, source: "local")))
                case 2: ContinueWatchingPreferences.retireSelection()
                default: UserDefaults.standard.set("local", forKey: ContinueWatchingPreferences.sourceKey)
                }
            }
            check(!captured.isCurrent(core: .shared), "post-original-target recheck rejects mutation \(index)")
        }
        CWScalarFixture.install(same)
        configure()
        let oldTarget = context()
        CoreBridge.shared.nativeBinding = nativeBinding(CWFixtureIDs.b)
        CoreBridge.shared.nativeBinding = nativeBinding(CWFixtureIDs.a)
        check(!oldTarget.isCurrent(core: .shared), "profile A-B-A cannot replace original native target")
        let retention = HomeContinueWatchingSelection.Intent(context: oldTarget, source: .trakt, traktSessionID: trakt, simklSessionID: nil)
        check(HomeContinueWatchingSelection.awaitsRecapture(retention), "extant same-owner generation-only UI retention remains positive")
        ProfileStore.shared.profiles = []
        check(!HomeContinueWatchingSelection.awaitsRecapture(retention), "generation-only retention cannot admit absent roster row")
        configure()
        let epoch = context()
        _ = ContinueWatchingPreferences.writeUserChoice("local", forKey: ContinueWatchingPreferences.sourceKey) { setFlat("local") }
        _ = ContinueWatchingPreferences.writeUserChoice("trakt", forKey: ContinueWatchingPreferences.sourceKey) { setFlat() }
        check(!epoch.isCurrent(core: .shared), "preference A-B-A retires old epoch")
        let provider = HomeContinueWatchingSelection.Intent(context: context(), source: .trakt, traktSessionID: trakt, simklSessionID: nil)
        TraktAuth.storedSessionID = .init(rawValue: "fixture-B")
        TraktAuth.storedSessionID = .init(rawValue: "fixture-A-reinstalled")
        check(!provider.isCurrent(), "provider A-B-A replacement cannot revive original session")
        configure()
        let legacy = context()
        CoreBridge.shared.usesNativeProfileState = false
        let legacyCurrent = context()
        check(legacyCurrent.isCurrent(core: .shared), "legacy retained lane positive")
        CredentialScopeRegistry.shared.retire()
        check(!legacyCurrent.isCurrent(core: .shared) && !legacy.isCurrent(core: .shared), "credential replacement retires original legacy and native contexts")
        configure()
        CWMappingHook.set { CWScalarFixture.install(.init(activeID: CWFixtureIDs.a, activeProfile: nil)) }
        check(TraktPlaybackShadow.shared.suggestion(for: meta, localSeconds: 10, durationSeconds: 3600) == nil,
              "same-turn metadata mapping mutation denies private suggestion")
        configure()
        let mappingFallback = fallback
        CWMappingHook.set { TraktAuth.storedSessionID = .init(rawValue: "fixture-mapping-replacement") }
        check(TraktPlaybackShadow.shared.continueWatchingSelection(fallback: mappingFallback).source == .local,
              "same-turn row mapping/provider replacement denies private cache")
        remainingBoundaryChecks()
        cachePublicationChecks()
        print("PASS CW worker currentness: \(checks) RAM/exact-predicate checks; no whole Trakt singleton/app claim")
    }
    static func remainingBoundaryChecks() {
        configure(); let beforeWindowChange = context()
        CoreBridge.shared.beforeTarget = {
            CoreBridge.shared.beforeTarget = nil
            CWScalarFixture.install(.init(activeID: CWFixtureIDs.a,
                activeProfile: CWScalarFixture.member(CWFixtureIDs.a, window: "40")))
        }
        check(!beforeWindowChange.isCurrent(core: .shared),
              "stored window mutation during original-target validation fails final scalar recheck")
        check(ContinueWatchingPreferences.current().window.rawValue == "20"
            && ProfileSelectionRead.snapshot()?.activeProfile?.continueWatchingWindow == "40",
              "stored window mutation control keeps flat preference unchanged")

        configure(); let beforeNativeReplacement = context()
        let unchangedSelection = ProfileSelectionRead.snapshot()
        let replacementB = nativeBinding(CWFixtureIDs.b), replacementA = nativeBinding(CWFixtureIDs.a)
        TraktPlaybackCacheStorage.configure(hook: {
            CoreBridge.shared.nativeBinding = replacementB
            CoreBridge.shared.nativeBinding = replacementA
        })
        check(!TraktPlaybackShadow.shared.fixtureCommit(beforeNativeReplacement, session: trakt),
              "native binding A-B-A during RAM save rejects the original captured target")
        check(ProfileSelectionRead.snapshot() == unchangedSelection
            && CoreBridge.shared.nativeBinding?.profileID == CWFixtureIDs.a
            && TraktPlaybackCacheStorage.saves == 1 && TraktPlaybackCacheStorage.resets == 1
            && TraktPlaybackShadow.shared.fixtureProgress["private-title"] == 40
            && TraktPlaybackShadow.shared.fixtureProgress["new-title"] == nil,
              "native save-boundary replacement retains scalar A, resets RAM persistence, and never publishes memory")

        configure(); let beforeProviderReplacement = context()
        let replacementSession = TraktSessionID(rawValue: "fixture-save-provider-replacement")
        TraktPlaybackCacheStorage.configure(hook: { TraktAuth.storedSessionID = replacementSession })
        check(!TraktPlaybackShadow.shared.fixtureCommit(beforeProviderReplacement, session: trakt),
              "provider replacement during RAM save fails the real post-save session predicate")
        check(beforeProviderReplacement.isCurrent(core: .shared)
            && TraktAuth.storedSessionID == replacementSession,
              "provider save-boundary control leaves captured scalar and original native target current")
        check(TraktPlaybackCacheStorage.saves == 1 && TraktPlaybackCacheStorage.resets == 1
            && TraktPlaybackShadow.shared.fixtureProgress["private-title"] == 40
            && TraktPlaybackShadow.shared.fixtureProgress["new-title"] == nil,
              "provider save-boundary replacement resets only RAM persistence and preserves previous memory")
    }
    static func cachePublicationChecks() {
        configure(); let c = context()
        TraktPlaybackCacheStorage.configure(fail: true)
        check(!TraktPlaybackShadow.shared.fixtureCommit(c, session: trakt), "failed save cannot publish memory")
        check(TraktPlaybackShadow.shared.fixtureProgress["private-title"] == 40, "failed save retains prior same-session state")
        configure(); let before = context()
        CWScalarFixture.install(.init(activeID: CWFixtureIDs.a, activeProfile: nil))
        check(!TraktPlaybackShadow.shared.fixtureCommit(before, session: trakt) && TraktPlaybackCacheStorage.saves == 0,
              "stale before lock writes nothing")
        configure(); let beforeSave = context(), calls = CWBox(0)
        CoreBridge.shared.beforeTarget = {
            let count = calls.update { $0 += 1; return $0 }
            if count == 2 { CWScalarFixture.install(.init(activeID: CWFixtureIDs.a, activeProfile: nil)) }
        }
        check(!TraktPlaybackShadow.shared.fixtureCommit(beforeSave, session: trakt) && TraktPlaybackCacheStorage.saves == 0,
              "stale lock-held pre-save predicate writes nothing")
        CoreBridge.shared.beforeTarget = nil
        configure(); let afterSave = context()
        TraktPlaybackCacheStorage.configure(hook: {
            CWScalarFixture.install(.init(activeID: CWFixtureIDs.a, activeProfile: nil))
        })
        check(!TraktPlaybackShadow.shared.fixtureCommit(afterSave, session: trakt), "mutation during RAM save fails post-save guard")
        check(TraktPlaybackCacheStorage.saves == 1 && TraktPlaybackCacheStorage.resets == 1
            && TraktPlaybackShadow.shared.fixtureProgress["private-title"] == 40, "stale saved result resets only RAM persistence and never exposes memory")
        configure(); let good = context()
        check(TraktPlaybackShadow.shared.fixtureCommit(good, session: trakt), "matching save/publish positive control")
        let shadow = TraktPlaybackShadow.shared
        shadow.fixtureRefresh(generation: 2, refreshing: 3)
        shadow.fixtureFinish(generation: 1, session: trakt, context: good)
        check(shadow.fixtureRefreshState.0 == 3 && !shadow.fixtureRefreshState.1, "old refresh cannot clear successor or arm throttle")
        shadow.fixtureRefresh(generation: 2, refreshing: 2)
        shadow.fixtureFinish(generation: 2, session: trakt, context: good)
        check(shadow.fixtureRefreshState.0 == nil && shadow.fixtureRefreshState.1, "matching refresh clears itself and arms throttle")
    }
}
