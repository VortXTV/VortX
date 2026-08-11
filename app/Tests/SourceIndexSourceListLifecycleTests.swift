// Standalone lifecycle race harness for the production SourceIndex identity and SourceListModel code.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/source-list-lifecycle-test \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/SourceSettlementPolicy.swift \
//     app/SourcesShared/SourceListModel.swift \
//     app/Tests/SourceIndexSourceListLifecycleTests.swift && /tmp/source-list-lifecycle-test

import Foundation
import Combine

struct CoreStream: Equatable, Sendable {
    let id: String
    let infoHash: String?
    let isTorrent: Bool
}

struct CoreStreamSourceGroup: Equatable, Sendable {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

struct ResolvedPin: Equatable, Sendable {}

struct SourceIndexLifecycleSnapshot: Equatable, Sendable {
    let sourceGeneration: UInt64
    let sessionGeneration: UInt64
    let consentGeneration: UInt64
}

enum SourceIndexLifecycleClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sourceGeneration: UInt64 = 0

    static func snapshot() -> SourceIndexLifecycleSnapshot {
        lock.withLock {
            SourceIndexLifecycleSnapshot(
                sourceGeneration: sourceGeneration,
                sessionGeneration: 0,
                consentGeneration: 0
            )
        }
    }

    static func closeSource() -> UInt64 {
        lock.withLock {
            let retired = sourceGeneration
            sourceGeneration &+= 1
            return retired
        }
    }
}

@MainActor
protocol SourceIndexLifecycleParticipant: AnyObject {
    func sourceIndexLifecycleDidClose(retiredSourceGeneration: UInt64)
}

@MainActor
final class SourceIndexLifecycleScope {
    static let shared = SourceIndexLifecycleScope()
    func register(_ participant: any SourceIndexLifecycleParticipant) {}
}

@MainActor
final class CoreBridge: ObservableObject {
    @Published var streamsEpoch = 0
    @Published var addons: [String] = []
    var groups: [CoreStreamSourceGroup]
    var rawSettlement: SourceContributorSettlement = .terminal
    var rawProgress = (loaded: 1, total: 1)

    init(groups: [CoreStreamSourceGroup]) { self.groups = groups }
    func streamGroups() -> [CoreStreamSourceGroup] { groups }
    func streamGroups(forStreamId: String) -> [CoreStreamSourceGroup] { groups }
    func streamLoadProgress() -> (loaded: Int, total: Int) { rawProgress }
    func streamLoadProgress(forStreamId: String) -> (loaded: Int, total: Int) { rawProgress }
    func streamContributorSettlement(metaId: String, streamId: String?) -> SourceContributorSettlement {
        rawSettlement
    }
}

@MainActor
final class TorBoxSearchSource: ObservableObject {
    @Published var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    @Published var settlementEpoch = 0
    var epoch = 0
    var publishedTarget: SourceIndexIdentity.PublicationTarget?
    var registered = true
    private var settlementTarget: String?
    private var settlement: SourceContributorSettlement = .pending

    func setSettlement(target: String?, state: SourceContributorSettlement) {
        settlementTarget = target
        settlement = state
        settlementEpoch &+= 1
    }

    func settlementState(for target: String?) -> SourceContributorSettlement {
        guard registered, let target else { return .inactive }
        guard settlementTarget == target else { return .pending }
        return settlement
    }

    func settlementState(for target: SourceIndexIdentity.TargetResolution) -> SourceContributorSettlement {
        guard let target = SourceIndexIdentity.validatedTarget(target) else { return .inactive }
        return settlementState(for: target.contentID)
    }

    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MergeAuthorization?,
        _ streams: [CoreStream], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil, !streams.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: "torbox", addon: "TorBox", streams: streams)]
    }
}

@MainActor
final class SourceIndexServeSource: ObservableObject, SourceIndexLifecycleParticipant {
    @Published var streams: [CoreStream] { didSet { epoch &+= 1 } }
    @Published var settlementEpoch = 0
    private(set) var epoch = 0
    private var gateOpen = true
    var publishedTarget: SourceIndexIdentity.PublicationTarget?
    var registered = true
    private var settlementTarget: String?
    private var settlement: SourceContributorSettlement = .pending

