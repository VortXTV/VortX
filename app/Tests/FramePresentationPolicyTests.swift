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

private func occurrenceCount(_ needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

private func snippetsInOrder(_ source: String, _ snippets: [String]) -> Bool {
    var cursor = source.startIndex
    for snippet in snippets {
        let compactSnippet = compactSwift(snippet)
        guard let range = source.range(
            of: compactSnippet,
            range: cursor..<source.endIndex
        ) else {
            return false
        }
        cursor = range.upperBound
    }
    return true
}

private func moveFirst(
    _ source: String,
    target: String,
    before anchor: String
) -> String? {
    guard let targetRange = source.range(of: target),
          let anchorRange = source.range(of: anchor),
          targetRange.lowerBound > anchorRange.lowerBound else {
        return nil
    }
    var mutated = source
    mutated.removeSubrange(targetRange)
    guard let adjustedAnchor = mutated.range(of: anchor) else { return nil }
    mutated.insert(contentsOf: target, at: adjustedAnchor.lowerBound)
    return mutated
}

private func moveFirst(
    _ source: String,
    target: String,
    after anchor: String
) -> String? {
    guard let targetRange = source.range(of: target),
          let anchorRange = source.range(of: anchor),
          targetRange != anchorRange else {
        return nil
    }
    var mutated = source
    mutated.removeSubrange(targetRange)
    guard let adjustedAnchor = mutated.range(of: anchor) else { return nil }
    mutated.insert(contentsOf: target, at: adjustedAnchor.upperBound)
    return mutated
}

private func teardownStopSource(_ source: String) -> String? {
    sourceSlice(
        source,
        after: "    func stop() {",
        from: "    func stop() {",
        to: "\n    deinit {"
    )
}

private func teardownReceiptContractPasses(_ source: String) -> Bool {
    guard let stop = teardownStopSource(source) else { return false }
    let compactStop = compactSwift(stop)
    let surfaceClassification = #"let surface = isFullPlayerPresentation || probeChannel.description == "player" ? "player" : "ambient""#
    let requestedReceipt = #"DiagnosticsLog.log("mpv", "stop-requested surface=\(surface)")"#
    let finishedReceipt = #"DiagnosticsLog.log("mpv", "destroy-finished surface=\(surface)")"#
    let guardLiveHandle = "guard let handle = mpv else { return }"
    let claimHandle = "mpv = nil"
    let quit = #"mpv_command_string(handle, "quit")"#
    let terminate = "mpv_terminate_destroy(handle)"
    let relayRelease = "relay?.release()"
    let destroyToFinished = compactSwift("\(terminate)\n\(finishedReceipt)")

    guard occurrenceCount("stop-requested", in: stop) == 1,
          occurrenceCount("destroy-finished", in: stop) == 1,
          occurrenceCount(compactSwift(surfaceClassification), in: compactStop) == 1,
          occurrenceCount(compactSwift(requestedReceipt), in: compactStop) == 1,
          occurrenceCount(compactSwift(finishedReceipt), in: compactStop) == 1,
          occurrenceCount("DiagnosticsLog.log(\"mpv\",", in: compactStop) == 2,
          occurrenceCount(destroyToFinished, in: compactStop) == 1 else {
        return false
    }

    return snippetsInOrder(
        compactStop,
        [
            guardLiveHandle,
            claimHandle,
            surfaceClassification,
            requestedReceipt,
            quit,
            "queue.async {",
            terminate,
            finishedReceipt,
            relayRelease,
        ]
    )
}

@MainActor
private func rejectTeardownReceiptMutation(
    _ name: String,
    original: String,
    mutated: String?
) {
    guard let mutated else {
        check("mpv teardown receipt mutation: \(name) is constructed", false)
        return
    }
    check("mpv teardown receipt mutation: \(name) changes source", mutated != original)
    check(
        "mpv teardown receipt mutation: \(name) turns red",
        !teardownReceiptContractPasses(mutated)
    )
}

@MainActor
private func teardownReceiptWiring(source: String) {
    guard let stop = teardownStopSource(source) else {
        check("mpv teardown receipts: normal stop is readable", false)
        return
    }
    let compactStop = compactSwift(stop)
    let surfaceClassification = #"let surface = isFullPlayerPresentation || probeChannel.description == "player" ? "player" : "ambient""#
    let requestedReceipt = #"DiagnosticsLog.log("mpv", "stop-requested surface=\(surface)")"#
    let finishedReceipt = #"DiagnosticsLog.log("mpv", "destroy-finished surface=\(surface)")"#
    let guardLiveHandle = "guard let handle = mpv else { return }"
    let quit = #"mpv_command_string(handle, "quit")"#
    let terminate = "mpv_terminate_destroy(handle)"
    let relayRelease = "relay?.release()"

    check("mpv teardown receipts: source contract", teardownReceiptContractPasses(source))
    check(
        "mpv teardown receipts: requested literal appears once in normal stop",
        occurrenceCount("stop-requested", in: stop) == 1
    )
    check(
        "mpv teardown receipts: finished literal appears once in normal stop",
        occurrenceCount("destroy-finished", in: stop) == 1
    )
    check(
        "mpv teardown receipts: requested receipt is after live-handle claim and before quit",
        snippetsInOrder(compactStop, [guardLiveHandle, "mpv = nil", requestedReceipt, quit])
    )
    check(
        "mpv teardown receipts: finished receipt is after destroy and before relay release",
        snippetsInOrder(compactStop, ["queue.async {", terminate, finishedReceipt, relayRelease])
    )
    check(
        "mpv teardown receipts: only fixed mpv receipt payloads are present",
        occurrenceCount("DiagnosticsLog.log(\"mpv\",", in: compactStop) == 2
            && compactStop.contains(compactSwift(requestedReceipt))
            && compactStop.contains(compactSwift(finishedReceipt))
            && compactStop.contains(compactSwift(surfaceClassification))
    )

    let earlyRelayReleaseMutant = replacingFirst(
        source,
        after: "    func stop() {",
        target: terminate,
        with: "\(terminate)\n\(relayRelease)"
    )
    rejectTeardownReceiptMutation(
        "early relay release between destroy and finished receipt",
        original: source,
        mutated: earlyRelayReleaseMutant
    )

    rejectTeardownReceiptMutation(
        "requested before guard/claim",
        original: source,
        mutated: moveFirst(
            source,
            target: requestedReceipt,
            before: guardLiveHandle
        )
    )
    rejectTeardownReceiptMutation(
        "requested after quit",
        original: source,
        mutated: moveFirst(
            source,
            target: requestedReceipt,
            after: quit
        )
    )
    rejectTeardownReceiptMutation(
        "finished before terminate",
        original: source,
        mutated: moveFirst(
            source,
            target: finishedReceipt,
            before: terminate
        )
    )
    rejectTeardownReceiptMutation(
        "finished after relay release",
        original: source,
        mutated: moveFirst(
            source,
            target: finishedReceipt,
            after: relayRelease
        )
    )
    rejectTeardownReceiptMutation(
        "duplicate requested literal",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: requestedReceipt,
            with: "\(requestedReceipt)\n\(requestedReceipt)"
        )
    )
    rejectTeardownReceiptMutation(
        "pointer data",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: requestedReceipt,
            with: #"DiagnosticsLog.log("mpv", "stop-requested surface=\(surface) handle=\(handle)")"#
        )
    )
    rejectTeardownReceiptMutation(
        "load-token data",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: requestedReceipt,
            with: #"DiagnosticsLog.log("mpv", "stop-requested surface=\(surface) loadToken=\(activeLoadToken)")"#
        )
    )
    rejectTeardownReceiptMutation(
        "user data",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: requestedReceipt,
            with: #"DiagnosticsLog.log("mpv", "stop-requested surface=\(surface) url=\(playUrl)")"#
        )
    )
    rejectTeardownReceiptMutation(
        "missing ambient classification",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: surfaceClassification,
            with: #"let surface = isFullPlayerPresentation || probeChannel.description == "player" ? "player" : "trailer""#
        )
    )
    rejectTeardownReceiptMutation(
        "missing player classification",
        original: source,
        mutated: replacingFirst(
            source,
            after: "    func stop() {",
            target: surfaceClassification,
            with: #"let surface = isFullPlayerPresentation || probeChannel.description == "ambient" ? "ambient" : "ambient""#
        )
    )
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
                private var lastFramePresentationDecisionSignature: String?
                private var lastReceiptFrameDropsPerMinute: Double?
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
                    .play(mpvSurfacePlayback.url, headers: mpvSurfacePlayback.headers,
                          audioSidecar: mpvSurfacePlayback.audioSidecar,
                          isDolbyVision: mpvSurfacePlayback.isDolbyVision)
                    .live(mpvSurfacePlayback.live)
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
            searchAfter: #"let status = mpv_set_property_string(handle, "cscale", restoreValue)"#,
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
            searchAfter: #"let status = mpv_set_property_string(handle, "cscale", restoreValue)"#,
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
            end: #"VXProbe.event(self.probeChannel, "endfile eof")"#,
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

    let tvReceiptPasses: (String) -> Bool = { source in
        guard let section = sourceSlice(
            source,
            after: "private func maybeLogFrameDropReceipt()",
            from: "private func maybeLogFrameDropReceipt()",
            to: "/// Live playback numbers"
        ) else { return false }
        return section.contains("rawOutputDelta30s=")
            && section.contains("settledOutputDelta30s=")
            && section.contains("cacheStateAtReceipt=")
            && section.contains("drawableAcquire=")
            && section.contains("drawableAcquireWaitMs=")
            && section.contains("presentCallback=unavailable-tvos")
            && section.contains("starved")
            && !section.contains("outputDropClass=")
            && !section.contains("delta30s=")
            && !section.contains("draw=")
            && !section.contains("nextDrawableWaitMs=")
            && !section.contains("presentLatency=")
            && !section.contains("presentSample30=")
            && !section.contains("presentSampleMs=")
    }
    let tvSource = sources["TVPlayerView.swift"]!
    check(
        "frame source contract: tvOS receipt reports raw and settled output drops plus drawable acquisition, not a nonexistent present callback",
        tvReceiptPasses(tvSource)
    )
    if let mutated = replacingFirst(
        tvSource,
        after: "let presentationText: String = {",
        target: "presentCallback=unavailable-tvos",
        with: "presentSample30=%d/%d"
    ) {
        check(
            "frame source contract mutation: legacy presentation sample is rejected",
            !tvReceiptPasses(mutated)
        )
    } else {
        check("frame source contract mutation: legacy presentation sample is constructed", false)
    }
    if let mutated = replacingFirst(
        tvSource,
        after: "let presentationText: String = {",
        target: "drawableAcquireWaitMs=",
        with: "waitMs="
    ) {
        check(
            "frame source contract mutation: drawable-acquire terminology is required",
            !tvReceiptPasses(mutated)
        )
    } else {
        check("frame source contract mutation: old drawable wait label is constructed", false)
    }

    let eventPasses: (String) -> Bool = { source in
        guard let section = sourceSlice(
            source,
            after: "case MPVProperty.frameDropCount:",
            from: "case MPVProperty.frameDropCount:",
            to: "case MPVProperty.decoderFrameDropCount:"
        ) else { return false }
        let boundedProperties = [
            "\"demuxer-cache-duration\"",
            "\"cache-buffering-state\"",
            "\"paused-for-cache\"",
            "\"demuxer-cache-state/underrun\"",
            "\"demuxer-cache-state/idle\"",
            "generation=\\(sample.generation)",
            "outputDelta=\\(sample.delta)",
        ]
        return section.components(separatedBy: "if sample.shouldEmitOutputContext {").count - 1 == 1
            && section.components(separatedBy: "DiagnosticsLog.log(").count - 1 == 1
            && section.components(separatedBy: "handle: handle").count - 1 == 5
            && section.components(separatedBy: "?? \"na\"").count - 1 == 5
            && boundedProperties.allSatisfy(section.contains)
            && section.contains("decoder: false")
            && section.contains("if sample.delta > 0, presentationSettled {")
            && !section.contains("handle: self.mpv")
    }
    let controllerSource = sources["MPVMetalViewController.swift"]!
    check(
        "frame source contract: frame-drop sampling uses local event handle",
        sourceSlice(
            controllerSource,
            after: "while true {",
            from: "guard let handle = self.mpv else { break }",
            to: "let event = mpv_wait_event(handle, 0)"
        ) != nil && eventPasses(controllerSource)
    )
    if let mutated = replacingFirst(
        controllerSource,
        after: "case MPVProperty.frameDropCount:",
        target: "if sample.shouldEmitOutputContext {",
        with: "if true {"
    ) {
        check(
            "frame source contract mutation: output context guard is required",
            !eventPasses(mutated)
        )
    } else {
        check("frame source contract mutation: output context guard is constructed", false)
    }
    if let mutated = replacingFirst(
        controllerSource,
        after: "case MPVProperty.frameDropCount:",
        target: "handle: handle",
        with: "handle: self.mpv"
    ) {
        check(
            "frame source contract mutation: nullable mpv reread is rejected",
            !eventPasses(mutated)
        )
    } else {
        check("frame source contract mutation: nullable mpv reread is constructed", false)
    }
    if let mutated = replacingFirst(
        controllerSource,
        after: "case MPVProperty.frameDropCount:",
        target: "decoder: false",
        with: "decoder: true"
    ) {
        check(
            "frame source contract mutation: decoder counter confusion is rejected",
            !eventPasses(mutated)
        )
    } else {
        check("frame source contract mutation: decoder counter confusion is constructed", false)
    }
    let helperBlock = sourceSlice(
        controllerSource,
        after: "private func diagnosticDouble(_ name: String) -> Double? {",
        from: "private func diagnosticDouble(_ name: String) -> Double? {",
        to: "private func diagnosticString"
    )
    check(
        "frame source contract: double and flag handle overloads delegate",
        helperBlock?.contains("return diagnosticDouble(name, handle: handle)") == true
            && helperBlock?.contains("return diagnosticFlag(name, handle: handle)") == true
    )
    if let source = sources["MPVMetalViewController.swift"] {
        teardownReceiptWiring(source: source)
    } else {
        check("mpv teardown receipts: governed source is readable", false)
    }
}

