// Standalone lifecycle + identity-boundary harness for the production SourceListModel.swift merge path.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/source-list-lifecycle-test \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/SourceListModel.swift \
//     app/Tests/SourceIndexSourceListLifecycleTests.swift && /tmp/source-list-lifecycle-test
//
// Run from the repo root, or pass the repo root as the single argument (the compile-negative phases below
// re-invoke swiftc against the production identity sources).
//
// THREE phases:
//
//   1. FORGE PROOF (compile-negative): the exact same-module-extension fixture that BROKE commit 9a017a1 --
//      an extension of `SourceIndexIdentity.PublicationTarget` in another file of the module that directly
//      initializes the stored properties (SE-0189) and prints an identity pair that never passed the role
//      resolver -- must now FAIL TO COMPILE, in both its pre-fix spelling and its seal-aware spelling.
//
//   2. MUTATION PROOF: a guard that cannot be shown to fail is not verified. A COPY of the production
//      identity file is re-widened two ways (drop `private` from the sealed storage; make the fileprivate
//      init internal) and the corresponding forge fixture must COMPILE AND RUN again against each widened
//      copy, printing the forged pair. This pins that the seal, and nothing else, is what stops the forge.
//
//   3. LIFECYCLE (production-linked, async): the REAL SourceListModel, driven through the REAL sealed
//      `SourceIndexIdentity.PublicationTarget` + `mergeAuthorization` gate, must publish matching auxiliary
//      rows, exclude stale ones synchronously on an identity change, fence detached stale ranks, and clear
//      on a Source Index lifecycle close. The auxiliary stubs publish TYPED targets built by the real
//      resolver -- there is no raw-string route left to drive them with.
//
// CAPTURED COMPILER OUTPUT (literal, from this machine, so "does not compile" is checkable prose):
//
// The PRE-FIX run of fixture (A) against 9a017a1's SourceIndexIdentity.swift compiled with exit 0 and printed:
//
//     FORGED pair: titleID=tt0000001 contentID=tt9999999:9:9
//
// which is the reviewer's bypass 1 reproduced verbatim: `internal` stored properties behind a `fileprivate`
// init are NOT a boundary inside one module.
//
// The POST-FIX run of fixture (A) (assigning the old stored names) fails with:
//
//     main.swift:13:14: error: cannot assign to property: 'titleID' is a get-only property
//     main.swift:14:14: error: cannot assign to property: 'contentID' is a get-only property
//     main.swift:15:14: error: cannot assign to property: 'season' is a get-only property
//     main.swift:16:14: error: cannot assign to property: 'episode' is a get-only property
//
// The POST-FIX run of fixture (B) (assigning the sealed storage directly) fails with:
//
//     main.swift:6:24: error: 'Storage' is inaccessible due to 'private' protection level
//     main.swift:6:14: error: 'storage' is inaccessible due to 'private' protection level
//
// and the MUTATION run (same fixture (B), `private` dropped from `struct Storage` and `let storage` in a
// temp copy) compiles with exit 0 and prints `FORGED pair: titleID=tt0000001 contentID=tt9999999:9:9` again.

import Foundation
import Combine

// MARK: - Compile-negative forge fixtures (phases 1 + 2)

/// Fixture (A): the pre-fix Codex forge, verbatim shape. A same-module extension (any file added to the app
/// target) that initializes the stored properties directly and prints a forged identity pair.
private let forgePreFixShape = """
import Foundation

extension SourceIndexIdentity.PublicationTarget {
    init(forgedTitleID: String, forgedContentID: String) {
        self.titleID = forgedTitleID
        self.contentID = forgedContentID
        self.season = nil
        self.episode = nil
    }
}

let forged = SourceIndexIdentity.PublicationTarget(
    forgedTitleID: "tt0000001",
    forgedContentID: "tt9999999:9:9"
)
print("FORGED pair: titleID=\\(forged.titleID) contentID=\\(forged.contentID)")
"""

/// Fixture (B): the seal-aware spelling of the same forge, targeting the sealed nested storage.
private let forgeStorageShape = """
import Foundation

extension SourceIndexIdentity.PublicationTarget {
    init(forgedTitleID: String, forgedContentID: String) {
        self.storage = Storage(titleID: forgedTitleID, contentID: forgedContentID, season: nil, episode: nil)
    }
}

let forged = SourceIndexIdentity.PublicationTarget(
    forgedTitleID: "tt0000001",
    forgedContentID: "tt9999999:9:9"
)
print("FORGED pair: titleID=\\(forged.titleID) contentID=\\(forged.contentID)")
"""