    init(streams: [CoreStream], publishedTarget: SourceIndexIdentity.PublicationTarget? = nil) {
        self.streams = streams
        self.publishedTarget = publishedTarget
    }

    func setSettlement(target: String?, state: SourceContributorSettlement) {
        settlementTarget = target
        settlement = state
        settlementEpoch &+= 1
    }

    func settlementState(for target: String?) -> SourceContributorSettlement {
        guard registered, gateOpen, let target else { return .inactive }
        guard settlementTarget == target else { return .pending }
        return settlement
    }

    func settlementState(for target: SourceIndexIdentity.TargetResolution) -> SourceContributorSettlement {
        guard let target = SourceIndexIdentity.validatedTarget(target) else { return .inactive }
        return settlementState(for: target.contentID)
    }

    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MergeAuthorization?,
        _ streams: [CoreStream], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil, !streams.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: "singularity", addon: "Singularity", streams: streams)]
    }

    func sourceIndexLifecycleDidClose(retiredSourceGeneration _: UInt64) {
        gateOpen = false
        publishedTarget = nil
        streams = []
        epoch &+= 1
        settlementTarget = nil
        settlement = .inactive
        settlementEpoch &+= 1
    }

    func permitsDetachedPublish(
        sourceEpoch: Int,
        lifecycle: SourceIndexLifecycleSnapshot,
        includedSingularity: Bool
    ) -> Bool {
        guard sourceEpoch == epoch, lifecycle == SourceIndexLifecycleClock.snapshot() else { return false }
        return !includedSingularity || gateOpen
    }
}

@MainActor
final class MediaServerSource: ObservableObject {
    @Published var groups: [CoreStreamSourceGroup] = [] { didSet { epoch &+= 1 } }
    @Published var settlementEpoch = 0
    var epoch = 0
    var publishedTarget: SourceIndexIdentity.MediaServerTarget?
    var registered = true
    private var settlementTarget: String?
    private var settlement: SourceContributorSettlement = .pending

    func setSettlement(target: String?, state: SourceContributorSettlement) {
        settlementTarget = target
        settlement = state
        settlementEpoch &+= 1
    }

    func settlementState(for target: String?) -> SourceContributorSettlement {
        guard registered, let target else { return .inactive }
        guard settlementTarget == target else { return .pending }
        return settlement
    }

    func settlementState(for target: SourceIndexIdentity.MediaServerTarget?) -> SourceContributorSettlement {
        settlementState(for: target?.token)
    }

    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MediaServerMergeAuthorization?,
        _ mediaGroups: [CoreStreamSourceGroup], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        authorization == nil ? groups : groups + mediaGroups
    }
}

@MainActor
final class DebridCacheAwareness: ObservableObject {
    @Published var cachedHashes: Set<String> = []
}

enum AddonTombstones {
    static func all() -> Set<String> { [] }
    static func normalize(_ value: String) -> String { value }
}

final class SourcePreferences: @unchecked Sendable {
    struct Snapshot: Sendable {}

    static let shared = SourcePreferences()
    var rankingSignature = "test"

    func snapshot() -> Snapshot { Snapshot() }

    @TaskLocal static var readingOverride: Snapshot?
}

enum ProfileStore {
    static func activeIsKids() -> Bool { false }
    static func activeDisabledAddons() -> Set<String> { [] }
}

enum PlaybackSettings {
    static let directLinksOnly = false
}

final class RankingBlocker: @unchecked Sendable {
    static let shared = RankingBlocker()

    private let condition = NSCondition()
    private var armed = false
    private var blocked = false

    func arm() {
        condition.withLock { armed = true }
    }

