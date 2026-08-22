// Executable harness for the two Dolby Vision playback fixes.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/dv-playback-contract-test \
//     app/Sources/Player/DVPlaybackPolicy.swift \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Tests/DVPlaybackContractTests.swift && /tmp/dv-playback-contract-test
//
// This suite CALLS the production decisions. An earlier version asserted on source text instead, because the code
// using these decisions lives in files that pull in AVFoundation and UIKit. That version was proven inadequate: a
// mutant that preserved every asserted string and appended `false` to the guard condition passed the whole suite
// while the guard could never fire. Substring assertions prove a line exists, not that it runs. The decisions now
// live in a dependency-free file so the real functions can be executed here.
//
// The bar is mutation survival, not a pass count: every assertion below must turn RED when its property is broken,
// including SEMANTIC breaks that leave the source text intact.

import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

/// Standalone-compilation stub for the buffer's failure-reason funnel (same pattern as the RemoteConfig stub).
enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) { print("[\(tag)] \(message)") }
}

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

private func sourceSlice(_ source: String, from start: String, to end: String) -> String? {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

/// Removes formatting and comment-only lines so wiring checks are scoped to executable source. This is only the
/// caller half of the contract: the assertions below still execute the production policy, while negative mutation
/// controls prove that each caller rule turns red when its real assignment, guard, or receipt mutation is bypassed.
private func compactSwift(_ source: String) -> String {
    source.components(separatedBy: "\n").compactMap { rawLine -> String? in
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return nil }
        if let comment = rawLine.range(of: "//"),
           !rawLine[..<comment.lowerBound].contains("\"") {
            return String(rawLine[..<comment.lowerBound])
        }
        return rawLine
    }
    .joined()
    .filter { !$0.isWhitespace }
}

private func replacingFirst(
    _ source: String,
    after anchor: String,
    target: String,
    with replacement: String
) -> String? {
    guard let anchorRange = source.range(of: anchor),
          let targetRange = source.range(
              of: target,
              range: anchorRange.lowerBound..<source.endIndex) else {
        return nil
    }
    var mutated = source
    mutated.replaceSubrange(targetRange, with: replacement)
    return mutated
}

private struct StartupWiringRule {
    let name: String
    let usesServer: Bool
    let start: String
    let end: String
    let exactSection: String
    let mutationTarget: String
    let mutationReplacement: String
    let allowsExecutablePrefix: Bool
    let secondaryMutationTarget: String?
    let secondaryMutationReplacement: String?

    init(
        name: String,
        usesServer: Bool,
        start: String,
        end: String,
        exactSection: String,
        mutationTarget: String,
        mutationReplacement: String,
        allowsExecutablePrefix: Bool = false,
        secondaryMutationTarget: String? = nil,
        secondaryMutationReplacement: String? = nil
    ) {
        self.name = name
        self.usesServer = usesServer
        self.start = start
        self.end = end
        self.exactSection = exactSection
        self.mutationTarget = mutationTarget
        self.mutationReplacement = mutationReplacement
        self.allowsExecutablePrefix = allowsExecutablePrefix
        self.secondaryMutationTarget = secondaryMutationTarget
        self.secondaryMutationReplacement = secondaryMutationReplacement
    }

    func passes(engine: String, server: String) -> Bool {
        let source = usesServer ? server : engine
        return sourceSlice(source, from: start, to: end).map {
            let compactActual = compactSwift($0)
            let compactExpected = compactSwift(exactSection)
            return allowsExecutablePrefix
                ? compactActual.hasSuffix(compactExpected)
                : compactActual == compactExpected
        } ?? false
    }
}

@MainActor private func checkStartupProductionWiring() {
    let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let playerRoot = appRoot.appendingPathComponent("Sources/Player")
    guard let engine = try? String(
        contentsOf: playerRoot.appendingPathComponent("AVPlayerEngine.swift"),
        encoding: .utf8),
          let server = try? String(
              contentsOf: playerRoot.appendingPathComponent("VortXRemuxHLSServer.swift"),
              encoding: .utf8) else {
        check("startup production wiring: governed sources are readable", false)
        return
    }

    let rules = [
        StartupWiringRule(
            name: "exact mount classification", usesServer: false,
            start: "private var forwardBufferMount: VortXRemuxForwardBufferPolicy.Mount {",
            end: "/// Render proof for the chrome's first-frame commit.",
            exactSection: """
            private var forwardBufferMount: VortXRemuxForwardBufferPolicy.Mount {
                if remuxRemoteMount != nil { return .remoteRemux }
                if remuxHLSServer != nil || remuxLoader != nil { return .localRemux }
                return .direct
            }
            """,
            mutationTarget: "if remuxRemoteMount != nil { return .remoteRemux }",
            mutationReplacement: "if remuxRemoteMount != nil { return .localRemux }"),
        StartupWiringRule(
            name: "initial item forward-buffer assignment", usesServer: false,
            start: "let newItem = AVPlayerItem(asset: newAsset)",
            end: "// Attach a pull-model frame tap",
            exactSection: """
            if isRemuxMounted {
                newItem.preferredForwardBufferDuration =
                    VortXRemuxForwardBufferPolicy.preferredDuration(
                        mount: forwardBufferMount,
                        hasProducedFirstFrame: false)
            }
            """,
            mutationTarget: "newItem.preferredForwardBufferDuration =",
            mutationReplacement: "_ =",
            allowsExecutablePrefix: true,
            secondaryMutationTarget: "if isRemuxMounted {",
            secondaryMutationReplacement: "if false && isRemuxMounted {"),
        StartupWiringRule(
            name: "first-frame steady-buffer restore", usesServer: false,
            start: "videoFrameEverProduced = true",
            end: "if let server = remuxHLSServer {",
            exactSection: """
            videoFrameEverProduced = true
            if isRemuxMounted {
                applyForwardBufferCouplingIfDue()
            }
            """,
            mutationTarget: "applyForwardBufferCouplingIfDue()",
            mutationReplacement: "_ = isRemuxMounted",
            secondaryMutationTarget: "if isRemuxMounted {",
            secondaryMutationReplacement: "if false && isRemuxMounted {"),
        StartupWiringRule(
            name: "HDR replacement forward-buffer restore", usesServer: false,
            start: "freshItem.preferredForwardBufferDuration =",
            end: "let output = AVPlayerItemVideoOutput(",
            exactSection: """
            freshItem.preferredForwardBufferDuration =
                VortXRemuxForwardBufferPolicy.preferredDuration(
                    mount: forwardBufferMount,
                    hasProducedFirstFrame: false)
            """,
            mutationTarget: "freshItem.preferredForwardBufferDuration =",
            mutationReplacement: "_ ="),
        StartupWiringRule(
            name: "memory-warning non-increasing mutation", usesServer: false,
            start: "@objc private func handleMemoryWarningNote() {",
            end: "DiagnosticsLog.log(",
            exactSection: """
            @objc private func handleMemoryWarningNote() {
                guard let item,
                      let replacement = VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
                          currentDuration: item.preferredForwardBufferDuration,
                          mount: forwardBufferMount,
                          hasProducedFirstFrame: videoFrameEverProduced) else { return }
                item.preferredForwardBufferDuration = replacement
            """,
            mutationTarget: "item.preferredForwardBufferDuration = replacement",
            mutationReplacement: "item.preferredForwardBufferDuration = max(replacement, 30)"),
        StartupWiringRule(
            name: "remux-only automatic stall waiting", usesServer: false,
            start: "player.automaticallyWaitsToMinimizeStalling =\n            VortXRemuxForwardBufferPolicy",
            end: "player.allowsExternalPlayback",
            exactSection: """
            player.automaticallyWaitsToMinimizeStalling =
                VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
                    mount: forwardBufferMount)
            """,
            mutationTarget: "mount: forwardBufferMount",
            mutationReplacement: "mount: .direct"),
        StartupWiringRule(
            name: "remote initial adaptive buffer", usesServer: false,
            start: "let newItem = AVPlayerItem(asset: AVURLAsset(url: mount.playlistURL))",
            end: "let output = AVPlayerItemVideoOutput(",
            exactSection: """
            let newItem = AVPlayerItem(asset: AVURLAsset(url: mount.playlistURL))
            newItem.preferredForwardBufferDuration =
                VortXRemuxForwardBufferPolicy.preferredDuration(
                    mount: .remoteRemux,
                    hasProducedFirstFrame: false)
            """,
            mutationTarget: "mount: .remoteRemux",
            mutationReplacement: "mount: .localRemux"),
        StartupWiringRule(
            name: "remote automatic stall waiting", usesServer: false,
            start: """
            #endif
                    player.automaticallyWaitsToMinimizeStalling =
                        VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
                            mount: .remoteRemux)
            """,
            end: "player.allowsExternalPlayback",
            exactSection: """
            #endif
            player.automaticallyWaitsToMinimizeStalling =
                VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
                    mount: .remoteRemux)
            """,
            mutationTarget: "mount: .remoteRemux",
            mutationReplacement: "mount: .direct"),
        StartupWiringRule(
            name: "cohort successor publication", usesServer: true,
            start: "if !isEngineReady,\n           consumptionAnchored,",
            end: "let ids = selectedVideo.segments.map(\\.id)",
            exactSection: """
            if !isEngineReady,
               consumptionAnchored,
               highestServedVideoSegmentID < 0,
               !ended,
               selectedVideo.segments.count > max(
                startupReadiness.maximumUnconsumedSegmentCount,
                startup.window.segments.count
               ) {
                selectedVideo = startupReadiness.unconsumedStartupWindow(
                    selectedVideo,
                    startupCohortCount: startup.window.segments.count
                )
                publishedVideoWindow = selectedVideo
            }
            """,
            mutationTarget: "startupCohortCount: startup.window.segments.count",
            mutationReplacement: "startupCohortCount: 0"),
        StartupWiringRule(
            name: "first media fetch release", usesServer: true,
            start: "private func serveSegment(", end: "private static let segmentChunk",
            exactSection: """
            private func serveSegment(_ connection: NWConnection, index: Int, delivery: Delivery = .legacy) {
                publicationLock.lock()
                if index > highestServedVideoSegmentID { highestServedVideoSegmentID = index }
                publicationLock.unlock()
                serveSpoolResource(
                    connection,
                    key: .video(segmentID: index),
                    path: "/seg\\(index).m4s",
                    contentType: "video/mp4",
                    delivery: delivery)
            }
            """,
            mutationTarget: "highestServedVideoSegmentID = index",
            mutationReplacement: "_ = index"),
        StartupWiringRule(
            name: "actual playhead receipt", usesServer: false,
            start: "playheadObserver = player.addPeriodicTimeObserver(",
            end: "NotificationCenter.default.addObserver(self, selector: #selector(didPlayToEnd(_:)),",
            exactSection: """
            playheadObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: playheadQueue
            ) { [weak remuxServer = remuxHLSServer] time in
                remuxServer?.reportPlaybackPosition(playerSeconds: time.seconds)
            }
            """,
            mutationTarget: "queue: playheadQueue",
            mutationReplacement: "queue: .main"),
        StartupWiringRule(
            name: "publication slides behind playhead", usesServer: true,
            start: "if consumptionAnchored {\n                    let playbackSegmentID",
            end: "} else {\n                    // Escape hatch OFF-path:",
            exactSection: """
            if consumptionAnchored {
                let playbackSegmentID = playbackSegmentID(in: common)
                let newStartID = VortXHLSConsumptionWindowPolicy.publicationStartID(
                    currentStartID: current.mediaSequence,
                    suffixStartID: suffixStartID,
                    playbackSegmentID: playbackSegmentID,
                    window: common)
                let slid = common.segments.drop { $0.id < newStartID }
                selectedVideo = slid.isEmpty ? common : VortXHLSWindow(segments: Array(slid))
            """,
            mutationTarget: "playbackSegmentID: playbackSegmentID",
            mutationReplacement: "playbackSegmentID: highestServedVideoSegmentID"),
    ]

    for rule in rules {
        check("startup production wiring: \(rule.name)", rule.passes(engine: engine, server: server))
        let source = rule.usesServer ? server : engine
        let mutated = replacingFirst(
            source,
            after: rule.start,
            target: rule.mutationTarget,
            with: rule.mutationReplacement)
        let caught = mutated.map {
            rule.usesServer
                ? !rule.passes(engine: engine, server: $0)
                : !rule.passes(engine: $0, server: server)
        } ?? false
        check("startup production wiring mutation: \(rule.name) turns red", caught)

        if let secondaryTarget = rule.secondaryMutationTarget,
           let secondaryReplacement = rule.secondaryMutationReplacement {
            let secondaryMutated = replacingFirst(
                source,
                after: rule.start,
                target: secondaryTarget,
                with: secondaryReplacement)
            let secondaryCaught = secondaryMutated.map {
                rule.usesServer
                    ? !rule.passes(engine: engine, server: $0)
                    : !rule.passes(engine: $0, server: server)
            } ?? false
            check("startup production wiring guard mutation: \(rule.name) turns red", secondaryCaught)
        }
    }
}

