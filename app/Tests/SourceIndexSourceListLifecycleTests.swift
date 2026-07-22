// Standalone lifecycle race harness for the production SourceListModel.swift.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/source-list-lifecycle-test \
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

enum SourceIndexIdentity {
    struct PublicationTarget: Equatable, Hashable, Sendable {
        let titleID: String
        let contentID: String
        let season: Int?
        let episode: Int?
    }

    enum TargetResolution: Equatable, Hashable, Sendable {
        case target(PublicationTarget)
        case absent
        case mismatch
    }

    static func target(
        _ titleID: String,
        contentID: String? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) -> TargetResolution {
        .target(PublicationTarget(
            titleID: titleID,
            contentID: contentID ?? titleID,
            season: season,
            episode: episode
        ))
    }
}

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

    init(groups: [CoreStreamSourceGroup]) { self.groups = groups }
    func streamGroups() -> [CoreStreamSourceGroup] { groups }
    func streamGroups(forStreamId: String) -> [CoreStreamSourceGroup] { groups }
}

@MainActor
final class TorBoxSearchSource: ObservableObject {
    @Published var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    var epoch = 0
    var publishedContentID: String?

    nonisolated static func merge(
        _ streams: [CoreStream], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard !streams.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: "torbox", addon: "TorBox", streams: streams)]
    }
}

@MainActor
final class SourceIndexServeSource: ObservableObject, SourceIndexLifecycleParticipant {
    @Published var streams: [CoreStream] { didSet { epoch &+= 1 } }
    private(set) var epoch = 0
    private var gateOpen = true
    var publishedContentID: String?

    init(streams: [CoreStream], publishedContentID: String? = nil) {
        self.streams = streams
        self.publishedContentID = publishedContentID
    }

    nonisolated static func merge(
        _ streams: [CoreStream], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard !streams.isEmpty else { return groups }
        return groups + [CoreStreamSourceGroup(id: "singularity", addon: "Singularity", streams: streams)]
    }

