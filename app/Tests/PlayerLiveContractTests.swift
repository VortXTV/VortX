// Executable Beta 7 live-player contract.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/player-live-contract \
//     app/Sources/Player/DVPlaybackPolicy.swift \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/MultiAudioPolicy.swift \
//     app/Sources/Player/SubtitleRenditionPolicy.swift \
//     app/Tests/PlayerLiveContractTests.swift && /tmp/player-live-contract
//
// This suite drives the production byte buffer, playlist window, request lookup, display-request ledger and
// media-selection state. The final wiring assertions are deliberately small: they prove the AVFoundation and
// Network-framework owners call the executable production seams above, while the behavior itself is exercised
// rather than mirrored here.

import Foundation

// Standalone-compilation stub for the buffer's production default. Tests pass an explicit tiny byte floor so a
// long-window eviction can execute without allocating the app's 64 MiB minimum.
struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func append(_ bytes: [UInt8], to buffer: VortXRemuxBuffer) {
    bytes.withUnsafeBufferPointer { raw in
        guard let base = raw.baseAddress else { return }
        buffer.append(base, count: raw.count)
    }
}

private func playlistSegmentIDs(_ lines: [String]) -> [Int] {
    lines.compactMap { line in
        guard line.hasPrefix("seg"), line.hasSuffix(".m4s") else { return nil }
        return Int(line.dropFirst(3).dropLast(4))
    }
}

private func sourceSection(_ source: String?, from start: String, to end: String) -> String? {
    guard let source,
          let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return nil }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private final class FakeDisplayManager {}

private final class ManualSegmentSender {
    private(set) var payloads: [Data] = []
    private var completions: [(Bool) -> Void] = []

    func send(_ data: Data, completion: @escaping (Bool) -> Void) {
        payloads.append(data)
        completions.append(completion)
    }

    func completeNext(_ succeeded: Bool) {
        guard !completions.isEmpty else { return }
        let completion = completions.removeFirst()
        completion(succeeded)
    }
}

@MainActor @main
enum PlayerLiveContractTests {
    static func main() {
        testInitialMountPinsStartupBytes()
        testResidentSlidingPlaylistAndAbsoluteRequests()
        testReadLeaseLifecycle()
        testDisplayRequestLifecycle()
        testSelectionRefreshLifecycle()
        testProductionWiring()

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }

    private static func testInitialMountPinsStartupBytes() {
        let buffer = VortXRemuxBuffer(windowFloorBytes: 16)
        append(Array(0..<80), to: buffer)
        let segments = (0..<8).map {
            VortXHLSSegment(id: $0, byteOffset: $0 * 10, byteLength: 10, duration: 5)
        }

        let served = buffer.read(offset: 0, length: 40, cancelled: { false })
        check("startup: initial bytes are served", served.failure == nil && served.data.count == 40)
        check("startup: reads cannot evict segment zero before engine readiness",
              buffer.residentByteRange.lowerBound == 0)

        let window = buffer.residentWindow(segments: segments)
        check("startup: initial immutable window begins at absolute segment zero", window.mediaSequence == 0)
        let lines = DVPlaybackPolicy.mediaPlaylistLines(
            window: window, ended: false, targetDuration: 5, mapURI: "init.mp4")
        check("startup: initial contract carries the precise zero-start preference",
              lines.contains("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"))
        check("startup: media sequence is exactly zero", lines.contains("#EXT-X-MEDIA-SEQUENCE:0"))
    }