typealias Req = DVPlaybackPolicy.DisplayRequest
final class FakeDisplayManager {}

// Compiling several files together means only a `main.swift` may carry top-level expressions, so the run body is a
// function invoked from `@main`, matching the other standalone suites in this directory.
@MainActor @main
enum DVPlaybackContractTests {
    static func main() { run() }
}

@MainActor func run() {

// MARK: - Native Dolby Vision pre-attach ordering

var nativeEvents: [String] = []
let loadedCriteriaIdentity = NSObject()
let nativeOutcome = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: loadedCriteriaIdentity,
    isCurrent: { true },
    apply: { criteria in
        nativeEvents.append(criteria === loadedCriteriaIdentity ? "apply-loaded" : "apply-other")
    },
    attach: { nativeEvents.append("attach") })
check("native DV: the exact loaded criteria object is applied before item attachment",
      nativeOutcome == .attachedWithLoadedCriteria
          && nativeEvents == ["apply-loaded", "attach"])

nativeEvents = []
let failedLoadOutcome = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: Optional<NSObject>.none,
    isCurrent: { true },
    apply: { _ in nativeEvents.append("apply") },
    attach: { nativeEvents.append("attach") })
check("native DV: criteria load failure attaches fail-soft without constructing or applying a guess",
      failedLoadOutcome == .attachedFailSoft && nativeEvents == ["attach"])

nativeEvents = []
let staleOutcome = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: loadedCriteriaIdentity,
    isCurrent: { false },
    apply: { _ in nativeEvents.append("apply") },
    attach: { nativeEvents.append("attach") })
check("native DV: a stale token or item generation never applies or attaches",
      staleOutcome == .stale && nativeEvents.isEmpty)

nativeEvents = []
var currentChecks = 0
let supersededDuringApply = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: loadedCriteriaIdentity,
    isCurrent: {
        currentChecks += 1
        return currentChecks == 1
    },
    apply: { _ in nativeEvents.append("apply") },
    attach: { nativeEvents.append("attach") })
check("native DV: a load superseded during display apply still cannot attach its retired item",
      supersededDuringApply == .stale && nativeEvents == ["apply"])

nativeEvents = []
let activeGeneration = 2
let slowA = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: "A",
    isCurrent: { activeGeneration == 1 },
    apply: { nativeEvents.append("apply-\($0)") },
    attach: { nativeEvents.append("attach-A") })
let fastB = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: "B",
    isCurrent: { activeGeneration == 2 },
    apply: { nativeEvents.append("apply-\($0)") },
    attach: { nativeEvents.append("attach-B") })
check("native DV: slow A then fast B lets only the latest generation switch and attach",
      slowA == .stale
          && fastB == .attachedWithLoadedCriteria
          && nativeEvents == ["apply-B", "attach-B"])

nativeEvents = []
let stoppedGeneration: Int? = nil
let completionAfterStop = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: "A",
    isCurrent: { stoppedGeneration == 1 },
    apply: { nativeEvents.append("apply-\($0)") },
    attach: { nativeEvents.append("attach-A") })
check("native DV: stopping during a slow preflight makes its completion side-effect-free",
      completionAfterStop == .stale && nativeEvents.isEmpty)

nativeEvents = []
var timeoutGeneration: Int? = 7
// The owner of the startup deadline retires the pending generation. This fixture intentionally does not choose
// the deadline duration or what the owner does at that deadline; it proves the load completion cannot resurrect
// the retired item after any external timeout policy has won the race.
timeoutGeneration = nil
let lateCompletionAfterTimeout = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: "late",
    isCurrent: { timeoutGeneration == 7 },
    apply: { nativeEvents.append("apply-\($0)") },
    attach: { nativeEvents.append("attach-late") })
check("native DV: a loader completing after the owning timeout retired its generation is inert",
      lateCompletionAfterTimeout == .stale && nativeEvents.isEmpty)

// MARK: - DV start position (the ~14s start)

let initialWindow = VortXHLSWindow(segments: [])
let header = DVPlaybackPolicy.mediaPlaylistLines(
    window: initialWindow, ended: false, targetDuration: 5, mapURI: "init.mp4")

check("start: the header states an explicit start point",
      header.contains { $0.hasPrefix("#EXT-X-START:") })
check("start: the offset is exactly zero",
      header.contains { $0.contains("TIME-OFFSET=0") && !$0.contains("TIME-OFFSET=0.") })
check("start: PRECISE=YES, so the client does not round back to a preceding segment",
      header.contains { $0.hasPrefix("#EXT-X-START:") && $0.contains("PRECISE=YES") })
// A negative offset is the live-edge behaviour being removed. It would still emit the tag, so the VALUE is pinned
// rather than the tag's presence.
check("start: no negative TIME-OFFSET (that is the live-edge behaviour we are removing)",
      !header.contains { $0.contains("TIME-OFFSET=-") })
// Asserted with a value DIFFERENT from the shipping 5. A mutation battery caught the earlier version: it passed 5
// and asserted 5, so replacing the interpolation with a hardcoded 5 was invisible. A fixture that happens to equal
// the value under test cannot detect that the value is ignored.
check("start: the target duration passed in is the one emitted",
      DVPlaybackPolicy.mediaPlaylistLines(
        window: initialWindow, ended: false, targetDuration: 7, mapURI: "i.mp4")
        .contains("#EXT-X-TARGETDURATION:7"))
check("start: a second, different target duration is also honoured",
      DVPlaybackPolicy.mediaPlaylistLines(
        window: initialWindow, ended: false, targetDuration: 11, mapURI: "i.mp4")
        .contains("#EXT-X-TARGETDURATION:11"))
check("start: the map URI is carried through",
      header.contains(#"#EXT-X-MAP:URI="init.mp4""#))
// The start tag must precede the segment list, which begins after the header. Emitting it after the segments would
// leave a client applying the live-edge rule before it ever reads the tag.
check("start: the start tag comes before the map line",
      {
          guard let s = header.firstIndex(where: { $0.hasPrefix("#EXT-X-START:") }),
                let m = header.firstIndex(where: { $0.hasPrefix("#EXT-X-MAP:") }) else { return false }
          return s < m
      }())

let producerAheadWindow = VortXHLSWindow(segments: (0...5).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 100, byteLength: 100,
                    start: Double($0 * 4), duration: 4)
})
let pinnedStartup = DVPlaybackPolicy.pinnedStartupSnapshot(
    window: producerAheadWindow, ended: false, minimumSegmentCount: 2)
let pinnedStartupLines = pinnedStartup.map {
    DVPlaybackPolicy.mediaPlaylistLines(
        window: $0.window, ended: $0.ended, targetDuration: 5, mapURI: "init.mp4")
} ?? []
check("start: a producer already at 0...N exposes only the earliest startup prefix",
      pinnedStartup?.window.segments.map(\.id) == [0, 1])
check("start: the executable first body cannot widen to a later producer segment",
      pinnedStartupLines.contains("seg0.m4s")
          && pinnedStartupLines.contains("seg1.m4s")
          && !pinnedStartupLines.contains("seg2.m4s")
          && !pinnedStartupLines.contains("seg5.m4s"))
let producerEndedAhead = DVPlaybackPolicy.pinnedStartupSnapshot(
    window: producerAheadWindow, ended: true, minimumSegmentCount: 2)
check("start: a capped prefix cannot inherit ENDLIST from unseen later segments",
      producerEndedAhead?.ended == false)
let shortEndedStartup = DVPlaybackPolicy.pinnedStartupSnapshot(
    window: VortXHLSWindow(segments: Array(producerAheadWindow.segments.prefix(1))),
    ended: true,
    minimumSegmentCount: 2)
check("start: a genuinely short completed source may expose its sole segment and ENDLIST",
      shortEndedStartup?.window.segments.map(\.id) == [0]
          && shortEndedStartup?.ended == true)
let lostZeroWindow = VortXHLSWindow(segments: Array(producerAheadWindow.segments.dropFirst()))
check("start: startup fails closed if absolute segment zero is no longer resident",
      DVPlaybackPolicy.pinnedStartupSnapshot(
          window: lostZeroWindow, ended: false, minimumSegmentCount: 2) == nil)