@main
private enum FramePresentationPolicyTests {
    @MainActor
    static func main() {
        productionWiring()
        policy()
        cscaleArmDecision()
        resetSafeCounters()
        outputDropContextEmission()
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
    private static func cscaleArmDecision() {
        typealias Policy = TVOSFramePresentationPolicy

        // THE FIX A core: predicate passes AND the prior cscale read is empty/nil (the `.standard`
        // libplacebo-default case) must ARM on the default sentinel, not bail. The old guard bailed
        // on an unreadable prior, so the mitigation could never arm on exactly its 4K DV target.
        check("nil prior arms on default sentinel",
              Policy.armDecision(shouldApply: true, alreadyApplied: false, priorCscale: nil)
                == .arm(prior: Policy.defaultCscaleToken))
        check("empty prior arms on default sentinel",
              Policy.armDecision(shouldApply: true, alreadyApplied: false, priorCscale: "")
                == .arm(prior: Policy.defaultCscaleToken))
        check("whitespace-only prior arms on default sentinel",
              Policy.armDecision(shouldApply: true, alreadyApplied: false, priorCscale: "  ")
                == .arm(prior: Policy.defaultCscaleToken))

        // A real recorded scaler is preserved verbatim so restore returns to it.
        check("real prior is recorded verbatim",
              Policy.armDecision(shouldApply: true, alreadyApplied: false,
                                 priorCscale: "ewa_lanczossharp")
                == .arm(prior: "ewa_lanczossharp"))
        check("real prior is trimmed",
              Policy.armDecision(shouldApply: true, alreadyApplied: false,
                                 priorCscale: " ewa_lanczossharp ")
                == .arm(prior: "ewa_lanczossharp"))

        // Already applied does not re-arm; ineligible restores.
        check("already applied makes no change",
              Policy.armDecision(shouldApply: true, alreadyApplied: true, priorCscale: nil)
                == .noChange)
        check("ineligible restores regardless of prior",
              Policy.armDecision(shouldApply: false, alreadyApplied: false,
                                 priorCscale: "ewa_lanczossharp") == .restore)
        check("ineligible restores even when already applied",
              Policy.armDecision(shouldApply: false, alreadyApplied: true, priorCscale: nil)
                == .restore)

        // Restore maps the sentinel back to the libplacebo DEFAULT (empty = mpv unset), never a
        // wrong literal scaler; a real scaler restores verbatim.
        check("sentinel restores to default (empty), not a literal scaler",
              Policy.restoreCscaleValue(prior: Policy.defaultCscaleToken) == "")
        check("real scaler restores verbatim",
              Policy.restoreCscaleValue(prior: "ewa_lanczossharp") == "ewa_lanczossharp")

        // FIX B shares this UHD gate with the mitigation predicate.
        check("UHD gate: 3840x2160 is UHD",
              Policy.isUltraHighDefinition(width: 3_840, height: 2_160))
        check("UHD gate: portrait 2160x3840 is UHD",
              Policy.isUltraHighDefinition(width: 2_160, height: 3_840))
        check("UHD gate: 1920x1080 is not UHD",
              !Policy.isUltraHighDefinition(width: 1_920, height: 1_080))
        check("UHD gate: 3840x1599 is not UHD",
              !Policy.isUltraHighDefinition(width: 3_840, height: 1_599))
        check("UHD gate: unknown 0x0 is not UHD (fail-open signal)",
              !Policy.isUltraHighDefinition(width: 0, height: 0))
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
    private static func outputDropContextEmission() {
        let accumulator = FramePresentationDiagnosticsAccumulator()
        accumulator.begin(generation: 7, now: 100, frameDropRaw: 10, decoderDropRaw: 3)
        let first = accumulator.recordDrop(raw: 12, decoder: false)
        check("first positive output delta emits context",
              first?.delta == 2 && first?.shouldEmitOutputContext == true)
        check("later output delta in interval suppresses context",
              accumulator.recordDrop(raw: 13, decoder: false)?.shouldEmitOutputContext == false)

        let decoderAccumulator = FramePresentationDiagnosticsAccumulator()
        decoderAccumulator.begin(generation: 7, now: 100, frameDropRaw: 10, decoderDropRaw: 3)
        check("decoder delta never emits output context",
              decoderAccumulator.recordDrop(raw: 5, decoder: true)?.shouldEmitOutputContext == false)

        _ = accumulator.takeSnapshot(
            now: 110, subtitleCodec: nil, subtitleSource: "off",
            activeCscale: nil, mitigationPriorCscale: nil,
            mitigationApplied: false, mitigationGate: "off"
        )
        check("takeSnapshot rearms output context",
              accumulator.recordDrop(raw: 14, decoder: false)?.shouldEmitOutputContext == true)

        accumulator.begin(generation: 8, now: 120, frameDropRaw: 40, decoderDropRaw: 4)
        check("new generation rearms output context",
              accumulator.recordDrop(raw: 41, decoder: false)?.shouldEmitOutputContext == true)

        accumulator.begin(generation: 9, now: 130, frameDropRaw: 50, decoderDropRaw: 4)
        let reset = accumulator.recordDrop(raw: 2, decoder: false)
        check("output context uses reset-safe delta",
              reset?.delta == 2 && reset?.shouldEmitOutputContext == true)
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
