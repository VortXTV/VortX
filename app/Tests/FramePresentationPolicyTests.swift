// Focused pure contract:
//
//   xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
//     app/Sources/Player/FramePresentationPolicy.swift \
//     app/Tests/FramePresentationPolicyTests.swift \
//     -o /tmp/frame-presentation-tests && /tmp/frame-presentation-tests

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func sourceSlice(
    _ source: String,
    after anchor: String,
    from start: String,
    to end: String
) -> String? {
    guard let anchorRange = source.range(of: anchor),
          let lower = source.range(
            of: start,
            range: anchorRange.lowerBound..<source.endIndex
          ),
          let upper = source.range(
            of: end,
            range: lower.upperBound..<source.endIndex
          ) else {
        return nil
    }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

/// Removes whitespace and comments so production-wiring checks compare executable source.
/// Each rule also applies a negative mutation to the real source and proves that the rule turns red.
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
            range: anchorRange.lowerBound..<source.endIndex
          ) else {
        return nil
    }
    var mutated = source
    mutated.replaceSubrange(targetRange, with: replacement)
    return mutated
}

private struct FramePresentationWiringRule {
    let name: String
    let file: String
    let searchAfter: String
    let mutationAfter: String
    let start: String
    let end: String
    let exactSection: String
    let mutationTarget: String
    let mutationReplacement: String

    init(
        name: String,
        file: String,
        searchAfter: String? = nil,
        mutationAfter: String? = nil,
        start: String,
        end: String,
        exactSection: String,
        mutationTarget: String,
        mutationReplacement: String
    ) {
        self.name = name
        self.file = file
        let resolvedSearchAfter = searchAfter ?? start
        self.searchAfter = resolvedSearchAfter
        self.mutationAfter = mutationAfter ?? resolvedSearchAfter
        self.start = start
        self.end = end
        self.exactSection = exactSection
        self.mutationTarget = mutationTarget
        self.mutationReplacement = mutationReplacement
    }

    func passes(sources: [String: String]) -> Bool {
        guard let source = sources[file] else { return false }
        return sourceSlice(source, after: searchAfter, from: start, to: end)
            .map { compactSwift($0) == compactSwift(exactSection) } ?? false
    }
}

private func input(
    full: Bool = true,
    standard: Bool = true,
    width: Int = 3_840,
    height: Int = 2_160,
    gamma: String = "pq",
    dv: Bool = false,
    peak: Double = 1,
    custom: [String] = []
) -> TVOSFramePresentationPolicy.Input {
    .init(
        fullPlayer: full, standardQuality: standard,
        videoWidth: width, videoHeight: height,
        gamma: gamma, dolbyVision: dv, signalPeak: peak,
        customOptionKeys: custom
    )
}

