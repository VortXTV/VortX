import Foundation

// This executable deliberately compiles the production iOS preparer against small, typed
// dependency doubles. The async warm/settlement/cleanup path remains production code; only
// provider, resolver, transport, and model edges are inert and deterministic.

struct NextEpisodePreparationRequest: Equatable, Sendable {
    let episodeID: String
    let attemptSequence: Int
    let deadline: TimeInterval
    let nearCredits: Bool
    let protectedTorrentHash: String?
    let preparedRemuxGeneration: UInt64
    let prepareLocalAVPlayerRemux: Bool

    init(episodeID: String, attemptSequence: Int, deadline: TimeInterval, nearCredits: Bool,
         protectedTorrentHash: String?, preparedRemuxGeneration: UInt64 = 0,
         prepareLocalAVPlayerRemux: Bool = false) {
        self.episodeID = episodeID
        self.attemptSequence = attemptSequence
        self.deadline = deadline
        self.nearCredits = nearCredits
        self.protectedTorrentHash = protectedTorrentHash
        self.preparedRemuxGeneration = preparedRemuxGeneration
        self.prepareLocalAVPlayerRemux = prepareLocalAVPlayerRemux
    }
}

enum NextEpisodePreparationBudget {
    static let addonFetchBudget: TimeInterval = 0.4
}

@MainActor
enum BoundedPreloadWorkPool {
    static func valueBeforeDeadline<Output>(_ deadline: TimeInterval,
                                            operation: @escaping () async -> Output) async -> Output? {
        guard deadline > ProcessInfo.processInfo.systemUptime, !Task.isCancelled else { return nil }
        return await operation()
    }
}

struct StreamSource: Sendable {
    let addon: String?
}

struct AddonDescriptor: Sendable {}

struct EpisodeSourceProvider: Sendable {}

struct ResolvedPin: Sendable {}

struct CoreVideo: Sendable {
    let id: String
    let season: Int?
    let episode: Int?
    let episodeNumber: Int
    let thumbnail: String?
}

struct PlaybackMeta: Sendable {
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?
}

struct CoreStream: Sendable, Equatable {
    let id: String
    let url: URL?
    let requestHeaders: [String: String]?
    let fixtureVideoID: String
}

struct CoreStreamSourceGroup: Sendable {
    let streams: [CoreStream]
}

final class PreparedTorrentEngineLease: @unchecked Sendable {}

final class VortXPreparedRemuxAttachment: @unchecked Sendable {
    init(handle: VortXPreparedRemuxHandle, ownerIdentity: VortXPreparedRemuxOwnerIdentity) {}
    func abandon(reason: String) {}
}

struct VortXPreparedRemuxHandle: Sendable {}

struct VortXPreparedRemuxOwnerIdentity: Sendable {
    let mediaID: String
    let generation: UInt64
    let sourceSignature: String
}

struct PlayerEpisodeStream: Sendable {
    let stream: CoreStream
    let url: URL
    let meta: PlaybackMeta
    let title: String
    let resume: Double
    let debridRef: String?
    let engineAddonBase: String?
    let preparationRequest: NextEpisodePreparationRequest
    let torrentPreparationLease: PreparedTorrentEngineLease?
    let preparedRemux: VortXPreparedRemuxAttachment?
}

struct DebridEpisode: Sendable {
    let season: Int
    let episode: Int
}

struct EpisodeSourceOwner: @unchecked Sendable {
    let sources: [StreamSource]
    private let current: () -> Bool

    init(legacySources: [StreamSource], legacyAddons: [AddonDescriptor] = [],
         legacyIsCurrent: @escaping () -> Bool) {
        sources = legacySources
        current = legacyIsCurrent
    }

    var isCurrent: Bool { current() }

    func sources(for episodeID: String) -> [StreamSource] {
        sources
    }

    func providers(seriesID: String, videoID: String) -> [EpisodeSourceProvider] {
        []
    }
}