let roundingSensitiveDurations = [2.00049, 2.00049, 2.00049, 2.00049, 2.00049, 4.998, 0.002]
let roundingSensitiveWindow = VortXHLSWindow(segments: roundingSensitiveDurations.enumerated().map {
    VortXHLSSegment(id: $0.offset, byteOffset: $0.offset * 100, byteLength: 100,
                    start: 0, duration: $0.element)
})
let exactRenderedStartup = DVPlaybackPolicy.pinnedStartupSnapshot(
    window: roundingSensitiveWindow,
    ended: false,
    minimumSegmentCount: 6,
    minimumRenderedDurationMilliseconds: 15_000)
check("start: the non-ended gate sums exact emitted EXTINF milliseconds rather than raw Doubles",
      exactRenderedStartup?.window.segments.map(\.id) == Array(0...6))
check("start: the selected non-ended prefix is the shortest one satisfying six segments and 15000ms",
      exactRenderedStartup.map {
          DVPlaybackPolicy.renderedDurationMilliseconds(of: $0.window) == 15_000
      } == true)
let productionStartupWindow = VortXHLSWindow(segments: (0..<10).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 100, byteLength: 100,
                    start: Double($0) * 2.5, duration: 2.5)
})
check("start: production startup exposes exactly the shortest absolute 0-prefix of six and fifteen seconds",
      DVPlaybackPolicy.pinnedStartupSnapshot(
          window: productionStartupWindow,
          ended: false,
          minimumSegmentCount: 6,
          minimumRenderedDurationMilliseconds: 15_000)?.window.segments.map(\.id) == Array(0...5))
check("start: an ended short title publishes its complete prefix with ENDLIST despite missing the live gate",
      DVPlaybackPolicy.pinnedStartupSnapshot(
          window: VortXHLSWindow(segments: Array(productionStartupWindow.segments.prefix(3))),
          ended: true,
          minimumSegmentCount: 6,
          minimumRenderedDurationMilliseconds: 15_000)?.ended == true)
check("start: a positive raw duration that renders as zero EXTINF milliseconds is rejected",
      DVPlaybackPolicy.pinnedStartupSnapshot(
          window: VortXHLSWindow(segments: [
              VortXHLSSegment(id: 0, byteOffset: 0, byteLength: 1, duration: 0.0004),
          ]),
          ended: true,
          minimumSegmentCount: 1,
          minimumRenderedDurationMilliseconds: 0) == nil)

let cohortVideo = VortXHLSWindow(segments: (0..<10).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 100, byteLength: 100,
                    start: Double($0) * 2.5, duration: 2.5)
})
let cohortAudio = VortXHLSWindow(segments: (0..<10).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 80, byteLength: 80,
                    start: Double($0) * 2, duration: 2)
})
let sharedCohort = DVPlaybackPolicy.pinnedStartupCohort(
    windows: [cohortVideo, cohortAudio],
    ended: false,
    minimumSegmentCount: 6,
    minimumRenderedDurationMilliseconds: 15_000)
check("cohort: the slowest rendition widens every startup route to one identical absolute-id prefix",
      sharedCohort?.window.segments.map(\.id) == Array(0...7))
let mismatchedCohort = VortXHLSWindow(segments: cohortAudio.segments.enumerated().map {
    VortXHLSSegment(id: $0.offset == 4 ? 99 : $0.element.id,
                    byteOffset: $0.element.byteOffset,
                    byteLength: $0.element.byteLength,
                    start: $0.element.start,
                    duration: $0.element.duration)
})
check("cohort: one rendition with a mismatched absolute id fails the master startup atomically",
      DVPlaybackPolicy.pinnedStartupCohort(
        windows: [cohortVideo, mismatchedCohort],
        ended: false,
        minimumSegmentCount: 6,
        minimumRenderedDurationMilliseconds: 15_000) == nil)
let endedVideo = VortXHLSWindow(segments: Array(cohortVideo.segments.prefix(3)))
let endedAudio = VortXHLSWindow(segments: Array(cohortAudio.segments.prefix(3)))
check("cohort: a genuinely short ended title publishes one complete shared cohort with ENDLIST",
      DVPlaybackPolicy.pinnedStartupCohort(
        windows: [endedVideo, endedAudio],
        ended: true,
        minimumSegmentCount: 6,
        minimumRenderedDurationMilliseconds: 15_000)?.ended == true)

let rollingWindow = VortXHLSWindow(segments: (40..<50).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 100, byteLength: 100,
                    start: Double($0 - 40) * 2.5, duration: 2.5)
})
check("rolling cohort: arbitrary absolute media sequences trim to the newest six-segment fifteen-second suffix",
      DVPlaybackPolicy.minimumConformingSuffix(
        window: rollingWindow,
        minimumSegmentCount: 6,
        minimumRenderedDurationMilliseconds: 15_000)?.segments.map(\.id) == Array(44...49))
let durationBoundWindow = VortXHLSWindow(segments: (40..<50).map {
    VortXHLSSegment(id: $0, byteOffset: $0 * 100, byteLength: 100,
                    start: Double($0 - 40), duration: 1)
})
check("rolling cohort: duration floor can retain more entries than the segment-count floor",
      DVPlaybackPolicy.minimumConformingSuffix(
        window: durationBoundWindow,
        minimumSegmentCount: 6,
        minimumRenderedDurationMilliseconds: 8_000)?.segments.map(\.id) == Array(42...49))
let gappedRollingWindow = VortXHLSWindow(segments: rollingWindow.segments.enumerated().map {
    VortXHLSSegment(id: $0.offset == 5 ? 60 : $0.element.id,
                    byteOffset: $0.element.byteOffset,
                    byteLength: $0.element.byteLength,
                    start: $0.element.start,
                    duration: $0.element.duration)
})
check("rolling cohort: an absolute-id gap cannot produce a reload suffix",
      DVPlaybackPolicy.minimumConformingSuffix(
        window: gappedRollingWindow,
        minimumSegmentCount: 6,
        minimumRenderedDurationMilliseconds: 15_000) == nil)

// MARK: - IDR legality and init publication are independent gates

func hevcNAL(_ type: UInt8, lengthPrefixBytes: Int = 4) -> [UInt8] {
    let payload: [UInt8] = [type << 1, 0x01]
    var prefix = [UInt8](repeating: 0, count: lengthPrefixBytes)
    prefix[lengthPrefixBytes - 1] = UInt8(payload.count)
    return prefix + payload
}

let hevcIDRWRADL = hevcNAL(19)
let hevcIDRNLP = hevcNAL(20)
let hevcCRA = hevcNAL(21)
let hevcBLA = hevcNAL(16)
check("IDR classifier: HEVC IDR_W_RADL is an exact segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: hevcIDRWRADL, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: HEVC IDR_N_LP is an exact segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: hevcIDRNLP, codec: .hevc, format: .lengthPrefixed(4)))
// CRA and BLA are sync IRAPs and LEGAL segment starts (a decoder tuning in discards their RASL leading
// pictures). The IDR-only rule shipped in build 189 killed every open-GOP HEVC source: no cut for a whole
// frozen target on fresh plays, no first segment on resume seeks landing on a CRA - both silent session
// deaths into the HDR10 demote. Build 187 cut on FFmpeg's KEY flag, which covers exactly these types.
check("IDR classifier: HEVC CRA is a sync IRAP segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: hevcCRA, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: HEVC BLA is a sync IRAP segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: hevcBLA, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: a mixed HEVC CRA plus IDR access unit is a sync segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: hevcCRA + hevcIDRWRADL, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: a mixed HEVC non-IDR slice plus IDR access unit fails closed",
      !VortXVideoIDRClassifier.isIDR(
          bytes: hevcNAL(1) + hevcIDRWRADL, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: a truncated length-prefixed access unit fails soft",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 4, 19 << 1, 0x01], codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: a zero-length NAL fails soft",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 0], codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: HEVC forbidden_zero_bit rejects an otherwise IDR-shaped header",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 2, 0x80 | (19 << 1), 0x01],
          codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: HEVC temporal_id_plus1 zero is malformed",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 2, 19 << 1, 0x00],
          codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: Annex-B HEVC IDR is accepted without a payload copy",
      VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 1, 19 << 1, 0x01], codec: .hevc, format: .annexB))
check("IDR classifier: Annex-B HEVC CRA is a sync IRAP segment start",
      VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 1, 21 << 1, 0x01], codec: .hevc, format: .annexB))
check("IDR classifier: HEVC RASL leading pictures never open a segment",
      !VortXVideoIDRClassifier.isIDR(
          bytes: hevcNAL(8), codec: .hevc, format: .lengthPrefixed(4))
          && !VortXVideoIDRClassifier.isIDR(
              bytes: hevcNAL(9), codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: plain-remux H.264 accepts only NAL type 5",
      VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 1, 0x65], codec: .h264, format: .lengthPrefixed(4))
          && !VortXVideoIDRClassifier.isIDR(
              bytes: [0, 0, 0, 1, 0x61], codec: .h264, format: .lengthPrefixed(4)))
check("IDR classifier: H.264 rejects forbidden, ref-idc-zero and mixed non-IDR VCL headers",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 1, 0xe5], codec: .h264, format: .lengthPrefixed(4))
          && !VortXVideoIDRClassifier.isIDR(
              bytes: [0, 0, 0, 1, 0x05], codec: .h264, format: .lengthPrefixed(4))
          && !VortXVideoIDRClassifier.isIDR(
              bytes: [0, 0, 0, 1, 0x61, 0, 0, 0, 1, 0x65],
              codec: .h264, format: .lengthPrefixed(4)))

check("segments: segment zero must begin on an IDR",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: false, incomingIsIDR: false, incomingHasKeyFlag: true,
          elapsed: 0) == .failSoft)
check("segments: segment zero rejects an IDR whose demux key flag disagrees",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: false, incomingIsIDR: true, incomingHasKeyFlag: false,
          elapsed: 0) == .failSoft)
check("segments: an IDR with matching key evidence opens segment zero",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: false, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 0) == .open)
check("segments: a target-age IDR with matching key evidence cuts before itself",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 1) == .cut)
check("segments: either IDR/key disagreement extends below the frozen target",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: false,
          elapsed: 1) == .continueOpen
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: true,
              elapsed: 1) == .continueOpen)
check("segments: a non-IDR at exactly twelve seconds remains legal",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false,
          elapsed: 12) == .continueOpen)
check("segments: the first positive delta beyond twelve seconds fails soft",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false,
          elapsed: 12.000_001) == .failSoft)
check("segments: a both-confirmed key at exactly twelve seconds remains a legal cut",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 12) == .cut)
check("segments: an eight-second GOP remains legal independent of aggregate byte size",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false,
          elapsed: 8) == .continueOpen)
