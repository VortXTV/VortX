// Inert host fixture. The runner inserts byte-extracted production methods at the markers below.
// No installed-app probes, URL opens, accounts, provider requests, media, or audio are used.
import Foundation
import Combine

enum CredentialScope: Hashable { case signedOutDevice }
final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()
    struct Capture: Equatable, Hashable, Sendable { let generation: UInt64 }
    var generation: UInt64 = 1
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}

// INSERT_OWNERSHIP_POLICY
// INSERT_PLAYBACK_METADATA
// INSERT_OWNER_EXTENSION
enum EpisodePlaybackIdentity {
    // INSERT_SERIES_LIFECYCLE
}

enum VortxJSON: Equatable { case string(String), unsigned(UInt64), object([String: VortxJSON]), null }
final class VortxNativeCoreFacade: @unchecked Sendable {
    struct RegistryBinding { let profileID: String }
    var registryBinding: RegistryBinding?
    var accountGeneration = UUID()
    var isAvailable = true
    var actions: [VortxJSON] = []
    var resume = 123.9
    var suspendResume = false
    private let resumeLock = NSLock()
    private var storedResumeGate: CheckedContinuation<Double, Never>?
    var resumeGate: CheckedContinuation<Double, Never>? {
        get { resumeLock.withLock { storedResumeGate } }
        set { resumeLock.withLock { storedResumeGate = newValue } }
    }
    func resumeSeconds(id: String, profileID: String, expectedAccountGeneration: UUID) async throws -> Double {
        if suspendResume { return await withCheckedContinuation { resumeGate = $0 } }
        return resume
    }
    func dispatchForProfile(_ value: VortxJSON, profileID: String, expectedAccountGeneration: UUID) -> Bool {
        guard registryBinding?.profileID == profileID, accountGeneration == expectedAccountGeneration else { return false }
        actions.append(value)
        return true
    }
}
final class ProfileStore: ObservableObject, @unchecked Sendable {
    static let shared = ProfileStore()
    @Published var activeID: UUID? = UUID()
    func recordProgress(meta: PlaybackMeta, positionSeconds: Double, durationSeconds: Double, profileID: UUID) {}
}
final class CoreBridge: @unchecked Sendable {
    static let shared = CoreBridge()
    var usesNativeProfileState = true
    private let nativeFacadeLock = NSLock()
    var nativeFacadeStorage: VortxNativeCoreFacade? = VortxNativeCoreFacade()
    var nativeCredentialCapture: CredentialScopeRegistry.Capture? = CredentialScopeRegistry.shared.capture()
    var nativeInstallGeneration = UUID()
    var nativePublishedAccountGeneration: UUID?
    var watched: [PlaybackMeta] = []
    func reset() {
        let facade = VortxNativeCoreFacade()
        facade.registryBinding = .init(profileID: ProfileStore.shared.activeID!.uuidString)
        nativeFacadeStorage = facade
        nativeCredentialCapture = CredentialScopeRegistry.shared.capture()
        nativePublishedAccountGeneration = facade.accountGeneration
        nativeInstallGeneration = UUID()
        watched = []
    }
    func markPlaybackWatched(_ meta: PlaybackMeta, target: PlaybackMutationTarget) {
        if target.stillOwnsCurrentContext(core: self) { watched.append(meta) }
    }
    func syncLibraryNow() {}
    // INSERT_NATIVE_BOUNDARY
}
enum ProfileSync { static let alsoSyncToStremio = false }
enum OwnerHistoryStore {
    static func recordPlayback(titleID: String, type: String, name: String, poster: String?, videoID: String,
                               positionSeconds: Double, durationSeconds: Double, capture: CredentialScopeRegistry.Capture) -> Bool { false }
}
@MainActor final class StremioAccount {
    var credentialBoundaryGeneration: UInt64 = 0
    var isSignedIn = true
    var authKey: String? { nil }
    static func isoNow() -> String { "fixture" }
    static func newLibraryItem(_ meta: PlaybackMeta, now: String) -> [String: Any] { [:] }
    func rawLibraryItem(id: String, authKey: String) async -> [String: Any]? { nil }
    func datastorePut(authKey: String, change: [String: Any]) async {}
    func resumeOffset(for meta: PlaybackMeta) async -> Double { 123.9 }
    // INSERT_ACCOUNT_PROGRESS
}
@MainActor enum SeriesSourceSticky {
    static var choices: [(String, String?, String?)] = []
    static func record(seriesKey: String, addon: String?, bingeGroup: String?) {
        if addon != nil || bingeGroup != nil { choices.append((seriesKey, addon, bingeGroup)) }
    }
}
struct CoreVideo { let id: String; let season: Int?; let episode: Int?; let releasedDate: Date? }
// Environmental configuration only: the real adapter's bundle lookup reads this inert fixture value.
enum Bundle { static let main = Self.fixture; case fixture
    func object(forInfoDictionaryKey key: String) -> Any? { key == "VortXURLScheme" ? "vortx-fixture" : nil }
}