struct StickySource: Sendable {
    let addon: String?
}

enum SeriesSourceSticky {
    struct Choice: Sendable {
        let source: StickySource
        let audioLanguage: String?
        fileprivate let revision: Int
    }

    private static let state = LockedStickyState()

    static func set(addon: String?) {
        state.set(addon: addon)
    }

    static func snapshot(for seriesID: String) -> Choice {
        state.snapshot()
    }

    static func admits(_ choice: Choice) -> Bool {
        state.admits(choice)
    }
}

private final class LockedStickyState: @unchecked Sendable {
    private let lock = NSLock()
    private var addon: String?
    private var revision = 0

    func set(addon: String?) {
        lock.lock()
        self.addon = addon
        revision += 1
        lock.unlock()
    }

    func snapshot() -> SeriesSourceSticky.Choice {
        lock.lock()
        defer { lock.unlock() }
        return .init(source: StickySource(addon: addon), audioLanguage: nil, revision: revision)
    }

    func admits(_ choice: SeriesSourceSticky.Choice) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return choice.revision == revision
    }
}

enum SourceIndexIdentity {
    enum Kind: Sendable { case series }

    struct Roles: Sendable {
        let catalogID: String
        let defaultVideoID: String?
        let currentVideoID: String
        let kind: Kind
    }

    struct Resolved: Sendable {
        let titleID: String
    }

    struct TargetResolution: Sendable, Equatable {
        let key: String
    }

    struct MediaServerTarget: Sendable, Equatable {
        let key: String
    }

    struct Publication: Sendable, Equatable {
        let key: String
    }

    static func resolve(_ roles: Roles) -> Resolved {
        .init(titleID: roles.catalogID)
    }

    static func publicationTarget(_ roles: Roles, season: Int, episode: Int?) -> TargetResolution {
        .init(key: "\(roles.catalogID)|\(roles.defaultVideoID ?? "")|\(roles.currentVideoID)|\(season)|\(episode ?? -1)")
    }

    static func mediaServerTarget(preferring target: TargetResolution, metaID: String,
                                  videoID: String) -> MediaServerTarget? {
        .init(key: target.key)
    }

    static func mergeAuthorization(published: Publication?, page: TargetResolution) -> String? {
        published?.key == page.key ? page.key : nil
    }

    static func mediaServerMergeAuthorization(published: Publication?, page: MediaServerTarget?) -> String? {
        guard let page, published?.key == page.key else { return nil }
        return page.key
    }
}

enum ProbeSettlementState: Sendable {
    case loading
    case settled
}

struct ProbeSettlementDecision: Sendable {
    let isSettled: Bool
}

enum SourceSettlementPolicy {
    enum RawState: Sendable { case terminal }

    static func decide(raw: RawState, auxiliary: [ProbeSettlementState],
                       deadlineExpired: Bool) -> ProbeSettlementDecision {
        .init(isSettled: deadlineExpired || auxiliary.allSatisfy { $0 == .settled })
    }
}

private final class AuxiliaryProbe: @unchecked Sendable {
    let kind: String
    let ordinal: Int
    private let lock = NSLock()
    private var state: ProbeSettlementState = .loading
    private var publication: SourceIndexIdentity.Publication?
    private var streamValues: [CoreStream] = []
    private var groupValues: [CoreStreamSourceGroup] = []
    private(set) var clearCount = 0

    init(kind: String, ordinal: Int) {
        self.kind = kind
        self.ordinal = ordinal
    }