@MainActor
private func productionWiring() {
    let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let paths = [
        "MPVMetalViewController.swift": appRoot
            .appendingPathComponent("Sources/Player/MPVMetalViewController.swift"),
        "MetalLayer.swift": appRoot
            .appendingPathComponent("Sources/Player/MetalLayer.swift"),
        "TVPlayerView.swift": appRoot
            .appendingPathComponent("SourcesTV/TVPlayerView.swift"),
    ]
    var sources: [String: String] = [:]
    for (name, path) in paths {
        sources[name] = try? String(contentsOf: path, encoding: .utf8)
    }
    guard sources.count == paths.count else {
        check("frame production wiring: governed sources are readable", false)
        return
    }

    let productionGate = "#if os(tvOS)"

    let rules = [
        FramePresentationWiringRule(
            name: "production controller state",
            file: "MPVMetalViewController.swift",
            start: "#if os(tvOS)\n"
                + "    private let framePresentationDiagnostics",
            end: "override func viewDidLoad()",
            exactSection: """
                #if os(tvOS)
                private let framePresentationDiagnostics = FramePresentationDiagnosticsAccumulator()
                private var framePresentationGeneration: UInt64 = 0
                private var framePresentationLoadedGeneration: UInt64?
                private var framePresentationStartedGeneration: UInt64?
                private var framePresentationPriorCscale: String?
                private var framePresentationMitigationApplied = false
                private var framePresentationRestorePending = false
                private var framePresentationVOPassesWork: DispatchWorkItem?
                private static let framePresentationVOPassesCooldown: TimeInterval = 2
                #endif
            """,
            mutationTarget: productionGate,
            mutationReplacement: "#if false"),
        FramePresentationWiringRule(
            name: "full-player activation and teardown",
            file: "MPVMetalViewController.swift",
            start: "var isFullPlayerPresentation = false {",
            end: """
                #if os(tvOS)
                private let framePresentationDiagnostics
            """,
            exactSection: """
                var isFullPlayerPresentation = false {
                    didSet {
                        #if os(tvOS)
                        if isFullPlayerPresentation {
                            startFramePresentationDiagnosticsIfReady()
                            updateFramePresentationPolicy()
                        } else {
                            stopFramePresentationDiagnostics()
                            restoreFramePresentationCscale()
                        }
                        #endif
                    }
                }
            """,
            mutationTarget: "if isFullPlayerPresentation {",
            mutationReplacement: "if false && isFullPlayerPresentation {"),
        FramePresentationWiringRule(
            name: "TV full-player launch wiring",
            file: "TVPlayerView.swift",
            start: "MPVMetalPlayerView(coordinator: coordinator)",
            end: ".ignoresSafeArea()",
            exactSection: """
                MPVMetalPlayerView(coordinator: coordinator)
                    .play(initialPlayback.url, headers: initialPlayback.headers, audioSidecar: audioSidecarURL,
                          isDolbyVision: StreamRanking.isDolbyVision(sourceHint ?? ""))
                    .live(initialLiveMode)
                    .onPropertyChange { _, name, data, token in handleProperty(name, data, loadToken: token) }
                    .onAppear {
                        coordinator.player?.isFullPlayerPresentation = true
                    }
            """,
            mutationTarget: "coordinator.player?.isFullPlayerPresentation = true",
            mutationReplacement: "coordinator.player?.isFullPlayerPresentation = false"),
        FramePresentationWiringRule(
            name: "production mpv observers",
            file: "MPVMetalViewController.swift",
            searchAfter: "checkError(mpv_initialize(mpv))",
            start: productionGate,
            end: "mpv_observe_property(mpv, 0, MPVProperty.pausedForCache",
            exactSection: """
                #if os(tvOS)
                mpv_observe_property(mpv, 0, MPVProperty.frameDropCount, MPV_FORMAT_INT64)
                mpv_observe_property(mpv, 0, MPVProperty.decoderFrameDropCount, MPV_FORMAT_INT64)
                mpv_observe_property(mpv, 0, MPVProperty.subtitleStart, MPV_FORMAT_DOUBLE)
                #endif
            """,
            mutationTarget:
                "mpv_observe_property(mpv, 0, MPVProperty.subtitleStart, MPV_FORMAT_DOUBLE)",
            mutationReplacement:
                "mpv_observe_property(mpv, 0, MPVProperty.subtitleStart, MPV_FORMAT_STRING)"),
        FramePresentationWiringRule(
            name: "Metal drawable wait receipt",
            file: "MetalLayer.swift",
            start: "override func nextDrawable() -> (any CAMetalDrawable)? {",
            end: "guard let d else { return nil }",
            exactSection: """
                override func nextDrawable() -> (any CAMetalDrawable)? {
                    #if os(tvOS)
                    let drawableWaitStartedAt = CACurrentMediaTime()
                    #endif
                    let d = super.nextDrawable()
                    #if os(tvOS)
                    let drawableAcquiredAt = CACurrentMediaTime()
                    let presentationDiagnostics = presentationDiagnostics
                    _ = presentationDiagnostics?.recordDrawable(
                        wait: drawableAcquiredAt - drawableWaitStartedAt,
                        returned: d != nil
                    )
                    #endif
            """,
            mutationTarget: "wait: drawableAcquiredAt - drawableWaitStartedAt",
            mutationReplacement: "wait: 0"),
        FramePresentationWiringRule(
            name: "generation-safe terminal cleanup",
            file: "MPVMetalViewController.swift",
            start: "private func scheduleFramePresentationTerminalCleanup(",
            end: "private func restoreFramePresentationCscale()",
            exactSection: """
                private func scheduleFramePresentationTerminalCleanup(
                    generation: UInt64,
                    loadToken: PlayerLoadToken
                ) {
                    guard framePresentationStartedGeneration == generation,
                          framePresentationDiagnostics.currentGeneration() == generation,
                          PlayerLoadProvenanceState.accepts(
                            callbackToken: loadToken,
                            activeToken: activeLoadToken
                          ) else {
                        return
                    }
                    stopFramePresentationDiagnostics()
                    restoreFramePresentationCscale()
                }
            """,
            mutationTarget: "restoreFramePresentationCscale()",
            mutationReplacement: "_ = framePresentationPriorCscale"),
        FramePresentationWiringRule(
            name: "failed live-handle restore remains retryable",
            file: "MPVMetalViewController.swift",
            searchAfter: #"let status = mpv_set_property_string(handle, "cscale", prior)"#,
            start: "self.framePresentationRestorePending = false",
            end: "DiagnosticsLog.log(",
            exactSection: #"""
                self.framePresentationRestorePending = false
                guard self.framePresentationMitigationApplied,
                      self.framePresentationPriorCscale == prior else {
                    return
                }
                if self.mpv == nil {
                    self.framePresentationPriorCscale = nil
                    self.framePresentationMitigationApplied = false
                    return
                }
                guard self.mpv == handle else { return }
                guard status >= 0 else {
                    self.mpvLog.error(
                        "tvOS frame presentation cscale restore failed: \(String(cString: mpv_error_string(status)), privacy: .public)"
                    )
                    return
                }

                self.framePresentationPriorCscale = nil
                self.framePresentationMitigationApplied = false
            """#,
            mutationTarget: "guard status >= 0 else {",
            mutationReplacement: """
                guard status >= 0 else {
                    self.framePresentationPriorCscale = nil
                    self.framePresentationMitigationApplied = false
            """),
        FramePresentationWiringRule(
            name: "successful live-handle restore clears mitigation state",
            file: "MPVMetalViewController.swift",
            searchAfter: #"let status = mpv_set_property_string(handle, "cscale", prior)"#,
            mutationAfter: "guard status >= 0 else {",
            start: "self.framePresentationRestorePending = false",
            end: "DiagnosticsLog.log(",
            exactSection: #"""
                self.framePresentationRestorePending = false
                guard self.framePresentationMitigationApplied,
                      self.framePresentationPriorCscale == prior else {
                    return
                }
                if self.mpv == nil {
                    self.framePresentationPriorCscale = nil
                    self.framePresentationMitigationApplied = false
                    return
                }
                guard self.mpv == handle else { return }
                guard status >= 0 else {
                    self.mpvLog.error(
                        "tvOS frame presentation cscale restore failed: \(String(cString: mpv_error_string(status)), privacy: .public)"
                    )
                    return
                }

                self.framePresentationPriorCscale = nil
                self.framePresentationMitigationApplied = false
            """#,
            mutationTarget: "self.framePresentationPriorCscale = nil",
            mutationReplacement: "_ = self.framePresentationPriorCscale"),
        FramePresentationWiringRule(
            name: "end-file error cleanup dispatch",
            file: "MPVMetalViewController.swift",
            start: "if ef.reason == MPV_END_FILE_REASON_ERROR {",
            end: "let msg = String(cString: mpv_error_string(ef.error))",
            exactSection: """
                if ef.reason == MPV_END_FILE_REASON_ERROR {
                    #if os(tvOS)
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              let generation = self.framePresentationDiagnostics.currentGeneration()
                        else { return }
                        self.scheduleFramePresentationTerminalCleanup(
                            generation: generation, loadToken: loadToken)
                    }
                    #endif
            """,
            mutationTarget: "guard let self,",
            mutationReplacement: "guard false, let self,"),
        FramePresentationWiringRule(
            name: "end-file EOF cleanup dispatch",
            file: "MPVMetalViewController.swift",
            start: "} else if ef.reason == MPV_END_FILE_REASON_EOF {",
            end: #"VXProbe.event("player", "endfile eof")"#,
            exactSection: """
                } else if ef.reason == MPV_END_FILE_REASON_EOF {
                    #if os(tvOS)
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              let generation = self.framePresentationDiagnostics.currentGeneration()
                        else { return }
                        self.scheduleFramePresentationTerminalCleanup(
                            generation: generation, loadToken: loadToken)
                    }
                    #endif
            """,
            mutationTarget: "guard let self,",
            mutationReplacement: "guard false, let self,"),
    ]

    for rule in rules {
        check("frame production wiring: \(rule.name)", rule.passes(sources: sources))
        guard let source = sources[rule.file],
              let mutated = replacingFirst(
                source,
                after: rule.mutationAfter,
                target: rule.mutationTarget,
                with: rule.mutationReplacement
              ) else {
            check("frame production wiring mutation: \(rule.name) is constructed", false)
            continue
        }
        var mutantSources = sources
        mutantSources[rule.file] = mutated
        check(
            "frame production wiring mutation: \(rule.name) turns red",
            !rule.passes(sources: mutantSources)
        )
    }
}

@main
private enum FramePresentationPolicyTests {
    @MainActor
    static func main() {
        productionWiring()
        policy()
        resetSafeCounters()
        presentedSamplingCadence()
        intervalScopedAggregates()
        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            fatalError("\(failures) FAILED")
        }
    }

    @MainActor
    private static func policy() {
        check("eligible PQ applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(input()))
        check("eligible HLG applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(gamma: " HLG ")
        ))
        check("DV evidence applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(gamma: "", dv: true)
        ))
        check("signal peak evidence applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(gamma: "bt.1886", peak: 1.001)
        ))
        check("embedded player vetoes", !TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(full: false)
        ))
        check("nonstandard quality vetoes", !TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(standard: false)
        ))
        check("sub-4K maximum dimension vetoes",
              !TVOSFramePresentationPolicy.shouldUseBilinearChroma(
                input(width: 3_839)
              ))
        check("short 4K minimum dimension vetoes",
              !TVOSFramePresentationPolicy.shouldUseBilinearChroma(
                input(width: 3_840, height: 1_599)
              ))
        check("portrait 4K applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(width: 2_160, height: 3_840)
        ))
        check("ultrawide 4K applies", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(width: 3_840, height: 1_600)
        ))
        check("SDR peak boundary vetoes", !TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(gamma: "bt.1886", peak: 1)
        ))
        check("unrelated custom audio is allowed", TVOSFramePresentationPolicy.shouldUseBilinearChroma(
            input(custom: ["audio-buffer"])
        ))
        for key in ["cscale", "scale-param1", "profile", "vo", "gpu_api",
                    "glsl-shaders", "vf"] {
            check("\(key) custom option vetoes",
                  !TVOSFramePresentationPolicy.shouldUseBilinearChroma(input(custom: [key])))
        }
    }

    @MainActor
    private static func resetSafeCounters() {
        var counter = FramePresentationDropCounter(initialRaw: 0)
        check("raw increase is counted", counter.observe(5) == 5)
        check("raw reset starts a new segment", counter.observe(2) == 2)
        check("post-reset increase is counted", counter.observe(4) == 2)
        check("interval spans resets", counter.takeInterval() == 9)
        check("receipt clears only the interval", counter.takeInterval() == 0 && counter.raw == 4)
        check("negative raw samples are ignored", counter.observe(-1) == 0 && counter.raw == 4)
    }

    @MainActor
    private static func presentedSamplingCadence() {
        let accumulator = FramePresentationDiagnosticsAccumulator()
        accumulator.begin(generation: 7, now: 100, frameDropRaw: 0, decoderDropRaw: 0)
        let earlySamples = (1..<FramePresentationDiagnosticsAccumulator.presentedSampleStride)
            .map { _ in accumulator.recordDrawable(wait: 0, returned: true) }
        check("presented handler is not armed before sample cadence",
              earlySamples.allSatisfy { $0 == nil })
        check("nil drawable does not advance successful cadence",
              accumulator.recordDrawable(wait: 0, returned: false) == nil)
        let firstReceipt = accumulator.takeSnapshot(
            now: 110, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("receipt contains and clears first interval drawables",
              firstReceipt?.drawableRequests == 30 && firstReceipt?.drawableNil == 1)
        check("lifetime sequence arms sample across receipt reset",
              accumulator.recordDrawable(wait: 0, returned: true) == 7)
        accumulator.recordPresented(generation: 7, latency: 0.012)
        let secondReceipt = accumulator.takeSnapshot(
            now: 120, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("second receipt contains only its interval",
              secondReceipt?.drawableRequests == 1
                && secondReceipt?.presentedSampleCallbacks == 1
                && secondReceipt?.presentedSampleAverageMilliseconds == 12)
        accumulator.begin(generation: 8, now: 101, frameDropRaw: 0, decoderDropRaw: 0)
        accumulator.recordPresented(generation: 7, latency: 1)
        let snapshot = accumulator.takeSnapshot(
            now: 101, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("late sampled callback is rejected after generation change",
              snapshot?.presentedSampleCallbacks == 0)
    }

    @MainActor
    private static func intervalScopedAggregates() {
        let accumulator = FramePresentationDiagnosticsAccumulator()
        accumulator.begin(generation: 7, now: 100, frameDropRaw: 10, decoderDropRaw: 3)
        check("drawable does not arm before sample cadence",
              accumulator.recordDrawable(wait: 0.002, returned: true) == nil)
        check("nil drawable has no presented generation",
              accumulator.recordDrawable(wait: 0.008, returned: false) == nil)
        accumulator.recordPresented(generation: 7, latency: 0.016)
        accumulator.recordPresented(generation: 7, latency: nil)
        accumulator.recordPresented(generation: 7, latency: 0)
        accumulator.recordPresented(generation: 7, latency: .nan)
        accumulator.recordPresented(generation: 6, latency: 9)
        check("frame raw delta recorded",
              accumulator.recordDrop(raw: 12, decoder: false)?.delta == 2)
        check("frame reset recorded",
              accumulator.recordDrop(raw: 1, decoder: false)?.delta == 1)
        check("decoder raw delta recorded",
              accumulator.recordDrop(raw: 5, decoder: true)?.delta == 2)
        accumulator.recordSubtitleStart(12)
        accumulator.recordSubtitleStart(12)
        accumulator.recordSubtitleStart(14)
        accumulator.recordVOPasses(
            .init(count: 3, averageMilliseconds: 4, peakMilliseconds: 7, slowest: "scale"),
            generation: 7
        )

        let first = accumulator.takeSnapshot(
            now: 130, subtitleCodec: "ass", subtitleSource: "embedded",
            activeCscale: "bilinear", mitigationPriorCscale: "ewa_lanczossharp",
            mitigationApplied: true, mitigationGate: "production-4k-hdr"
        )
        check("drawable aggregate", first?.drawableRequests == 2 && first?.drawableNil == 1)
        check("drawable wait aggregate",
              first?.drawableWaitAverageMilliseconds == 5
                && first?.drawableWaitMaximumMilliseconds == 8)
        check("presented aggregate excludes invalid latency",
              first?.presentedSampleCallbacks == 4 && first?.presentedSampleTimeValid == 1
                && first?.presentedSampleAverageMilliseconds == 16
                && first?.presentedSampleMaximumMilliseconds == 16)
        check("reset-safe receipt deltas",
              first?.frameDropsSinceReceipt == 3 && first?.decoderDropsSinceReceipt == 2)
        check("subtitle starts deduplicate without text",
              first?.subtitleCodec == "ass" && first?.subtitleSource == "embedded"
                && first?.subtitleCueCount == 2 && first?.subtitleCuesPerMinute == 4)
        check("first vo-passes snapshot retained", first?.voPasses?.slowest == "scale")
        check("active and prior cscale retained",
              first?.activeCscale == "bilinear"
                && first?.mitigationPriorCscale == "ewa_lanczossharp")

        _ = accumulator.recordDrawable(wait: 0.004, returned: true)
        accumulator.recordPresented(generation: 7, latency: 0.020)
        _ = accumulator.recordDrop(raw: 2, decoder: false)
        _ = accumulator.recordDrop(raw: 1, decoder: true)
        accumulator.recordSubtitleStart(14)
        accumulator.recordSubtitleStart(nil)
        accumulator.recordSubtitleStart(14)
        let second = accumulator.takeSnapshot(
            now: 160, subtitleCodec: "ass", subtitleSource: "embedded",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("second receipt has only new drawable interval",
              second?.drawableRequests == 1 && second?.drawableNil == 0
                && second?.drawableWaitAverageMilliseconds == 4
                && second?.drawableWaitMaximumMilliseconds == 4)
        check("second receipt has only new presented interval",
              second?.presentedSampleCallbacks == 1
                && second?.presentedSampleTimeValid == 1
                && second?.presentedSampleAverageMilliseconds == 20
                && second?.presentedSampleMaximumMilliseconds == 20)
        check("drop baselines survive receipt reset",
              second?.frameDropsSinceReceipt == 1
                && second?.decoderDropsSinceReceipt == 1)
        check("unavailable subtitle start resets dedup",
              second?.subtitleCueCount == 1 && second?.subtitleCuesPerMinute == 2)
        check("one-shot vo snapshot survives receipts",
              second?.voPasses?.slowest == "scale")

        let empty = accumulator.takeSnapshot(
            now: 190, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("receipt clears interval presentation and subtitle aggregates",
              empty?.drawableRequests == 0 && empty?.drawableNil == 0
                && empty?.drawableWaitAverageMilliseconds == 0
                && empty?.drawableWaitMaximumMilliseconds == 0
                && empty?.presentedSampleCallbacks == 0
                && empty?.presentedSampleTimeValid == 0
                && empty?.presentedSampleAverageMilliseconds == 0
                && empty?.presentedSampleMaximumMilliseconds == 0
                && empty?.subtitleCueCount == 0)
        check("receipt preserves generation raw baselines and vo snapshot",
              empty?.generation == 7 && empty?.frameDropsSinceReceipt == 0
                && empty?.decoderDropsSinceReceipt == 0
                && empty?.voPasses?.count == 3)

        accumulator.begin(generation: 8, now: 200, frameDropRaw: 50, decoderDropRaw: 8)
        accumulator.recordPresented(generation: 7, latency: 1)
        accumulator.recordSubtitleStart(14)
        let next = accumulator.takeSnapshot(
            now: 200, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: "ewa_lanczossharp", mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("new generation rejects late callback and resets subtitle dedup",
              next?.generation == 8 && next?.presentedSampleCallbacks == 0
                && next?.frameDropsSinceReceipt == 0
                && next?.subtitleCueCount == 1)
    }
}
