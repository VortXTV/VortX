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

private func scratchDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vortx-player-live-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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

private func sourceContainsInOrder(_ source: String?, _ needles: [String]) -> Bool {
    guard let source else { return false }
    var cursor = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: cursor..<source.endIndex) else { return false }
        cursor = range.upperBound
    }
    return true
}

private final class FakeDisplayManager {}

private final class SpoolProbeState {
    var calls = 0
    var attemptedTrim = false
}

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
        testSessionSpoolAdmissionAndFailures()
        testPlaylistRetentionAndFileLeases()
        testSpoolResponsePump()
        testSessionLifecycleAndScavenge()
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

    private static func testSessionSpoolAdmissionAndFailures() {
        let root = scratchDirectory("spool-admission")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VortXRemuxBuffer(windowFloorBytes: 1)
        append(Array(UInt8(0)..<UInt8(16)), to: source)
        check("spool source: bounded snapshot reads exact resident chunks without advancing RAM",
              source.snapshotChunk(offset: 2, length: 3) == Data([2, 3, 4])
                  && source.residentByteRange.lowerBound == 0)

        guard let exact = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 8,
            chunkSize: 3,
            scavengeStaleSessions: false) else {
            check("spool: exact-cap session directory is creatable", false)
            return
        }
        let video0 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 0)
        let exactResource = VortXHLSSessionSpool.SpillResource(
            key: video0, buffer: source, offset: 0, length: 8, durationMilliseconds: 4_000)
        check("spool admission: a reservation exactly equal to the session cap commits",
              exact.spill([exactResource]))
        check("spool accounting: committed bytes replace, rather than stack with, their reservation",
              exact.accounting.finalBytes == 8
                  && exact.accounting.reservedBytes == 0
                  && exact.accounting.temporaryBytes == 0
                  && exact.accounting.admittedBytes == 8)
        let video1 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 1)
        check("spool admission: cap plus one fails before creating a temporary file",
              !exact.spill([.init(
                  key: video1, buffer: source, offset: 8, length: 1,
                  durationMilliseconds: 1_000)]))
        check("spool admission: rejection never evicts protected committed media",
              exact.contains(video0) && !exact.contains(video1) && exact.accounting.finalBytes == 8)
        let namesAfterFirstCommit = exact.fileNamesOnDisk
        check("spool de-dup: the same key and exact bytes are idempotent across variant/cohort publication",
              exact.spill([exactResource])
                  && exact.fileNamesOnDisk == namesAfterFirstCommit
                  && exact.accounting.finalBytes == 8)
        check("spool de-dup: the same key with conflicting bytes fails without rewriting backing",
              !exact.spill([.init(
                  key: video0, buffer: source, offset: 8, length: 8,
                  durationMilliseconds: 4_000)])
                  && exact.fileNamesOnDisk == namesAfterFirstCommit
                  && exact.accounting.finalBytes == 8)

        guard let tooSmall = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 7,
            chunkSize: 3,
            scavengeStaleSessions: false) else {
            check("spool: cap-minus-one session directory is creatable", false)
            return
        }
        check("spool admission: an eight-byte cohort is rejected by a seven-byte cap",
              !tooSmall.spill([exactResource]) && tooSmall.accounting.admittedBytes == 0)

        guard let partial = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 4,
            failureInjection: .write(afterBytes: 3),
            scavengeStaleSessions: false) else {
            check("spool: partial-write fixture is creatable", false)
            return
        }
        check("spool failure: an injected partial write publishes no backing",
              !partial.spill([exactResource]) && !partial.contains(video0))
        check("spool failure: partial bytes and reservations are both removed from live accounting",
              partial.accounting.finalBytes == 0
                  && partial.accounting.temporaryBytes == 0
                  && partial.accounting.reservedBytes == 0
                  && partial.accounting.peakTemporaryBytes == 3
                  && partial.accounting.peakReservedBytes == 8)
        check("spool failure: no .part survives a partial write",
              !partial.fileNamesOnDisk.contains(where: { $0.hasSuffix(".part") }))

        guard let diskFull = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 4,
            failureInjection: .diskFull(afterBytes: 5),
            scavengeStaleSessions: false) else {
            check("spool: disk-full fixture is creatable", false)
            return
        }
        check("spool failure: disk-full rolls back its partial cohort and accounting",
              !diskFull.spill([exactResource])
                  && diskFull.accounting.admittedBytes == 0
                  && diskFull.fileNamesOnDisk.isEmpty)

        guard let renameFailure = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 2,
            failureInjection: .rename(afterSuccessfulMoves: 1),
            scavengeStaleSessions: false) else {
            check("spool: rename-failure fixture is creatable", false)
            return
        }
        let pair: [VortXHLSSessionSpool.SpillResource] = [
            .init(key: video0, buffer: source, offset: 0, length: 4, durationMilliseconds: 2_000),
            .init(key: video1, buffer: source, offset: 4, length: 4, durationMilliseconds: 2_000),
        ]
        check("spool failure: a second rename failure rolls back the first renamed cohort member",
              !renameFailure.spill(pair)
                  && !renameFailure.contains(video0)
                  && !renameFailure.contains(video1)
                  && renameFailure.fileNamesOnDisk.isEmpty)

        guard let sizeMismatch = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 4,
            failureInjection: .sizeMismatch,
            scavengeStaleSessions: false) else {
            check("spool: size-mismatch fixture is creatable", false)
            return
        }
        check("spool failure: exact-size mismatch after write cannot rename or register",
              !sizeMismatch.spill([exactResource])
                  && !sizeMismatch.contains(video0)
                  && sizeMismatch.accounting.admittedBytes == 0
                  && sizeMismatch.fileNamesOnDisk.isEmpty)

        guard let overflow = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: Int.max,
            chunkSize: 4,
            scavengeStaleSessions: false) else {
            check("spool: overflow fixture is creatable", false)
            return
        }
        check("spool arithmetic: summing Int.max plus one rejects before reservation or file creation",
              !overflow.spill([
                  .init(key: .video(segmentID: 90), buffer: source, offset: 0,
                        length: Int.max, durationMilliseconds: 1),
                  .init(key: .video(segmentID: 91), data: Data([1]), durationMilliseconds: 1),
              ])
                  && overflow.accounting.admittedBytes == 0
                  && overflow.fileNamesOnDisk.isEmpty)
        check("spool validation: negative ranges, nonpositive durations and empty payloads fail before admission",
              !overflow.spill([.init(
                  key: .video(segmentID: 92), buffer: source, offset: -1,
                  length: 1, durationMilliseconds: 1)])
                  && !overflow.spill([.init(
                      key: .video(segmentID: 93), data: Data([1]), durationMilliseconds: 0)])
                  && !overflow.spill([.init(
                      key: .video(segmentID: 94), data: Data(), durationMilliseconds: 1)]))

        guard let overlap = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: false) else {
            check("spool: overlap fixture is creatable", false)
            return
        }
        let probe = SpoolProbeState()
        overlap.installFileOperationProbe { owner in
            probe.calls += 1
            _ = owner.accounting
            if !probe.attemptedTrim {
                probe.attemptedTrim = true
                source.markEngineReady()
                _ = source.discardPrefix(before: 8)
            }
        }
        check("spool locking: filesystem callbacks can re-enter coordinator reads without a held state lock",
              overlap.spill([.init(
                  key: .video(segmentID: 95), buffer: source, offset: 0,
                  length: 8, durationMilliseconds: 4_000)])
                  && probe.calls > 0)
        check("spool source lease: an eviction attempt between chunk writes cannot undercut the staged range",
              overlap.contains(.video(segmentID: 95))
                  && source.residentByteRange.lowerBound == 0)
        check("spool memory: segment spill never snapshots more than its configured bounded chunk",
              exact.accounting.peakChunkBytes <= 3)
        check("spool production: the default session admission cap is exactly 512 MiB",
              VortXHLSSessionSpool.defaultCapacityBytes == 512 * 1024 * 1024)
        let bytesAt44Point7MbitForFourSeconds = 44_700_000 / 8 * 4
        check("spool bitrate: 44.7 Mbit/s stays under the byte guard while the four-second IDR rule remains decisive",
              bytesAt44Point7MbitForFourSeconds < 32 * 1024 * 1024
                  && VortXHLSBoundaryPolicy.decision(
                      hasOpenSegment: true,
                      incomingIsIDR: false,
                      elapsed: 4,
                      openBytes: bytesAt44Point7MbitForFourSeconds) == .failSoft)
    }

    private static func testPlaylistRetentionAndFileLeases() {
        let root = scratchDirectory("spool-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VortXRemuxBuffer(windowFloorBytes: 1)
        append(Array(repeating: 0x5a, count: 64), to: source)
        guard let spool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 128,
            chunkSize: 4,
            scavengeStaleSessions: false) else {
            check("retention: session directory is creatable", false)
            return
        }
        let v0 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 0)
        let v1 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 1)
        let v2 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 2)
        check("retention: one durable cohort registers each shared video resource exactly once",
              spool.spill([
                  .init(key: v0, buffer: source, offset: 0, length: 10, durationMilliseconds: 4_000),
                  .init(key: v1, buffer: source, offset: 10, length: 10, durationMilliseconds: 5_000),
                  .init(key: v2, buffer: source, offset: 20, length: 10, durationMilliseconds: 6_000),
              ]) && spool.accounting.finalBytes == 30)

        _ = spool.recordPlaylistGeneration(
            playlistID: "video-dv", resourceKeys: [v0, v1], now: 100)
        _ = spool.recordPlaylistGeneration(
            playlistID: "video-hdr", resourceKeys: [v0, v1], now: 101)
        _ = spool.recordPlaylistGeneration(
            playlistID: "video-dv", resourceKeys: [v1, v2], now: 110)
        check("retention: removal from one duplicate variant does not start expiry while another still contains it",
              spool.retentionDeadline(for: v0) == nil)
        _ = spool.recordPlaylistGeneration(
            playlistID: "video-hdr", resourceKeys: [v1, v2], now: 120)
        check("retention: last removal uses removal + segment duration + longest containing playlist duration",
              spool.retentionDeadline(for: v0) == 133)
        _ = spool.recordPlaylistGeneration(
            playlistID: "video-dv", resourceKeys: [v0, v1, v2], now: 125)
        check("retention: reappearing before expiry cancels the old removal deadline",
              spool.retentionDeadline(for: v0) == nil)
        _ = spool.recordPlaylistGeneration(
            playlistID: "video-dv", resourceKeys: [v1, v2], now: 130)
        check("retention: a later removal recomputes from the new removal time and longer generation",
              spool.retentionDeadline(for: v0) == 149)
        check("retention: every distributed variant generation is recorded without double-counting shared bytes",
              spool.playlistGenerationCount(playlistID: "video-dv") == 4
                  && spool.playlistGenerationCount(playlistID: "video-hdr") == 2
                  && spool.accounting.finalBytes == 30)

        let before = spool.openResource(v0, now: 148.999)
        check("retention: a request immediately before expiry atomically opens its backing", before != nil)
        before?.close(now: 148.999)
        let at = spool.openResource(v0, now: 149)
        check("retention: the exact lower-bound deadline remains serveable", at != nil)
        at?.close(now: 149)
        check("retention: a request after expiry is rejected and unleased backing is reclaimed",
              spool.openResource(v0, now: 149.001) == nil && !spool.contains(v0))

        _ = spool.recordPlaylistGeneration(playlistID: "video-dv", resourceKeys: [], now: 130)
        _ = spool.recordPlaylistGeneration(playlistID: "video-hdr", resourceKeys: [], now: 131)
        let protectedLease = spool.openResource(v1, now: 150.999)
        check("retention lease: a response can acquire backing immediately before its exact deadline",
              protectedLease != nil)
        spool.collectExpired(now: 152)
        check("retention lease: expiry cannot delete a file beneath an active response",
              spool.contains(v1) && spool.openResource(v1, now: 152) == nil)
        protectedLease?.close(now: 152)
        check("retention lease: terminal callback releases and reclaims an already-expired backing",
              !spool.contains(v1))

        let audio0 = VortXHLSSessionSpool.ResourceKey.audio(renditionID: 7, segmentID: 0)
        let subtitle0 = VortXHLSSessionSpool.ResourceKey.subtitle(renditionID: 3, segmentID: 0)
        check("retention topology: alternate audio and rendered subtitle share the same session cap",
              spool.spill([
                  .init(key: audio0, buffer: source, offset: 30, length: 8, durationMilliseconds: 4_000),
                  .init(key: subtitle0, data: Data("WEBVTT\n\n".utf8), durationMilliseconds: 4_000),
              ]))
        _ = spool.recordPlaylistGeneration(
            playlistID: "audio-7", resourceKeys: [audio0], now: 200)
        _ = spool.recordPlaylistGeneration(
            playlistID: "subs-3", resourceKeys: [subtitle0], now: 200)
        _ = spool.recordPlaylistGeneration(playlistID: "audio-7", resourceKeys: [], now: 210)
        _ = spool.recordPlaylistGeneration(playlistID: "subs-3", resourceKeys: [], now: 210)
        check("retention topology: audio and subtitle deadlines use their own distributed generations",
              spool.retentionDeadline(for: audio0) == 218
                  && spool.retentionDeadline(for: subtitle0) == 218)

        guard let arithmetic = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 1,
            chunkSize: 1,
            scavengeStaleSessions: false) else {
            check("retention arithmetic: overflow fixture is creatable", false)
            return
        }
        let extreme = VortXHLSSessionSpool.ResourceKey.video(segmentID: Int.max)
        check("retention arithmetic: an extreme duration can be registered without eager overflow",
              arithmetic.spill([.init(
                  key: extreme, data: Data([1]), durationMilliseconds: Int.max)])
                  && arithmetic.recordPlaylistGeneration(
                      playlistID: "extreme", resourceKeys: [extreme], now: 0) != nil)
        check("retention arithmetic: duration plus longest-generation overflow fails atomically",
              arithmetic.recordPlaylistGeneration(
                  playlistID: "extreme", resourceKeys: [], now: 1) == nil
                  && arithmetic.playlistGenerationCount(playlistID: "extreme") == 1
                  && arithmetic.retentionDeadline(for: extreme) == nil)

        guard let nonfinite = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 1,
            chunkSize: 1,
            scavengeStaleSessions: false) else {
            check("retention arithmetic: deadline fixture is creatable", false)
            return
        }
        let finite = VortXHLSSessionSpool.ResourceKey.video(segmentID: Int.max - 1)
        _ = nonfinite.spill([.init(key: finite, data: Data([2]), durationMilliseconds: 1)])
        _ = nonfinite.recordPlaylistGeneration(
            playlistID: "finite", resourceKeys: [finite], now: 0)
        check("retention arithmetic: a nonfinite clock fails closed without advancing the generation",
              nonfinite.recordPlaylistGeneration(
                  playlistID: "finite", resourceKeys: [],
                  now: .infinity) == nil
                  && nonfinite.playlistGenerationCount(playlistID: "finite") == 1
                  && nonfinite.retentionDeadline(for: finite) == nil)
    }

    private static func testSpoolResponsePump() {
        let root = scratchDirectory("spool-pump")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VortXRemuxBuffer(windowFloorBytes: 1)
        let bytes = Array(UInt8(0)..<UInt8(8))
        append(bytes, to: source)
        guard let spool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 24,
            chunkSize: 2,
            scavengeStaleSessions: false) else {
            check("file pump: session directory is creatable", false)
            return
        }
        let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 0)
        guard spool.spill([.init(
            key: key, buffer: source, offset: 0, length: 8, durationMilliseconds: 4_000)]),
              let lease = spool.openResource(key, now: 1),
              let response = VortXSpoolResponsePump(lease: lease, chunkSize: 2) else {
            check("file pump: durable resource opens before any response header", false)
            return
        }
        let sender = ManualSegmentSender()
        var terminal: VortXSpoolResponsePump.Terminal?
        var routeOwner: VortXSpoolResponsePump? = response
        routeOwner?.start(
            header: Data("head".utf8),
            cancelled: { false },
            send: sender.send,
            terminal: { terminal = $0 })
        routeOwner = nil
        sender.completeNext(true)
        sender.completeNext(true)
        sender.completeNext(true)
        sender.completeNext(true)
        sender.completeNext(true)
        check("file pump: one open handle stays owned through header and every bounded body callback",
              terminal == .complete
                  && sender.payloads == [
                      Data("head".utf8), Data(bytes[0..<2]), Data(bytes[2..<4]),
                      Data(bytes[4..<6]), Data(bytes[6..<8]),
                  ])
        check("file pump: terminal completion releases the request lease", spool.activeLeaseCount == 0)

        let errorKey = VortXHLSSessionSpool.ResourceKey.video(segmentID: 1)
        _ = spool.spill([.init(
            key: errorKey, buffer: source, offset: 0, length: 8, durationMilliseconds: 4_000)])
        if let errorLease = spool.openResource(errorKey, now: 1),
           let errorPump = VortXSpoolResponsePump(lease: errorLease, chunkSize: 2) {
            let errorSender = ManualSegmentSender()
            var errorTerminal: VortXSpoolResponsePump.Terminal?
            errorPump.start(
                header: Data("head".utf8), cancelled: { false },
                send: errorSender.send, terminal: { errorTerminal = $0 })
            errorSender.completeNext(true)
            errorSender.completeNext(false)
            check("file pump: a mid-body send failure drains its file lease exactly once",
                  errorTerminal == .sendError && spool.activeLeaseCount == 0)
        } else {
            check("file pump: send-failure fixture opens", false)
        }

        let cancellationKey = VortXHLSSessionSpool.ResourceKey.video(segmentID: 2)
        _ = spool.spill([.init(
            key: cancellationKey, buffer: source, offset: 0, length: 8,
            durationMilliseconds: 4_000)])
        if let cancellationLease = spool.openResource(cancellationKey, now: 1),
           let cancellationPump = VortXSpoolResponsePump(lease: cancellationLease, chunkSize: 2) {
            let cancellationSender = ManualSegmentSender()
            var cancelled = false
            var cancellationTerminal: VortXSpoolResponsePump.Terminal?
            cancellationPump.start(
                header: Data("head".utf8), cancelled: { cancelled },
                send: cancellationSender.send, terminal: { cancellationTerminal = $0 })
            cancellationSender.completeNext(true)
            cancelled = true
            cancellationSender.completeNext(true)
            check("file pump: mid-body cancellation stops before another read and drains its lease",
                  cancellationTerminal == .cancelled
                      && cancellationSender.payloads.count == 2
                      && spool.activeLeaseCount == 0)
        } else {
            check("file pump: cancellation fixture opens", false)
        }
    }

    private static func testSessionLifecycleAndScavenge() {
        let root = scratchDirectory("spool-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VortXRemuxBuffer(windowFloorBytes: 1)
        append(Array(repeating: 0x33, count: 8), to: source)
        guard let first = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: false) else {
            check("lifecycle: first session directory is creatable", false)
            return
        }
        let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 0)
        _ = first.spill([.init(
            key: key, buffer: source, offset: 0, length: 8, durationMilliseconds: 4_000)])
        first.producerDidReachEOF()
        check("lifecycle: EOF is not teardown and keeps the UUID session directory intact",
              FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        let lease = first.openResource(key, now: 0)
        first.invalidateSession()
        check("lifecycle: invalidation alone cannot delete files while listener ownership remains",
              FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        first.listenerDidRetire()
        check("lifecycle: invalidation plus listener retirement still waits for request-lease drain",
              FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        lease?.close(now: 0)
        lease?.close(now: 0)
        first.invalidateSession()
        first.listenerDidRetire()
        check("lifecycle: zero bytes remain only after invalidation, listener retirement and lease drain",
              !FileManager.default.fileExists(atPath: first.sessionDirectory.path))

        guard let activeSibling = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: false) else {
            check("scavenge: active sibling is creatable", false)
            return
        }
        let stale = root.appendingPathComponent("stale-session", isDirectory: true)
        try? FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try? Data([1]).write(to: stale.appendingPathComponent("orphan.part"))
        guard let laterLaunch = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: true) else {
            check("scavenge: later session is creatable", false)
            return
        }
        check("scavenge: a later launch removes a prior orphan but never an active sibling",
              !FileManager.default.fileExists(atPath: stale.path)
                  && FileManager.default.fileExists(atPath: activeSibling.sessionDirectory.path)
                  && FileManager.default.fileExists(atPath: laterLaunch.sessionDirectory.path))
        let siblingKey = VortXHLSSessionSpool.ResourceKey.video(segmentID: 7)
        _ = activeSibling.spill([.init(
            key: siblingKey, buffer: source, offset: 0, length: 8,
            durationMilliseconds: 4_000)])
        laterLaunch.invalidateSession()
        laterLaunch.listenerDidRetire()
        check("lifecycle overlap: cleaning one simultaneous session cannot cross-delete its sibling backing",
              activeSibling.contains(siblingKey)
                  && FileManager.default.fileExists(atPath: activeSibling.sessionDirectory.path))
        withExtendedLifetime((activeSibling, laterLaunch)) {}
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
        let engineContract = try? String(contentsOf: playerURL.appendingPathComponent("PlayerEngine.swift"),
                                         encoding: .utf8)
        let resumePolicy = try? String(contentsOf: playerURL.appendingPathComponent("RemuxResumePolicy.swift"),
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
        let spoolResourceResponse = sourceSection(
            server,
            from: "private func serveSpoolResource(",
            to: "// MARK: - Response helpers")
        let masterPublication = sourceSection(
            server,
            from: "private func prepareMasterPublication()",
            to: "private func logStartupCohortTimeout()")
        let rollingPublication = sourceSection(
            server,
            from: "private func currentPublication()",
            to: "private func topologyMatches(")
        let publicationReceipt = sourceSection(
            server,
            from: "private func recordPublication(",
            to: "private func exactWindow(")
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
        check("wiring: segment URIs resolve directly through durable absolute-id spool keys",
              videoSegmentResponse?.contains("key: .video(segmentID: index)") == true
                  && videoSegmentResponse?.contains("window.segment(id:") == false
                  && audioSegmentResponse?.contains(
                    "key: .audio(renditionID: renditionID, segmentID: segmentID)") == true)
        check("wiring: every media route opens its durable lease before constructing a 200 response",
              sourceContainsInOrder(spoolResourceResponse, [
                "stream.openHLSResource(key)",
                "VortXSpoolResponsePump(",
                "HTTP/1.1 200 OK",
                "response.start(",
              ]))
        check("wiring: the shared durable response pump uses one bounded 512 KiB chunk size",
              spoolResourceResponse?.contains("chunkSize: Self.segmentChunk") == true
                  && server?.contains("private static let segmentChunk = 512 * 1024") == true)
        check("wiring: one snapshot binds durable video backing and optional feature state",
              immutableSnapshot?.contains("_hlsSegments.filter") == true
                  && immutableSnapshot?.contains("hlsSpool?.contains(.video(segmentID: $0.id))") == true
                  && immutableSnapshot?.contains(
                      "let audioPublished = _alternateAudioState == .ready && _alternateAudioPlan != nil") == true
                  && immutableSnapshot?.contains("audioPlan: audioPublished ? _alternateAudioPlan : nil") == true
                  && immutableSnapshot?.contains("subtitleFailureReason: _subtitleSettlement.invalidationReason") == true)
        check("wiring: master waits for one exact six-segment fifteen-second common cohort",
              masterPublication?.contains("DVPlaybackPolicy.pinnedStartupCohort(") == true
                  && masterPublication?.contains("minimumSegmentCount: Self.minimumStartupSegments") == true
                  && masterPublication?.contains(
                    "minimumRenderedDurationMilliseconds: Self.minimumStartupDurationMilliseconds") == true
                  && server?.contains("private static let minimumStartupSegments = 6") == true
                  && server?.contains(
                    "private static let minimumStartupDurationMilliseconds = 15_000") == true)
        check("wiring: post-ready reloads advance only one common contiguous rendition frontier",
              rollingPublication?.contains("greatestCommonContiguousWindow(") == true
                  && rollingPublication?.contains("DVPlaybackPolicy.minimumConformingSuffix(") == true
                  && rollingPublication?.contains(
                    "HLS publication frontier lost a previously advertised segment") == true)
        check("wiring: every logical playlist receipt is committed before a publication body is returned",
              sourceContainsInOrder(rollingPublication, [
                "recordPublication(",
                "return Publication(",
              ])
                  && publicationReceipt?.contains("stream.recordHLSPlaylist(\"/media.m3u8\"") == true
                  && publicationReceipt?.contains("/media-hdr.m3u8") == true
                  && publicationReceipt?.contains("/audio\\(plan.alternate.id).m3u8") == true
                  && publicationReceipt?.contains("/sub\\(rendition.id).m3u8") == true)
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
        check("wiring: alternate publication is filtered to durable resources sharing the video id frontier",
              immutableSnapshot?.contains("let residentIDs = Set(videoWindow.segments.map(\\.id))") == true
                  && immutableSnapshot?.contains("residentIDs.contains($0.segmentID)") == true
                  && immutableSnapshot?.contains("hlsSpool?.contains(.audio(") == true)
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
        check("wiring: subtitle playlists render only the coordinator-approved common publication",
              subtitlePlaylist?.contains("self.currentPublication()") == true
                  && subtitlePlaylist?.contains("publication.subtitles.contains") == true
                  && subtitlePlaylist?.contains("publication.subtitleWindow") == true
                  && subtitlePlaylist?.contains("snapshot.subtitleWindow") == false)
        check("wiring: every subtitle cap removes the optional publication with a typed reason",
              subtitleCollection?.contains("invalidateSubtitles(.payloadBound)") == true
                  && subtitleCollection?.contains("invalidateSubtitles(.storedBound)") == true
                  && subtitleCollection?.contains("invalidateSubtitles(.cueCountBound)") == true)
        check("wiring: subtitle invalidation cannot fail or rewrite the primary A/V stream",
              subtitleInvalidation?.contains("_subtitleRenditions.removeAll") == true
                  && subtitleInvalidation?.contains("_subtitleCues.removeAll") == true
                  && subtitleInvalidation?.contains("buffer.fail") == false
                  && subtitleInvalidation?.contains("_hlsSegments") == false)
        check("wiring: optional audio and subtitle renditions ship default-on with local rollback keys",
              stream?.contains("isFeatureOn(\"dvRemuxMultiAudio\", default: true)") == true
                  && stream?.contains("isFeatureOn(\"dvRemuxSubtitles\", default: true)") == true
                  && stream?.contains("stremiox.dvRemuxMultiAudio") == true
                  && stream?.contains("stremiox.dvRemuxSubtitles") == true)
        check("wiring: PlayerEngine exposes the exact pre-load resume-origin API",
              engineContract?.contains("func configureResumeOrigin(seconds: Double)") == true
                  && engine?.contains("func configureResumeOrigin(seconds: Double)") == true)
        check("wiring: a configured nonzero origin is consumed before the remux server is constructed",
              sourceContainsInOrder(engine, [
                "resumeConfiguration.consumeForNextLoad()",
                "let requestedRemuxOrigin = currentLoadResumeOrigin",
                "VortXRemuxHLSServer.make(",
                "startAtSeconds: requestedRemuxOrigin",
              ]))
        check("wiring: the server forwards the configured origin into the remux stream",
              sourceContainsInOrder(server, [
                "startAtSeconds: Double = 0",
                "VortXMKVRemuxStream(",
                "startAtSeconds: startAtSeconds",
              ]))
        check("wiring: resume seek, base-video origin latch and packet rebase are all live",
              stream?.contains("avformat_seek_file(") == true
                  && stream?.contains("RemuxResumePolicy.canEstablishOrigin(") == true
                  && stream?.contains("rebaseFromOrigin(p, timeBase:") == true
                  && stream?.contains("rebaseFromOrigin(pkt, timeBase:") == true
                  && engine?.contains("remuxHLSServer?.timelineOriginSeconds") == true
                  && resumePolicy?.contains("static let isEnabledByDefault = true") == true)
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