    func refresh(target: SourceIndexIdentity.TargetResolution) {
        let videoID = target.key.split(separator: "|").dropFirst(2).first.map(String.init) ?? "unknown"
        let stream = CoreStream(
            id: "aux-\(kind)-\(ordinal)-\(videoID)",
            url: URL(string: "http://fixture.test/\(videoID)/\(kind)")!,
            requestHeaders: nil,
            fixtureVideoID: videoID
        )
        lock.lock()
        publication = .init(key: target.key)
        streamValues = [stream]
        groupValues = [.init(streams: [stream])]
        // The first invocation settles at once. Every successor starts in the populated/loading state,
        // which is the race window under test. A shared baseline therefore exposes its snapshots to the
        // old invocation's eventual clearResults call.
        state = (ordinal == 1 && clearCount == 0 && refreshCount == 0)
            || FixtureWorld.probes.successorStartsSettled
            ? .settled : .loading
        refreshCount += 1
        lock.unlock()
    }

    private var refreshCount = 0

    func settlement(for target: SourceIndexIdentity.TargetResolution) -> ProbeSettlementState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func publishedTargetValue() -> SourceIndexIdentity.Publication? {
        lock.lock()
        defer { lock.unlock() }
        return publication
    }

    func streamsValue() -> [CoreStream] {
        lock.lock()
        defer { lock.unlock() }
        return streamValues
    }

    func groupsValue() -> [CoreStreamSourceGroup] {
        lock.lock()
        defer { lock.unlock() }
        return groupValues
    }

    func settle() {
        lock.lock()
        state = .settled
        lock.unlock()
    }

    func clear() {
        lock.lock()
        clearCount += 1
        publication = nil
        streamValues = []
        groupValues = []
        lock.unlock()
    }

    func isLoadingAndPopulated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .loading && !streamValues.isEmpty
    }

    func isCleared() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clearCount > 0 && streamValues.isEmpty && publication == nil
    }

    var isSuccessor: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ordinal >= 2 || refreshCount >= 2
    }
}

private final class ProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrdinal: [String: Int] = [:]
    private var probesByKind: [String: [AuxiliaryProbe]] = [:]
    private(set) var successorStartsSettled = false

    func reset(successorStartsSettled: Bool) {
        lock.lock()
        nextOrdinal = [:]
        probesByKind = [:]
        self.successorStartsSettled = successorStartsSettled
        lock.unlock()
    }

    func make(kind: String) -> AuxiliaryProbe {
        lock.lock()
        let ordinal = (nextOrdinal[kind] ?? 0) + 1
        nextOrdinal[kind] = ordinal
        let probe = AuxiliaryProbe(kind: kind, ordinal: ordinal)
        probesByKind[kind, default: []].append(probe)
        lock.unlock()
        return probe
    }

    func allProbes() -> [AuxiliaryProbe] {
        lock.lock()
        defer { lock.unlock() }
        return probesByKind.values.flatMap { $0 }
    }

    func successorIsLoadingAndPopulated() -> Bool {
        lock.lock()
        let probes = probesByKind.values.flatMap { $0 }
        lock.unlock()
        let successors = probes.filter { $0.isSuccessor }
        return successors.count >= 3 && successors.allSatisfy { $0.isLoadingAndPopulated() }
    }

    func settleSuccessors() {
        allProbes().filter { $0.isSuccessor }.forEach { $0.settle() }
    }

    func successorWasCleared() -> Bool {
        allProbes().contains { $0.isSuccessor && $0.isCleared() }
    }
}

private enum FixtureWorld {
    static let probes = ProbeRegistry()
    static let resolver = ResolverGate()

    static func reset(heldCalls: Set<Int>, successorStartsSettled: Bool = false) async {
        probes.reset(successorStartsSettled: successorStartsSettled)
        SeriesSourceSticky.set(addon: "source-a")
        await resolver.reset(heldCalls: heldCalls)
    }
}