    private static func testResidentSlidingPlaylistAndAbsoluteRequests() {
        let buffer = VortXRemuxBuffer(windowFloorBytes: 16)
        append(Array(repeating: 0x5a, count: 140), to: buffer)
        let segments = (0..<14).map {
            VortXHLSSegment(id: $0, byteOffset: $0 * 10, byteLength: 10, duration: 5)
        }

        buffer.markEngineReady()
        let consumed = buffer.read(offset: 0, length: 90, cancelled: { false })
        check("eviction: long read succeeds", consumed.failure == nil && consumed.data.count == 90)
        check("eviction: long read advances the resident byte floor", buffer.residentByteRange.lowerBound == 74)

        let window = buffer.residentWindow(segments: segments)
        check("playlist: real first fully resident absolute segment becomes media sequence", window.mediaSequence == 8)
        check("playlist: evicted absolute segment is not addressable", window.segment(id: 0) == nil)
        check("playlist: nonzero absolute segment maps by id rather than array offset",
              window.segment(id: 8)?.byteOffset == 80)

        let lines = DVPlaybackPolicy.mediaPlaylistLines(
            window: window, ended: false, targetDuration: 5, mapURI: "init.mp4")
        let ids = playlistSegmentIDs(lines)
        check("playlist: media sequence is the first retained id", lines.contains("#EXT-X-MEDIA-SEQUENCE:8"))
        check("playlist: stale evicted URI is not advertised", !lines.contains("seg0.m4s"))
        check("playlist: sliding window is not falsely declared append-only EVENT",
              !lines.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        check("playlist: zero-start preference is limited to the initial zero-sequence contract",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-START:") }))
        check("playlist: advertised ids exactly equal the immutable resident window", ids == Array(8..<14))

        var everyAdvertisedRequestWasReadable = true
        for id in ids {
            guard let segment = window.segment(id: id) else {
                everyAdvertisedRequestWasReadable = false
                continue
            }
            let response = buffer.read(offset: segment.byteOffset,
                                       length: segment.byteLength,
                                       cancelled: { false })
            if response.failure != nil || response.data.count != segment.byteLength {
                everyAdvertisedRequestWasReadable = false
            }
        }
        check("requests: every advertised absolute URI produces readable bytes", everyAdvertisedRequestWasReadable)

        let ended = DVPlaybackPolicy.mediaPlaylistLines(
            window: window, ended: true, targetDuration: 5, mapURI: "init.mp4")
        check("playlist: completed resident window carries ENDLIST", ended.contains("#EXT-X-ENDLIST"))
    }

    private static func testReadLeaseLifecycle() {
        func makeBuffer() -> (VortXRemuxBuffer, [UInt8]) {
            let buffer = VortXRemuxBuffer(windowFloorBytes: 1)
            let bytes = Array(UInt8(0)..<UInt8(24))
            append(bytes, to: buffer)
            buffer.markEngineReady()
            return (buffer, bytes)
        }

        func trimAndCheckHeld(_ label: String, _ buffer: VortXRemuxBuffer) {
            _ = buffer.discardPrefix(before: 16)
            check(label, buffer.residentByteRange.lowerBound == 0)
        }

        func trimAndCheckReleased(_ label: String, _ buffer: VortXRemuxBuffer) {
            _ = buffer.discardPrefix(before: 16)
            check(label,
                  buffer.read(offset: 0, length: 1, cancelled: { false }).failure != nil)
        }

        do {
            let (buffer, bytes) = makeBuffer()
            let sender = ManualSegmentSender()
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2, cancelled: { false })
            check("lease pump: a resident segment prepares without a full-resource copy", response != nil)
            response?.start(
                header: Data("head".utf8),
                cancelled: { false },
                send: sender.send,
                terminal: { terminal = $0 })
            response = nil   // production's route-local owner ends here; callback handoffs must retain the pump
            trimAndCheckHeld("lease pump: lease survives the pending header callback", buffer)

            sender.completeNext(true)
            check("lease pump: header completion advances to the probed first chunk",
                  sender.payloads == [Data("head".utf8), Data(bytes[0..<2])])
            trimAndCheckHeld("lease pump: lease survives the pending first-body callback", buffer)

            sender.completeNext(true)
            check("lease pump: first-body completion reads only the next bounded chunk",
                  sender.payloads.last == Data(bytes[2..<4]))
            trimAndCheckHeld("lease pump: lease survives the first tail callback", buffer)

            sender.completeNext(true)
            check("lease pump: every subsequent callback advances one bounded chunk",
                  sender.payloads.last == Data(bytes[4..<6]))
            trimAndCheckHeld("lease pump: lease survives every later tail callback", buffer)
            sender.completeNext(true)
            check("lease pump: final chunk is still bounded", sender.payloads.last == Data(bytes[6..<8]))
            trimAndCheckHeld("lease pump: lease survives until final send completion", buffer)
            sender.completeNext(true)
            check("lease pump: final send reports successful completion", terminal == .complete)
            trimAndCheckReleased("lease pump: successful completion releases the full-range lease", buffer)
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2, cancelled: { false })
            response?.start(
                header: Data("head".utf8), cancelled: { false },
                send: sender.send, terminal: { terminal = $0 })
            let retainedThroughTerminal = response
            response = nil
            trimAndCheckHeld("lease pump: header error cannot release before its callback", buffer)
            sender.completeNext(false)
            check("lease pump: header send error terminates exactly once", terminal == .sendError)
            withExtendedLifetime(retainedThroughTerminal) {
                trimAndCheckReleased("lease pump: header send error explicitly releases the lease", buffer)
            }
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2, cancelled: { false })
            response?.start(
                header: Data("head".utf8), cancelled: { false },
                send: sender.send, terminal: { terminal = $0 })
            response = nil
            sender.completeNext(true)
            trimAndCheckHeld("lease pump: first-body error cannot release before its callback", buffer)
            sender.completeNext(false)
            check("lease pump: first-body send error terminates", terminal == .sendError)
            trimAndCheckReleased("lease pump: first-body send error releases the lease", buffer)
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2, cancelled: { false })
            response?.start(
                header: Data("head".utf8), cancelled: { false },
                send: sender.send, terminal: { terminal = $0 })
            response = nil
            sender.completeNext(true)
            sender.completeNext(true)
            trimAndCheckHeld("lease pump: tail error cannot release before its callback", buffer)
            sender.completeNext(false)
            check("lease pump: tail send error terminates", terminal == .sendError)
            trimAndCheckReleased("lease pump: tail send error releases the lease", buffer)
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var invalidated = false
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2,
                cancelled: { invalidated })
            response?.start(
                header: Data("head".utf8), cancelled: { invalidated },
                send: sender.send, terminal: { terminal = $0 })
            response = nil
            trimAndCheckHeld("lease pump: invalidation waits for the pending header callback", buffer)
            invalidated = true
            sender.completeNext(true)
            check("lease pump: header completion observes invalidation before sending a body", 
                  terminal == .cancelled && sender.payloads.count == 1)
            trimAndCheckReleased("lease pump: header-stage invalidation releases the lease", buffer)
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var invalidated = false
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2,
                cancelled: { invalidated })
            response?.start(
                header: Data("head".utf8), cancelled: { invalidated },
                send: sender.send, terminal: { terminal = $0 })
            response = nil
            sender.completeNext(true)
            trimAndCheckHeld("lease pump: invalidation cannot release while a body send is pending", buffer)
            invalidated = true
            sender.completeNext(true)
            check("lease pump: invalidation wins before another tail is read", terminal == .cancelled)
            trimAndCheckReleased("lease pump: invalidation releases the lease", buffer)
        }

        do {
            let (buffer, _) = makeBuffer()
            let sender = ManualSegmentSender()
            var terminal: VortXSegmentResponsePump.Terminal?
            var response = VortXSegmentResponsePump(
                source: buffer, offset: 0, length: 8, chunkSize: 2, cancelled: { false })
            response?.start(
                header: Data("head".utf8), cancelled: { false },
                send: sender.send, terminal: { terminal = $0 })
            response = nil
            sender.completeNext(true)
            buffer.fail("injected read failure")
            sender.completeNext(true)
            check("lease pump: a source failure terminates before another send", terminal == .readError)
            check("lease pump: source failure cannot enqueue a stale tail", sender.payloads.count == 2)
        }
    }

    private static func testDisplayRequestLifecycle() {
        let firstManager = FakeDisplayManager()
        let replacementManager = FakeDisplayManager()
        let request = DVPlaybackPolicy.DisplayRequest(
            range: "dolbyVision", rate: 23.976, width: 3840, height: 2160)
        var ledger = DVPlaybackPolicy.DisplayRequestLedger()

        check("display: first manager begins a request", ledger.begin(request, manager: firstManager))
        check("display: duplicate pending request is coalesced", !ledger.begin(request, manager: firstManager))
        ledger.complete(request, manager: firstManager, applied: false)
        check("display: failed assignment is retryable", ledger.begin(request, manager: firstManager))
        ledger.complete(request, manager: firstManager, applied: true)
        check("display: successfully applied duplicate is skipped", !ledger.begin(request, manager: firstManager))
        check("display: manager replacement re-applies the same criteria",
              ledger.begin(request, manager: replacementManager))
        ledger.complete(request, manager: replacementManager, applied: true)
        ledger.reset()
        check("display: reset makes the next identical request eligible",
              ledger.begin(request, manager: replacementManager))

        check("display: authoritative 23.976 survives an unknown asset-track rate",
              DVPlaybackPolicy.frameRate(classified: 23.976, assetTrack: 0) == 23.976)
        check("display: an unknown session never invents 60Hz",
              DVPlaybackPolicy.frameRate(classified: 0, assetTrack: 0) == nil)
        check("display: a known asset rate is used when no classified rate exists",
              DVPlaybackPolicy.frameRate(classified: 0, assetTrack: 24) == 24)
    }

    private static func testSelectionRefreshLifecycle() {
        var state = DVPlaybackPolicy.SelectionRefreshState()
        check("selection: initial snapshot publishes", state.update(audio: 0, subtitle: nil))
        check("selection: unchanged snapshot is coalesced", !state.update(audio: 0, subtitle: nil))
        check("selection: successful manual audio selection refreshes", state.update(audio: 1, subtitle: nil))
        check("selection: system-driven subtitle selection refreshes", state.update(audio: 1, subtitle: 2))
        check("selection: subtitle Off refreshes selected flags", state.update(audio: 1, subtitle: nil))
        check("selection: selected flags contain exactly the current option",
              DVPlaybackPolicy.selectedFlags(optionCount: 3, selectedIndex: 1) == [false, true, false])
        check("selection: Off clears every selected flag",
              DVPlaybackPolicy.selectedFlags(optionCount: 3, selectedIndex: nil) == [false, false, false])
    }

    private static func testProductionWiring() {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let playerURL = testsURL.deletingLastPathComponent().appendingPathComponent("Sources/Player")
        let server = try? String(contentsOf: playerURL.appendingPathComponent("VortXRemuxHLSServer.swift"),
                                 encoding: .utf8)
        let stream = try? String(contentsOf: playerURL.appendingPathComponent("VortXMKVRemuxStream.swift"),
                                 encoding: .utf8)
        let display = try? String(contentsOf: playerURL.appendingPathComponent("HDRDisplayMode.swift"),
                                  encoding: .utf8)
        let engine = try? String(contentsOf: playerURL.appendingPathComponent("AVPlayerEngine.swift"),
                                 encoding: .utf8)
        let manualSelection = sourceSection(engine, from: "private func select(", to: "/// The overlay host")
        let groupLoad = sourceSection(engine, from: "private func loadSelectionGroups()",
                                      to: "/// Rebuild cached selected flags")
        let subtitlePlaylist = sourceSection(
            server,
            from: "private func serveSubtitlePlaylist(",
            to: "private func serveSubtitleSegment(")
        let videoSegmentResponse = sourceSection(
            server,
            from: "private func serveSegment(",
            to: "private static let segmentChunk")
        let audioSegmentResponse = sourceSection(
            server,
            from: "private func serveAudioSegment(",
            to: "// MARK: - Optional settled subtitle renditions")
        let subtitleInvalidation = sourceSection(
            stream,
            from: "private func invalidateSubtitles(",
            to: "/// Decode one collected text packet")
        let subtitleCollection = sourceSection(
            stream,
            from: "private func collectSubtitlePacket(",
            to: "private static func streamLanguage(")
        let immutableSnapshot = sourceSection(
            stream,
            from: "func hlsWindowSnapshot()",
            to: "/// Monotonic mount-progress counters")
        let alternateMuxer = sourceSection(
            stream,
            from: "private final class VortXAlternateAudioMuxer",
            to: "// MARK: - Small helpers not exposed cleanly")
        let alternateCloseSegment = sourceSection(
            stream,
            from: "func closeSegment(id:",
            to: "/// EOF has no following packet")
        let alternatePacketHold = sourceSection(
            stream,
            from: "private func holdAlternateAudioPacket(",
            to: "private func drainAlternateAudio(")
        let alternateTimeout = sourceSection(
            stream,
            from: "func omitPendingAlternateAudioOnTimeout()",
            to: "private func holdAlternateAudioPacket(")
        let closeVideoSegment = sourceSection(
            stream,
            from: "private func hlsCloseSegment(",
            to: "private func hlsBuildSignaling(")
        let videoTiming = sourceSection(
            stream,
            from: "private func hlsVideoStep(",
            to: "private func hlsApplyVideoStep(")
        let appURL = testsURL.deletingLastPathComponent()
        let whatsNew = try? String(contentsOf: appURL.appendingPathComponent("SourcesShared/WhatsNew.swift"),
                                   encoding: .utf8)
        let changelog = try? String(contentsOf: appURL.deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md"), encoding: .utf8)

        check("wiring: server renders the resident immutable window",
              server?.contains("DVPlaybackPolicy.mediaPlaylistLines(window:") == true)
        check("wiring: server uses the byte-compared production master renderer",
              server?.contains("DVPlaybackPolicy.masterPlaylistData(") == true)
        check("wiring: segment requests resolve absolute ids through the window",
              server?.contains("window.segment(id: index)") == true)
        check("wiring: video and audio use the executable lease-owning response pump",
              videoSegmentResponse?.contains("VortXSegmentResponsePump(") == true
                  && audioSegmentResponse?.contains("VortXSegmentResponsePump(") == true
                  && videoSegmentResponse?.contains("response.start(") == true
                  && audioSegmentResponse?.contains("response.start(") == true)
        check("wiring: production selects a bounded chunk size for both response pumps",
              videoSegmentResponse?.contains("chunkSize: Self.segmentChunk") == true
                  && audioSegmentResponse?.contains("chunkSize: Self.segmentChunk") == true
                  && server?.contains("private static let segmentChunk = 512 * 1024") == true)
        check("wiring: one snapshot binds the resident video base and optional feature state",
              immutableSnapshot?.contains("buffer.residentWindow(segments: _hlsSegments)") == true
                  && immutableSnapshot?.contains(
                      "let audioPublished = _alternateAudioState == .ready && _alternateAudioPlan != nil") == true
                  && immutableSnapshot?.contains("audioPlan: audioPublished ? _alternateAudioPlan : nil") == true
                  && immutableSnapshot?.contains("subtitleFailureReason: _subtitleSettlement.invalidationReason") == true)
        check("wiring: alternate audio owns a separate muxer and cloned packet references",
              stream?.contains("private final class VortXAlternateAudioMuxer") == true
                  && stream?.contains("av_packet_clone(packet)") == true
                  && stream?.contains("mappable.insert(alternateAudioIn)") == false)
        check("wiring: alternate publication requires a real nonempty packet from that stream",
              alternatePacketHold?.contains("guard packet.pointee.size > 0") == true
                  && alternatePacketHold?.contains(
                      "provenPacketStreamIndices: [Int(packet.pointee.stream_index)]") == true
                  && alternatePacketHold?.contains("_alternateAudioCandidatePlan = provenPlan") == true
                  && closeVideoSegment?.contains("MultiAudioPolicy.finalizeForPublication(") == true
                  && stream?.contains("_alternateAudioPlan = candidateAudioPlan") == false)
        check("wiring: JOC observation reaches the fail-closed rendition policy",
              stream?.contains("isJOC: $0.atmos") == true)
        check("wiring: a cloned late packet is freed and fails only the optional alternate",
              alternatePacketHold?.contains("alignment.isBehindClosedFrontier(timestamp)") == true
                  && alternatePacketHold?.contains("av_packet_free(&optional)") == true
                  && alternatePacketHold?.contains(".discontinuity : .byteBudget") == true)
        check("wiring: timeout cannot overwrite an alternate that became ready at the deadline",
              alternateTimeout?.contains("hlsLock.lock()") == true
                  && alternateTimeout?.contains("guard _alternateAudioState == .pending") == true
                  && alternateTimeout?.contains("markAlternateAudioFailed") == false
                  && immutableSnapshot?.contains(
                      "_alternateAudioState = MultiAudioPolicy.snapshotState(") == true)
        check("wiring: alternate output uses a nonblocking cap and propagates callback failure",
              alternateMuxer?.contains("buffer.appendIfWithinResidentLimit(") == true
                  && alternateMuxer?.contains("fail(.byteBudget)") == true
                  && alternateMuxer?.contains("return AVERROR_EXIT_CONST") == true
                  && alternateMuxer?.contains("buffer.append(bytes") == false)
        check("wiring: alternate segment metadata comes from accepted packet timestamps",
              alternateMuxer?.contains("audioCoverage.accept(timing)") == true
                  && alternateCloseSegment?.contains("let proof = audioCoverage.close(") == true
                  && alternateCloseSegment?.contains("boundary: boundary") == true
                  && alternateCloseSegment?.contains("decodeStart: proof.decodeStart") == true
                  && alternateCloseSegment?.contains("decodeEnd: proof.decodeEnd") == true
                  && alternateCloseSegment?.contains("decodeStart: start") == false)
        check("wiring: audio playlist alignment uses the authoritative video-frame drift bound",
              immutableSnapshot?.contains("videoFrameDuration: videoFrameDuration") == true)
        check("wiring: an unselected alternate trims to the primary resident window",
              immutableSnapshot?.contains("MultiAudioPolicy.retentionFloor(") == true
                  && immutableSnapshot?.contains("audioMuxer.buffer.discardPrefix(before: audioFloor)") == true
                  && immutableSnapshot?.contains("$0.segmentID < firstVideoID") == true)
        check("wiring: alternate cap failure is typed and tears down held refs without primary failure",
              stream?.contains("markAlternateAudioFailed(muxer.failureCategory ?? .muxer)") == true
                  && stream?.contains("discardHeldAudio(alignment: &alignment, packets: &packets)") == true)
        check("wiring: EOF closes on observed packet end instead of a target-duration guess",
              videoTiming?.contains("pkt.pointee.duration > 0") == true
                  && videoTiming?.contains("hlsVideoEndState.observe(") == true
                  && stream?.contains(
                      "MultiAudioPolicy.finalizationDecision(observedEnd: hlsVideoEndState.latestEnd)") == true
                  && stream?.contains("case .failUnproven:") == true
                  && stream?.contains("buffer.fail(\"final video packet end was not observed\")") == true
                  && stream?.contains("hlsVideoEndState.latestEnd ?? hlsLastVideoSec") == false
                  && stream?.contains("hlsLastVideoSec + Self.hlsTargetSegmentSecs") == false
                  && closeVideoSegment?.contains("let duration = endSec - startSec") == true
                  && closeVideoSegment?.contains("max(0.04") == false)
        check("wiring: audio and subtitle resource paths route through their tested parsers",
              server?.contains("MultiAudioPolicy.parseRequest(path: path)") == true
                  && server?.contains("SubtitleRenditionPolicy.parseRequest(path: path)") == true)
        check("wiring: subtitle playlists wait for a settled nonempty shared window or EOF",
              subtitlePlaylist?.contains("guard let window = snapshot.subtitleWindow") == true
                  && subtitlePlaylist?.contains("!window.segments.isEmpty || snapshot.ended") == true
                  && subtitlePlaylist?.contains("return .invalidated") == true)
        check("wiring: every subtitle cap removes the optional publication with a typed reason",
              subtitleCollection?.contains("invalidateSubtitles(.payloadBound)") == true
                  && subtitleCollection?.contains("invalidateSubtitles(.storedBound)") == true
                  && subtitleCollection?.contains("invalidateSubtitles(.cueCountBound)") == true)
        check("wiring: subtitle invalidation cannot fail or rewrite the primary A/V stream",
              subtitleInvalidation?.contains("_subtitleRenditions.removeAll") == true
                  && subtitleInvalidation?.contains("_subtitleCues.removeAll") == true
                  && subtitleInvalidation?.contains("buffer.fail") == false
                  && subtitleInvalidation?.contains("_hlsSegments") == false)
        check("wiring: optional player features remain default-off",
              stream?.contains("isFeatureOn(\"dvRemuxMultiAudio\", default: false)") == true
                  && stream?.contains("isFeatureOn(\"dvRemuxSubtitles\", default: false)") == true)
        check("wiring: remux resume has no production launch caller",
              engine?.contains("resumeStartSeconds") == false
                  && engine?.contains("remuxTimelineOrigin") == false
                  && stream?.contains("startAtSeconds") == false)
        check("wiring: display manager uses the success-aware request ledger",
              display?.contains("displayRequestLedger.begin") == true
                  && display?.contains("displayRequestLedger.complete") == true
                  && display?.contains("let previousCriteria = manager.preferredDisplayCriteria") == true
                  && display?.contains("let readbackCriteria = manager.preferredDisplayCriteria") == true
                  && display?.contains("readbackCriteria !== previousCriteria") == true
                  && display?.contains("let applied = manager.preferredDisplayCriteria != nil") == false
                  && display?.contains("preferredDisplayCriteria === criteria") == false)
        check("wiring: manual selection immediately refreshes cached flags",
              manualSelection?.contains("refreshSelectionTracks(for: item)") == true)
        check("wiring: system media-selection changes are observed",
              engine?.contains("AVPlayerItem.mediaSelectionDidChangeNotification") == true)
        check("wiring: loaded groups force their initial track-list publication",
              groupLoad?.contains("selectionRefreshState.reset()") == true
                  && groupLoad?.contains("refreshSelectionTracks(for: item)") == true)
        check("release: Beta 7 is the first parseable changelog version",
              changelog?.range(of: "## 0.3.14 Beta 7")?.lowerBound
                  == changelog?.range(of: "## ")?.lowerBound)
        check("release: fallback copy names the resident playlist fix",
              whatsNew?.contains("playlists no longer point at discarded video") == true)
        check("release: rejected start and one-switch claims are gone",
              whatsNew?.contains("start at the beginning instead of about fourteen seconds") == false
                  && whatsNew?.contains("mode changes once") == false)
    }
}
