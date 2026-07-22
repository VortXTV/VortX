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
//      resolver -- must now FAIL TO COMPILE, in both its pre-fix spelling and its seal-aware spelling. The
//      SAME proof now also covers `SourceIndexIdentity.MediaServerTarget` (the sealed media-server page
//      identity): its get-only spelling, its storage spelling, AND its direct-init spelling must all be
//      rejected, so no ORDINARY construction route can smuggle a pre-baked media page token past the
//      identity file's factories (memory-safety opt-outs like `unsafeBitCast` are outside this proof's
//      scope, as documented on the type).
//
//   2. MUTATION PROOF: a guard that cannot be shown to fail is not verified. A COPY of the production
//      identity file is re-widened four ways (drop `private` from each sealed storage; make each fileprivate
//      init internal) and the corresponding forge fixture must COMPILE AND RUN again against each widened
//      copy, printing the forged value. This pins that the seal, and nothing else, is what stops the forge.
//
//   3. LIFECYCLE (production-linked, async): the REAL SourceListModel, driven through the REAL sealed
//      `SourceIndexIdentity.PublicationTarget` + `mergeAuthorization(published:page:)` gate AND the sealed
//      `MediaServerTarget` + `mediaServerMergeAuthorization` gate, must publish matching auxiliary rows,
//      exclude stale ones synchronously on an identity change, keep both the published output AND any
//      in-flight detached rebuild across an `.absent` -> `.mismatch` witness step (the derived-identity
//      comparison in `setContext`), fence detached stale ranks, and clear on a Source Index lifecycle
//      close. The auxiliary stubs publish TYPED targets built by the real resolver and the real media
//      factories -- there is no raw-string route left to drive them with.
//
// CAPTURED COMPILER OUTPUT (literal, from this machine, so "does not compile" is checkable prose).
// Recaptured 2026-07-22 by reproducing `compileForge`'s exact invocation (fixture written as main.swift,
// compiled with `xcrun swiftc -swift-version 6 <contract> <identity copy> main.swift -o <bin>`) under
// Apple Swift 6.3.2 (swiftlang-6.3.2.1.108). The compiler prints each error with an annotated source
// snippet and `note:` lines pointing into the (per-run temp) identity copy; only the `error:` lines are
// quoted below, with the per-run temp directory prefix elided to the file's basename. An earlier revision
// of this header quoted fixture (A)'s errors at lines 13-16 and fixture (B)'s at line 6, and omitted (B)'s
// two follow-on `nil` errors. The provenance of those old numbers could not be reconstructed: they match
// neither the main.swift the harness writes (fixture (A)'s four assignments sit at its lines 5-8, and
// fixture (B)'s storage assignment at its line 5) nor where either fixture's string literal sits in this
// file. The block below is a fresh capture, not a correction of the old one. What the compiler really prints:
//
// The PRE-FIX run of fixture (A) against 9a017a1's SourceIndexIdentity.swift compiled with exit 0 and printed:
//
//     FORGED pair: titleID=tt0000001 contentID=tt9999999:9:9
//
// which is the reviewer's bypass 1 reproduced verbatim: `internal` stored properties behind a `fileprivate`
// init are NOT a boundary inside one module.
//
// The POST-FIX run of fixture (A) (assigning the old stored names) exits 1 with:
//
//     main.swift:5:14: error: cannot assign to property: 'titleID' is a get-only property
//     main.swift:6:14: error: cannot assign to property: 'contentID' is a get-only property
//     main.swift:7:14: error: cannot assign to property: 'season' is a get-only property
//     main.swift:8:14: error: cannot assign to property: 'episode' is a get-only property
//
// The POST-FIX run of fixture (B) (assigning the sealed storage directly) exits 1 with:
//
//     main.swift:5:24: error: 'Storage' is inaccessible due to 'private' protection level
//     main.swift:5:14: error: 'storage' is inaccessible due to 'private' protection level
//     main.swift:5:92: error: 'nil' requires a contextual type
//     main.swift:5:106: error: 'nil' requires a contextual type
//
// (the two `nil` errors are fallout of the same seal: with `Storage` inaccessible, its memberwise init is
// unknown, so the `season:`/`episode:` nil literals have no type to adopt), and the MUTATION run (same
// fixture (B), `private` dropped from `struct Storage` and `let storage` in a temp copy) compiles with
// exit 0 and prints `FORGED pair: titleID=tt0000001 contentID=tt9999999:9:9` again.
//
// The MEDIA-SERVER fixtures, captured against the sealed MediaServerTarget on this machine the same way:
//
// Fixture (D) (assigning the get-only `token` from a same-module extension) exits 1 with:
//
//     main.swift:5:14: error: cannot assign to property: 'token' is a get-only property
//
// Fixture (E) (assigning the sealed media storage directly) exits 1 with:
//
//     main.swift:5:24: error: 'Storage' is inaccessible due to 'private' protection level
//     main.swift:5:14: error: 'storage' is inaccessible due to 'private' protection level
//
// Fixture (F) (calling the fileprivate init directly) exits 1 with (one line in the real output):
//
//     main.swift:3:14: error: 'SourceIndexIdentity.MediaServerTarget' initializer is inaccessible due to 'fileprivate' protection level
//
// and BOTH media mutation runs (fixture (E) against a copy whose media Storage block loses `private`;
// fixture (F) against a copy whose `fileprivate init(token:)` becomes internal) compile with exit 0 and
// print `FORGED media token: meta:forged|video:forged` again.

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