check("segments: malformed timing fails soft",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: .nan) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: -0.1) == .failSoft)
check("segments: invalid normal and frozen target inputs fail soft",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 1, targetSeconds: 0) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: 1, targetSeconds: 2, frozenTargetSeconds: 1) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: 1, frozenTargetSeconds: 999) == .failSoft)

let targetFallback = VortXHLSTargetPolicy.freeze(indexEvidence: nil)
let incompleteTarget = VortXHLSTargetPolicy.freeze(indexEvidence: .init(
    completeness: .incomplete, adjacentIntervalsSeconds: [.nan, -1, 99]))
let emptyTarget = VortXHLSTargetPolicy.freeze(indexEvidence: .init(
    completeness: .validatedComplete, adjacentIntervalsSeconds: []))
check("target authority: absent, incomplete and empty evidence freeze conservative twelve",
      targetFallback == .init(seconds: 12, authority: .conservativeFallback)
          && VortXHLSTargetPolicy.conservativeTarget == targetFallback
          && incompleteTarget == targetFallback
          && emptyTarget == targetFallback)
check("target authority: validated complete intervals ceil their maximum with a five-second floor",
      VortXHLSTargetPolicy.freeze(indexEvidence: .init(
          completeness: .validatedComplete,
          adjacentIntervalsSeconds: [4, 4.9])) == .init(
              seconds: 5, authority: .validatedCompleteIndex)
          && VortXHLSTargetPolicy.freeze(indexEvidence: .init(
              completeness: .validatedComplete,
              adjacentIntervalsSeconds: [5, 7.2])) == .init(
                  seconds: 8, authority: .validatedCompleteIndex))
check("target authority: exact twelve is valid while malformed or over-twelve complete evidence rejects",
      VortXHLSTargetPolicy.freeze(indexEvidence: .init(
          completeness: .validatedComplete,
          adjacentIntervalsSeconds: [12])) == .init(
              seconds: 12, authority: .validatedCompleteIndex)
          && VortXHLSTargetPolicy.freeze(indexEvidence: .init(
              completeness: .validatedComplete,
              adjacentIntervalsSeconds: [.nan])) == nil
          && VortXHLSTargetPolicy.freeze(indexEvidence: .init(
              completeness: .validatedComplete,
              adjacentIntervalsSeconds: [0])) == nil
          && VortXHLSTargetPolicy.freeze(indexEvidence: .init(
              completeness: .validatedComplete,
              adjacentIntervalsSeconds: [12.000_001])) == nil)
let targetSevenReadiness = VortXHLSStartupReadiness(
    frozenTarget: .init(seconds: 7, authority: .validatedCompleteIndex))
// The startup floor is a flat one-decodable-segment / six-second budget, decoupled from the frozen target: the
// 6-segment / 3x-target floor (36s at the conservative target) held every UHD master past the chrome's 10s
// start watchdog and inflated the live window into the then-smaller session spool ceiling - the build 189
// field regression, twice over.
check("startup readiness: one independently decodable segment and six seconds are one immutable contract",
      targetSevenReadiness == .init(
          frozenTarget: .init(seconds: 7, authority: .validatedCompleteIndex),
          minimumSegmentCount: 1))
check("startup readiness: the startup floor is 6000 rendered milliseconds regardless of target",
      targetSevenReadiness?.minimumRenderedDurationMilliseconds == 6_000
          && VortXHLSStartupReadiness(
              frozenTarget: VortXHLSTargetPolicy.conservativeTarget)?
              .minimumRenderedDurationMilliseconds == 6_000)
// The forward buffer starts at AVPlayer's readiness window; the publication floor deliberately sits ABOVE it
// (readiness + 50%) so a startup cohort is never declined for want of a few milliseconds of media.
check("startup forward buffer: local remux starts at the readiness window the publication floor exceeds",
      VortXRemuxForwardBufferPolicy.preferredDuration(
          mount: .localRemux,
          hasProducedFirstFrame: false)
          == VortXRemuxForwardBufferPolicy.startupSeconds
          && Double(VortXHLSStartupReadiness.startupFloorMilliseconds) / 1_000
              > VortXRemuxForwardBufferPolicy.startupSeconds)
check("startup forward buffer: remote remux starts adaptive at zero",
      VortXRemuxForwardBufferPolicy.preferredDuration(
          mount: .remoteRemux,
          hasProducedFirstFrame: false) == 0)
check("startup forward buffer: local and remote restore thirty seconds after first frame",
      VortXRemuxForwardBufferPolicy.preferredDuration(
          mount: .localRemux,
          hasProducedFirstFrame: true) == 30
          && VortXRemuxForwardBufferPolicy.preferredDuration(
              mount: .remoteRemux,
              hasProducedFirstFrame: true) == 30)
check("startup forward buffer: direct playback retains its prior thirty-second memory cap",
      VortXRemuxForwardBufferPolicy.preferredDuration(
          mount: .direct,
          hasProducedFirstFrame: false) == 30)
check("startup waiting: only local and remote remux mounts minimize stalling automatically",
      VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
          mount: .localRemux)
          && VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
              mount: .remoteRemux)
          && !VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
              mount: .direct))
check("startup forward buffer: a memory warning never increases a positive duration",
      VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
          currentDuration: 4,
          mount: .localRemux,
          hasProducedFirstFrame: false) == nil
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 4,
              mount: .localRemux,
              hasProducedFirstFrame: true) == nil)
check("startup forward buffer: memory pressure lowers oversized and system-selected buffers to the phase cap",
      VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
          currentDuration: 30,
          mount: .localRemux,
          hasProducedFirstFrame: false) == 4
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 0,
              mount: .localRemux,
              hasProducedFirstFrame: false) == 4
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 0,
              mount: .direct,
              hasProducedFirstFrame: false) == 30
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 0,
              mount: .remoteRemux,
              hasProducedFirstFrame: false) == 4
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 2,
              mount: .remoteRemux,
              hasProducedFirstFrame: false) == nil
          && VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
              currentDuration: 30,
              mount: .remoteRemux,
              hasProducedFirstFrame: false) == 4)
checkStartupProductionWiring()
check("startup readiness: an unconsumed playlist exposes at most two startup segments",
      targetSevenReadiness?.maximumUnconsumedSegmentCount == 2
          && VortXHLSStartupReadiness(
              frozenTarget: VortXHLSTargetPolicy.conservativeTarget,
              minimumSegmentCount: 3)?.maximumUnconsumedSegmentCount == 3)

let retentionMiB = 1024 * 1024
check("consumption retention: two windows, operational reserve and safety headroom exactly fill the cap",
      VortXHLSConsumptionWindowPolicy.ordinarySessionCapacityBytes
          == 2 * VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes
              + VortXHLSConsumptionWindowPolicy.operationalReserveBytes
              + VortXHLSConsumptionWindowPolicy.safetyHeadroomBytes
          && VortXHLSConsumptionWindowPolicy.ordinarySessionCapacityBytes == 1024 * retentionMiB
          && VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes == 352 * retentionMiB
          && VortXHLSConsumptionWindowPolicy.operationalReserveBytes == 256 * retentionMiB
          && VortXHLSConsumptionWindowPolicy.safetyHeadroomBytes == 64 * retentionMiB)
check("consumption retention: publication grace fits inside the producer backpressure deadline",
      VortXHLSConsumptionWindowPolicy.keepBehindSeconds == 150
          && VortXHLSBackpressureWaitState.stallLimitSeconds == 180
          && VortXRemuxBuffer.stageBackpressureStallSeconds == 180)

// Exact byte-length receipts from the Build 202 second mount (`vortx-diag 16.log:1383-1600`). Fixed legal
// durations keep the independent 150-second time bound nonbinding so this fixture isolates the byte-floor proof.
let fieldSegmentSizes = [
    184_742, 1_047_150, 2_518_442, 2_836_990, 3_635_875, 3_146_346, 7_858_815, 15_571_013,
    11_132_000, 8_060_199, 5_212_663, 3_992_461, 3_206_638, 3_403_501, 9_444_427, 11_712_910,
    13_767_207, 10_340_394, 10_172_693, 11_311_393, 7_871_884, 2_528_177, 1_833_215, 415_326,
    9_328_517, 9_084_461, 13_742_935, 11_680_604, 9_974_965, 10_356_184, 10_781_201, 11_078_838,
    9_079_871, 9_759_553, 10_724_147, 10_480_971, 11_492_612, 11_624_650, 11_947_753, 9_125_284,
    8_333_610, 9_099_184, 8_131_207, 13_055_562, 11_200_147, 10_545_344, 9_139_909, 10_998_145,
    11_060_180, 11_411_404, 11_540_188, 12_052_489, 12_702_882, 11_719_529, 11_535_133,
    11_517_230, 11_496_886, 10_924_036,
]
var fieldByteOffset = 0
let fieldWindow = VortXHLSWindow(segments: fieldSegmentSizes.enumerated().map { id, byteLength in
    defer { fieldByteOffset += byteLength }
    return VortXHLSSegment(
        id: id,
        byteOffset: fieldByteOffset,
        byteLength: byteLength,
        start: Double(id) * 1.25,
        duration: 1.25)
})
let fieldFloor = VortXHLSConsumptionWindowPolicy.floor(frontier: 57, window: fieldWindow)
let fieldRetained = fieldWindow.segments.filter { $0.id >= fieldFloor }
check("consumption retention: the 58-segment field shape slides before the ordinary cap",
      fieldFloor == 22
          && fieldRetained.count == 36
          && fieldRetained.reduce(0) { $0 + $1.byteLength } == 368_974_152
          && fieldWindow.segments.reduce(0) { $0 + $1.byteLength } == 517_930_072
          && fieldWindow.segments.reduce(0) { $0 + $1.byteLength }
              < VortXHLSConsumptionWindowPolicy.ordinarySessionCapacityBytes)
check("consumption retention: the field-shaped slide still keeps useful rewind history",
      fieldRetained.reduce(0.0) { $0 + $1.duration } == 45)
check("playhead mapping: exact segment boundaries map to the displayed segment",
      VortXHLSConsumptionWindowPolicy.segmentID(
        atPlaybackSeconds: 25,
        window: fieldWindow) == 20
          && VortXHLSConsumptionWindowPolicy.segmentID(
            atPlaybackSeconds: 26.249,
            window: fieldWindow) == 20
          && VortXHLSConsumptionWindowPolicy.segmentID(
            atPlaybackSeconds: 26.25,
            window: fieldWindow) == 21)
