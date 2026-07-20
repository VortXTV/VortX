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
            auxiliaryContentID: "tt0903747:1:1", mediaServerTargetID: "page:tt0903747:1:1"
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

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:2", continuity: nil, pin: nil,
            auxiliaryContentID: "tt0903747:1:2", mediaServerTargetID: "page:tt0903747:1:2"
        )
        let identityClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "ordinary" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
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
        for _ in 0..<4_000 {
            let ids = Set(model.groups.map(\.id))
            if ids.isSuperset(of: ["torbox", "singularity", "media"]) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let matchingAuxiliaryIncluded = ["torbox", "singularity", "media"].allSatisfy { id in
            model.groups.contains { $0.id == id }
        }

        model.setContext(
            metaId: "tt0903747", streamId: "tt0903747:1:3", continuity: nil, pin: nil,
            auxiliaryContentID: "tt0903747:1:3", mediaServerTargetID: "page:tt0903747:1:3"
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

        if initialPublished && identityClearedSynchronously && staleAuxiliaryExcluded
            && matchingAuxiliaryIncluded && nextEpisodeClearedSynchronously
            && detachedRankBlocked && clearedSynchronously && staleCompletionFenced {
            print("PASS  SourceListModel clears identities, excludes stale auxiliary rows, and fences stale ranks")
            exit(0)
        }
        print("FAIL  initial=\(initialPublished) identityClear=\(identityClearedSynchronously) auxScope=\(staleAuxiliaryExcluded) auxMatch=\(matchingAuxiliaryIncluded) nextClear=\(nextEpisodeClearedSynchronously) blocked=\(detachedRankBlocked) clear=\(clearedSynchronously) fenced=\(staleCompletionFenced)")
        exit(1)
    }
}