    func waitIfArmed() {
        condition.lock()
        guard armed else {
            condition.unlock()
            return
        }
        armed = false
        blocked = true
        while blocked { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    func hasBlocked() -> Bool {
        condition.withLock { blocked }
    }
}

/// Stub of the diag-21 sticky store. The lifecycle properties under test are about ORDERING and generation
/// fencing, not about which stream wins, so "no remembered pick" is the right stand-in: the production model
/// snapshots this on the main actor before its detached rank, and this harness only has to let that compile.
enum SeriesSourceSticky {
    static func preference(for _: String) -> (addon: String?, bingeGroup: String?)? { nil }
}

/// Stub of the diag-21 provider-failure demotion. Nothing has failed in this harness.
enum ProviderHealth {
    static func penaltyActive(addonName _: String?) -> Bool { false }
}

enum StreamRanking {
    static func rankedGroups(
        _ groups: [CoreStreamSourceGroup],
        pin: ResolvedPin?,
        debridCachedHashes: Set<String>
    ) -> [CoreStreamSourceGroup] {
        RankingBlocker.shared.waitIfArmed()
        return groups
    }

    static func best(
        _ groups: [CoreStreamSourceGroup],
        continuity: String?,
        pin: ResolvedPin?,
        sticky: (addon: String?, bingeGroup: String?)? = nil,
        providerPenalty: ((String) -> Bool)? = nil,
        debridCachedHashes: Set<String>
    ) -> CoreStream? {
        groups.first?.streams.first
    }

    static func tiers(_ groups: [CoreStreamSourceGroup]) -> [String] {
        groups.isEmpty ? [] : ["test"]
    }

    static func resolutionOptions(
        _ groups: [CoreStreamSourceGroup]
    ) -> [(label: String, stream: CoreStream)] {
        guard let stream = groups.first?.streams.first else { return [] }
        return [("test", stream)]
    }
}

enum VortxShadowRanking {
    static func observe(
        groups: [CoreStreamSourceGroup],
        continuity: String?,
        pin: ResolvedPin?,
        cachedHashes: Set<String>,
        prefs: SourcePreferences.Snapshot,
        metaId: String
    ) {}
}

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}
enum VXProbeRedaction {
    static func identityToken(_ raw: String?) -> String { raw == nil ? "none" : "redacted" }
}

func lifecycleTarget(_ contentID: String?) -> SourceIndexIdentity.TargetResolution {
    guard let contentID else { return .absent }
    let parts = contentID.split(separator: ":")
    guard parts.count == 1 || parts.count == 3 else { return .absent }
    let titleID = String(parts[0])
    let roles = SourceIndexIdentity.Roles(
        catalogID: titleID, defaultVideoID: nil, currentVideoID: nil,
        kind: parts.count == 3 ? .series : .movie
    )
    return SourceIndexIdentity.publicationTarget(
        roles,
        season: parts.count == 3 ? Int(parts[1]) : nil,
        episode: parts.count == 3 ? Int(parts[2]) : nil
    )
}

func lifecycleMediaTarget(_ contentID: String?) -> SourceIndexIdentity.MediaServerTarget? {
    guard let contentID else { return nil }
    let target = lifecycleTarget(contentID)
    if SourceIndexIdentity.validatedTarget(target) != nil {
        return SourceIndexIdentity.mediaServerTarget(page: target)
    }
    return SourceIndexIdentity.mediaServerTarget(metaID: contentID)
}

@main
struct SourceIndexSourceListLifecycleTests {
    @MainActor
    static func main() async {
        let ordinary = CoreStream(id: "ordinary", infoHash: nil, isTorrent: false)
        let pooled = CoreStream(id: "pooled", infoHash: String(repeating: "a", count: 40), isTorrent: true)
        let torboxRow = CoreStream(id: "torbox-row", infoHash: String(repeating: "b", count: 40), isTorrent: true)
        let mediaRow = CoreStream(id: "media-row", infoHash: nil, isTorrent: false)
        let core = CoreBridge(groups: [
            CoreStreamSourceGroup(id: "ordinary", addon: "Ordinary", streams: [ordinary]),
        ])
        let target11 = lifecycleTarget("tt0903747:1:1")
        let media11 = lifecycleMediaTarget("tt0903747:1:1")
        let torbox = TorBoxSearchSource()
        torbox.publishedTarget = target11.target
        torbox.streams = [torboxRow]
        torbox.setSettlement(target: "tt0903747:1:1", state: .terminal)
        let singularity = SourceIndexServeSource(
            streams: [pooled], publishedTarget: target11.target
        )
        singularity.setSettlement(target: "tt0903747:1:1", state: .terminal)
        let mediaServers = MediaServerSource()
        mediaServers.publishedTarget = media11
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        mediaServers.setSettlement(target: media11?.token, state: .terminal)
        let debridCache = DebridCacheAwareness()
        let model = SourceListModel(settlementMaximumWait: 2)
        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:1", continuity: nil, pin: nil,
            auxiliaryTarget: target11, mediaServerTarget: media11
        )