@MainActor class ExitFixturePlayer {
    var activeLoadToken: UUID? = UUID()
    var stops = 0
    func invalidateLoadToken() { activeLoadToken = nil }
    func stop() { stops += 1 }
}
@MainActor final class AVPlayerEngineController: ExitFixturePlayer { var isRemuxMounted = false }
@MainActor final class ScrobbleCoordinator {
    static let shared = ScrobbleCoordinator()
    var stops = 0
    func playbackStopped(_ meta: PlaybackMeta, position: Double, duration: Double) { stops += 1 }
}
enum DiskCacheSetting { static func clearCache() {} }
@MainActor final class TVExitFixture {
    struct Lease { func close() {} }
    struct Ref { var nativeUsenetLease: Lease? }
    struct Advance { var debridRef: Ref? }
    struct Coordinator { var player: ExitFixturePlayer? = ExitFixturePlayer() }
    struct Sanity { func isAccepted(owner: UUID?) -> Bool { owner != nil } }
    var coordinator = Coordinator()
    var assetSanityAttempt = Sanity()
    var pendingAdvance: Advance?, supersededAdvance: Advance?, curDebridRef: Ref?
    var failedEpisodeResolutionTarget: UUID?, exitAcceptedLoadToken: UUID?
    var leftPlayback = false, refinding = false, eofFrozenAtTerminal = false
    var persistenceBlockedForExit = false, hasUncommittedIssuedMedia = false, switchingEpisode = false
    var isCurrentLiveStream = false
    var episodeSwitchGeneration = 1, sourceSwitchGeneration = 1, resumeRetryGeneration = 1
    var terminalAdvanceDeadlineTask: Task<Void, Never>?, refindTask: Task<Void, Never>?
    var autoRetryTask: Task<Void, Never>?, avToMPVHandoffTask: Task<Void, Never>?
    var currentTime = 95.0, duration = 100.0, suppressedResumeFloor: Double?
    var curMeta: PlaybackMeta? = InfuseReturnTests.meta
    var currentTorrentHash: String?
    var closeCount = 0
    var account = StremioAccount()
    var core = CoreBridge.shared
    var playbackMutationTarget = PlaybackMutationTarget.capture(core: CoreBridge.shared)
    func resetRapidBufferingRecovery(reason: String) {}
    func clearPostFrameResumeSeekWatchdog() {}
    func cancelTerminalFinalityRefresh() {}
    func cancelDirectResumeInventoryRefresh() {}
    func cancelEmptySourceRecovery() {}
    func refreshPlaybackIdleTimer() {}
    func flushPendingSubOffsetSave() {}
    func invalidateEpisodeResolution() {}
    func invalidateNextEpisodePreparation(reason: String) {}
    func invalidateLocalTrickplayCapture() {}
    func cancelAssetSanityObservationDeadline() {}
    func closeTorrent(hash: String) {}
    static func replayServerConfigAfterRemux() {}
    func onClose() { closeCount += 1 }
    func exitForHandoff() {
        #if BASELINE
        leavePlayback()
        // Baseline had no external-handoff admission mode.
        #else
        leavePlayback(externalHandoff: true)
        #endif
        saveProgress(at: currentTime, acceptedOwner: exitAcceptedLoadToken)
    }
    func exitNormally() {
        leavePlayback()
        saveProgress(at: currentTime, acceptedOwner: exitAcceptedLoadToken)
    }
    // INSERT_TV_EXIT
    // INSERT_TV_PROGRESS
}
@MainActor final class IOSExitFixture {
    struct Deferred { func invalidate() {} }
    var persistenceBlockedForExit = false, hasUncommittedIssuedMedia = false, externalHandoffConfirmed = false
    var playbackExited = false, switchingEpisode = false, engineWritesOpen = true
    var episodeSwitchGeneration = 1, resumeRetryGeneration = 1
    var episodeResolveGeneration: Int?, pendingAdvance: Int?, supersededAdvance: Int?, failedEpisodeResolutionID: String?
    var deferredResumeAttempt = Deferred()
    var autoRetryTask: Task<Void, Never>?
    var coordinator = TVExitFixture.Coordinator()
    var assetSanityAttempt = TVExitFixture.Sanity()
    var suppressedResumeFloor: Double?, duration = 100.0
    var curMeta: PlaybackMeta? = InfuseReturnTests.meta
    var playbackMutationTarget = PlaybackMutationTarget.capture(core: CoreBridge.shared)
    var account = StremioAccount()
    var engineWrites = 0
    func onProgress(_ position: Double, _ duration: Double, _ target: PlaybackMutationTarget) { engineWrites += 1 }
    func invalidateEpisodeResolution() {}
    func invalidatePreparedEpisode(reason: String) {}
    func disappear(confirmed: Bool) {
        if confirmed { externalHandoffConfirmed = true; persistenceBlockedForExit = true }
        let oldToken = coordinator.player?.activeLoadToken
        invalidateEpisodeWorkForExit()
        reportProgress(95, acceptedOwner: oldToken)
    }
    // INSERT_IOS_INVALIDATE
    // INSERT_IOS_PROGRESS
    // INSERT_IOS_ACCOUNT_PROGRESS
}