check("playhead mapping: invalid clocks and gaps never authorize eviction",
      VortXHLSConsumptionWindowPolicy.segmentID(
        atPlaybackSeconds: -.infinity,
        window: fieldWindow) == nil
          && VortXHLSConsumptionWindowPolicy.segmentID(
            atPlaybackSeconds: .nan,
            window: fieldWindow) == nil
          && VortXHLSConsumptionWindowPolicy.segmentID(
            atPlaybackSeconds: -1,
            window: fieldWindow) == nil)

let requestAheadOfPlayhead = 57
let actualPlaybackSegment = 12
let requestAnchoredStart = VortXHLSConsumptionWindowPolicy.publicationStartID(
    currentStartID: fieldWindow.mediaSequence,
    suffixStartID: requestAheadOfPlayhead,
    playbackSegmentID: requestAheadOfPlayhead,
    window: fieldWindow)
let playheadAnchoredStart = VortXHLSConsumptionWindowPolicy.publicationStartID(
    currentStartID: fieldWindow.mediaSequence,
    suffixStartID: requestAheadOfPlayhead,
    playbackSegmentID: actualPlaybackSegment,
    window: fieldWindow)
check("played frontier: twenty-segment fetch-ahead cannot evict the displayed segment",
      requestAnchoredStart > actualPlaybackSegment
          && playheadAnchoredStart <= actualPlaybackSegment)
check("played frontier: no playhead receipt keeps the original sequence pinned",
      VortXHLSConsumptionWindowPolicy.publicationStartID(
        currentStartID: fieldWindow.mediaSequence,
        suffixStartID: requestAheadOfPlayhead,
        playbackSegmentID: nil,
        window: fieldWindow) == fieldWindow.mediaSequence)
// 50 and 57 (not 12/37): after the section-6 two-pool fix, the behind-frontier byte cap on THIS field shape
// (`fieldSegmentSizes`) only starts to bind once the behind-only prefix itself exceeds 352 MiB, which first
// happens crossing index 44. 12/37 both left the cap unbound now that ahead-of-frontier volume no longer
// counts toward it, so both floors were 0 and the strict `<` below no longer discriminated anything - 50 and
// 57 keep this a real test of "a later frontier's OWN behind-frontier volume trips the cap further out," not
// an artifact of the old ahead-of-frontier crowding bug.
check("played frontier: a backward seek moves eviction authority backward",
      VortXHLSConsumptionWindowPolicy.publicationStartID(
        currentStartID: fieldWindow.mediaSequence,
        suffixStartID: requestAheadOfPlayhead,
        playbackSegmentID: 50,
        window: fieldWindow)
          < VortXHLSConsumptionWindowPolicy.publicationStartID(
            currentStartID: fieldWindow.mediaSequence,
            suffixStartID: requestAheadOfPlayhead,
            playbackSegmentID: 57,
            window: fieldWindow))

let fieldSegmentBytes = 8 * retentionMiB
let producedAheadWindow = VortXHLSWindow(segments: (0..<80).map {
    VortXHLSSegment(
        id: $0,
        byteOffset: $0 * fieldSegmentBytes,
        byteLength: fieldSegmentBytes,
        start: Double($0) * 1.25,
        duration: 1.25)
})
let producedAheadFloor = VortXHLSConsumptionWindowPolicy.floor(
    frontier: 59,
    window: producedAheadWindow)
// Root-cause report section 6: before the two-pool fix, the 20 segments AHEAD of frontier 59 (ids 60-79, 160
// MiB) were folded into `retainedBytes` FIRST (the reversed walk visits the highest IDs first), so only
// 352-160=192 MiB (24 segments) of BEHIND-frontier budget was left, giving floor=36 and exactly 55 seconds
// less rewind history than this fixture's segment shape can actually afford. The fix reserves the full 352
// MiB for behind-frontier retention regardless of how much lies ahead: 352 MiB / 8 MiB = exactly 44
// behind-frontier segments (ids 16-59, 55s of rewind - well under the independent 150s cap, so the byte cap is
// what binds here), giving floor=16. A regression to the old shared-pool behavior would move this back to 36
// and shrink `behindFrontierBytes` below the full retention budget, so this assertion catches that mutation.
let producedAheadRetained = producedAheadWindow.segments.filter { $0.id >= producedAheadFloor }
let producedAheadBehindFrontier = producedAheadRetained.filter { $0.id <= 59 }
let producedAheadAheadOfFrontier = producedAheadRetained.filter { $0.id > 59 }
check("consumption retention: produced-ahead bytes no longer crowd out the behind-frontier rewind budget",
      producedAheadFloor == 16
          && producedAheadBehindFrontier.count == 44
          && producedAheadBehindFrontier.reduce(0) { $0 + $1.byteLength }
              == VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes
          && producedAheadBehindFrontier.reduce(0.0) { $0 + $1.duration } == 55)
check("consumption retention: every produced-ahead segment stays published regardless of its own volume",
      producedAheadAheadOfFrontier.count == 20
          && producedAheadAheadOfFrontier.map(\.id) == Array(60..<80))
check("consumption retention: the retained window can legitimately exceed W once ahead/behind are independent",
      producedAheadRetained.reduce(0) { $0 + $1.byteLength }
          > VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes)

let longPlaylistWindow = VortXHLSWindow(segments: (0..<26).map {
    VortXHLSSegment(
        id: $0,
        byteOffset: $0,
        byteLength: 1,
        start: Double($0) * 12,
        duration: 12)
})
let longPlaylistFloor = VortXHLSConsumptionWindowPolicy.floor(
    frontier: 20,
    window: longPlaylistWindow)
let longPlaylist = longPlaylistWindow.segments.filter { $0.id >= longPlaylistFloor }
check("backpressure: produced-ahead media makes the legal playlist grace exceed 180 seconds",
      longPlaylistFloor == 9
          && longPlaylist.count == 17
          && longPlaylist.reduce(0.0) { $0 + $1.duration } == 204)
var longPlaylistWait = VortXHLSBackpressureWaitState(
    now: 0,
    progress: .init(
        physicalBytes: 26,
        frontierGeneration: 1,
        latestRetentionDeadline: 216))
check("backpressure: actual armed retention prevents failure at the static 180-second edge",
      !longPlaylistWait.shouldFail(
          now: 180,
          progress: .init(
              physicalBytes: 26,
              frontierGeneration: 1,
              latestRetentionDeadline: 216)))
check("backpressure: a resource remains protected at its exact 216-second deadline",
      !longPlaylistWait.shouldFail(
          now: 216,
          progress: .init(
              physicalBytes: 26,
              frontierGeneration: 1,
              latestRetentionDeadline: 216)))
var expiredLongPlaylistWait = VortXHLSBackpressureWaitState(
    now: 0,
    progress: .init(
        physicalBytes: 26,
        frontierGeneration: 1,
        latestRetentionDeadline: 216))
check("backpressure: no progress fails immediately after both the 180-second stall edge and legal retention deadline",
      expiredLongPlaylistWait.shouldFail(
          now: 216.001,
          progress: .init(
              physicalBytes: 26,
              frontierGeneration: 1,
              latestRetentionDeadline: 216)))
check("backpressure: reclamation progress resets the monotonic stall clock",
      !longPlaylistWait.shouldFail(
          now: 216.001,
          progress: .init(
              physicalBytes: 25,
              frontierGeneration: 1,
              latestRetentionDeadline: nil))
          && longPlaylistWait.stalledSince == 216.001)
var frontierOnlyWait = VortXHLSBackpressureWaitState(
    now: 0,
    progress: .init(
        physicalBytes: 26,
        frontierGeneration: 1,
        latestRetentionDeadline: 216))
check("backpressure: frontier-only progress resets the stall clock with unchanged physical bytes",
      !frontierOnlyWait.shouldFail(
          now: 216.001,
          progress: .init(
              physicalBytes: 26,
              frontierGeneration: 2,
              latestRetentionDeadline: 216))
          && frontierOnlyWait.stalledSince == 216.001
          && !frontierOnlyWait.shouldFail(
              now: 396.001,
              progress: .init(
                  physicalBytes: 26,
                  frontierGeneration: 2,
                  latestRetentionDeadline: 216))
          && frontierOnlyWait.shouldFail(
              now: 396.002,
              progress: .init(
                  physicalBytes: 26,
                  frontierGeneration: 2,
                  latestRetentionDeadline: 216)))

let producerAheadAtStart = VortXHLSWindow(segments: (0..<8).map {
    VortXHLSSegment(
        id: $0,
        byteOffset: $0 * 100,
        byteLength: 100,
        start: Double($0) * 4,
        duration: 4)
})
check("startup readiness: the executable unconsumed window keeps the first two absolute segments",
      targetSevenReadiness?.unconsumedStartupWindow(
          producerAheadAtStart,
          startupCohortCount: 0
      )
          .segments.map(\.id) == [0, 1])
let alreadySmallStart = VortXHLSWindow(segments: Array(producerAheadAtStart.segments.prefix(1)))
check("startup readiness: an already-small unconsumed window is byte-range identical",
      targetSevenReadiness?.unconsumedStartupWindow(
          alreadySmallStart,
          startupCohortCount: 0
      ) == alreadySmallStart)
let shortFragmentStart = VortXHLSWindow(segments: (0..<8).map {
    VortXHLSSegment(
        id: $0,
        byteOffset: $0 * 100,
        byteLength: 100,
        start: Double($0) * 1.2,
        duration: 1.2)
})
check("startup readiness: the unconsumed cap carries one produced successor beyond a four-segment cohort",
      targetSevenReadiness?.unconsumedStartupWindow(
          shortFragmentStart,
          startupCohortCount: 4
      ).segments.map(\.id) == [0, 1, 2, 3, 4])
let fieldStartupWindow = VortXHLSWindow(segments: [
    VortXHLSSegment(id: 0, byteOffset: 0, byteLength: 100, start: 0, duration: 1.63),
    VortXHLSSegment(id: 1, byteOffset: 100, byteLength: 100, start: 1.63, duration: 1.75),
    VortXHLSSegment(id: 2, byteOffset: 200, byteLength: 100, start: 3.38, duration: 1.25),
    VortXHLSSegment(id: 3, byteOffset: 300, byteLength: 100, start: 4.63, duration: 1.25),
    VortXHLSSegment(id: 4, byteOffset: 400, byteLength: 100, start: 5.88, duration: 1.25),
    VortXHLSSegment(id: 5, byteOffset: 500, byteLength: 100, start: 7.13, duration: 1.25),
])
let fieldStartupFirstFour = VortXHLSWindow(
    segments: Array(fieldStartupWindow.segments.prefix(4)))