/// Fixture (C): direct construction through the declared init. Rejected while the init stays fileprivate
/// (the IdentityCallerGateTests ACCESS check pins the sealed direction; this file pins the widened one).
private let forgeDirectInitShape = """
import Foundation

let forged = SourceIndexIdentity.PublicationTarget(
    titleID: "tt0000001", contentID: "tt9999999:9:9", season: nil, episode: nil
)
print("FORGED pair: titleID=\\(forged.titleID) contentID=\\(forged.contentID)")
"""

private struct CompileOutcome {
    let exitCode: Int32
    let diagnostics: String
    let runOutput: String
}

/// Compile `fixture` (as main.swift, so top-level expressions are legal) together with the production
/// contract file and `identitySource`, in ONE swiftc invocation -- one invocation is one module, which is
/// exactly the standing of any file added to the app target. On compile success the produced binary is run
/// and its output captured.
private func compileForge(
    fixture: String,
    contractPath: String,
    identitySource: String,
    label: String
) -> CompileOutcome {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("vortx-forge-\(label)-\(UUID().uuidString)",
                                                           isDirectory: true)
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let identityCopy = dir.appendingPathComponent("SourceIndexIdentity.swift")
        try identitySource.write(to: identityCopy, atomically: true, encoding: .utf8)
        let fixtureFile = dir.appendingPathComponent("main.swift")
        try fixture.write(to: fixtureFile, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("forge-\(label)")

        let compile = Process()
        let pipe = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = [
            "swiftc", "-swift-version", "6",
            contractPath, identityCopy.path, fixtureFile.path,
            "-o", binary.path,
        ]
        compile.standardOutput = pipe
        compile.standardError = pipe
        try compile.run()
        compile.waitUntilExit()
        let diagnostics = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        var runOutput = ""
        if compile.terminationStatus == 0 {
            let run = Process()
            let runPipe = Pipe()
            run.executableURL = binary
            run.standardOutput = runPipe
            run.standardError = runPipe
            try run.run()
            run.waitUntilExit()
            runOutput = String(decoding: runPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        return CompileOutcome(exitCode: compile.terminationStatus, diagnostics: diagnostics, runOutput: runOutput)
    } catch {
        return CompileOutcome(exitCode: -1, diagnostics: "harness error: \(error)", runOutput: "")
    }
}

/// Phases 1 + 2. Returns human-readable failures; empty means the boundary holds AND is shown able to fail.
private func forgeProofFailures(repoRoot: String) -> [String] {
    var failures: [String] = []
    let contractPath = repoRoot + "/app/SourcesShared/SourceIndexContract.swift"
    let identityPath = repoRoot + "/app/SourcesShared/SourceIndexIdentity.swift"
    guard let identitySource = try? String(contentsOfFile: identityPath, encoding: .utf8) else {
        return ["cannot read \(identityPath); the forge proof covers nothing"]
    }

    // Phase 1a: the pre-fix forge must be rejected, for the reason the seal predicts.
    let preFix = compileForge(fixture: forgePreFixShape, contractPath: contractPath,
                              identitySource: identitySource, label: "prefix-shape")
    if preFix.exitCode == 0 {
        failures.append("FORGE: the pre-fix same-module extension forge COMPILED; output: \(preFix.runOutput)")
    } else if !preFix.diagnostics.contains("cannot assign to property: 'titleID' is a get-only property") {
        failures.append("FORGE: pre-fix forge failed for an unexpected reason:\n\(preFix.diagnostics)")
    }

    // Phase 1b: the seal-aware forge must be rejected as INACCESSIBLE private storage.
    let sealAware = compileForge(fixture: forgeStorageShape, contractPath: contractPath,
                                 identitySource: identitySource, label: "storage-shape")
    if sealAware.exitCode == 0 {
        failures.append("FORGE: the storage-targeting forge COMPILED; output: \(sealAware.runOutput)")
    } else if !sealAware.diagnostics.contains("'storage' is inaccessible due to 'private' protection level") {
        failures.append("FORGE: storage forge failed for an unexpected reason:\n\(sealAware.diagnostics)")
    }

    // Phase 2 preconditions: the exact sealed spellings must exist in the production source, so the widening
    // below provably bites. A rename that silently defeated the mutation would otherwise pass forever.
    let sealedStorageDecl = "private struct Storage"
    let sealedStorageLet = "private let storage: Storage"
    let sealedInit = "fileprivate init(titleID: String, contentID: String, season: Int?, episode: Int?)"
    for needle in [sealedStorageDecl, sealedStorageLet, sealedInit] where !identitySource.contains(needle) {
        failures.append("MUTATION: expected sealed spelling `\(needle)` not found; the widening proof is dead")
    }
    guard failures.isEmpty else { return failures }

    // Phase 2a: drop `private` from the sealed storage -> the storage forge must COMPILE AND RUN again.
    let widenedStorage = identitySource
        .replacingOccurrences(of: sealedStorageDecl, with: "struct Storage")
        .replacingOccurrences(of: sealedStorageLet, with: "let storage: Storage")
    let reopened = compileForge(fixture: forgeStorageShape, contractPath: contractPath,
                                identitySource: widenedStorage, label: "widened-storage")
    if reopened.exitCode != 0 {
        failures.append("MUTATION: re-widened storage did NOT re-open the forge; the proof that the seal is "
                        + "load-bearing failed:\n\(reopened.diagnostics)")
    } else if !reopened.runOutput.contains("FORGED pair: titleID=tt0000001") {
        failures.append("MUTATION: widened forge compiled but did not print the forged pair: \(reopened.runOutput)")
    }

    // Phase 2b: make the fileprivate init internal again -> direct construction must COMPILE AND RUN again.
    let widenedInit = identitySource.replacingOccurrences(
        of: sealedInit,
        with: "init(titleID: String, contentID: String, season: Int?, episode: Int?)")
    let reopenedInit = compileForge(fixture: forgeDirectInitShape, contractPath: contractPath,
                                    identitySource: widenedInit, label: "widened-init")
    if reopenedInit.exitCode != 0 {
        failures.append("MUTATION: internal-again init did NOT re-open direct construction:\n"
                        + reopenedInit.diagnostics)
    } else if !reopenedInit.runOutput.contains("FORGED pair: titleID=tt0000001") {
        failures.append("MUTATION: widened-init forge compiled but did not print the forged pair: "
                        + reopenedInit.runOutput)
    }
    return failures
}

// MARK: - Production-linked lifecycle stubs (phase 3)

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

/// TorBox stub: publishes the REAL sealed `PublicationTarget` type. There is deliberately NO raw-string
/// identity setter here -- the only way this harness can point the stub at a page is a target built by the
/// real role resolver, which is the whole point of the boundary under test.
@MainActor
final class TorBoxSearchSource: ObservableObject {
    @Published var streams: [CoreStream] = [] { didSet { epoch &+= 1 } }
    var epoch = 0
    var publishedTarget: SourceIndexIdentity.PublicationTarget?

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
    private(set) var epoch = 0
    private var gateOpen = true
    var publishedTarget: SourceIndexIdentity.PublicationTarget?

    init(streams: [CoreStream], publishedTarget: SourceIndexIdentity.PublicationTarget? = nil) {
        self.streams = streams
        self.publishedTarget = publishedTarget
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

enum VXProbeRedaction {
    static func identityToken(_ raw: String?) -> String { "redacted" }
}

// MARK: - Run

@main
struct SourceIndexSourceListLifecycleTests {
    /// A resolver-built series episode target. The ONLY identity constructor this harness has.
    @MainActor
    static func episodeTarget(_ catalogID: String, season: Int, episode: Int)
        -> SourceIndexIdentity.PublicationTarget {
        guard let target = SourceIndexIdentity.publicationTarget(
            SourceIndexIdentity.Roles(
                catalogID: catalogID, defaultVideoID: nil, currentVideoID: nil, kind: .series),
            season: season, episode: episode
        ).target else { fatalError("fixture target must resolve") }
        return target
    }

    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        let repoRoot = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath

        // Phases 1 + 2: the forge must not compile, and must be shown to compile again when the seal widens.
        let forgeFailures = forgeProofFailures(repoRoot: repoRoot)
        for failure in forgeFailures { print("FAIL  \(failure)") }
        if forgeFailures.isEmpty {
            print("PASS  forge: same-module extension forge rejected in both spellings; both re-widenings re-open it")
        }

        // The authorization factory's contract, pinned directly against resolver-built targets.
        let e1 = episodeTarget("tt0903747", season: 1, episode: 1)
        let e2 = episodeTarget("tt0903747", season: 1, episode: 2)
        let authorizationContract =
            SourceIndexIdentity.mergeAuthorization(published: e1, pageContentID: e1.contentID) != nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, pageContentID: e2.contentID) == nil
            && SourceIndexIdentity.mergeAuthorization(published: nil, pageContentID: e1.contentID) == nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, pageContentID: nil) == nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, pageContentID: "") == nil
        print(authorizationContract
              ? "PASS  authorization: granted only for a published target whose content id the witness matches"
              : "FAIL  authorization: factory contract broken")

        // Phase 3: the real SourceListModel over the typed merge gate.
        let e3 = episodeTarget("tt0903747", season: 1, episode: 3)
        let ordinary = CoreStream(id: "ordinary", infoHash: nil, isTorrent: false)
        let pooled = CoreStream(id: "pooled", infoHash: String(repeating: "a", count: 40), isTorrent: true)
        let torboxRow = CoreStream(id: "torbox-row", infoHash: String(repeating: "b", count: 40), isTorrent: true)
        let mediaRow = CoreStream(id: "media-row", infoHash: nil, isTorrent: false)
        let core = CoreBridge(groups: [
            CoreStreamSourceGroup(id: "ordinary", addon: "Ordinary", streams: [ordinary]),
        ])
        let torbox = TorBoxSearchSource()
        torbox.publishedTarget = e1
        torbox.streams = [torboxRow]
        let singularity = SourceIndexServeSource(streams: [pooled], publishedTarget: e1)
        let mediaServers = MediaServerSource()
        mediaServers.publishedContentID = "page:tt0903747:1:1"
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        let debridCache = DebridCacheAwareness()
        let model = SourceListModel()
        // The witness the views hand over is the resolver target's content id, exactly as the detail screens
        // derive it (`auxiliaryTarget.target?.contentID`).
        model.setContext(
            metaId: "tt0903747", streamId: e1.contentID, continuity: nil, pin: nil,
            auxiliaryContentID: e1.contentID, mediaServerTargetID: "page:tt0903747:1:1"
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
            metaId: "tt0903747", streamId: e2.contentID, continuity: nil, pin: nil,
            auxiliaryContentID: e2.contentID, mediaServerTargetID: "page:tt0903747:1:2"
        )
        let identityClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "ordinary" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        // The sources still publish E1's typed target with live rows; the page witness is E2. The typed gate
        // must refuse the merge -- this is the stale-episode fence, now unpassable by any raw-string route.
        let staleAuxiliaryExcluded = ["torbox", "singularity", "media"].allSatisfy { id in
            !model.groups.contains { $0.id == id }
        }

        torbox.publishedTarget = e2
        torbox.streams = [torboxRow]
        singularity.publishedTarget = e2
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
            metaId: "tt0903747", streamId: e3.contentID, continuity: nil, pin: nil,
            auxiliaryContentID: e3.contentID, mediaServerTargetID: "page:tt0903747:1:3"
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

        let lifecycleHolds = initialPublished && identityClearedSynchronously && staleAuxiliaryExcluded
            && matchingAuxiliaryIncluded && nextEpisodeClearedSynchronously
            && detachedRankBlocked && clearedSynchronously && staleCompletionFenced
        if lifecycleHolds {
            print("PASS  SourceListModel clears identities, excludes stale auxiliary rows via the typed gate, and fences stale ranks")
        } else {
            print("FAIL  initial=\(initialPublished) identityClear=\(identityClearedSynchronously) auxScope=\(staleAuxiliaryExcluded) auxMatch=\(matchingAuxiliaryIncluded) nextClear=\(nextEpisodeClearedSynchronously) blocked=\(detachedRankBlocked) clear=\(clearedSynchronously) fenced=\(staleCompletionFenced)")
        }

        let allPassed = forgeFailures.isEmpty && authorizationContract && lifecycleHolds
        print(allPassed ? "ALL PASS" : "FAILURES PRESENT")
        exit(allPassed ? 0 : 1)
    }
}