        model.bind(
            core: core,
            torbox: torbox,
            singularity: singularity,
            mediaServers: mediaServers,
            debridCache: debridCache
        )
        for _ in 0..<2_000 {
            if model.groups.contains(where: { $0.id == "singularity" }) { break }
            await Task.yield()
        }
        let initialPublished = ["torbox", "singularity", "media"].allSatisfy { id in
            model.groups.contains { $0.id == id }
        }
        let initialSettled = model.settlement == .settledAll

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:2", continuity: nil, pin: nil,
            auxiliaryTarget: lifecycleTarget("tt0903747:1:2"),
            mediaServerTarget: lifecycleMediaTarget("tt0903747:1:2")
        )
        let identityClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
            && model.settlement == .waiting
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "ordinary" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let staleAuxiliaryExcluded = ["torbox", "singularity", "media"].allSatisfy { id in
            !model.groups.contains { $0.id == id }
        }
        torbox.setSettlement(target: "tt0903747:1:1", state: .terminal)
        singularity.setSettlement(target: "tt0903747:1:1", state: .terminal)
        mediaServers.setSettlement(target: media11?.token, state: .terminal)
        try? await Task<Never, Never>.sleep(nanoseconds: 350_000_000)
        let staleTargetCompletionIgnored = model.settlement == .waiting

