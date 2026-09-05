// Executable contract for the bounded timeline-origin pre-scan receipt.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remux-timeline-origin-policy-test \
//     app/Sources/Player/RemuxTimelineOriginPolicy.swift \
//     app/Tests/RemuxTimelineOriginPolicyTests.swift && \
//     /tmp/remux-timeline-origin-policy-test
//
// This is deliberately a pure policy harness. It checks the small decisions that the FFmpeg remux loop
// delegates to the policy, without simulating packets or importing the production AVFoundation/libav graph.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
enum RemuxTimelineOriginPolicyTests {
    static func main() {
        freshDTSStopsAndPublishesZero()
        resumeDTSStopsAndPublishesAchievedOrigin()
        resumePTSOnlyContinuesAndSelectsFallback()
        missingTimestampAtLimitRemainsNoneAndExhausted()
        check("empty header reads beyond provisional first DTS",
              RemuxTimelineOriginPolicy.headerRepairLookahead(videoDelay: 0) == 4)
        check("header repair lookahead is bounded for hostile reorder depth",
              RemuxTimelineOriginPolicy.headerRepairLookahead(videoDelay: Int.max) == 18)
        check("fresh provisional zero plus missing DTS anchors to real successor",
              RemuxTimelineOriginPolicy.leadingDTSAnchor([0, nil, nil, 42]) == 3)
        check("resume missing leading DTS anchors to real successor",
              RemuxTimelineOriginPolicy.leadingDTSAnchor([nil, nil, 42]) == 2)
        check("valid DTS sequence is untouched",
              RemuxTimelineOriginPolicy.leadingDTSAnchor([0, 42, 83, 125]) == nil)
        check("established DTS sequence cannot be rewritten for a later gap",
              RemuxTimelineOriginPolicy.leadingDTSAnchor([0, 42, nil, nil, 125]) == nil)
        check("missing-only bounded prefix is not guessed",
              RemuxTimelineOriginPolicy.leadingDTSAnchor([nil, nil, nil]) == nil)

        if failures != 0 {
            fatalError("\(failures) remux timeline-origin policy checks failed")
        }
    }

    @MainActor private static func freshDTSStopsAndPublishesZero() {
        let stops = RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: true,
            timelineRebaseRequired: true,
            originLatched: true)
        let unmappedStops = RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: false,
            timelineRebaseRequired: true,
            originLatched: true)
        let noRebaseStops = RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: true,
            timelineRebaseRequired: false,
            originLatched: false)
        let publishedOrigin = RemuxTimelineOriginPolicy.publishedOriginSeconds(
            mode: .fresh,
            achievedShiftSeconds: 37.125)
        let outcome = RemuxTimelineOriginPolicy.PrescanOutcome(
            mode: .fresh,
            scanned: 3,
            mappedBase: 1,
            basis: .dts,
            exhausted: false,
            achievedShiftSeconds: 37.125)

        check("fresh DTS stops after a mapped base packet", stops)
        check("fresh stop requires a mapped base packet", !unmappedStops)
        check("a mapped base packet stops when no rebase is required", noRebaseStops)
        check("fresh publishes origin zero despite a nonzero achieved shift", publishedOrigin == 0)
        check(
            "fresh DTS receipt is exact and redacted",
            outcome.receipt ==
                "timeline-origin-prescan mode=fresh scanned=3/240 mappedBase=1 basis=dts exhausted=0 shift=37.125")
    }

    @MainActor private static func resumeDTSStopsAndPublishesAchievedOrigin() {
        let stops = RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: true,
            timelineRebaseRequired: true,
            originLatched: true)
        let publishedOrigin = RemuxTimelineOriginPolicy.publishedOriginSeconds(
            mode: .resume,
            achievedShiftSeconds: 1830.375)
        let outcome = RemuxTimelineOriginPolicy.PrescanOutcome(
            mode: .resume,
            scanned: 8,
            mappedBase: 2,
            basis: .dts,
            exhausted: false,
            achievedShiftSeconds: 1830.375)

        check("resume DTS stops after the origin is latched", stops)
        check("resume publishes the achieved shift", publishedOrigin == 1830.375)
        check(
            "resume DTS receipt includes only bounded fields and a finite shift",
            outcome.receipt ==
                "timeline-origin-prescan mode=resume scanned=8/240 mappedBase=2 basis=dts exhausted=0 shift=1830.375")
    }

    @MainActor private static func resumePTSOnlyContinuesAndSelectsFallback() {
        let continues = !RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: true,
            timelineRebaseRequired: true,
            originLatched: false)
        let basis = RemuxTimelineOriginPolicy.originBasis(
            dts: nil,
            ptsFallback: 1830_375_000)
        let dtsWins = RemuxTimelineOriginPolicy.originBasis(
            dts: 1830_375_000,
            ptsFallback: 1831_000_000)
        let outcome = RemuxTimelineOriginPolicy.PrescanOutcome(
            mode: .resume,
            scanned: 12,
            mappedBase: 3,
            basis: basis,
            exhausted: false,
            achievedShiftSeconds: 1830.375)

        check("resume PTS-only base packets continue while no origin is latched", continues)
        check("resume PTS-only input selects the PTS fallback basis", basis == .ptsFallback)
        check("observed DTS takes precedence over a PTS fallback", dtsWins == .dts)
        check(
            "resume PTS fallback receipt is exact",
            outcome.receipt ==
                "timeline-origin-prescan mode=resume scanned=12/240 mappedBase=3 basis=pts-fallback exhausted=0 shift=1830.375")
    }

    @MainActor private static func missingTimestampAtLimitRemainsNoneAndExhausted() {
        let continuesUntilTheBound = !RemuxTimelineOriginPolicy.shouldStopAfterMappedBasePacket(
            isMappedBasePacket: true,
            timelineRebaseRequired: true,
            originLatched: false)
        let basis = RemuxTimelineOriginPolicy.originBasis(dts: nil, ptsFallback: nil)
        let outcome = RemuxTimelineOriginPolicy.PrescanOutcome(
            mode: .fresh,
            scanned: RemuxTimelineOriginPolicy.preScanPacketLimit,
            mappedBase: 1,
            basis: basis,
            exhausted: true,
            achievedShiftSeconds: nil)
        let bounded = RemuxTimelineOriginPolicy.formatReceipt(
            mode: .fresh,
            scanned: RemuxTimelineOriginPolicy.preScanPacketLimit + 1,
            mappedBase: RemuxTimelineOriginPolicy.preScanPacketLimit + 1,
            basis: .none,
            exhausted: true,
            achievedShiftSeconds: .infinity)

        check("the policy hard limit is exactly 240 packets", RemuxTimelineOriginPolicy.preScanPacketLimit == 240)
        check("no timestamp keeps the pre-scan fail-closed until the bound", continuesUntilTheBound)
        check("no timestamp is classified as none, never as PTS fallback", basis == .none)
        check(
            "no-timestamp receipt is exhausted, bounded, and redacted",
            outcome.receipt ==
                "timeline-origin-prescan mode=fresh scanned=240/240 mappedBase=1 basis=none exhausted=1"
                && !outcome.receipt.contains("shift=")
                && !outcome.receipt.contains("url")
                && !outcome.receipt.contains("track")
                && !outcome.receipt.contains("title"))
        check(
            "receipt formatter caps hostile unbounded and non-finite input",
            bounded ==
                "timeline-origin-prescan mode=fresh scanned=240/240 mappedBase=240 basis=none exhausted=1")
    }
}