private actor ResolverGate {
    struct Call: Sendable {
        let ordinal: Int
        let videoID: String
        let streamID: String
    }

    private var calls: [Call] = []
    private var heldCalls: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    func reset(heldCalls: Set<Int>) {
        self.heldCalls = heldCalls
        calls = []
        waiters = [:]
    }

    func resolve(candidate: CoreStream) async -> CoreStream {
        let ordinal = calls.count + 1
        calls.append(.init(ordinal: ordinal, videoID: candidate.fixtureVideoID, streamID: candidate.id))
        guard heldCalls.contains(ordinal) else { return candidate }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[ordinal, default: []].append(continuation)
        }
        return candidate
    }

    func release(_ ordinal: Int) {
        heldCalls.remove(ordinal)
        let pending = waiters.removeValue(forKey: ordinal) ?? []
        pending.forEach { $0.resume() }
    }

    func releaseAll() {
        let pending = waiters.values.flatMap { $0 }
        waiters = [:]
        heldCalls = []
        pending.forEach { $0.resume() }
    }

    func callsSnapshot() -> [Call] { calls }
}

final class TorBoxSearchSource: @unchecked Sendable {
    private let probe = FixtureWorld.probes.make(kind: "torbox")

    var streams: [CoreStream] { probe.streamsValue() }
    var publishedTarget: SourceIndexIdentity.Publication? { probe.publishedTargetValue() }

    func refresh(target: SourceIndexIdentity.TargetResolution) { probe.refresh(target: target) }
    func settlementState(for target: SourceIndexIdentity.TargetResolution) -> ProbeSettlementState {
        probe.settlement(for: target)
    }
    func clearResults() { probe.clear() }

    static func merge(authorizedBy: String?, _ auxiliary: [CoreStream],
                      into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard authorizedBy != nil else { return groups }
        return groups + auxiliary.map { .init(streams: [$0]) }
    }
}

final class SourceIndexServeSource: @unchecked Sendable {
    private let probe = FixtureWorld.probes.make(kind: "source-index")

    var streams: [CoreStream] { probe.streamsValue() }
    var publishedTarget: SourceIndexIdentity.Publication? { probe.publishedTargetValue() }

    func refresh(target: SourceIndexIdentity.TargetResolution) { probe.refresh(target: target) }
    func settlementState(for target: SourceIndexIdentity.TargetResolution) -> ProbeSettlementState {
        probe.settlement(for: target)
    }
    func clearResults() { probe.clear() }

    static func merge(authorizedBy: String?, _ auxiliary: [CoreStream],
                      into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard authorizedBy != nil else { return groups }
        return groups + auxiliary.map { .init(streams: [$0]) }
    }
}

final class MediaServerSource: @unchecked Sendable {
    private let probe = FixtureWorld.probes.make(kind: "media-server")

    var groups: [CoreStreamSourceGroup] { probe.groupsValue() }
    var publishedTarget: SourceIndexIdentity.Publication? { probe.publishedTargetValue() }

    func refresh(imdb: String, season: Int, episode: Int?, title: String,
                 publicationTarget target: SourceIndexIdentity.MediaServerTarget?) {
        if let target {
            let publicationTarget = SourceIndexIdentity.TargetResolution(key: target.key)
            probe.refresh(target: publicationTarget)
        }
    }

    func settlementState(for target: SourceIndexIdentity.MediaServerTarget?) -> ProbeSettlementState {
        guard let target else { return .settled }
        return probe.settlement(for: .init(key: target.key))
    }
    func clearResults() { probe.clear() }

    static func merge(authorizedBy: String?, _ auxiliary: [CoreStreamSourceGroup],
                      into groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard authorizedBy != nil else { return groups }
        return groups + auxiliary
    }
}

enum AuxiliarySourcePipeline {
    static func refresh(target: SourceIndexIdentity.TargetResolution,
                        torBox: TorBoxSearchSource, sourceIndex: SourceIndexServeSource,
                        isSignedIn: Bool) {
        torBox.refresh(target: target)
        sourceIndex.refresh(target: target)
    }
}

@MainActor
func warmFetchEpisodeSourceGroups(sources: [StreamSource], request: NextEpisodePreparationRequest,
                                  wantedAddon: String?) async -> [CoreStreamSourceGroup] {
    // All candidates in this fixture arrive through the auxiliary publishers. This is intentional:
    // clearing a successor's populated snapshots must make the successor fail, not fall back to a raw
    // source candidate and mask the ownership regression.
    []
}

