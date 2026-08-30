// Focused standalone regression harness:
// xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
//   -D TRICKPLAY_E2E_POLICY_TESTING -parse-as-library \
//   app/SourcesShared/CommunityTrickplay.swift app/Tests/TrickplayEndToEndCorrectionTests.swift \
//   -o /tmp/trickplay-e2e-correction-tests && /tmp/trickplay-e2e-correction-tests

import Foundation

@main
private enum TrickplayEndToEndCorrectionTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testActualCaptureTimestampsSurviveVTTAndResumeGaps()
        testPartialCommunityCoverageFallsBack()
        testLegacyIntervalOnlyArtifactRemainsSupported()
        testHostileVTTCoordinatesFailSoft()
        testBoundedRetentionContinuesPastSixHundred()
        testBoundedRetentionHonorsSmallerFleetMaximum()
        testRetainedCadencePreservesCoverageAndSeekGaps()
        testPreStrideGapEvidenceSurvivesAdversarialSheetStrides()
        testMediaGenerationRejectsStaleEpisodeCallback()
        testFetchEpochClaimRejectsABA()
        testCommunityFetchContract()
        testStoreAndUICompletionContract()
        testProtectedUHDHDRCaptureContract()
        testProductionWiringUsesThePolicies()
        print("TrickplayEndToEndCorrectionTests: \(passed)/\(passed) passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(file):\(line): \(message)")
        }
        passed += 1
    }

    private static func testActualCaptureTimestampsSurviveVTTAndResumeGaps() {
        let times = [120.0, 130.0, 400.0, 410.0]
        let vtt = TrickplayTimeline.makeVTT(
            captureTimes: times,
            nominalInterval: 10,
            cols: 2,
            tileW: 320,
            tileH: 180
        )
        expect(vtt != nil, "valid actual capture timestamps must produce a VTT")
        expect(
            vtt!.contains("00:02:00.000 --> 00:02:10.000")
                && vtt!.contains("00:06:40.000 --> 00:06:50.000"),
            "VTT cue starts must retain resume-position capture timestamps"
        )
        expect(
            !vtt!.contains("00:02:20.000 --> 00:06:40.000"),
            "a playback gap must not be represented as community thumbnail coverage"
        )

        let parsed = TrickplayTimeline.parseVTT(
            vtt!,
            frameCount: times.count,
            cols: 2,
            tileW: 320,
            tileH: 180
        )
        expect(parsed?.map(\.start) == times, "downloaded VTT must restore the actual capture timeline")
        expect(
            parsed?[2].tileIndex == 2 && parsed?[2].x == 0 && parsed?[2].y == 180,
            "timestamp cues must retain their row-major sprite coordinates"
        )
        expect(
            cueIndex(at: 150, parsed: parsed, frameCount: times.count) == nil,
            "the gap after a pre-seek capture must fall through to local cache"
        )
        expect(
            cueIndex(at: 400, parsed: parsed, frameCount: times.count) == 2,
            "the resumed capture must become available at its actual playback time"
        )
    }

    private static func testPartialCommunityCoverageFallsBack() {
        let parsed = TrickplayTimeline.makeCues(
            captureTimes: [40, 50],
            nominalInterval: 10,
            cols: 2,
            tileW: 320,
            tileH: 180
        )
        expect(
            cueIndex(at: 45, parsed: parsed, frameCount: 2) == 0,
            "a time inside community coverage should use its community tile"
        )
        expect(
            cueIndex(at: 39.999, parsed: parsed, frameCount: 2) == nil,
            "a partial sheet must not mask a local frame before its first cue"
        )
        expect(
            cueIndex(at: 60, parsed: parsed, frameCount: 2) == nil,
            "a partial sheet must not clamp beyond its final cue"
        )
        expect(
            cueIndex(at: -1, parsed: parsed, frameCount: 2) == nil,
            "negative scrub time must fail soft to local lookup"
        )
    }

    private static func testLegacyIntervalOnlyArtifactRemainsSupported() {
        expect(
            cueIndex(at: 0, parsed: nil, frameCount: 2) == 0
                && cueIndex(at: 19.999, parsed: nil, frameCount: 2) == 1,
            "an older artifact without advertised VTT must retain interval-based lookup"
        )
        expect(
            cueIndex(at: 20, parsed: nil, frameCount: 2) == nil,
            "legacy lookup must still return nil outside its real finite span"
        )
        expect(
            TrickplayTimeline.parseVTT(
                "WEBVTT\n\nnot a cue\n",
                frameCount: 2,
                cols: 2,
                tileW: 320,
                tileH: 180
            ) == nil,
            "a malformed advertised VTT must be rejected instead of inventing coverage"
        )
        expect(
            cueIndex(at: 5, parsed: [], frameCount: 2) == nil,
            "an advertised but unavailable VTT must leave community coverage empty for local fallback"
        )
    }

    private static func testHostileVTTCoordinatesFailSoft() {
        let extremeY = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        sprite#xywh=0,\(Int.max),1,1

        """
        expect(
            TrickplayTimeline.parseVTT(
                extremeY,
                frameCount: 2,
                cols: 2,
                tileW: 1,
                tileH: 1
            ) == nil,
            "an extreme representable row coordinate must fail soft instead of overflowing tile indexing"
        )

        let extremeX = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        sprite#xywh=\(Int.max),0,1,1

        """
        expect(
            TrickplayTimeline.parseVTT(
                extremeX,
                frameCount: 2,
                cols: 2,
                tileW: 1,
                tileH: 1
            ) == nil,
            "an extreme representable column coordinate must fail soft to local fallback"
        )
    }

    private static func testBoundedRetentionContinuesPastSixHundred() {
        var retainedTimes: [Double] = []
        for capture in 0...1_200 {
            let candidates = retainedTimes + [Double(capture) * 10]
            let retained = TrickplaySessionFrameRetention.retainedIndices(
                captureTimes: candidates,
                limit: 600
            )
            retainedTimes = retained.map { candidates[$0] }
        }

        expect(retainedTimes.count == 600, "the whole-session capture buffer must stay bounded at 600")
        expect(
            retainedTimes.first == 0 && retainedTimes.last == 12_000,
            "bounded decimation must preserve both the opening and latest observed capture"
        )
        expect(
            zip(retainedTimes, retainedTimes.dropFirst()).allSatisfy(<),
            "retained whole-session captures must remain strictly time ordered"
        )
        expect(
            retainedTimes.contains { abs($0 - 6_000) <= 40 },
            "decimation must retain representative middle coverage, not only opening and tail frames"
        )
    }

    private static func testBoundedRetentionHonorsSmallerFleetMaximum() {
        let fleetMaximum = 37
        let captureLimit = TrickplaySessionFrameRetention.captureLimit(
            frameBoundsMax: fleetMaximum
        )
        expect(captureLimit == fleetMaximum, "a validated non-default fleet maximum must be retained exactly")
        expect(
            TrickplaySessionFrameRetention.captureLimit(frameBoundsMax: 1) == 2,
            "capture retention must keep the sprite builder's two-frame floor"
        )

        var retainedTimes: [Double] = []
        for capture in 0...200 {
            let candidates = retainedTimes + [Double(capture) * 10]
            let retained = TrickplaySessionFrameRetention.retainedIndices(
                captureTimes: candidates,
                limit: captureLimit
            )
            retainedTimes = retained.map { candidates[$0] }
        }
        expect(
            retainedTimes.count == fleetMaximum,
            "capture must never cross a smaller live frame maximum and poison later uploads"
        )
        expect(
            retainedTimes.first == 0 && retainedTimes.last == 2_000,
            "smaller-bound decimation must keep accepting and retain the newest capture"
        )
        expect(
            retainedTimes.contains { abs($0 - 1_000) <= 80 },
            "smaller-bound decimation must still represent the middle of the observed session"
        )
    }

    private static func testRetainedCadencePreservesCoverageAndSeekGaps() {
        var retainedTimes: [Double] = []
        for capture in 0...1_200 {
            let candidates = retainedTimes + [Double(capture) * 10]
            let retained = TrickplaySessionFrameRetention.retainedIndices(
                captureTimes: candidates,
                limit: 600
            )
            retainedTimes = retained.map { candidates[$0] }
        }
        let retainedCadence = TrickplayTimeline.nominalCadence(
            captureTimes: retainedTimes,
            fallbackInterval: 10
        )
        expect(
            retainedCadence == 20,
            "whole-session decimation must advertise its retained ordinary cadence instead of stale ten seconds"
        )

        let sheetStride = Int(ceil(Double(retainedTimes.count) / 80))
        let targetCount = Int(ceil(Double(retainedTimes.count) / Double(sheetStride)))
        let selectedIndices = TrickplaySessionFrameRetention.evenlySpacedIndices(
            count: retainedTimes.count,
            targetCount: targetCount
        )
        let selectedTimes = selectedIndices.map { retainedTimes[$0] }
        expect(
            selectedTimes.first == retainedTimes.first && selectedTimes.last == retainedTimes.last,
            "additional sheet decimation must preserve both retained timeline endpoints"
        )
        let effectiveInterval = retainedCadence * Double(sheetStride)
        let expectedFrames = max(1, Int((12_000 / effectiveInterval).rounded()))
        let advertisedCoverage = Double(selectedTimes.count) / Double(expectedFrames)
        expect(
            advertisedCoverage >= 0.98,
            "retained cadence must keep worker metadata coverage near the continuous-session truth"
        )
        let continuousFences = TrickplayTimeline.selectedCueEndFences(
            retainedCaptureTimes: retainedTimes,
            selectedIndices: selectedIndices,
            retainedCadence: retainedCadence
        )!
        let continuousCues = TrickplayTimeline.makeCues(
            captureTimes: selectedTimes,
            nominalInterval: effectiveInterval,
            gapFenceInterval: retainedCadence,
            cueEndFences: continuousFences,
            cols: 10,
            tileW: 1,
            tileH: 1
        )!
        let sampleTimes = Array(stride(from: 0.0, through: 12_000.0, by: 10))
        let coveredSamples = sampleTimes.filter { time in
            TrickplayTimeline.cue(
                at: time,
                parsedCues: continuousCues,
                frameCount: continuousCues.count,
                legacyInterval: effectiveInterval,
                cols: 10,
                tileW: 1,
                tileH: 1
            ) != nil
        }
        expect(
            Double(coveredSamples.count) / Double(sampleTimes.count) >= 0.98,
            "a continuous post-cap session must remain near-continuously covered after sheet decimation"
        )

        for sparseSeekTimes in [[120.0, 400.0], [120.0, 400.0, 800.0]] {
            let sparseCadence = TrickplayTimeline.nominalCadence(
                captureTimes: sparseSeekTimes,
                fallbackInterval: 10
            )
            expect(
                sparseCadence == 10,
                "sparse seek-only timestamps cannot manufacture a coarser ordinary cadence"
            )
            let sparseIndices = Array(sparseSeekTimes.indices)
            let sparseFences = TrickplayTimeline.selectedCueEndFences(
                retainedCaptureTimes: sparseSeekTimes,
                selectedIndices: sparseIndices,
                retainedCadence: sparseCadence
            )!
            let sparseCues = TrickplayTimeline.makeCues(
                captureTimes: sparseSeekTimes,
                nominalInterval: sparseCadence,
                gapFenceInterval: sparseCadence,
                cueEndFences: sparseFences,
                cols: 2,
                tileW: 1,
                tileH: 1
            )!
            expect(
                TrickplayTimeline.cue(
                    at: sparseSeekTimes.count == 2 ? 200 : 500,
                    parsedCues: sparseCues,
                    frameCount: sparseCues.count,
                    legacyInterval: sparseCadence,
                    cols: 2,
                    tileW: 1,
                    tileH: 1
                ) == nil,
                "a real sparse seek gap must remain available to persistent local fallback"
            )
        }
        let stridedSeekCues = TrickplayTimeline.makeCues(
            captureTimes: [120, 400],
            nominalInterval: 160,
            gapFenceInterval: 20,
            cueEndFences: TrickplayTimeline.selectedCueEndFences(
                retainedCaptureTimes: [120, 400],
                selectedIndices: [0, 1],
                retainedCadence: 20
            )!,
            cols: 2,
            tileW: 1,
            tileH: 1
        )!
        expect(
            TrickplayTimeline.cue(
                at: 200,
                parsedCues: stridedSeekCues,
                frameCount: stridedSeekCues.count,
                legacyInterval: 160,
                cols: 2,
                tileW: 1,
                tileH: 1
            ) == nil,
            "a larger sheet stride must not bridge the real 120-to-400 seek gap"
        )
    }

    private static func testPreStrideGapEvidenceSurvivesAdversarialSheetStrides() {
        for sheetStride in [8, 15, 30] {
            let retainedCadence = 20.0
            let firstBlockDeltas = [10.0]
                + Array(repeating: retainedCadence, count: sheetStride - 2)
                + [50.0]
            let allDeltas = firstBlockDeltas
                + Array(repeating: retainedCadence, count: sheetStride)
            var retainedTimes = [120.0]
            for delta in allDeltas {
                retainedTimes.append(retainedTimes.last! + delta)
            }
            let selectedIndices = [0, sheetStride, sheetStride * 2]
            let selectedTimes = selectedIndices.map { retainedTimes[$0] }
            let effectiveInterval = retainedCadence * Double(sheetStride)
            expect(
                selectedTimes[1] - selectedTimes[0] == effectiveInterval + retainedCadence,
                "the adversarial selected delta must equal the old post-stride discontinuity threshold"
            )

            let cueEndFences = TrickplayTimeline.selectedCueEndFences(
                retainedCaptureTimes: retainedTimes,
                selectedIndices: selectedIndices,
                retainedCadence: retainedCadence
            )
            let preGapTime = retainedTimes[sheetStride - 1]
            expect(
                cueEndFences?[0] == preGapTime + retainedCadence,
                "pre-stride analysis must carry the last pre-gap coverage boundary through sheet sampling"
            )
            let vtt = TrickplayTimeline.makeVTT(
                captureTimes: selectedTimes,
                nominalInterval: effectiveInterval,
                gapFenceInterval: retainedCadence,
                cueEndFences: cueEndFences!,
                cols: 2,
                tileW: 1,
                tileH: 1
            )!
            let parsed = TrickplayTimeline.parseVTT(
                vtt,
                frameCount: selectedTimes.count,
                cols: 2,
                tileW: 1,
                tileH: 1
            )
            expect(
                TrickplayTimeline.cue(
                    at: preGapTime + retainedCadence + 1,
                    parsedCues: parsed,
                    frameCount: selectedTimes.count,
                    legacyInterval: effectiveInterval,
                    cols: 2,
                    tileW: 1,
                    tileH: 1
                ) == nil,
                "sheet stride \(sheetStride) must not bridge a genuine gap hidden at the old threshold"
            )
        }
    }

    private static func testMediaGenerationRejectsStaleEpisodeCallback() {
        expect(
            TrickplayPreviewReadGate.accepts(
                requestToken: 41,
                requestMediaKey: "episode-a",
                currentToken: 41,
                currentMediaKey: "episode-a"
            ),
            "the current episode's current read may publish"
        )
        expect(
            !TrickplayPreviewReadGate.accepts(
                requestToken: 41,
                requestMediaKey: "episode-a",
                currentToken: 42,
                currentMediaKey: "episode-b"
            ),
            "a true episode reconfigure must reject the outgoing read callback"
        )
        expect(
            !TrickplayPreviewReadGate.accepts(
                requestToken: 41,
                requestMediaKey: "episode-a",
                currentToken: 43,
                currentMediaKey: "episode-a"
            ),
            "a later return to the same media key must not revive an old generation"
        )
    }

    private static func testFetchEpochClaimRejectsABA() {
        let claims: [(String, Bool)] = [("A1", TrickplayFetchClaim.accepts(requestEpoch: 1, requestKey: "a", currentEpoch: 3, currentKey: "a")), ("B2", TrickplayFetchClaim.accepts(requestEpoch: 2, requestKey: "b", currentEpoch: 3, currentKey: "a")), ("A3", TrickplayFetchClaim.accepts(requestEpoch: 3, requestKey: "a", currentEpoch: 3, currentKey: "a"))]
        let published = claims.filter { $0.1 }.map { $0.0 }; let cleared = claims.filter { $0.1 }.map { $0.0 }
        expect(published == ["A3"] && cleared == ["A3"], "only A3 may publish and clear the retained fetch handle")
    }

    private static func testCommunityFetchContract() {
        let community = source("app/SourcesShared/CommunityTrickplay.swift")
        guard let fetchStart = community.range(of: "enum FetchUnavailableReason"),
              let fetchEnd = community.range(of: "// MARK: - Upload-after-generate", range: fetchStart.upperBound..<community.endIndex) else {
            fatalError("cannot inspect community fetch boundary")
        }
        let fetch = community[fetchStart.lowerBound..<fetchEnd.lowerBound]
        expect(["enum FetchUnavailableReason", "metadataUnavailable", "metadataInvalid", "spriteUnavailable", "advertisedIndexInvalid",
                "var diagnosticCode: String", "metadata-unavailable", "metadata-invalid", "sprite-unavailable", "advertised-index-invalid",
                "case hit(Sheet)", "unavailable(FetchUnavailableReason)", "cancelled"].allSatisfy { fetch.contains($0) }
                    && !fetch.contains("String(describing:"),
               "community fetch must expose only finite typed outcomes and transport-free diagnostic codes")
        expect(["ContinuousClock.now.advanced(by: .seconds(3))", "ContinuousClock.now.advanced(by: .seconds(5))", "Task.sleep(until:",
                "withTaskGroup", "group.cancelAll()", "group.addTask { .sprite", "group.addTask { .vtt"].allSatisfy { fetch.contains($0) },
               "metadata/assets must use absolute 3s/5s structured deadlines")
        expect(fetch.contains("enum FetchStatus: Sendable") && fetch.contains("statusCode: Int") && !fetch.contains("cues = []") && !fetch.contains("?? []")
            && fetch.contains("return .unavailable(.advertisedIndexInvalid)"),
               "asset groups must pass typed status data and never manufacture an advertised-index hit")
    }

    private static func testStoreAndUICompletionContract() {
        let store = source("app/SourcesShared/ScrubThumbnails.swift")
        let tv = source("app/SourcesTV/TVPlayerView.swift")
        guard let showStart = store.range(of: "func show(time: Double)"), let clearStart = store.range(of: "func clear()", range: showStart.upperBound..<store.endIndex),
              let clearEnd = store.range(of: "private func previewStateForRemoteState", range: clearStart.upperBound..<store.endIndex),
              let completionStart = store.range(of: "private func completeCommunityFetch("),
              let completionEnd = store.range(of: "/// The raw `tmdb:", range: completionStart.upperBound..<store.endIndex),
              let uiStart = tv.range(of: "private var trickplayControls"), let bubbleStart = tv.range(of: "private func trickplayBubble", range: uiStart.upperBound..<tv.endIndex) else {
            fatalError("cannot inspect trickplay completion boundaries")
        }
        let show = store[showStart.lowerBound..<clearStart.lowerBound]; let clear = store[clearStart.lowerBound..<clearEnd.lowerBound]
        let completion = store[completionStart.lowerBound..<completionEnd.lowerBound]; let ui = tv[uiStart.lowerBound..<bubbleStart.lowerBound]
        expect(["private var communityFetchTask: Task<Void, Never>?", "private var communityFetchEpoch", "private var communityFetchKey: String?", "private enum CommunityRemotePhase", "enum PreviewState", "private var activeScrubTime: Double?", "private var pendingLocalReadToken: Int?"].allSatisfy { store.contains($0) } && store.contains("private func cancelCommunityFetch()") && store.contains("deinit { communityFetchTask?.cancel() }") && !store.contains("deinit { cancelCommunityFetch() }") && store.contains("private func completeCommunityFetch("), "the store must own one keyed task, cancellation, epoch, phase, state, and pending read")
        let communityAt = show.range(of: "communitySheet")!.lowerBound
        let memoryAt = show.range(of: "memoryImage")!.lowerBound
        expect(!show.contains("CommunityTrickplay.fetch") && show.contains("activeScrubTime = time") && show.contains("image = nil") && communityAt < memoryAt && memoryAt < show.range(of: "imageAsync")!.lowerBound,
               "show(time:) must never fetch and must retain community, memory, then disk fallback order")
        expect(store.contains("TrickplayFetchClaim.accepts(") && store.contains("if let activeTime = activeScrubTime") && store.contains("show(time: activeTime)")
            && store.contains("pendingLocalReadToken") && store.contains("communityFetchTask = nil") && store.contains("communityFetchKey = nil"),
               "accepted completion must check key plus epoch and re-resolve the active scrub time")
        let claim = completion.range(of: "TrickplayFetchClaim.accepts")!.lowerBound
        expect(claim < completion.range(of: "communityFetchTask = nil")!.lowerBound && claim < completion.range(of: "communityFetchKey = nil")!.lowerBound
            && claim < completion.range(of: "switch result")!.lowerBound,
               "stale completion must be rejected before it can clear a newer task")
        guard let stateStart = store.range(of: "private func previewStateForRemoteState"), let stateEnd = store.range(of: "/// Heavy frame processing", range: stateStart.upperBound..<store.endIndex) else { fatalError("cannot inspect preview-state aggregation") }
        let state = store[stateStart.lowerBound..<stateEnd.lowerBound]
        expect(clear.contains("showToken &+= 1") && clear.contains("activeScrubTime = nil") && clear.contains("pendingLocalReadToken = nil") && clear.contains("previewState = .hidden") && show.contains("resolved == nil ? self.previewStateForRemoteState() : .ready") && state.contains("case .idle: return .unavailable") && state.contains("case .loading: return .loading") && state.contains("case .settled: return .unavailable") && store.contains("communityRemotePhase = .loading"), "clear must hide, while a completed local miss aggregates idle/settled as unavailable and loading as loading")
        expect(ui.contains("Loading previews…") && ui.contains("Previews unavailable") && ui.contains("previewState")
            && ui.contains("scrubThumbnails.previewState != .hidden") && ui.contains("value: scrubThumbnails.previewState") && !ui.contains("image != nil || scrubThumbnails.previewStatus"),
               "the TV scrubber must use PreviewState for text-only states and height")
        expect(completion.components(separatedBy: "VXProbe.log(\"tp\"").count == 2 && completion.contains("case .unavailable(let reason)") && completion.contains("communityUnavailableReason = reason") && completion.contains("detail=\\(diagnosticDetail)") && completion.contains("outcome=") && !completion.contains("key=") && !completion.contains("url=") && !completion.contains("error="),
               "fetch completion diagnostics must preserve a fixed unavailable category and remain redacted")
    }

    private static func testProtectedUHDHDRCaptureContract() {
        let tv = source("app/SourcesTV/TVPlayerView.swift")
        guard let start = tv.range(of: "private func maybeCaptureLocalTrickplay"), let end = tv.range(of: "/// UHD Dolby Vision", range: start.upperBound..<tv.endIndex) else {
            fatalError("cannot inspect UHD-HDR capture guard")
        }
        let captureGate = tv[start.lowerBound..<end.lowerBound]
        expect(captureGate.contains("shouldSkipLocalTrickplayCaptureForUHDHDR()") && captureGate.contains("captureTrickplayFrame(at: time)") && captureGate.range(of: "shouldSkipLocalTrickplayCaptureForUHDHDR()")!.lowerBound < captureGate.range(of: "captureTrickplayFrame(at: time)")!.lowerBound && tv.contains("private func shouldSkipLocalTrickplayCaptureForUHDHDR() -> Bool") && tv.contains("isCurrentContentUHDHDR()") && tv.contains("isHDR || player.contentIsDolbyVision || player.hdrAvailable || sourceAdvertisesHDR") && tv.contains("hint.contains(\"hdr\") || hint.contains(\"hlg\")") && tv.contains("isHDR = false") && !tv.contains("screenshot-raw") && tv.contains("captureFrameJPEGData"), "all UHD HDR classes must bypass the only local inline capture path while remote/provider previews remain intact")
    }

    private static func testProductionWiringUsesThePolicies() {
        let community = source("app/SourcesShared/CommunityTrickplay.swift")
        let store = source("app/SourcesShared/ScrubThumbnails.swift")
        guard let configureStart = store.range(of: "func configure(localCacheKey: String?)"),
              let communityStart = store.range(
                  of: "func configureCommunity(",
                  range: configureStart.upperBound..<store.endIndex
              ) else {
            fatalError("cannot inspect the stable media-key configure boundary")
        }
        let localConfigure = store[configureStart.lowerBound..<communityStart.lowerBound]
        expect(
            community.contains("let parsed = TrickplayTimeline.parseVTT(")
                && community.contains("guard let vtt = TrickplayTimeline.makeVTT(")
                && community.contains("cues = parsed")
                && community.contains("parsedCues: cues"),
            "production must consume and publish the tested timestamp timeline"
        )
        expect(
            store.contains("TrickplaySessionFrameRetention.retainedIndices(")
                && !store.contains("sessionFrames.count < 600")
                && !store.contains("limit: 600")
                && store.contains("RemoteConfig.snapshot.trickplayFrameBounds.max")
                && store.contains("frameBoundsMax:")
                && community.contains("TrickplaySessionFrameRetention.evenlySpacedIndices("),
            "production must admit later captures without exceeding the live validated frame maximum"
        )
        expect(
            store.contains("intervalS: sessionNominalInterval")
                && store.contains("interval: sessionNominalInterval")
                && community.contains("let retainedInterval = TrickplayTimeline.nominalCadence(")
                && community.contains("effectiveInterval = retainedInterval * Double(stride)")
                && community.contains("TrickplayTimeline.selectedCueEndFences(")
                && community.contains("cueEndFences: picked.cueEndFences")
                && community.contains("gapFenceInterval: retainedInterval"),
            "coverage, metadata, and VTT must share retained cadence plus propagated pre-stride gap evidence"
        )
        expect(
            localConfigure.contains("showToken &+= 1")
                && store.contains("TrickplayPreviewReadGate.accepts("),
            "production must generation-fence async local reads on media reconfigure"
        )
    }

    private static func source(_ relativePath: String) -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try! String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func cueIndex(
        at time: Double,
        parsed: [TrickplayTimelineCue]?,
        frameCount: Int
    ) -> Int? {
        TrickplayTimeline.cue(
            at: time,
            parsedCues: parsed,
            frameCount: frameCount,
            legacyInterval: 10,
            cols: 2,
            tileW: 320,
            tileH: 180
        )?.tileIndex
    }
}