/// Fixture (D): the media-lane forge, pre-fix spelling -- a same-module extension of the sealed
/// `MediaServerTarget` assigning its exposed property directly, which would let any file hand the merge gate
/// a pre-baked page token that no factory formatted.
private let forgeMediaPreFixShape = """
import Foundation

extension SourceIndexIdentity.MediaServerTarget {
    init(forgedToken: String) {
        self.token = forgedToken
    }
}

let forged = SourceIndexIdentity.MediaServerTarget(forgedToken: "meta:forged|video:forged")
print("FORGED media token: \\(forged.token)")
"""

/// Fixture (E): the seal-aware spelling of the media forge, targeting the sealed nested storage.
private let forgeMediaStorageShape = """
import Foundation

extension SourceIndexIdentity.MediaServerTarget {
    init(forgedToken: String) {
        self.storage = Storage(token: forgedToken)
    }
}

let forged = SourceIndexIdentity.MediaServerTarget(forgedToken: "meta:forged|video:forged")
print("FORGED media token: \\(forged.token)")
"""

/// Fixture (F): direct construction of `MediaServerTarget` through the declared init. Rejected while the
/// init stays fileprivate; the widened-init mutation below must re-admit it.
private let forgeMediaDirectInitShape = """
import Foundation

let forged = SourceIndexIdentity.MediaServerTarget(token: "meta:forged|video:forged")
print("FORGED media token: \\(forged.token)")
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

    // Phase 1c: the media-lane pre-fix forge (assigning the exposed `token`) must be rejected as get-only.
    let mediaPreFix = compileForge(fixture: forgeMediaPreFixShape, contractPath: contractPath,
                                   identitySource: identitySource, label: "media-prefix-shape")
    if mediaPreFix.exitCode == 0 {
        failures.append("FORGE: the media-target extension forge COMPILED; output: \(mediaPreFix.runOutput)")
    } else if !mediaPreFix.diagnostics.contains("cannot assign to property: 'token' is a get-only property") {
        failures.append("FORGE: media pre-fix forge failed for an unexpected reason:\n\(mediaPreFix.diagnostics)")
    }

    // Phase 1d: the media storage-targeting forge must be rejected as INACCESSIBLE private storage.
    let mediaSealAware = compileForge(fixture: forgeMediaStorageShape, contractPath: contractPath,
                                      identitySource: identitySource, label: "media-storage-shape")
    if mediaSealAware.exitCode == 0 {
        failures.append("FORGE: the media storage forge COMPILED; output: \(mediaSealAware.runOutput)")
    } else if !mediaSealAware.diagnostics.contains("'storage' is inaccessible due to 'private' protection level") {
        failures.append("FORGE: media storage forge failed for an unexpected reason:\n\(mediaSealAware.diagnostics)")
    }

    // Phase 1e: direct construction of MediaServerTarget must be rejected while the init stays fileprivate
    // (PublicationTarget's sealed direction is pinned by the IdentityCallerGateTests ACCESS check; the media
    // type has no such external pin, so this file carries both directions itself).
    let mediaDirect = compileForge(fixture: forgeMediaDirectInitShape, contractPath: contractPath,
                                   identitySource: identitySource, label: "media-direct-init")
    if mediaDirect.exitCode == 0 {
        failures.append("FORGE: direct MediaServerTarget construction COMPILED; output: \(mediaDirect.runOutput)")
    } else if !mediaDirect.diagnostics.contains("initializer is inaccessible due to 'fileprivate' protection level") {
        failures.append("FORGE: media direct init failed for an unexpected reason:\n\(mediaDirect.diagnostics)")
    }

    // Phase 2 preconditions: the exact sealed spellings must exist in the production source, so the widening
    // below provably bites. A rename that silently defeated the mutation would otherwise pass forever. The
    // media storage needle is MULTI-LINE (it includes `let token: String`) because `private struct Storage` /
    // `private let storage: Storage` now name two seals; the scoped needle keeps each mutation minimal.
    let sealedStorageDecl = "private struct Storage"
    let sealedStorageLet = "private let storage: Storage"
    let sealedInit = "fileprivate init(titleID: String, contentID: String, season: Int?, episode: Int?)"
    let sealedMediaStorage = [
        "        private struct Storage: Equatable, Hashable, Sendable {",
        "            let token: String",
        "        }",
        "",
        "        private let storage: Storage",
    ].joined(separator: "\n")
    let sealedMediaInit = "fileprivate init(token: String)"
    for needle in [sealedStorageDecl, sealedStorageLet, sealedInit, sealedMediaStorage, sealedMediaInit]
    where !identitySource.contains(needle) {
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

    // Phase 2c: drop `private` from ONLY the media storage block -> the media storage forge must COMPILE AND
    // RUN again, which proves the media seal (and nothing else) is what stops fixture (E).
    let widenedMediaStorage = identitySource.replacingOccurrences(
        of: sealedMediaStorage,
        with: sealedMediaStorage
            .replacingOccurrences(of: "private struct Storage", with: "struct Storage")
            .replacingOccurrences(of: "private let storage", with: "let storage"))
    let reopenedMedia = compileForge(fixture: forgeMediaStorageShape, contractPath: contractPath,
                                     identitySource: widenedMediaStorage, label: "widened-media-storage")
    if reopenedMedia.exitCode != 0 {
        failures.append("MUTATION: re-widened media storage did NOT re-open the media forge:\n"
                        + reopenedMedia.diagnostics)
    } else if !reopenedMedia.runOutput.contains("FORGED media token: meta:forged|video:forged") {
        failures.append("MUTATION: widened media forge compiled but did not print the forged token: "
                        + reopenedMedia.runOutput)
    }

    // Phase 2d: make the media fileprivate init internal -> direct construction must COMPILE AND RUN again.
    let widenedMediaInit = identitySource.replacingOccurrences(
        of: sealedMediaInit, with: "init(token: String)")
    let reopenedMediaInit = compileForge(fixture: forgeMediaDirectInitShape, contractPath: contractPath,
                                         identitySource: widenedMediaInit, label: "widened-media-init")
    if reopenedMediaInit.exitCode != 0 {
        failures.append("MUTATION: internal-again media init did NOT re-open direct construction:\n"
                        + reopenedMediaInit.diagnostics)
    } else if !reopenedMediaInit.runOutput.contains("FORGED media token: meta:forged|video:forged") {
        failures.append("MUTATION: widened-media-init forge compiled but did not print the forged token: "
                        + reopenedMediaInit.runOutput)
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

/// Media-server stub: publishes the REAL sealed `MediaServerTarget` type and requires the REAL typed
/// authorization, mirroring the production owner. As with the TorBox stub, there is deliberately NO
/// raw-string identity setter -- the only way to point this stub at a page is a target built by the real
/// identity-file factories.
@MainActor
final class MediaServerSource: ObservableObject {
    @Published var groups: [CoreStreamSourceGroup] = [] { didSet { epoch &+= 1 } }
    var epoch = 0
    var publishedTarget: SourceIndexIdentity.MediaServerTarget?

    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MediaServerMergeAuthorization?,
        _ mediaGroups: [CoreStreamSourceGroup], into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        guard authorization != nil else { return groups }
        return groups + mediaGroups
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
    /// A resolver-built series episode resolution -- what a page computes and hands to `setContext`.
    @MainActor
    static func episodeResolution(_ catalogID: String, season: Int, episode: Int)
        -> SourceIndexIdentity.TargetResolution {
        SourceIndexIdentity.publicationTarget(
            SourceIndexIdentity.Roles(
                catalogID: catalogID, defaultVideoID: nil, currentVideoID: nil, kind: .series),
            season: season, episode: episode
        )
    }

    /// The sealed target out of the resolution above -- what an auxiliary source publishes. Together these
    /// are the ONLY identity constructors this harness has.
    @MainActor
    static func episodeTarget(_ catalogID: String, season: Int, episode: Int)
        -> SourceIndexIdentity.PublicationTarget {
        guard let target = episodeResolution(catalogID, season: season, episode: episode).target
        else { fatalError("fixture target must resolve") }
        return target
    }

    /// A factory-built media-server page target (the IMDb-less `meta:<id>|video:<id>` lane, which is the
    /// shape the identity file itself formats). The harness cannot spell a token by hand.
    @MainActor
    static func mediaTarget(_ metaID: String, video videoID: String)
        -> SourceIndexIdentity.MediaServerTarget {
        guard let target = SourceIndexIdentity.mediaServerTarget(metaID: metaID, videoID: videoID)
        else { fatalError("fixture media target must build") }
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
            print("PASS  forge: PublicationTarget + MediaServerTarget forges rejected in every spelling; "
                  + "all four re-widenings re-open them")
        }

        // The authorization factory's contract, pinned directly against resolver-built values. The page side
        // is a typed resolution now: `.absent` / `.mismatch` are the only spellings of "no page identity"
        // left, and a stale page is expressed as a different resolver-built episode -- there is no string
        // parameter through which anything else could be said.
        let r1 = episodeResolution("tt0903747", season: 1, episode: 1)
        let r2 = episodeResolution("tt0903747", season: 1, episode: 2)
        let e1 = episodeTarget("tt0903747", season: 1, episode: 1)
        let e2 = episodeTarget("tt0903747", season: 1, episode: 2)
        let authorizationContract =
            SourceIndexIdentity.mergeAuthorization(published: e1, page: r1) != nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, page: r2) == nil
            && SourceIndexIdentity.mergeAuthorization(published: e2, page: r1) == nil
            && SourceIndexIdentity.mergeAuthorization(published: nil, page: r1) == nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, page: .absent) == nil
            && SourceIndexIdentity.mergeAuthorization(published: e1, page: .mismatch) == nil
        print(authorizationContract
              ? "PASS  authorization: granted only for a published target whose canonical content id the page resolution matches"
              : "FAIL  authorization: factory contract broken")

        // The media-server factories' contract: the identity file formats every token (IMDb pages ride the
        // canonical content id verbatim; IMDb-less pages ride the formatted parts), each part is bounded by
        // the 128-byte identity cap, and an unusable part fails the WHOLE target instead of widening it.
        let oversized = String(repeating: "x", count: 200)
        let mediaFactoryContract =
            SourceIndexIdentity.mediaServerTarget(page: r1)?.token == e1.contentID
            && SourceIndexIdentity.mediaServerTarget(page: .absent) == nil
            && SourceIndexIdentity.mediaServerTarget(page: .mismatch) == nil
            && SourceIndexIdentity.mediaServerTarget(metaID: "meta-1")?.token == "meta:meta-1"
            && SourceIndexIdentity.mediaServerTarget(metaID: "meta-1", videoID: "vid-1")?.token
                == "meta:meta-1|video:vid-1"
            && SourceIndexIdentity.mediaServerTarget(metaID: nil) == nil
            && SourceIndexIdentity.mediaServerTarget(metaID: "") == nil
            && SourceIndexIdentity.mediaServerTarget(metaID: oversized) == nil
            && SourceIndexIdentity.mediaServerTarget(metaID: "meta-1", videoID: oversized) == nil
            && SourceIndexIdentity.mediaServerTarget(metaID: "meta-1", videoID: "") == nil
            && SourceIndexIdentity.mediaServerTarget(preferring: r1, metaID: "meta-1", videoID: "vid-1")?.token
                == e1.contentID
            && SourceIndexIdentity.mediaServerTarget(preferring: .absent, metaID: "meta-1", videoID: "vid-1")?.token
                == "meta:meta-1|video:vid-1"
        print(mediaFactoryContract
              ? "PASS  media factory: tokens are derived or formatted only by the identity file, parts bounded, no partial fallback"
              : "FAIL  media factory: contract broken")

        let msA = mediaTarget("tt0903747", video: "tt0903747:1:1")
        let msB = mediaTarget("tt0903747", video: "tt0903747:1:2")
        let mediaAuthorizationContract =
            SourceIndexIdentity.mediaServerMergeAuthorization(published: msA, page: msA) != nil
            && SourceIndexIdentity.mediaServerMergeAuthorization(published: msA, page: msB) == nil
            && SourceIndexIdentity.mediaServerMergeAuthorization(published: nil, page: msA) == nil
            && SourceIndexIdentity.mediaServerMergeAuthorization(published: msA, page: nil) == nil
        print(mediaAuthorizationContract
              ? "PASS  media authorization: granted only when the published and page tokens compare equal (Swift String equality)"
              : "FAIL  media authorization: factory contract broken")

        // INJECTIVITY of the fallback encoding (the separator gate). Before the gate, these two DIFFERENT
        // pages formatted the byte-identical token `meta:kitsu:42|video:kitsu:42:7` -- a movie page whose
        // add-on/catalog-controlled meta id embeds the separator, and a legitimate episode page -- and
        // `mediaServerMergeAuthorization` then authorized merging one page's direct-play rows into the
        // other. The crafted spelling must now build NOTHING (a separator-bearing part fails the whole
        // target, fail-closed), the legitimate two-part page must still build its exact token, and the
        // authorization must refuse to bridge the two pages in either direction.
        let craftedCollision = SourceIndexIdentity.mediaServerTarget(metaID: "kitsu:42|video:kitsu:42:7")
        let legitimateEpisodePage = SourceIndexIdentity.mediaServerTarget(metaID: "kitsu:42",
                                                                          videoID: "kitsu:42:7")
        let separatorInjectivityContract =
            craftedCollision == nil
            && legitimateEpisodePage?.token == "meta:kitsu:42|video:kitsu:42:7"
            && SourceIndexIdentity.mediaServerTarget(metaID: "kitsu:42", videoID: "kit|su:42:7") == nil
            && SourceIndexIdentity.mediaServerMergeAuthorization(
                published: craftedCollision, page: legitimateEpisodePage) == nil
            && SourceIndexIdentity.mediaServerMergeAuthorization(
                published: legitimateEpisodePage, page: craftedCollision) == nil
        print(separatorInjectivityContract
              ? "PASS  media injectivity: separator-bearing parts are rejected, so the crafted one-part/two-part collision is unbuildable"
              : "FAIL  media injectivity: the colliding pair is constructible again")

        // Phase 3: the real SourceListModel over the typed merge gates (all three lanes).
        let r3 = episodeResolution("tt0903747", season: 1, episode: 3)
        let e3 = episodeTarget("tt0903747", season: 1, episode: 3)
        let msC = mediaTarget("tt0903747", video: "tt0903747:1:3")
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
        mediaServers.publishedTarget = msA
        mediaServers.groups = [
            CoreStreamSourceGroup(id: "media", addon: "My Server", streams: [mediaRow]),
        ]
        let debridCache = DebridCacheAwareness()
        let model = SourceListModel()
        // The page hands over its TYPED resolutions, exactly as the detail screens now do (`auxiliaryTarget`
        // and the factory-built `mediaServerTarget` computed vars) -- nothing here is a string.
        model.setContext(
            metaId: "tt0903747", streamId: e1.contentID, continuity: nil, pin: nil,
            auxiliaryTarget: r1, mediaServerTarget: msA
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
            auxiliaryTarget: r2, mediaServerTarget: msB
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
        mediaServers.publishedTarget = msB
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
            auxiliaryTarget: r3, mediaServerTarget: msC
        )
        let nextEpisodeClearedSynchronously = model.groups.isEmpty
            && model.best == nil
            && model.tiers.isEmpty
            && model.resolutionOptions.isEmpty
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "singularity" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }

        // Restored `.absent` <-> `.mismatch` semantics (both derive a nil witness): stepping the page's
        // typed resolution between the two "no usable identity" states is NOT an identity change, so the
        // published ENGINE rows must stay painted synchronously -- no <=250 ms empty flash. Reachable in
        // production when an add-on later emits a `defaultVideoId` from a different title; it regressed
        // when the output identity carried the resolution enum instead of the derived canonical witness.
        model.setContext(
            metaId: "tt0903747", streamId: e3.contentID, continuity: nil, pin: nil,
            auxiliaryTarget: .absent, mediaServerTarget: nil
        )
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "ordinary" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let paintedUnderAbsent = model.groups.contains { $0.id == "ordinary" }
        model.setContext(
            metaId: "tt0903747", streamId: e3.contentID, continuity: nil, pin: nil,
            auxiliaryTarget: .mismatch, mediaServerTarget: nil
        )
        let absentMismatchKeepsEngineRows = paintedUnderAbsent
            && model.groups.contains { $0.id == "ordinary" }

        // PIN (SourceListModel.setContext, the derived-identity comparison): `identityChanged` must be
        // decided on the DERIVED output identities, not field-wise on the raw context fields. A field-wise
        // comparison over the typed fields leaves every check above green -- `.absent` -> `.mismatch`
        // derives the same nil witness either way, so the getters never blank -- but it silently makes the
        // transition retire work again: `generation` bumps (discarding a live detached rebuild) and
        // `publishedSignature` nulls (forcing a redundant reassembly). Observed through the public surface:
        // park a detached rebuild that carries a NEW engine group on the ranking blocker, step `.absent` ->
        // `.mismatch` while it is parked, and the new group must NOT surface -- under the field-wise
        // regression the step retires the parked rebuild and the coalescer runs a SECOND, unparked assembly
        // that publishes the group while the first still sits on the blocker. After release, the parked
        // rebuild's own result must land, proving its generation was never retired.
        model.setContext(
            metaId: "tt0903747", streamId: e3.contentID, continuity: nil, pin: nil,
            auxiliaryTarget: .absent, mediaServerTarget: nil
        )
        let lateRow = CoreStream(id: "late-row", infoHash: nil, isTorrent: false)
        core.groups = [
            CoreStreamSourceGroup(id: "ordinary", addon: "Ordinary", streams: [ordinary]),
            CoreStreamSourceGroup(id: "late", addon: "Late", streams: [lateRow]),
        ]
        RankingBlocker.shared.arm()
        core.streamsEpoch &+= 1
        for _ in 0..<4_000 {
            if RankingBlocker.shared.hasBlocked() { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let lateRebuildParked = RankingBlocker.shared.hasBlocked()
        model.setContext(
            metaId: "tt0903747", streamId: e3.contentID, continuity: nil, pin: nil,
            auxiliaryTarget: .mismatch, mediaServerTarget: nil
        )
        // Generous window vs the 250 ms coalescer: with the derived comparison, "late" CANNOT surface while
        // the only assembly that computed it is parked (the coalesced re-trigger bails on the pending
        // signature before any assembly); the field-wise regression publishes it inside this window.
        var lateSurfacedWhileParked = false
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "late" }) {
                lateSurfacedWhileParked = true
                break
            }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        RankingBlocker.shared.release()
        for _ in 0..<4_000 {
            if model.groups.contains(where: { $0.id == "late" }) { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000)
        }
        let parkedRebuildLanded = model.groups.contains { $0.id == "late" }
        let absentMismatchKeepsInFlightRebuild = lateRebuildParked && !lateSurfacedWhileParked
            && parkedRebuildLanded
        // Restore the plain engine snapshot for the phases below (the next epoch bump re-snapshots it).
        core.groups = [
            CoreStreamSourceGroup(id: "ordinary", addon: "Ordinary", streams: [ordinary]),
        ]

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
            && absentMismatchKeepsEngineRows && absentMismatchKeepsInFlightRebuild
            && detachedRankBlocked && clearedSynchronously && staleCompletionFenced
        if lifecycleHolds {
            print("PASS  SourceListModel clears identities, excludes stale auxiliary rows via the typed gate, keeps engine rows AND in-flight rebuilds across absent<->mismatch, and fences stale ranks")
        } else {
            print("FAIL  initial=\(initialPublished) identityClear=\(identityClearedSynchronously) auxScope=\(staleAuxiliaryExcluded) auxMatch=\(matchingAuxiliaryIncluded) nextClear=\(nextEpisodeClearedSynchronously) absentMismatch=\(absentMismatchKeepsEngineRows) inFlight=\(absentMismatchKeepsInFlightRebuild) parked=\(lateRebuildParked) surfacedWhileParked=\(lateSurfacedWhileParked) landed=\(parkedRebuildLanded) blocked=\(detachedRankBlocked) clear=\(clearedSynchronously) fenced=\(staleCompletionFenced)")
        }

        let allPassed = forgeFailures.isEmpty && authorizationContract && mediaFactoryContract
            && mediaAuthorizationContract && separatorInjectivityContract && lifecycleHolds
        print(allPassed ? "ALL PASS" : "FAILURES PRESENT")
        exit(allPassed ? 0 : 1)
    }
}