@MainActor
func warmFetchEpisodeSourceGroups(providers: [EpisodeSourceProvider], sources: [StreamSource],
                                  request: NextEpisodePreparationRequest,
                                  wantedAddon: String?) async -> [CoreStreamSourceGroup] {
    await warmFetchEpisodeSourceGroups(sources: sources, request: request, wantedAddon: wantedAddon)
}

@MainActor
func warmFetchEpisodeSourceGroups(providers: [EpisodeSourceProvider],
                                  request: NextEpisodePreparationRequest,
                                  wantedAddon: String?) async -> [CoreStreamSourceGroup] {
    await warmFetchEpisodeSourceGroups(sources: [], request: request, wantedAddon: wantedAddon)
}

@MainActor
func iOSDisplayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] { groups }

enum StreamRanking {
    static func rankedCandidates(_ groups: [CoreStreamSourceGroup], continuity: String?, binge: String?,
                                 pin: ResolvedPin?, sticky: StickySource, stickyAuthoritative: Bool,
                                 preserveChosenRelease: Bool, desiredAudioLanguage: String?,
                                 providerPenalty: (String) -> Int, debridCachedHashes: Set<String>) -> [CoreStream] {
        groups.flatMap(\.streams)
    }

    static func continuityLanguageMismatch(_ stream: CoreStream, desired: String?) -> Bool { false }
    static func signature(_ stream: CoreStream) -> String { stream.id }
    static func isDolbyVision(_ signature: String) -> Bool { false }
}

enum ProviderHealth {
    static func penaltyActive(addonName: String) -> Int { 0 }
}

@MainActor
func iOSResolveRankedEpisodeCandidate(_ candidates: [CoreStream], episode: DebridEpisode?,
                                      waitForLocalUsenetNode: Bool, deadline: TimeInterval,
                                      stillCurrent: @escaping () -> Bool)
    async -> (stream: CoreStream, url: URL, ref: String?)? {
    guard let candidate = candidates.first else { return nil }
    let resolved = await FixtureWorld.resolver.resolve(candidate: candidate)
    return (resolved, resolved.url!, nil)
}

enum VortXPreparedRemuxCallerPolicy {
    enum Mode: Sendable { case fixtureUnavailable }
    enum WarmPath: Equatable, Sendable { case prefixRange, none }

    static func mode(avPlayerActive: Bool, mountIsOnDevice: Bool, rawTorrent: Bool,
                     dolbyVision: Bool, dolbyVisionRemuxEligible: Bool,
                     plainRemuxEligible: Bool) -> Mode? { nil }
    static func transportWarmPath(preparedMode: Mode?) -> WarmPath { .none }
}

enum PlayerEngineRouter {
    static func shouldDVRemux(url: URL) -> Bool { false }
    static func shouldPlainRemux(url: URL) -> Bool { false }
}

enum AVPlayerEngineController {
    static func prepareRemuxTransport(input: URL, headers: [String: String]?,
                                      mode: VortXPreparedRemuxCallerPolicy.Mode?,
                                      startAtSeconds: Double,
                                      ownerIdentity: VortXPreparedRemuxOwnerIdentity)
        async -> VortXPreparedRemuxHandle? { nil }
}

enum BoundedRangeWarmup {
    struct Result: Sendable {}
    static func fetch(_ request: URLRequest, limit: Int) async throws -> Result { .init() }
}

func prepareWarmTorrentEngine(_ stream: CoreStream,
                              request: NextEpisodePreparationRequest) async -> PreparedTorrentEngineLease? {
    nil
}

func retireWarmTorrentEngine(_ lease: PreparedTorrentEngineLease, reason: String) {}

func iOSEngineAddonBase(for stream: CoreStream, in groups: [CoreStreamSourceGroup]) -> String? { "fixture" }