// INSERT_INFUSE_LINK
// INSERT_TRANSFER_POLICY
#if !BASELINE
// INSERT_COORDINATOR
// INSERT_ADAPTER

@MainActor final class UIApplication {
    static let shared = UIApplication()
    var opened: URL?
    var completion: ((Bool) -> Void)?
    func open(_ url: URL, options: [String: Any], completionHandler: @escaping (Bool) -> Void) {
        opened = url; completion = completionHandler
    }
}
@MainActor final class NSWorkspace {
    struct OpenConfiguration {}
    static let shared = NSWorkspace()
    var opened: URL?
    var completion: ((Any?, Error?) -> Void)?
    func open(_ url: URL, configuration: OpenConfiguration, completionHandler: @escaping (Any?, Error?) -> Void) {
        opened = url; completion = completionHandler
    }
}
enum FixtureExternalPlayer {
    struct Target {
        var id = "infuse"
        var isInstalled = true
        func deepLink(for stream: URL, metadata: PlaybackMeta?) -> URL? { stream }
    }
    // INSERT_APPLE_OPEN
}
enum FixtureTVExternalPlayers {
    struct Player { let scheme: String; func launch(_ stream: URL, _ metadata: PlaybackMeta?) -> URL? { stream } }
    // INSERT_TV_OPEN
}
@MainActor struct TVDefaultFence {
    var leftPlayback = false
    var curURL: URL? = InfuseReturnTests.stream
    var playbackSessionID = "session"
    var episodeSwitchGeneration = 3
    var coordinator = TVExitFixture.Coordinator()
    func capture(u: URL) -> () -> Bool {
        let session = playbackSessionID, generation = episodeSwitchGeneration
        let owner = coordinator.player!.activeLoadToken!
        // INSERT_TV_DEFAULT_FENCE
        return allowsLaunch
    }
}
#endif

@main enum InfuseReturnTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ label: String, _ value: Bool) {
        checks += 1
        if value { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
    }
    static let stream = URL(string: "https://media.invalid/episode.mkv?token=SYNTHETIC_PRIVATE_TOKEN%26x")!
    static let meta = PlaybackMeta(libraryId: "tt1234", videoId: "provider:episode:2", type: "series", name: "Example",
                                   poster: nil, season: 1, episode: 2)
    static func query(_ url: URL) -> [URLQueryItem] { URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [] }
    static func value(_ url: URL, _ name: String) -> String? { query(url).first { $0.name == name }?.value }
    static func callback(_ launch: URL, position: String = "42", stream: String? = nil, error: Bool = false) -> URL {
        let raw = value(launch, error ? "x-error" : "x-success")!
        var components = URLComponents(string: raw)!
        components.queryItems = error
            ? [.init(name: "failedUrl", value: stream ?? Self.stream.absoluteString), .init(name: "errorCode", value: "100")]
            : [.init(name: "lastPlayedUrl", value: stream ?? Self.stream.absoluteString), .init(name: "position", value: position)]
        return components.url!
    }
    @MainActor static func drain() async { for _ in 0..<30 { await Task.yield() } }