let fieldStartupFirstFive = VortXHLSWindow(
    segments: Array(fieldStartupWindow.segments.prefix(5)))
let fieldStartupFirstFourCohort = DVPlaybackPolicy.pinnedStartupCohort(
    windows: [fieldStartupFirstFour],
    ended: false,
    minimumSegmentCount: targetSevenReadiness?.minimumSegmentCount ?? 0,
    minimumRenderedDurationMilliseconds:
        targetSevenReadiness?.minimumRenderedDurationMilliseconds ?? 0)
check("startup readiness: the first four field segments total 5880ms and do not form a non-ended cohort",
      DVPlaybackPolicy.renderedDurationMilliseconds(of: fieldStartupFirstFour) == 5_880
          && fieldStartupFirstFourCohort == nil)
let fieldStartupCohort = DVPlaybackPolicy.pinnedStartupCohort(
    windows: [fieldStartupWindow],
    ended: false,
    minimumSegmentCount: targetSevenReadiness?.minimumSegmentCount ?? 0,
    minimumRenderedDurationMilliseconds:
        targetSevenReadiness?.minimumRenderedDurationMilliseconds ?? 0)
check("startup readiness: the first five field segments total 7130ms and freeze the shortest five-segment cohort",
      DVPlaybackPolicy.renderedDurationMilliseconds(of: fieldStartupFirstFive) == 7_130
          && fieldStartupCohort?.window.segments.map(\.id) == [0, 1, 2, 3, 4])
check("startup readiness: the first field-shaped body includes segment five as growth evidence",
      targetSevenReadiness?.unconsumedStartupWindow(
          fieldStartupWindow,
          startupCohortCount: fieldStartupCohort?.window.segments.count ?? 0
      ).segments.map(\.id) == [0, 1, 2, 3, 4, 5])
check("startup readiness: a successor that is not produced yet is never invented",
      targetSevenReadiness?.unconsumedStartupWindow(
          fieldStartupFirstFive,
          startupCohortCount: 5
      ).segments.map(\.id) == [0, 1, 2, 3, 4])
check("startup readiness: invalid target bounds and segment counts are rejected without a force unwrap",
      VortXHLSStartupReadiness(
          frozenTarget: .init(seconds: 4, authority: .validatedCompleteIndex)) == nil
          && VortXHLSStartupReadiness(
              frozenTarget: .init(seconds: 13, authority: .conservativeFallback)) == nil
          && VortXHLSStartupReadiness(
              frozenTarget: VortXHLSTargetPolicy.conservativeTarget,
              minimumSegmentCount: 0) == nil)

check("early display intent: only a fully described clean DV stream-copy source may overlap panel setup",
      DVPlaybackPolicy.canPublishEarlyDisplayIntent(
          requiresDolbyVision: true,
          dolbyVisionProfile: 8,
          width: 3840,
          height: 2160,
          frameRate: 23.976,
          hasBaseVideo: true,
          hvc1ExtradataReady: true,
          hasStreamCopyAudio: true))
for rejected in [
    DVPlaybackPolicy.canPublishEarlyDisplayIntent(
        requiresDolbyVision: false, dolbyVisionProfile: 8, width: 3840, height: 2160,
        frameRate: 23.976, hasBaseVideo: true, hvc1ExtradataReady: true, hasStreamCopyAudio: true),
    DVPlaybackPolicy.canPublishEarlyDisplayIntent(
        requiresDolbyVision: true, dolbyVisionProfile: -1, width: 3840, height: 2160,
        frameRate: 23.976, hasBaseVideo: true, hvc1ExtradataReady: true, hasStreamCopyAudio: true),
    DVPlaybackPolicy.canPublishEarlyDisplayIntent(
        requiresDolbyVision: true, dolbyVisionProfile: 8, width: 3840, height: 2160,
        frameRate: 23.976, hasBaseVideo: true, hvc1ExtradataReady: false, hasStreamCopyAudio: true),
    DVPlaybackPolicy.canPublishEarlyDisplayIntent(
        requiresDolbyVision: true, dolbyVisionProfile: 8, width: 3840, height: 2160,
        frameRate: 23.976, hasBaseVideo: true, hvc1ExtradataReady: true, hasStreamCopyAudio: false),
    DVPlaybackPolicy.canPublishEarlyDisplayIntent(
        requiresDolbyVision: true, dolbyVisionProfile: 8, width: 3840, height: 2160,
        frameRate: 0, hasBaseVideo: true, hvc1ExtradataReady: true, hasStreamCopyAudio: true),
] {
    check("early display intent: incomplete or speculative source evidence fails closed", !rejected)
}

var sequentialDeadline = VortXHLSMountDeadlineState()
check("mount deadline: start at monotonic 100 freezes one absolute edge at 130",
      sequentialDeadline.start(now: 100) == 130)
check("mount deadline: a later stage receives nineteen remaining seconds, never a fresh thirty",
      sequentialDeadline.remaining(now: 111) == (19, false))
check("mount deadline: a stage at 129.999 receives only the final millisecond",
      abs(sequentialDeadline.remaining(now: 129.999).seconds - 0.001) < 0.000_001)
let readyBeforeExpiry = sequentialDeadline.markReady(now: 129.999_9)
check("mount deadline: ready just before expiry wins and stays terminal",
      readyBeforeExpiry == (true, false)
          && sequentialDeadline.remaining(now: 131).seconds == .infinity)
var expiredDeadline = VortXHLSMountDeadlineState()
_ = expiredDeadline.start(now: 100)
let exactExpiry = expiredDeadline.remaining(now: 130)
let repeatedExpiry = expiredDeadline.remaining(now: 131)
check("mount deadline: exact expiry owns one transition and later polls cannot fire it again",
      exactExpiry == (0, true) && repeatedExpiry == (0, false))
check("mount deadline: ready after expiry is inert",
      expiredDeadline.markReady(now: 131) == (false, false))
var crossingProbeDeadline = VortXHLSMountDeadlineState()
_ = crossingProbeDeadline.start(now: 0)
let crossingProbeHadBudget = crossingProbeDeadline.remaining(now: 29.999).seconds > 0
let crossingProbeResult = crossingProbeDeadline.gateSuccessfulProbe(
    "master", completedAt: 30, invalidated: false)
check("mount deadline: a probe that starts in budget but completes at the edge is rejected once",
      crossingProbeHadBudget
          && crossingProbeResult.value == nil
          && crossingProbeResult.didExpire
          && crossingProbeDeadline.phase == .timedOut)
let repeatedCrossingProbe = crossingProbeDeadline.gateSuccessfulProbe(
    "master", completedAt: 30.001, invalidated: false)
let crossingProbeTimeoutCount = [crossingProbeResult, repeatedCrossingProbe]
    .filter { $0.didExpire }.count
check("mount deadline: a repeated late probe cannot emit a second expiry and readiness stays rejected",
      repeatedCrossingProbe.value == nil
          && !repeatedCrossingProbe.didExpire
          && crossingProbeTimeoutCount == 1
          && crossingProbeDeadline.markReady(now: 30.002) == (false, false))
var readyProbeDeadline = VortXHLSMountDeadlineState()
_ = readyProbeDeadline.start(now: 0)
_ = readyProbeDeadline.markReady(now: 29.999)
check("mount deadline: ready state keeps later master probes valid unless the server is invalidated",
      readyProbeDeadline.gateSuccessfulProbe(
          "reload", completedAt: 60, invalidated: false).value == "reload"
          && readyProbeDeadline.gateSuccessfulProbe(
              "reload", completedAt: 60, invalidated: true).value == nil)

var abortedInit = VortXHLSInitPublicationState()
abortedInit.abort(reason: "malformed moov")
check("init: abort terminates scanning without pretending the init was published",
      abortedInit.scanTerminated && !abortedInit.initPublished)
check("init: an aborted scan can never reopen media cuts or spooling",
      !abortedInit.mayPublishMedia && abortedInit.failureReason == "malformed moov")
var publishedInit = VortXHLSInitPublicationState()
publishedInit.publish()
check("init: successful publication independently terminates scanning and opens media publication",
      publishedInit.scanTerminated && publishedInit.initPublished && publishedInit.mayPublishMedia)

let pendingBoundaries = VortXHLSPendingPublicationMachine<String?>()
check("pending boundary: first both-confirmed key is retained while init is delayed",
      pendingBoundaries.append(
          segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
          && pendingBoundaries.count == 1
          && pendingBoundaries.first?.segmentID == 0
          && pendingBoundaries.first?.endSeconds == 3)
var delayedInitDrainCalls = 0
var delayedInitPublishCalls = 0
let delayedInitResult = pendingBoundaries.advance(
    initMayPublishMedia: { false },
    proveNextFragment: { 7 },
    performPostInitDrain: {
        delayedInitDrainCalls += 1
        return true
    },
    publish: { _, _ in
        delayedInitPublishCalls += 1
        return true
    })
check("pending boundary: delayed init cannot force publication or an interleave drain",
      delayedInitResult == .waitingForInit
          && delayedInitDrainCalls == 0
          && delayedInitPublishCalls == 0
          && pendingBoundaries.first?.segmentID == 0)
check("pending boundary: newest tail at exactly twelve remains legal while a pending prefix exists",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true,
          incomingIsIDR: false,
          incomingHasKeyFlag: false,
          elapsed: 12) == .continueOpen)
check("pending boundary: newest tail beyond twelve fails and cannot be hidden by an older prefix",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true,
          incomingIsIDR: false,
          incomingHasKeyFlag: false,
          elapsed: 12.000_001) == .failSoft)
check("pending boundary: key six appends behind key three instead of replacing it",
      pendingBoundaries.append(
          segmentID: 1, startSeconds: 3, endSeconds: 6, payload: nil)
          && pendingBoundaries.count == 2
          && pendingBoundaries.first?.segmentID == 0
          && pendingBoundaries.logicalSegmentStartSeconds == 6)
check("pending boundary: late alternate audio stays paired with its exact video ID",
      pendingBoundaries.attachPayload("audio-0", toSegmentID: 0)
          && pendingBoundaries.first?.payload == "audio-0")
check("pending boundary: an unmatched alternate-audio ID is rejected without replacing the FIFO head",
      !pendingBoundaries.attachPayload("wrong-audio", toSegmentID: 7)
          && pendingBoundaries.first?.payload == "audio-0")
var incompletePublishCalls = 0
var incompleteDrainCalls = 0
let incompleteResult = pendingBoundaries.advance(
    initMayPublishMedia: { true },
    allowPostInitDrain: false,
    proveNextFragment: { nil as Int? },
    performPostInitDrain: {
        incompleteDrainCalls += 1
        return true
    },
    publish: { _, _ in
        incompletePublishCalls += 1
        return true
    })
