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
check("IDR classifier: HEVC CRA is random access but not IDR",
      !VortXVideoIDRClassifier.isIDR(
          bytes: hevcCRA, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: HEVC BLA is not silently promoted to IDR",
      !VortXVideoIDRClassifier.isIDR(
          bytes: hevcBLA, codec: .hevc, format: .lengthPrefixed(4)))
check("IDR classifier: a mixed HEVC CRA plus IDR access unit is not an IDR-only segment start",
      !VortXVideoIDRClassifier.isIDR(
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
check("IDR classifier: Annex-B HEVC CRA remains non-IDR",
      !VortXVideoIDRClassifier.isIDR(
          bytes: [0, 0, 0, 1, 21 << 1, 0x01], codec: .hevc, format: .annexB))
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
          elapsed: 0, openBytes: 0) == .failSoft)
check("segments: segment zero rejects an IDR whose demux key flag disagrees",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: false, incomingIsIDR: true, incomingHasKeyFlag: false,
          elapsed: 0, openBytes: 0) == .failSoft)
check("segments: an IDR with matching key evidence opens segment zero",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: false, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 0, openBytes: 0) == .open)
check("segments: a target-age IDR with matching key evidence cuts before itself",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 1, openBytes: 1) == .cut)
check("segments: either IDR/key disagreement extends below the hard guard",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: false,
          elapsed: 1, openBytes: 1) == .continueOpen
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: true,
              elapsed: 1, openBytes: 1) == .continueOpen)
check("segments: the four-second guard on a non-IDR fails soft instead of publishing an illegal cut",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false,
          elapsed: 4, openBytes: 1) == .failSoft)
check("segments: the 32MiB guard on a non-IDR fails soft instead of publishing an illegal cut",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: false, incomingHasKeyFlag: false, elapsed: 1,
          openBytes: 32 * 1024 * 1024) == .failSoft)
check("segments: an IDR at the hard guard remains a legal cut",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true, elapsed: 4,
          openBytes: 32 * 1024 * 1024) == .cut)
check("segments: malformed timing and byte inputs fail soft",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: .nan, openBytes: 0) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: -0.1, openBytes: 0) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: 1, openBytes: -1) == .failSoft)
check("segments: invalid target, maximum duration and byte thresholds fail soft",
      VortXHLSBoundaryPolicy.decision(
          hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
          elapsed: 1, openBytes: 1,
          targetSeconds: 0) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: 1, openBytes: 1,
              targetSeconds: 2, maximumSeconds: 1) == .failSoft
          && VortXHLSBoundaryPolicy.decision(
              hasOpenSegment: true, incomingIsIDR: true, incomingHasKeyFlag: true,
              elapsed: 1, openBytes: 1,
              maximumBytes: 0) == .failSoft)

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
let pendingHardLimitDecision = VortXHLSBoundaryPolicy.decision(
    hasOpenSegment: true,
    incomingIsIDR: false,
    incomingHasKeyFlag: false,
    elapsed: 4,
    openBytes: 1)
let pendingMayDeferHardLimit = VortXHLSBoundaryPolicy.mayDeferHardLimitFailure(
    hasOpenSegment: true,
    incomingIsIDR: false,
    incomingHasKeyFlag: false,
    elapsed: 4,
    openBytes: 1)
check("pending boundary: non-IDR hard failure is suppressed while a confirmed cut is unresolved",
      pendingBoundaries.effectiveBoundaryDecision(
          pendingHardLimitDecision,
          deferHardLimitFailure: pendingMayDeferHardLimit) == .continueOpen)
let invalidPendingDecision = VortXHLSBoundaryPolicy.decision(
    hasOpenSegment: true,
    incomingIsIDR: false,
    incomingHasKeyFlag: false,
    elapsed: -1,
    openBytes: -1)
let invalidPendingMayDefer = VortXHLSBoundaryPolicy.mayDeferHardLimitFailure(
    hasOpenSegment: true,
    incomingIsIDR: false,
    incomingHasKeyFlag: false,
    elapsed: -1,
    openBytes: -1)
check("pending boundary: invalid timing and byte inputs remain fail-closed",
      invalidPendingDecision == .failSoft
          && !invalidPendingMayDefer
          && pendingBoundaries.effectiveBoundaryDecision(
              invalidPendingDecision,
              deferHardLimitFailure: invalidPendingMayDefer) == .failSoft)
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
