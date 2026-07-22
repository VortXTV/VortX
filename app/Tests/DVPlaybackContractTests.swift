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

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
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

nativeEvents = []
// RED until the native-HLS terminal timeout path retires this ownership (or an engine-local preflight deadline
// wins first). The current chrome terminal branch presents an error without stopping the engine, so token and
// generation can remain current. This deliberately leaves duration and remediation policy unspecified.
let hlsGenerationStillCurrentAfterTerminalTimeout = 9
let lateHLSCompletion = DVPlaybackPolicy.completeNativePreAttach(
    loadedCriteria: "late-hls",
    isCurrent: { hlsGenerationStillCurrentAfterTerminalTimeout == 9 },
    apply: { nativeEvents.append("apply-\($0)") },
    attach: { nativeEvents.append("attach-late-hls") })
check("native DV RED: terminal native-HLS timeout must retire ownership before a late loader returns",
      lateHLSCompletion == .stale && nativeEvents.isEmpty)

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
#EXT-X-STREAM-INF:BANDWIDTH=19900000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,ec-3",FRAME-RATE=23.976
media-hdr.m3u8

""".utf8)
check("artifact: DV flag-off master is byte-identical to the pre-feature body",
      DVPlaybackPolicy.masterPlaylistData(
        input: dvMasterInput, mediaTags: [], streamInfAttributes: "") == dvFlagOffArtifact)
let decorated = String(decoding: DVPlaybackPolicy.masterPlaylistData(
    input: dvMasterInput,
    mediaTags: [#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Primary""#],
    streamInfAttributes: #",AUDIO="audio",SUBTITLES="subs""#), as: UTF8.self)
check("artifact: optional tags precede variants and every variant receives the same attributes",
      decorated.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Primary\"\n#EXT-X-STREAM-INF")
        && decorated.components(separatedBy: #",AUDIO="audio",SUBTITLES="subs""#).count == 3)

// MARK: - Display switch de-duplication (the flicker)

let manager = FakeDisplayManager()
var ledger = DVPlaybackPolicy.DisplayRequestLedger()
let dv60 = Req(range: "dolbyVision", rate: 60, width: 3840, height: 2160)

// The property that matters: an identical repeat is redundant, so the caller skips the assignment.
check("flicker: the first request is accepted", ledger.begin(dv60, manager: manager))
check("flicker: an identical pending request is redundant", !ledger.begin(dv60, manager: manager))
ledger.complete(dv60, manager: manager, applied: true)
check("flicker: an identical applied request is redundant", !ledger.begin(dv60, manager: manager))
// The property that keeps it SAFE: nothing that differs may ever be skipped, or a needed switch is lost.
check("flicker: a different rate is NOT redundant",
      ledger.begin(Req(range: "dolbyVision", rate: 23.976, width: 3840, height: 2160),
                   manager: manager))
check("flicker: a different range is NOT redundant",
      ledger.begin(Req(range: "hdr10", rate: 60, width: 3840, height: 2160), manager: manager))
check("flicker: a different width is NOT redundant",
      ledger.begin(Req(range: "dolbyVision", rate: 60, width: 1920, height: 2160), manager: manager))
check("flicker: a different height is NOT redundant",
      ledger.begin(Req(range: "dolbyVision", rate: 60, width: 3840, height: 1080), manager: manager))
ledger.reset()
check("flicker: reset makes an identical request eligible", ledger.begin(dv60, manager: manager))

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