check("pending boundary: parser-incomplete media cannot publish or advance the FIFO",
      incompleteResult == .waitingForFragment
          && incompletePublishCalls == 0
          && incompleteDrainCalls == 0
          && pendingBoundaries.first?.segmentID == 0)
var firstReadyBoundaryID: Int?
var firstReadyBoundaryPayload: String?
var oneProofAvailable = true
let firstReadyResult = pendingBoundaries.advance(
    initMayPublishMedia: { true },
    allowPostInitDrain: false,
    proveNextFragment: {
        guard oneProofAvailable else { return nil as Int? }
        oneProofAvailable = false
        return 42
    },
    performPostInitDrain: { false },
    publish: { boundary, _ in
        firstReadyBoundaryID = boundary.segmentID
        firstReadyBoundaryPayload = boundary.payload
        return true
    })
check("pending boundary: parser proof consumes only the FIFO head",
      firstReadyResult == .waitingForFragment
          && firstReadyBoundaryID == 0
          && firstReadyBoundaryPayload == "audio-0"
          && pendingBoundaries.count == 1
          && pendingBoundaries.first?.segmentID == 1)

let progressBeforeDrain = VortXHLSPendingPublicationMachine<String?>()
_ = progressBeforeDrain.append(
    segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
_ = progressBeforeDrain.append(
    segmentID: 1, startSeconds: 3, endSeconds: 6, payload: nil)
var preDrainProofAvailable = true
var preDrainCalls = 0
var preDrainPublishedIDs: [Int] = []
let progressBeforeDrainResult = progressBeforeDrain.advance(
    initMayPublishMedia: { true },
    proveNextFragment: {
        guard preDrainProofAvailable else { return nil as Int? }
        preDrainProofAvailable = false
        return 42
    },
    performPostInitDrain: {
        preDrainCalls += 1
        return true
    },
    publish: { boundary, _ in
        preDrainPublishedIDs.append(boundary.segmentID)
        return true
    })
check("pending boundary: a complete head before the one drain lets its partial successor keep waiting",
      progressBeforeDrainResult == .waitingForFragment
          && preDrainCalls == 1
          && preDrainPublishedIDs == [0]
          && progressBeforeDrain.count == 1
          && progressBeforeDrain.first?.segmentID == 1)

let terminalAfterProgress = VortXHLSPendingPublicationMachine<String?>()
_ = terminalAfterProgress.append(
    segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
_ = terminalAfterProgress.append(
    segmentID: 1, startSeconds: 3, endSeconds: 6, payload: nil)
var terminalProofAvailable = true
var terminalDrainCalls = 0
var terminalPublishedIDs: [Int] = []
let terminalAfterProgressResult = terminalAfterProgress.advance(
    initMayPublishMedia: { true },
    allowPostInitDrain: false,
    incompleteIsTerminal: true,
    proveNextFragment: {
        guard terminalProofAvailable else { return nil as Int? }
        terminalProofAvailable = false
        return 42
    },
    performPostInitDrain: {
        terminalDrainCalls += 1
        return true
    },
    publish: { boundary, _ in
        terminalPublishedIDs.append(boundary.segmentID)
        return true
    })
check("pending boundary: EOF stays terminal after publishing a complete head before a partial successor",
      terminalAfterProgressResult == .failed(.incompleteAtEnd)
          && terminalDrainCalls == 0
          && terminalPublishedIDs == [0]
          && terminalAfterProgress.count == 1
          && terminalAfterProgress.first?.segmentID == 1)

let noProgressAfterDrain = VortXHLSPendingPublicationMachine<String?>()
_ = noProgressAfterDrain.append(
    segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
var noProgressDrainCalls = 0
var noProgressPublishCalls = 0
let noProgressResult = noProgressAfterDrain.advance(
    initMayPublishMedia: { true },
    proveNextFragment: { nil as Int? },
    performPostInitDrain: {
        noProgressDrainCalls += 1
        return true
    },
    publish: { _, _ in
        noProgressPublishCalls += 1
        return true
    })
check("pending boundary: a successful drain with no parser proof remains fail-closed",
      noProgressResult == .failed(.incompleteAfterDrain)
          && noProgressDrainCalls == 1
          && noProgressPublishCalls == 0
          && noProgressAfterDrain.first?.segmentID == 0)

let progressAfterDrain = VortXHLSPendingPublicationMachine<String?>()
_ = progressAfterDrain.append(
    segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
_ = progressAfterDrain.append(
    segmentID: 1, startSeconds: 3, endSeconds: 6, payload: nil)
var progressDrainCompleted = false
var progressProofsRemaining = 1
var progressPublishedIDs: [Int] = []
let progressResult = progressAfterDrain.advance(
    initMayPublishMedia: { true },
    proveNextFragment: {
        guard progressDrainCompleted, progressProofsRemaining > 0 else { return nil as Int? }
        progressProofsRemaining -= 1
        return 42
    },
    performPostInitDrain: {
        progressDrainCompleted = true
        return true
    },
    publish: { boundary, _ in
        progressPublishedIDs.append(boundary.segmentID)
        return true
    })
check("pending boundary: drain progress publishes one head and retains an incomplete successor",
      progressResult == .waitingForFragment
          && progressPublishedIDs == [0]
          && progressAfterDrain.count == 1
          && progressAfterDrain.first?.segmentID == 1)

// MARK: - Flag-off master artifact identity

let plainMasterInput = DVPlaybackPolicy.MasterPlaylistInput(
    videoCodec: "hvc1.2.4.L153.B0",
    supplementalCodec: nil,
    videoRange: nil,
    audioCodec: "ec-3",
    width: 1920,
    height: 1080,
    bandwidth: 5_000_000,
    fps: 23.976,
    dolbyVision: false)
let plainFlagOffArtifact = Data("""
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L153.B0,ec-3",FRAME-RATE=23.976
media.m3u8

""".utf8)
check("artifact: plain flag-off master is byte-identical to the pre-feature body",
      DVPlaybackPolicy.masterPlaylistData(
        input: plainMasterInput, mediaTags: [], streamInfAttributes: "") == plainFlagOffArtifact)

let dvMasterInput = DVPlaybackPolicy.MasterPlaylistInput(
    videoCodec: "hvc1.2.4.L153.B0",
    supplementalCodec: "dvh1.08.06/db1p",
    videoRange: "PQ",
    audioCodec: "ec-3",
    width: 3840,
    height: 2160,
    bandwidth: 20_000_000,
    fps: 23.976,
    dolbyVision: true)
let dvFlagOffArtifact = Data("""
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,ec-3",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",VIDEO-RANGE=PQ,FRAME-RATE=23.976
media.m3u8

""".utf8)
check("artifact: DV master advertises exactly one DV video variant",
      DVPlaybackPolicy.masterPlaylistData(
        input: dvMasterInput, mediaTags: [], streamInfAttributes: "") == dvFlagOffArtifact)
let decorated = String(decoding: DVPlaybackPolicy.masterPlaylistData(
    input: dvMasterInput,
    mediaTags: [#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Primary""#],
    streamInfAttributes: #",AUDIO="audio",SUBTITLES="subs""#), as: UTF8.self)
check("artifact: optional tags precede the single video variant",
      decorated.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Primary\"\n#EXT-X-STREAM-INF")
        && decorated.components(separatedBy: #",AUDIO="audio",SUBTITLES="subs""#).count == 2
        && !decorated.contains("media-hdr.m3u8"))

let hdrRecoveryArtifact = Data("""
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,ec-3",VIDEO-RANGE=PQ,FRAME-RATE=23.976
media-hdr.m3u8

""".utf8)
check("artifact: Profile 8.1 recovery is a separate exact-PQ single-variant master",
      DVPlaybackPolicy.masterPlaylistData(
        input: dvMasterInput,
        mediaTags: [],
        streamInfAttributes: "",
        videoVariant: .hdrFallback) == hdrRecoveryArtifact)

let p84MasterInput = DVPlaybackPolicy.MasterPlaylistInput(
    videoCodec: "hvc1.2.4.L153.B0",
    supplementalCodec: "dvh1.08.06/db4h",
    videoRange: "HLG",
    audioCodec: "ec-3",
    width: 3840,
    height: 2160,
    bandwidth: 20_000_000,
    fps: 23.976,
    dolbyVision: true)
let p84RecoveryArtifact = Data("""
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,ec-3",VIDEO-RANGE=HLG,FRAME-RATE=23.976
media-hdr.m3u8

""".utf8)
check("artifact: Profile 8.4 recovery is a separate exact-HLG single-variant master",
      DVPlaybackPolicy.masterPlaylistData(
        input: p84MasterInput,
        mediaTags: [],
        streamInfAttributes: "",
        videoVariant: .hdrFallback) == p84RecoveryArtifact)

check("HDR recovery: exact healthy DV CoreMedia -12927 failure gets one explicit fallback",
      DVPlaybackPolicy.shouldAttemptHDRFallback(
        dolbyVision: true,
        remuxMounted: true,
        mountHealthy: true,
        fallbackAvailable: true,
        alreadyAttempted: false,
        errorDomain: "CoreMediaErrorDomain",
        errorCode: -12927))
check("HDR recovery: an already attempted fallback cannot loop",
      !DVPlaybackPolicy.shouldAttemptHDRFallback(
        dolbyVision: true,
        remuxMounted: true,
        mountHealthy: true,
        fallbackAvailable: true,
        alreadyAttempted: true,
        errorDomain: "CoreMediaErrorDomain",
        errorCode: -12927))
check("HDR recovery: Profile 5 or another no-base-layer source cannot claim HDR recovery",
      !DVPlaybackPolicy.shouldAttemptHDRFallback(
        dolbyVision: true,
        remuxMounted: true,
        mountHealthy: true,
        fallbackAvailable: false,
        alreadyAttempted: false,
        errorDomain: "CoreMediaErrorDomain",
        errorCode: -12927))
check("HDR recovery: unrelated failures keep their existing fail-soft path",
      !DVPlaybackPolicy.shouldAttemptHDRFallback(
        dolbyVision: true,
        remuxMounted: true,
        mountHealthy: true,
        fallbackAvailable: true,
        alreadyAttempted: false,
        errorDomain: "AVFoundationErrorDomain",
        errorCode: -11828))
check("HDR recovery: a pre-ready replacement may cross the mount ready edge itself",
      DVPlaybackPolicy.acceptsRemuxReady(
        transitionAccepted: true,
        mountAlreadyReady: true,
        recoveryItem: true))
check("HDR recovery: an already-ready mount may accept its replacement item",
      DVPlaybackPolicy.acceptsRemuxReady(
        transitionAccepted: false,
        mountAlreadyReady: true,
        recoveryItem: true))
check("HDR recovery: an expired pre-ready mount cannot look already ready",
      !DVPlaybackPolicy.acceptsRemuxReady(
        transitionAccepted: false,
        mountAlreadyReady: false,
        recoveryItem: true))
check("HDR recovery: an ordinary duplicate ready callback remains rejected",
      !DVPlaybackPolicy.acceptsRemuxReady(
        transitionAccepted: false,
        mountAlreadyReady: true,
        recoveryItem: false))
check("HDR recovery: local master URL rewrites only the terminal resource",
      DVPlaybackPolicy.hdrFallbackMasterURL(
        from: URL(string: "http://127.0.0.1:4321/master.m3u8")!)?.absoluteString
        == "http://127.0.0.1:4321/master-hdr.m3u8")
check("HDR recovery: hosted capability prefix and query survive the rewrite",
      DVPlaybackPolicy.hdrFallbackMasterURL(
        from: URL(string: "http://host:4321/r/capability/master.m3u8?session=one")!)?.absoluteString
        == "http://host:4321/r/capability/master-hdr.m3u8?session=one")
check("HDR recovery: a non-master URL cannot be rewritten into a claim",
      DVPlaybackPolicy.hdrFallbackMasterURL(
        from: URL(string: "http://host:4321/r/capability/media.m3u8")!) == nil)
check("HDR recovery: Profile 8.4 base layer requests HLG",
      DVPlaybackPolicy.hdrFallbackDisplayRange(videoRange: "HLG") == .hlg)
check("HDR recovery: PQ and unknown base layers request HDR10",
      DVPlaybackPolicy.hdrFallbackDisplayRange(videoRange: "PQ") == .hdr10
        && DVPlaybackPolicy.hdrFallbackDisplayRange(videoRange: nil) == .hdr10)
check("HDR recovery: capability stays closed before surgery settles",
      !DVPlaybackPolicy.supportsHDRFallback(
        dolbyVision: true,
        videoCodec: "hvc1.2.4.L153.B0",
        surgerySettled: false,
        recoveryInitAvailable: true))
check("HDR recovery: capability stays closed when surgery produced no init",
      !DVPlaybackPolicy.supportsHDRFallback(
        dolbyVision: true,
        videoCodec: "hvc1.2.4.L153.B0",
        surgerySettled: true,
        recoveryInitAvailable: false))
check("HDR recovery: Profile 5 stays closed even if impossible recovery bytes appear",
      !DVPlaybackPolicy.supportsHDRFallback(
        dolbyVision: true,
        videoCodec: "dvh1.05.06",
        surgerySettled: true,
        recoveryInitAvailable: true))
check("HDR recovery: compatible DV plus settled valid init opens the capability",
      DVPlaybackPolicy.supportsHDRFallback(
        dolbyVision: true,
        videoCodec: "hvc1.2.4.L153.B0",
        surgerySettled: true,
        recoveryInitAvailable: true))

var recoverySeek = DVPlaybackPolicy.HDRRecoverySeekState()
recoverySeek.stageReplacement(
    playerSeconds: 42,
    queuedUserSourceSeconds: nil)
check("HDR recovery seek: automatic retry restores the old player clock",
      recoverySeek.consume(sourceToPlayer: { $0 - 3_600 }) == 42
        && recoverySeek.automaticPlayerSeconds == nil
        && recoverySeek.userSourceSeconds == nil)
recoverySeek.stageReplacement(
    playerSeconds: 42,
    queuedUserSourceSeconds: 3_700)
check("HDR recovery seek: a pre-ready queued user intent atomically beats the automatic clock",
      recoverySeek.consume(sourceToPlayer: { $0 - 3_600 }) == 100
        && recoverySeek.automaticPlayerSeconds == nil
        && recoverySeek.userSourceSeconds == nil)
check("HDR recovery seek: consumed state cannot replay on a later callback",
      recoverySeek.consume(sourceToPlayer: { $0 }) == nil)
recoverySeek.stageReplacement(
    playerSeconds: 42,
    queuedUserSourceSeconds: nil)
check("HDR recovery failover: old player clock maps through the live origin before remount",
      recoverySeek.failoverSourceSeconds(
        currentSourceSeconds: 3_600,
        playerToSource: { 3_600 + $0 }) == 3_642)
recoverySeek.supersedeWithUser(sourceSeconds: 3_700)
check("HDR recovery failover: newest user source intent supersedes automatic restoration",
      recoverySeek.failoverSourceSeconds(
        currentSourceSeconds: 3_600,
        playerToSource: { 3_600 + $0 }) == 3_700)
check("host failover: a seek queued during capability refresh beats every staged clock",
      recoverySeek.failoverSourceSeconds(
        pendingUserSourceSeconds: 3_800,
        currentSourceSeconds: 3_600,
        playerToSource: { 3_600 + $0 }) == 3_800)

var recoverySelection = DVPlaybackPolicy.HDRRecoverySelectionState(
    audioSelectionKnown: true,
    audioIndex: 1,
    subtitleSelectionKnown: true,
    subtitleIndex: 2,
    externalSubtitleActive: false)
recoverySelection.selectAudio(5)
recoverySelection.selectAudio(-1)
recoverySelection.selectSubtitle(7, externalTrackID: 100_000)
recoverySelection.selectSubtitle(100_000, externalTrackID: 100_000)
check("HDR recovery selection: newest replacement-time audio and subtitle intent wins",
      recoverySelection.audioSelectionKnown
        && recoverySelection.audioIndex == nil
        && recoverySelection.subtitleSelectionKnown
        && recoverySelection.subtitleIndex == nil
        && recoverySelection.externalSubtitleActive)

let staleMountedSelection = DVPlaybackPolicy.HDRRecoverySelectionState(
    audioSelectionKnown: true,
    audioIndex: 1,
    subtitleSelectionKnown: true,
    subtitleIndex: 2,
    externalSubtitleActive: false)
let newestPendingSelection = DVPlaybackPolicy.HDRRecoverySelectionState(
    audioSelectionKnown: true,
    audioIndex: 5,
    subtitleSelectionKnown: true,
    subtitleIndex: nil,
    externalSubtitleActive: true)
let remountSelection = DVPlaybackPolicy.selectionForFreshRemount(
    pendingReplacement: newestPendingSelection,
    current: staleMountedSelection)
check("host failover selection: pending replacement intent beats stale mounted groups",
      remountSelection.audioIndex == 5)
check("host failover selection: discarded external cues fail closed to subtitle Off",
      remountSelection.subtitleSelectionKnown
        && remountSelection.subtitleIndex == nil
        && !remountSelection.externalSubtitleActive)

check("DV bitrate pin: only the authoritatively signaled primary DV remux qualifies",
      DVPlaybackPolicy.shouldPinPreferredPeakBitRate(
        isRemuxMounted: true,
        usingHDRFallbackItem: false,
        contentIsDolbyVision: true,
        signalingDolbyVision: true))
check("DV bitrate pin: plain remux, HDR recovery, and route-only guesses stay unpinned",
      !DVPlaybackPolicy.shouldPinPreferredPeakBitRate(
        isRemuxMounted: true,
        usingHDRFallbackItem: false,
        contentIsDolbyVision: false,
        signalingDolbyVision: false)
        && !DVPlaybackPolicy.shouldPinPreferredPeakBitRate(
            isRemuxMounted: true,
            usingHDRFallbackItem: true,
            contentIsDolbyVision: true,
            signalingDolbyVision: true)
        && !DVPlaybackPolicy.shouldPinPreferredPeakBitRate(
            isRemuxMounted: true,
            usingHDRFallbackItem: false,
            contentIsDolbyVision: true,
            signalingDolbyVision: false))

// MARK: - Display switch de-duplication (the flicker)

let manager = FakeDisplayManager()
var ledger = DVPlaybackPolicy.DisplayRequestLedger()
let dv60 = Req(range: "dolbyVision", rate: 60, width: 3840, height: 2160)

// The property that matters: an identical repeat is redundant, so the caller skips the assignment.
check("flicker: the first request is accepted", ledger.begin(dv60, manager: manager))
check("flicker: an identical pending request is redundant", !ledger.begin(dv60, manager: manager))
check("flicker: an in-flight request is not falsely reported as applied",
      !ledger.isApplied(dv60, manager: manager))
ledger.complete(dv60, manager: manager, applied: true)
check("flicker: an identical applied request is redundant", !ledger.begin(dv60, manager: manager))
check("flicker: a completed matching request is reported as applied",
      ledger.isApplied(dv60, manager: manager))
// The property that keeps it SAFE: anything that can change the negotiated mode may never be skipped.
check("flicker: a different rate is NOT redundant",
      ledger.begin(Req(range: "dolbyVision", rate: 23.976, width: 3840, height: 2160),
                   manager: manager))
check("flicker: a different range is NOT redundant",
      ledger.begin(Req(range: "hdr10", rate: 60, width: 3840, height: 2160), manager: manager))
// Dimensions cannot change the negotiated mode (tvOS matches dynamic range + refresh rate; the output
// resolution is the user's Settings choice, never content dims), and re-assigning criteria still
// renegotiates the link. So a dims-only repeat of an applied mode is REDUNDANT: this is the readyToPlay
// re-assert (presentationSize dims) after serveMaster's request (classifier dims), which blanked the
// screen for a mode the panel was already in.
check("flicker: a dims-only width change of an applied mode IS redundant",
      !ledger.begin(Req(range: "dolbyVision", rate: 60, width: 1920, height: 2160), manager: manager))
check("flicker: a dims-only height change of an applied mode IS redundant",
      !ledger.begin(Req(range: "dolbyVision", rate: 60, width: 3840, height: 1080), manager: manager))
ledger.reset()
check("flicker: reset makes an identical request eligible", ledger.begin(dv60, manager: manager))

let retryManager = FakeDisplayManager()
var retryLedger = DVPlaybackPolicy.DisplayRequestLedger()
check("display retry: the speculative request is admitted",
      retryLedger.begin(dv60, manager: retryManager))
retryLedger.complete(dv60, manager: retryManager, applied: false)
check("display retry: a failed speculative request remains unapplied and final signaling may retry",
      !retryLedger.isApplied(dv60, manager: retryManager)
          && retryLedger.begin(dv60, manager: retryManager))
retryLedger.complete(dv60, manager: retryManager, applied: true)
check("display retry: successful final signaling is latched and a duplicate master is redundant",
      retryLedger.isApplied(dv60, manager: retryManager)
          && !retryLedger.begin(dv60, manager: retryManager))

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