@MainActor
private func fixtureContext(videos: [CoreVideo]) -> iOSNextEpisodePreparationContext {
    iOSNextEpisodePreparationContext(
        seriesID: "fixture-series",
        seriesName: "Fixture Series",
        defaultSeason: 1,
        defaultVideoID: videos.first?.id,
        poster: nil,
        sources: [.init(addon: "source-a")],
        legacyAddons: [],
        continuity: nil,
        binge: nil,
        pin: nil,
        cachedHashes: [],
        signedInToVortX: false,
        videos: { videos },
        resumeOffset: { _ in 0 },
        isCurrent: { true }
    )
}

private func request(episodeID: String, sequence: Int, generation: UInt64 = 0) -> NextEpisodePreparationRequest {
    .init(episodeID: episodeID, attemptSequence: sequence,
          deadline: ProcessInfo.processInfo.systemUptime + 3,
          nearCredits: false, protectedTorrentHash: nil,
          preparedRemuxGeneration: generation, prepareLocalAVPlayerRemux: false)
}

private func launch(_ preparer: iOSNextEpisodePreparer,
                    request: NextEpisodePreparationRequest,
                    context: iOSNextEpisodePreparationContext) -> Task<PlayerEpisodeStream?, Never> {
    Task { @MainActor in
        await preparer.warm(request, context: context)
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool,
                       attempts: Int = 300) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

@main
@MainActor
private enum NextEpisodePreparationAttemptTests {
    private static var passed = 0

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            print("FAIL  \(message)")
            exit(1)
        }
    }

    @MainActor
    private static func makePreparerAndContext(videos: [CoreVideo]) ->
        (iOSNextEpisodePreparer, iOSNextEpisodePreparationContext) {
        (iOSNextEpisodePreparer(), fixtureContext(videos: videos))
    }

    static func main() async {
        let videos = [
            CoreVideo(id: "E2", season: 1, episode: 2, episodeNumber: 2, thumbnail: nil),
            CoreVideo(id: "E3", season: 1, episode: 3, episodeNumber: 3, thumbnail: nil)
        ]

        await coreHeldCancellationRace(videos: videos)
        await immediateSameKeyRearm(videos: videos)
        await abaRearm(videos: videos)
        await changedRemuxGenerationDoesNotReuseTask(videos: videos)
        await cancelThenLateOldCompletion(videos: videos)

        print("PASS  all next-episode attempt ownership checks (\(passed) assertions)")
    }

    private static func coreHeldCancellationRace(videos: [CoreVideo]) async {
        await FixtureWorld.reset(heldCalls: [1])
        let (preparer, context) = makePreparerAndContext(videos: videos)
        let old = launch(preparer, request: request(episodeID: "E2", sequence: 2, generation: 10), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 1 }),
               "old E2 attempt 2 reaches the non-cooperative resolver")
        expect(await waitUntil({ FixtureWorld.probes.allProbes().count == 3 }),
               "old attempt has three production-owned auxiliary publishers")

        SeriesSourceSticky.set(addon: "source-b")
        let successor = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 11), context: context)
        expect(await waitUntil({ FixtureWorld.probes.successorIsLoadingAndPopulated() }),
               "source-change rearm creates populated/loading successor snapshots")
        await FixtureWorld.resolver.release(1)
        let oldResult = await old.value
        expect(oldResult == nil, "late cancelled old attempt cannot publish a stream")
        expect(!FixtureWorld.probes.successorWasCleared(),
               "old deferred cleanup does not clear successor auxiliary snapshots")
        FixtureWorld.probes.settleSuccessors()
        let successorResult = await successor.value
        expect(successorResult?.meta.videoId == "E2" && successorResult?.preparationRequest.attemptSequence == 1,
               "successor settles and yields the real prepared E2 stream")
        expect(successorResult?.url.scheme == "http" && successorResult?.debridRef == nil
                   && successorResult?.preparedRemux == nil,
               "prepared winner stays on the direct plain-HTTP, non-torrent, non-remux path")
    }

    private static func immediateSameKeyRearm(videos: [CoreVideo]) async {
        await FixtureWorld.reset(heldCalls: [1, 2], successorStartsSettled: true)
        let (preparer, context) = makePreparerAndContext(videos: videos)
        let first = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 20), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 1 }),
               "same-key first invocation reaches resolver")
        await MainActor.run { preparer.cancel() }
        let second = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 21), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 2 }),
               "same-key rearm is a distinct resolver invocation")
        await FixtureWorld.resolver.release(1)
        expect(await first.value == nil, "cancelled same-key predecessor remains rejected when released")
        expect(!FixtureWorld.probes.successorWasCleared(),
               "released same-key predecessor cannot clear successor state")
        await FixtureWorld.resolver.release(2)
        let secondResult = await second.value
        expect(secondResult?.preparationRequest.preparedRemuxGeneration == 21,
               "same-key rearm retains the replacement remux generation")
    }

    private static func abaRearm(videos: [CoreVideo]) async {
        await FixtureWorld.reset(heldCalls: [1], successorStartsSettled: true)
        let (preparer, context) = makePreparerAndContext(videos: videos)
        let e2Old = launch(preparer, request: request(episodeID: "E2", sequence: 1), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 1 }),
               "ABA old E2 reaches resolver")
        let e3 = launch(preparer, request: request(episodeID: "E3", sequence: 1), context: context)
        let e3Result = await e3.value
        expect(e3Result?.meta.videoId == "E3", "E2 to other episode rearm publishes E3")
        let e2New = launch(preparer, request: request(episodeID: "E2", sequence: 1), context: context)
        let e2Result = await e2New.value
        expect(e2Result?.meta.videoId == "E2", "other episode back to E2 publishes a fresh E2")
        expect(await FixtureWorld.resolver.callsSnapshot().count == 3,
               "E2 to other to E2 uses three distinct invocations")
        await FixtureWorld.resolver.release(1)
        expect(await e2Old.value == nil, "the oldest ABA E2 completion remains rejected")
    }

    private static func changedRemuxGenerationDoesNotReuseTask(videos: [CoreVideo]) async {
        await FixtureWorld.reset(heldCalls: [1], successorStartsSettled: true)
        let (preparer, context) = makePreparerAndContext(videos: videos)
        let old = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 30), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 1 }),
               "generation baseline reaches resolver")
        let replacement = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 31), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 2 }),
               "changed preparedRemuxGeneration does not reuse the old task")
        let result = await replacement.value
        expect(result?.preparationRequest.preparedRemuxGeneration == 31,
               "prepared stream carries the changed remux generation")
        await FixtureWorld.resolver.release(1)
        expect(await old.value == nil, "late generation-baseline completion is rejected")
    }

    private static func cancelThenLateOldCompletion(videos: [CoreVideo]) async {
        await FixtureWorld.reset(heldCalls: [1, 2], successorStartsSettled: true)
        let (preparer, context) = makePreparerAndContext(videos: videos)
        let old = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 40), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 1 }),
               "cancel-late-old baseline reaches resolver")
        await MainActor.run { preparer.cancel() }
        let current = launch(preparer, request: request(episodeID: "E2", sequence: 1, generation: 41), context: context)
        expect(await waitUntil({ await FixtureWorld.resolver.callsSnapshot().count == 2 }),
               "cancel() permits the replacement task to reach resolver")
        await FixtureWorld.resolver.release(1)
        expect(await old.value == nil, "late old completion after cancel() is rejected")
        // The new resolver is still held. If old completion retired the active owner, the replacement
        // would be unable to finish with its own prepared stream after the final release.
        await FixtureWorld.resolver.release(2)
        let currentResult = await current.value
        expect(currentResult?.preparationRequest.preparedRemuxGeneration == 41,
               "late old completion cannot cancel the active replacement")
    }
}