    func sourceIndexLifecycleDidClose(retiredSourceGeneration _: UInt64) {
        gateOpen = false
        publishedContentID = nil
        streams = []
        epoch &+= 1
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

enum AuxiliarySourcePipeline {
    struct Snapshot: Sendable {
        let target: SourceIndexIdentity.PublicationTarget?
        let torBoxStreams: [CoreStream]
        let sourceIndexStreams: [CoreStream]
    }

    @MainActor
    static func snapshot(
        target: SourceIndexIdentity.TargetResolution,
        torBox: TorBoxSearchSource,
        sourceIndex: SourceIndexServeSource
    ) -> Snapshot {
        guard case let .target(validated) = target else {
            return Snapshot(target: nil, torBoxStreams: [], sourceIndexStreams: [])
        }
        return Snapshot(
            target: validated,
            torBoxStreams: torBox.publishedContentID == validated.contentID ? torBox.streams : [],
            sourceIndexStreams: sourceIndex.publishedContentID == validated.contentID ? sourceIndex.streams : []
        )
    }

    nonisolated static func merged(
        into groups: [CoreStreamSourceGroup],
        snapshot: Snapshot
    ) -> [CoreStreamSourceGroup] {
        SourceIndexServeSource.merge(
            snapshot.sourceIndexStreams,
            into: TorBoxSearchSource.merge(snapshot.torBoxStreams, into: groups)
        )
    }
}

@MainActor
final class MediaServerSource: ObservableObject {
    @Published var groups: [CoreStreamSourceGroup] = [] { didSet { epoch &+= 1 } }
    var epoch = 0
    var publishedContentID: String?

    nonisolated static func merge(
        _ mediaGroups: [CoreStreamSourceGroup], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        groups + mediaGroups
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
        debridCachedHashes: Set<String>
    ) -> CoreStream? {
        groups.lazy.flatMap(\.streams).first { $0.id.hasPrefix("downloadable") }
            ?? groups.first?.streams.first
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
    static func identityToken(_ value: String?) -> String { "redacted" }
}

@main
struct SourceIndexSourceListLifecycleTests {
    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if predicate() { return true }
            try? await Task<Never, Never>.sleep(nanoseconds: 500_000)
        }
        return predicate()
    }

    @MainActor
    static func main() async {
        let ordinary = CoreStream(id: "ordinary", infoHash: nil, isTorrent: false)
        let pooled = CoreStream(id: "pooled", infoHash: String(repeating: "a", count: 40), isTorrent: true)
        let torboxRow = CoreStream(
            id: "downloadable-A",
            infoHash: String(repeating: "b", count: 40),
            isTorrent: true
        )
        let mediaRow = CoreStream(id: "media-row", infoHash: nil, isTorrent: false)
        let targetA = SourceIndexIdentity.target(
            "tt0903747", contentID: "tt0903747:1:1", season: 1, episode: 1
        )
        let targetB = SourceIndexIdentity.target(
            "tt0903747", contentID: "tt0903747:1:2", season: 1, episode: 2
        )
        let core = CoreBridge(groups: [
            CoreStreamSourceGroup(id: "ordinary", addon: "Ordinary", streams: [ordinary]),
        ])
        let torbox = TorBoxSearchSource()
        torbox.publishedContentID = "tt0903747:1:1"
        torbox.streams = [torboxRow]
        let singularity = SourceIndexServeSource(
            streams: [pooled], publishedContentID: "tt0903747:1:1"
        )
        let mediaServers = MediaServerSource()
        mediaServers.publishedContentID = "page:tt0903747:1:1"
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        let debridCache = DebridCacheAwareness()
        let model = SourceListModel()
        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:1", continuity: nil, pin: nil,
            auxiliaryTarget: targetA, mediaServerTargetID: "page:tt0903747:1:1"
        )

        model.bind(
            core: core,
            torbox: torbox,
            singularity: singularity,
            mediaServers: mediaServers,
            debridCache: debridCache
        )
        _ = await waitUntil { model.groups.contains(where: { $0.id == "singularity" }) }
        let initialPublished = ["torbox", "singularity", "media"].allSatisfy { id in
            model.groups.contains { $0.id == id }
        }
        let targetAReachesFinalDownloadChoice = model.best?.id == "downloadable-A"
        let ordinaryEnginePreserved = model.groups.contains { $0.id == "ordinary" }

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:2", continuity: nil, pin: nil,
            auxiliaryTarget: targetB, mediaServerTargetID: "page:tt0903747:1:2"
        )
        let identityClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        _ = await waitUntil { model.groups.contains(where: { $0.id == "ordinary" }) }
        let staleAuxiliaryExcluded = ["torbox", "singularity", "media"].allSatisfy { id in
            !model.groups.contains { $0.id == id }
        }

        torbox.publishedContentID = "tt0903747:1:2"
        torbox.streams = [torboxRow]
        singularity.publishedContentID = "tt0903747:1:2"
        singularity.streams = [pooled]
        mediaServers.publishedContentID = "page:tt0903747:1:2"
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        _ = await waitUntil {
            let ids = Set(model.groups.map(\.id))
            return ids.isSuperset(of: ["torbox", "singularity", "media"])
        }
        let matchingAuxiliaryIncluded = ["torbox", "singularity", "media"].allSatisfy { id in
            model.groups.contains { $0.id == id }
        }

        model.setContext(
            metaId: "tt0903747", streamId: "mismatch", continuity: nil, pin: nil,
            auxiliaryTarget: .mismatch
        )
        _ = await waitUntil { model.groups.map(\.id) == ["ordinary"] }
        let mismatchPreservesOrdinary = model.groups.map(\.id) == ["ordinary"]
            && model.best?.id == "ordinary"

        model.setContext(
            metaId: "tt0903747", streamId: "absent", continuity: nil, pin: nil,
            auxiliaryTarget: .absent
        )
        _ = await waitUntil { model.groups.map(\.id) == ["ordinary"] }
        let absentPreservesOrdinary = model.groups.map(\.id) == ["ordinary"]
            && model.best?.id == "ordinary"