    @MainActor static func main() async {
        let core = CoreBridge.shared
        core.reset()
        let account = StremioAccount()
        #if BASELINE
        let link = InfuseDeepLink.playURL(stream: stream, metadata: meta)!
        check("baseline actual link carries requested resume", value(link, "position") == "123")
        check("baseline actual link supplies return capability", value(link, "x-success") != nil && value(link, "x-error") != nil)
        await account.saveProgress(for: meta, positionSeconds: 42, durationSeconds: 0, target: .capture(core: core))
        check("baseline actual native boundary accepts unknown duration", core.nativeFacadeStorage!.actions.count == 1)
        let baselineExit = TVExitFixture()
        ScrobbleCoordinator.shared.stops = 0
        baselineExit.exitForHandoff(); await drain()
        check("baseline actual handoff exit suppresses synchronous scrobble stop", ScrobbleCoordinator.shared.stops == 0)
        check("baseline actual handoff exit suppresses stale progress flush", core.nativeFacadeStorage!.actions.isEmpty)
        core.reset()
        let iosExit = IOSExitFixture()
        iosExit.disappear(confirmed: true); await drain()
        check("baseline actual iOS disappearance preserves external progress fence", iosExit.engineWrites == 0 && core.nativeFacadeStorage!.actions.isEmpty)
        #else
        await coordinatorChecks()
        await adapterChecks(account)
        await wrapperChecks(account)
        await nativeBoundaryChecks(account)
        await exitChecks()
        #endif
        print("RESULT \(checks - failures)/\(checks) passed; \(failures) failed")
        if failures > 0 { exit(1) }
    }