        let target12 = lifecycleTarget("tt0903747:1:2")
        let media12 = lifecycleMediaTarget("tt0903747:1:2")
        torbox.publishedTarget = target12.target
        torbox.streams = [torboxRow]
        torbox.setSettlement(target: "tt0903747:1:2", state: .terminal)
        singularity.publishedTarget = target12.target
        singularity.streams = [pooled]
        singularity.setSettlement(target: "tt0903747:1:2", state: .terminal)
        mediaServers.publishedTarget = media12
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        mediaServers.setSettlement(target: media12?.token, state: .terminal)
        for _ in 0..<4_000 {
            let ids = Set(model.groups.map(\.id))
            if ids.isSuperset(of: ["torbox", "singularity", "media"]) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let matchingAuxiliaryIncluded = ["torbox", "singularity", "media"].allSatisfy { id in
            model.groups.contains { $0.id == id }
        }
        let matchingAuxiliarySettled = model.settlement == .settledAll

        // A no-raw/add-on installation with one valid-empty auxiliary response is a complete set, not a
        // twenty-second wait. The same model then proves same-identity retry deadlines are re-armed after both
        // settled-all and a prior deadline completion.
        let auxiliaryCore = CoreBridge(groups: [])
        auxiliaryCore.rawSettlement = .inactive
        auxiliaryCore.rawProgress = (0, 0)
        let auxiliaryTorbox = TorBoxSearchSource()
        auxiliaryTorbox.setSettlement(target: "tt0000001", state: .terminal)
        let auxiliarySingularity = SourceIndexServeSource(streams: [])
        auxiliarySingularity.registered = false
        let auxiliaryMedia = MediaServerSource()
        auxiliaryMedia.registered = false
        let auxiliaryDebridCache = DebridCacheAwareness()
        let auxiliaryModel = SourceListModel(settlementMaximumWait: 0.05)
        auxiliaryModel.setContext(
            metaId: "tt0000001", streamId: nil, continuity: nil, pin: nil,
            auxiliaryTarget: lifecycleTarget("tt0000001"), mediaServerTarget: nil
        )
        auxiliaryModel.bind(
            core: auxiliaryCore,
            torbox: auxiliaryTorbox,
            singularity: auxiliarySingularity,
            mediaServers: auxiliaryMedia,
            debridCache: auxiliaryDebridCache
        )
        for _ in 0..<4_000 {
            if auxiliaryModel.settlement == .settledAll { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let auxiliaryOnlyEmptySettles = auxiliaryModel.settlement == .settledAll

        auxiliaryTorbox.setSettlement(target: "tt0000001", state: .pending)
        for _ in 0..<4_000 {
            if auxiliaryModel.settlement == .waiting { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let retryReopened = auxiliaryModel.settlement == .waiting
        try? await Task<Never, Never>.sleep(nanoseconds: 400_000_000)
        let retryWasBounded = auxiliaryModel.settlement == .settledDeadline

        auxiliaryTorbox.setSettlement(target: "tt0000001", state: .terminal)
        for _ in 0..<4_000 {
            if auxiliaryModel.settlement == .settledAll { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        auxiliaryTorbox.setSettlement(target: "tt0000001", state: .pending)
        for _ in 0..<4_000 {
            if auxiliaryModel.settlement == .waiting { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let postDeadlineRetryReopened = auxiliaryModel.settlement == .waiting
        try? await Task<Never, Never>.sleep(nanoseconds: 400_000_000)
        let postDeadlineRetryWasBounded = auxiliaryModel.settlement == .settledDeadline

        auxiliaryTorbox.registered = false
        auxiliaryTorbox.setSettlement(target: "tt0000001", state: .terminal)
        for _ in 0..<4_000 {
            if auxiliaryModel.settlement == .settledAll { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let ineligibleContributorIsInactive = auxiliaryModel.settlement == .settledAll

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:3", continuity: nil, pin: nil,
            auxiliaryTarget: lifecycleTarget("tt0903747:1:3"),
            mediaServerTarget: lifecycleMediaTarget("tt0903747:1:3")
        )
        let nextEpisodeClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "singularity" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }

        RankingBlocker.shared.arm()
        core.streamsEpoch &+= 1
        for _ in 0..<2_000 {
            if RankingBlocker.shared.hasBlocked() { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let detachedRankBlocked = RankingBlocker.shared.hasBlocked()

        let retired = SourceIndexLifecycleClock.closeSource()
        singularity.sourceIndexLifecycleDidClose(retiredSourceGeneration: retired)
        model.sourceIndexLifecycleDidClose(retiredSourceGeneration: retired)
        let clearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty

        RankingBlocker.shared.release()
        for _ in 0..<4_000 {
            if model.groups.map(\.id) == ["ordinary"] && model.best?.id == "ordinary" { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let staleCompletionFenced = model.groups.map(\.id) == ["ordinary"]
            && model.best?.id == "ordinary"
            && !model.groups.contains(where: { $0.id == "singularity" })

        if initialPublished && initialSettled && identityClearedSynchronously && staleAuxiliaryExcluded
            && staleTargetCompletionIgnored && matchingAuxiliaryIncluded && matchingAuxiliarySettled
            && auxiliaryOnlyEmptySettles && retryReopened && retryWasBounded
            && postDeadlineRetryReopened && postDeadlineRetryWasBounded
            && ineligibleContributorIsInactive && nextEpisodeClearedSynchronously
            && detachedRankBlocked && clearedSynchronously && staleCompletionFenced {
            print("PASS  SourceListModel settles complete generations, re-arms bounded retries, and fences stale work")
            exit(0)
        }
        print("FAIL  initial=\(initialPublished)/\(initialSettled) identityClear=\(identityClearedSynchronously) auxScope=\(staleAuxiliaryExcluded) staleTarget=\(staleTargetCompletionIgnored) auxMatch=\(matchingAuxiliaryIncluded)/\(matchingAuxiliarySettled) empty=\(auxiliaryOnlyEmptySettles) retry=\(retryReopened)/\(retryWasBounded) postDeadlineRetry=\(postDeadlineRetryReopened)/\(postDeadlineRetryWasBounded) ineligible=\(ineligibleContributorIsInactive) nextClear=\(nextEpisodeClearedSynchronously) blocked=\(detachedRankBlocked) clear=\(clearedSynchronously) fenced=\(staleCompletionFenced)")
        exit(1)
    }
}