        model.setContext(
            metaId: "tt0903747", streamId: "nil-default", continuity: nil, pin: nil
        )
        _ = await waitUntil { model.groups.map(\.id) == ["ordinary"] }
        let nilDefaultPreservesOrdinary = model.groups.map(\.id) == ["ordinary"]
            && model.best?.id == "ordinary"

        let episodeOnlyTarget = SourceIndexIdentity.target(
            "tt0903747", contentID: "tt0903747:3:0", season: 3, episode: 0
        )
        torbox.publishedContentID = "tt0903747:3:0"
        torbox.streams = [torboxRow]
        singularity.publishedContentID = "tt0903747:3:0"
        singularity.streams = [pooled]
        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:3:0", continuity: nil, pin: nil,
            auxiliaryTarget: episodeOnlyTarget
        )
        _ = await waitUntil {
            Set(model.groups.map(\.id)).isSuperset(of: ["ordinary", "torbox", "singularity"])
        }
        let episodeOnlyIncluded = Set(model.groups.map(\.id)).isSuperset(
            of: ["ordinary", "torbox", "singularity"]
        ) && model.best?.id == "downloadable-A"

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:3", continuity: nil, pin: nil,
            auxiliaryTarget: SourceIndexIdentity.target(
                "tt0903747", contentID: "tt0903747:1:3", season: 1, episode: 3
            ),
            mediaServerTargetID: "page:tt0903747:1:3"
        )
        let nextEpisodeClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        _ = await waitUntil { model.groups.contains(where: { $0.id == "ordinary" }) }

        RankingBlocker.shared.arm()
        core.streamsEpoch &+= 1
        _ = await waitUntil { RankingBlocker.shared.hasBlocked() }
        let detachedRankBlocked = RankingBlocker.shared.hasBlocked()

        let retired = SourceIndexLifecycleClock.closeSource()
        singularity.sourceIndexLifecycleDidClose(retiredSourceGeneration: retired)
        model.sourceIndexLifecycleDidClose(retiredSourceGeneration: retired)
        let clearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty

        RankingBlocker.shared.release()
        _ = await waitUntil { model.groups.map(\.id) == ["ordinary"] && model.best?.id == "ordinary" }
        let staleCompletionFenced = model.groups.map(\.id) == ["ordinary"]
            && model.best?.id == "ordinary"
            && !model.groups.contains(where: { $0.id == "singularity" })

        let checks = [
            (initialPublished, "typed target A includes exact auxiliary owners"),
            (targetAReachesFinalDownloadChoice, "typed target A reaches the final downloadable choice"),
            (ordinaryEnginePreserved, "ordinary engine groups remain available beside auxiliary rows"),
            (identityClearedSynchronously, "target change clears published selection synchronously"),
            (staleAuxiliaryExcluded, "delayed target A owners cannot enter target B"),
            (matchingAuxiliaryIncluded, "target B includes both exact owner publications"),
            (mismatchPreservesOrdinary, "mismatch excludes auxiliary rows and preserves ordinary engine"),
            (absentPreservesOrdinary, "absent target excludes auxiliary rows and preserves ordinary engine"),
            (nilDefaultPreservesOrdinary, "default nil-equivalent target preserves ordinary engine"),
            (episodeOnlyIncluded, "episode-only target reaches merge, rank, and final choice"),
            (nextEpisodeClearedSynchronously, "next episode clears the prior selection synchronously"),
            (detachedRankBlocked, "lifecycle test holds a detached rank in flight"),
            (clearedSynchronously, "lifecycle close clears every published output synchronously"),
            (staleCompletionFenced, "retired detached rank cannot republish auxiliary rows"),
        ]
        for (passed, name) in checks {
            print("\(passed ? "PASS" : "FAIL")  \(name)")
        }
        exit(checks.allSatisfy(\.0) ? 0 : 1)
    }
}