    #if !BASELINE
    @MainActor static func coordinatorChecks() async {
        let coordinator = InfuseHandoffCoordinator()
        var current = true
        var progress: [(Double, Double?)] = []
        var watched = 0
        var sources = 0
        let episodes: [InfuseHandoffCoordinator.Episode] = [
            .init(id: "special", season: 0, episode: 1), .init(id: meta.videoId, season: 1, episode: 2),
            .init(id: "opaque-next", season: 2, episode: 1)]
        func context(_ duration: Double? = nil) -> InfuseHandoffCoordinator.Context {
            .init(metadata: meta, duration: duration, episodes: episodes, isCurrent: { current },
                  progress: { progress.append(($0, $1)) }, watched: { watched += 1 }, acceptedSource: { sources += 1 })
        }
        func launch(_ duration: Double? = nil) -> InfuseHandoffCoordinator.Launch {
            let launch = coordinator.prepare(stream: stream, position: 123.9, scheme: "vortx-fixture", context: context(duration))!
            coordinator.launchFinished(launch.id, launched: true)
            return launch
        }
        let first = launch()
        check("real resume encoded as whole seconds", value(first.url, "position") == "123")
        check("exact stream and filename retained", value(first.url, "url") == stream.absoluteString
              && value(first.url, "filename") == "Example S01E02 {imdb-tt1234}.mkv")
        check("launch alone has no progress watched or preference", progress.isEmpty && watched == 0 && sources == 0)
        coordinator.handle(callback(first.url))
        check("early close returns exact genuine position with unknown duration", progress.count == 1 && progress[0].0 == 42 && progress[0].1 == nil)
        check("success alone never marks completed", watched == 0 && coordinator.returned?.completed == false)
        check("next regular episode crosses season without choosing S0", coordinator.returned?.next?.id == "opaque-next")
        coordinator.handle(callback(first.url, position: "1000"))
        check("duplicate return consumed once", progress.count == 1 && watched == 0 && sources == 1)
        check("explicit watched confirmation accepted exactly once", coordinator.confirmWatched(first.id) && !coordinator.confirmWatched(first.id) && watched == 1)
        let second = launch(100)
        check("old confirmation cannot retire or mutate a newer pending launch", !coordinator.confirmWatched(first.id))
        coordinator.handle(callback(first.url))
        check("old generation cannot consume new launch", coordinator.returned == nil)
        coordinator.handle(callback(second.url, position: "89"))
        check("known duration early close still not completion", coordinator.returned?.completed == false && watched == 1)
        let third = launch(100)
        coordinator.handle(callback(third.url, position: "90"))
        check("real duration uses existing Apple 90 percent watched policy", coordinator.returned?.completed == true && watched == 2)
        let mismatchedDuration = launch(100)
        coordinator.handle(callback(mismatchedDuration.url, position: "300"))
        check("timestamp beyond captured duration cannot fake completion", coordinator.returned?.completed == false && progress.last?.1 == nil && watched == 2)
        let fourth = launch()
        let before = progress.count
        let malformed: [URL] = [callback(fourth.url, position: "-1"), callback(fourth.url, position: "1.2"),
            callback(fourth.url, position: "NaN"), callback(fourth.url, position: "999999"),
            callback(fourth.url, stream: "https://wrong.invalid/e3.mkv")]
        for url in malformed { coordinator.handle(url) }
        var duplicated = URLComponents(url: callback(fourth.url), resolvingAgainstBaseURL: false)!
        duplicated.queryItems?.append(.init(name: "position", value: "70"))
        coordinator.handle(duplicated.url!)
        check("malformed duplicate or wrong stream cannot update or consume", progress.count == before && coordinator.returned == nil)
        var foreign = URLComponents(url: callback(fourth.url), resolvingAgainstBaseURL: false)!
        foreign.scheme = "another-app"
        coordinator.handle(foreign.url!)
        check("foreign callback scheme refused", coordinator.returned == nil)
        coordinator.handle(callback(fourth.url, error: true))
        check("Infuse error never progress watched source or next", progress.count == before && watched == 2
              && coordinator.returned?.failed == true && coordinator.returned?.next == nil && !coordinator.confirmWatched(fourth.id))
        let failedLaunch = coordinator.prepare(stream: stream, position: 0, scheme: "vortx-fixture", context: context())!
        coordinator.launchFinished(failedLaunch.id, launched: false)
        coordinator.handle(callback(failedLaunch.url))
        check("rejected OS launch has no callback authority", coordinator.returned == nil)
        let retired = launch()
        current = false
        coordinator.handle(callback(retired.url))
        current = true
        coordinator.handle(callback(retired.url))
        check("retired owner cannot revive consumed pending authority", coordinator.returned == nil && progress.count == before)
        let old = launch()
        let fresh = launch()
        coordinator.launchFinished(old.id, launched: false)
        coordinator.handle(callback(fresh.url, position: "0"))
        check("late launch failure isolated and zero position retained", coordinator.returned?.id == fresh.id && progress.last?.0 == 0)
        let special = PlaybackMeta(libraryId: "s", videoId: "special", type: "series", name: "s", poster: nil, season: 0, episode: 1)
        check("explicit special selection keeps its own successor", InfuseHandoffCoordinator.nextEpisode(after: special, in: episodes)?.id == meta.videoId)
        check("explicit special selection may continue through specials", InfuseHandoffCoordinator.nextEpisode(after: special,
            in: episodes + [.init(id: "special-next", season: 0, episode: 2)])?.id == "special-next")
        check("unknown missing or duplicate episode identity refuses next", InfuseHandoffCoordinator.nextEpisode(after: meta, in: []) == nil
              && InfuseHandoffCoordinator.nextEpisode(after: meta, in: episodes + [episodes[1]]) == nil)
        check("duplicate successor coordinate refuses silent lexical pick", InfuseHandoffCoordinator.nextEpisode(after: meta,
            in: episodes + [.init(id: "conflicting-next", season: 2, episode: 1)]) == nil)
        check("same opaque ID with inconsistent episode coordinates refuses next", InfuseHandoffCoordinator.nextEpisode(after: meta,
            in: [.init(id: meta.videoId, season: 3, episode: 1), .init(id: "next", season: 3, episode: 2)]) == nil)
        for url in ["http://127.0.0.1/s", "http://127.2.3.4/s", "http://localhost/s", "http://[::1]/s", "file:///movie.mkv", "http://2130706433/s",
                    "http://[0:0:0:0:0:0:0:1]/s", "http://[::ffff:7f00:1]/s", "http://localhost./s", "http://127.0.0.1./s",
                    "http://0177.0.0.1/s", "http://0x7f000001/s", "http://127.1/s", "http://[::127.0.0.1]/s", "http://[::]/s"] {
            check("local or nonremote media rejected \(URL(string: url)!.scheme!)", !InfuseHandoffCoordinator.canTransfer(URL(string: url)!))
        }
        check("invalid outgoing positions are safe", InfuseDeepLink.resumePosition(.nan) == 0 && InfuseDeepLink.resumePosition(.infinity) == 0
              && InfuseDeepLink.resumePosition(-1) == 0 && InfuseDeepLink.resumePosition(Double.greatestFiniteMagnitude) == 0)
        var launchAlive = true
        let detached = coordinator.prepare(stream: stream, position: 0, scheme: "vortx-fixture", context: context(),
                                           allowsLaunch: { launchAlive })!
        coordinator.launchFinished(detached.id, launched: true)
        launchAlive = false
        coordinator.handle(callback(detached.url))
        check("confirmed launch drops dismissed view predicate but preserves owner", coordinator.returned?.id == detached.id)
    }

    @MainActor static func adapterChecks(_ account: StremioAccount) async {
        let core = CoreBridge.shared
        let adapter = ExternalPlaybackHandoff.shared
        core.reset(); adapter.dismiss(); SeriesSourceSticky.choices = []
        let request = ExternalPlaybackHandoff.Request(metadata: meta, account: account, addon: "Chosen provider", bingeGroup: "Chosen release")
        let launch = await adapter.prepare(stream: stream, metadata: meta, request: request)!
        check("actual adapter reads exact owner resume", value(launch.url, "position") == "123")
        adapter.launchFinished(launch, launched: true)
        adapter.refresh()
        adapter.handle(callback(launch.url, position: "bad"))
        var staleNonce = URLComponents(url: callback(launch.url), resolvingAgainstBaseURL: false)!
        staleNonce.path = "/\(UUID().uuidString.lowercased())/success"
        adapter.handle(staleNonce.url!)
        adapter.handle(callback(launch.url))
        await drain()
        guard case let .object(action)? = core.nativeFacadeStorage!.actions.last else { check("native action emitted", false); return }
        check("actual adapter and account writer preserve exact episode at unknown duration", action["videoId"] == .string(meta.videoId)
              && action["metaId"] == .string(meta.libraryId) && action["positionMs"] == .unsigned(42000) && action["durationMs"] == .unsigned(0))
        check("foreground refresh and malformed old-nonce callbacks preserve valid pending launch", adapter.presentation?.id == launch.id)
        check("unknown duration progress is not watched", core.watched.isEmpty && adapter.presentation?.completed == false)
        check("accepted explicit source preference retained", SeriesSourceSticky.choices.count == 1 && SeriesSourceSticky.choices[0].1 == "Chosen provider")
        adapter.confirmWatched(launch.id!)
        check("explicit confirmation reaches exact captured watched target", core.watched == [meta])
        adapter.dismiss()
        let staleRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account)
        let originalProfile = ProfileStore.shared.activeID
        ProfileStore.shared.activeID = UUID(); ProfileStore.shared.activeID = originalProfile
        check("synchronous profile A B A epoch prevents revival", await adapter.prepare(stream: stream, metadata: meta, request: staleRequest) == nil)
        adapter.dismiss()
        let staleCredential = ExternalPlaybackHandoff.Request(metadata: meta, account: account)
        account.credentialBoundaryGeneration += 1
        check("same slot account replacement refuses old launch", await adapter.prepare(stream: stream, metadata: meta, request: staleCredential) == nil)
        adapter.dismiss()
        let facade = core.nativeFacadeStorage!
        facade.suspendResume = true
        let suspendedRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account)
        let task = Task { @MainActor in await adapter.prepare(stream: stream, metadata: meta, request: suspendedRequest) }
        await drain()
        check("actual native resume reached inert suspension", facade.resumeGate != nil)
        adapter.enteredInternalPlayer()
        facade.resumeGate?.resume(returning: 90); facade.resumeGate = nil; facade.suspendResume = false
        check("new internal generation rejects late resume resolution", await task.value == nil)
        adapter.dismiss()
        facade.suspendResume = true
        let cancelledRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account)
        let cancelled = Task { @MainActor in await adapter.prepare(stream: stream, metadata: meta, request: cancelledRequest) }
        await drain(); cancelled.cancel()
        facade.resumeGate?.resume(returning: 80); facade.resumeGate = nil; facade.suspendResume = false
        check("cancelled caller cannot create late callback authority", await cancelled.value == nil)
        adapter.dismiss(); core.reset()
        let nextInventory: [InfuseHandoffCoordinator.Episode] = [.init(id: meta.videoId, season: 1, episode: 2), .init(id: "next", season: 1, episode: 3)]
        let navigationRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account, episodes: nextInventory)
        let navigation = await adapter.prepare(stream: stream, metadata: meta, request: navigationRequest)!
        adapter.launchFinished(navigation, launched: true)
        adapter.handle(callback(navigation.url)); adapter.confirmWatched(navigation.id!)
        check("accepted confirmation offers exact next navigation", adapter.chooseNext(navigation.id!)?.id == "next")
        adapter.enteredInternalPlayer(); adapter.refresh()
        check("next detail presentation survives its own internal player mount", adapter.presentation?.id == navigation.id)
        let callCount = core.nativeFacadeStorage!.actions.count
        adapter.handle(callback(navigation.url, position: "900")); await drain()
        check("next internal mount retires old callback despite retained detail UI", core.nativeFacadeStorage!.actions.count == callCount)
        ProfileStore.shared.activeID = UUID(); adapter.refresh()
        check("owner change dismisses retained next UI", adapter.presentation == nil)
        ProfileStore.shared.activeID = originalProfile; core.reset(); adapter.dismiss()
        var admissible = true
        let viewRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account, allowsLaunch: { admissible })
        admissible = false
        check("retired caller before launch is rejected", await adapter.prepare(stream: stream, metadata: meta, request: viewRequest) == nil)
    }

    @MainActor static func wrapperChecks(_ account: StremioAccount) async {
        let adapter = ExternalPlaybackHandoff.shared
        adapter.dismiss(); CoreBridge.shared.reset()
        var completions: [Bool] = []
        let request = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 78)
        FixtureExternalPlayer.open(.init(), stream: stream, metadata: meta, handoff: request) { completions.append($0) }
        await drain()
        let apple = NSWorkspace.shared
        check("actual macOS open method reaches inert OS seam with resume and callbacks", apple.opened.map { value($0, "position") == "78" && value($0, "x-success") != nil } == true)
        check("URL construction is not launch success", completions.isEmpty)
        apple.completion?(nil, NSError(domain: "Fixture", code: 1)); await drain()
        check("actual OS rejection delivered", completions == [false])
        if let url = apple.opened { adapter.handle(callback(url)) }
        check("OS-rejected capability cannot mutate history", adapter.presentation == nil)
        adapter.dismiss(); completions = []
        let tvRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 88)
        FixtureTVExternalPlayers.open(stream, in: .init(scheme: "infuse"), metadata: meta, handoff: tvRequest) { completions.append($0) }
        await drain()
        let tv = UIApplication.shared
        check("actual tvOS open method uses callback position", tv.opened.map { value($0, "position") == "88" } == true && completions.isEmpty)
        tv.completion?(true); await drain()
        check("actual tvOS waits for confirmed OS launch", completions == [true] && adapter.presentation == nil)
        if let url = tv.opened { adapter.handle(callback(url, position: "90")) }
        await drain()
        check("actual launched tvOS wrapper return reaches coordinator", adapter.presentation?.position == 90)
        adapter.dismiss()
        apple.opened = nil; completions = []
        let localRequest = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 88)
        FixtureExternalPlayer.open(.init(), stream: URL(string: "http://[::ffff:7f00:1]/stream")!, metadata: meta, handoff: localRequest) { completions.append($0) }
        await drain()
        check("actual launch wrapper never opens alternate loopback media", apple.opened == nil && completions == [false])
        adapter.dismiss(); completions = []
        var launchCurrent = true
        let replaced = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 10,
                                                        allowsLaunch: { launchCurrent })
        FixtureExternalPlayer.open(.init(), stream: stream, metadata: meta, handoff: replaced) { completions.append($0) }
        await drain()
        let retiredURL = apple.opened!
        launchCurrent = false
        apple.completion?(nil, nil); await drain()
        adapter.handle(callback(retiredURL))
        check("actual macOS late launch cannot retain replaced load authority", completions == [false] && adapter.presentation == nil)
        adapter.dismiss(); completions = []
        let retiredOwner = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 10)
        FixtureTVExternalPlayers.open(stream, in: .init(scheme: "infuse"), metadata: meta, handoff: retiredOwner) { completions.append($0) }
        await drain()
        let retiredTVURL = tv.opened!
        account.credentialBoundaryGeneration += 1
        tv.completion?(true); await drain()
        adapter.handle(callback(retiredTVURL))
        check("actual tvOS late launch cannot retain retired account authority", completions == [false] && adapter.presentation == nil)
        adapter.dismiss(); completions = []; CoreBridge.shared.reset(); SeriesSourceSticky.choices = []
        let earlyFailure = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 10, addon: "Chosen")
        FixtureExternalPlayer.open(.init(), stream: stream, metadata: meta, handoff: earlyFailure) { completions.append($0) }
        await drain()
        adapter.handle(callback(apple.opened!)); await drain()
        check("actual early callback cannot mutate before OS confirmation", adapter.presentation == nil
              && CoreBridge.shared.nativeFacadeStorage!.actions.isEmpty && CoreBridge.shared.watched.isEmpty && SeriesSourceSticky.choices.isEmpty)
        apple.completion?(nil, NSError(domain: "Fixture", code: 2)); await drain()
        check("actual OS failure discards deferred callback without progress or preference", completions == [false]
              && adapter.presentation == nil && CoreBridge.shared.nativeFacadeStorage!.actions.isEmpty && SeriesSourceSticky.choices.isEmpty)
        adapter.dismiss(); completions = []
        var earlyCurrent = true
        let earlyReplaced = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 10,
                                                             allowsLaunch: { earlyCurrent })
        FixtureExternalPlayer.open(.init(), stream: stream, metadata: meta, handoff: earlyReplaced) { completions.append($0) }
        await drain()
        earlyCurrent = false
        adapter.handle(callback(apple.opened!)); await drain()
        apple.completion?(nil, NSError(domain: "Fixture", code: 3)); await drain()
        check("actual replaced-load callback before OS failure has no mutation authority", completions == [false]
              && adapter.presentation == nil && CoreBridge.shared.nativeFacadeStorage!.actions.isEmpty && CoreBridge.shared.watched.isEmpty)
        adapter.dismiss(); completions = []
        let earlySuccess = ExternalPlaybackHandoff.Request(metadata: meta, account: account, position: 10)
        FixtureTVExternalPlayers.open(stream, in: .init(scheme: "infuse"), metadata: meta, handoff: earlySuccess) { completions.append($0) }
        await drain()
        let earlySuccessURL = tv.opened!
        adapter.handle(callback(earlySuccessURL, position: "17"))
        adapter.handle(callback(earlySuccessURL, position: "99")); await drain()
        check("actual early success remains deferred and one-shot", adapter.presentation == nil && CoreBridge.shared.nativeFacadeStorage!.actions.isEmpty)
        tv.completion?(true); await drain()
        check("actual confirmed OS success admits first deferred callback exactly once", completions == [true]
              && adapter.presentation?.position == 17 && CoreBridge.shared.nativeFacadeStorage!.actions.count == 1)
    }

    @MainActor static func nativeBoundaryChecks(_ account: StremioAccount) async {
        let core = CoreBridge.shared
        core.reset()
        let target = PlaybackMutationTarget.capture(core: core)
        await account.saveProgress(for: meta, positionSeconds: 0, durationSeconds: 0, target: target)
        check("actual native account boundary admits zero position zero duration", core.nativeFacadeStorage!.actions.count == 1)
        for pair in [(Double.nan, 0.0), (Double.infinity, 0), (-1, 0), (1, -1), (1, Double.nan),
                     (1, Double.infinity), (Double(UInt64.max) / 1000, 0), (1, Double(UInt64.max) / 1000)] {
            core.reportNativeProgress(for: meta, positionSeconds: pair.0, durationSeconds: pair.1, target: target)
        }
        check("native boundary rejects nonfinite negative and UInt64 overflow", core.nativeFacadeStorage!.actions.count == 1)
        core.nativeInstallGeneration = UUID()
        await account.saveProgress(for: meta, positionSeconds: 99, durationSeconds: 0, target: target)
        check("native session replacement refuses old target", core.nativeFacadeStorage!.actions.count == 1)
        let fresh = PlaybackMutationTarget.capture(core: core)
        core.nativeFacadeStorage!.accountGeneration = UUID()
        await account.saveProgress(for: meta, positionSeconds: 99, durationSeconds: 0, target: fresh)
        check("native account epoch replacement refuses old target", core.nativeFacadeStorage!.actions.count == 1)
        core.reset()
        let credentialTarget = PlaybackMutationTarget.capture(core: core)
        CredentialScopeRegistry.shared.generation += 1
        await account.saveProgress(for: meta, positionSeconds: 99, durationSeconds: 0, target: credentialTarget)
        check("native credential retirement refuses callback", core.nativeFacadeStorage!.actions.isEmpty)
        core.reset()
    }

    @MainActor static func exitChecks() async {
        let core = CoreBridge.shared
        core.reset(); ScrobbleCoordinator.shared.stops = 0
        let handoff = TVExitFixture()
        handoff.exitForHandoff(); await drain()
        check("actual TV handoff exit blocks synchronous scrobble stop", ScrobbleCoordinator.shared.stops == 0)
        check("actual TV handoff exit blocks stale account progress flush", core.nativeFacadeStorage!.actions.isEmpty)
        check("handoff exit still stops renderer and closes surface", handoff.coordinator.player?.stops == 1 && handoff.closeCount == 1)
        let ordinary = TVExitFixture()
        ordinary.exitNormally(); await drain()
        check("ordinary TV exit retains existing scrobble and progress behavior", ScrobbleCoordinator.shared.stops == 1 && core.nativeFacadeStorage!.actions.count == 1)
        let state = TVDefaultFence()
        let fence = state.capture(u: stream)
        check("actual TV default admission accepts original media owner", fence())
        state.coordinator.player?.activeLoadToken = UUID()
        check("actual TV default admission rejects same URL replacement token", !fence())
        core.reset()
        let ios = IOSExitFixture()
        ios.disappear(confirmed: true); await drain()
        check("actual iOS disappearance preserves confirmed external progress fence", ios.engineWrites == 0 && core.nativeFacadeStorage!.actions.isEmpty)
        let ordinaryIOS = IOSExitFixture()
        ordinaryIOS.disappear(confirmed: false); await drain()
        check("failed launch and fresh iOS mount do not inherit confirmed latch", ordinaryIOS.engineWrites == 1 && core.nativeFacadeStorage!.actions.count == 1)
    }
    #endif
}
