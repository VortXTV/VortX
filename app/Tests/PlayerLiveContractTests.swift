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

/// Standalone-compilation stub for the buffer's failure-reason funnel (same pattern as the RemoteConfig stub).
enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) { print("[\(tag)] \(message)") }
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

private func posixMode(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes?[.posixPermissions] as? NSNumber else { return nil }
    return permissions.intValue & 0o777
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

private final class SpoolPermissionProbeState {
    var partMode: Int?
}

private final class BlockingStageProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false

    func callAsFunction(_ owner: VortXHLSSessionSpool) {
        _ = owner.accounting
        lock.lock()
        let shouldBlock = !blocked
        if shouldBlock { blocked = true }
        lock.unlock()
        if shouldBlock {
            entered.signal()
            release.wait()
        }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
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
        testMutableOpenStageContract()
        testMutableOpenStageFailuresAndCleanup()
        testPlaylistRetentionAndFileLeases()
        testSpoolResponsePump()
        testSessionLifecycleAndScavenge()
        testDisplayRequestLifecycle()
        testSelectionRefreshLifecycle()
        testBoundaryKeyAgreement()
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
        check("spool permissions: parent, launch and session directories are owner-only and traversable",
              posixMode(root) == 0o700
                  && posixMode(exact.sessionDirectory.deletingLastPathComponent()) == 0o700
                  && posixMode(exact.sessionDirectory) == 0o700)
        let committedURL = namesAfterFirstCommit.first.map {
            exact.sessionDirectory.appendingPathComponent($0)
        }
        check("spool permissions: committed media is owner read-write only",
              committedURL.flatMap(posixMode) == 0o600)
        check("spool permissions: no staging part remains visible after atomic promotion",
              !namesAfterFirstCommit.contains(where: { $0.hasSuffix(".part") }))

        guard let permissionSpool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 8,
            chunkSize: 2,
            scavengeStaleSessions: false) else {
            check("spool permissions: live-part fixture is creatable", false)
            return
        }
        let permissionProbe = SpoolPermissionProbeState()
        permissionSpool.installFileOperationProbe { owner in
            guard permissionProbe.partMode == nil,
                  let partName = owner.fileNamesOnDisk.first(where: { $0.hasSuffix(".part") }) else {
                return
            }
            permissionProbe.partMode = posixMode(
                owner.sessionDirectory.appendingPathComponent(partName))
        }
        check("spool permissions: staging part is already 0600 while materialization is active",
              permissionSpool.spill([.init(
                  key: .video(segmentID: 200), data: Data([1, 2, 3, 4]),
                  durationMilliseconds: 1_000)])
                  && permissionProbe.partMode == 0o600)
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
        let legalLargeGOPBytes = 33 * 1024 * 1024
        check("spool bitrate: a GOP above the retired 32 MiB guard remains logically legal through twelve seconds",
              legalLargeGOPBytes > 32 * 1024 * 1024
                  && VortXHLSBoundaryPolicy.decision(
                      hasOpenSegment: true,
                      incomingIsIDR: false,
                      incomingHasKeyFlag: false,
                      elapsed: 8) == .continueOpen)
    }

    private static func readAll(_ lease: VortXHLSSessionSpool.ResourceLease?) -> Data? {
        guard let lease else { return nil }
        defer { lease.close(now: 0) }
        var result = Data()
        do {
            while result.count < lease.length {
                let chunk = try lease.read(maxLength: 3)
                guard !chunk.isEmpty else { return nil }
                result.append(chunk)
            }
            return result
        } catch {
            return nil
        }
    }

    /// Phase-2 open-GOP storage contract. Tiny producer limits make every RAM -> disk edge executable without
    /// allocating the production 80 MiB pre-ready window; the linked movenc harness owns the real >80 MiB case.
    private static func testMutableOpenStageContract() {
        let root = scratchDirectory("open-stage")
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        guard let spool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 64,
            chunkSize: 2,
            scavengeStaleSessions: false),
              let stage = spool.attachOpenStage(to: buffer) else {
            check("open stage: session and attachment are creatable", false)
            return
        }

        append([0, 1, 2, 3, 4, 5, 6, 7], to: buffer)
        check("open stage adoption: arming after init adopts every already-produced media byte",
              stage.arm(base: 4)
                  && stage.snapshot.storage == .memory
                  && stage.snapshot.baseOffset == 4
                  && stage.snapshot.logicalEndOffset == 8
                  && spool.accounting.openBytes == 4
                  && spool.accounting.admittedBytes == 4)

        let straddlingPatch: [UInt8] = [90, 91, 92, 93]
        let patched = straddlingPatch.withUnsafeBufferPointer { raw in
            buffer.overwrite(at: 2, bytes: raw.baseAddress!, count: raw.count)
        }
        var adoptedBytes: Data?
        if let claim = stage.claim() {
            _ = claim.withBytes { adoptedBytes = Data([UInt8]($0)) }
            claim.release()
        }
        check("open stage mutation: a closed-prefix/open-prefix straddling patch updates the mutable suffix",
              patched && adoptedBytes == Data([92, 93, 6, 7]))

        append([8, 9, 10, 11], to: buffer)
        let active = stage.snapshot
        check("open stage activation: projected RAM pressure backfills under a lease before the append crosses",
              active.storage == .active
                  && active.baseOffset == 4
                  && active.logicalEndOffset == 12
                  && active.durableEndOffset == 12
                  && spool.accounting.openBytes == 8)
        check("open stage permissions: UUID directories are 0700 and the live stage is 0600",
              posixMode(root) == 0o700
                  && posixMode(spool.sessionDirectory.deletingLastPathComponent()) == 0o700
                  && posixMode(spool.sessionDirectory) == 0o700
                  && active.fileURL.flatMap(posixMode) == 0o600)
        check("open stage pressure: durable bytes leave the resident buffer instead of parking at its ceiling",
              buffer.residentByteRange.lowerBound == buffer.residentByteRange.upperBound)

        let whollyClosedPatch: [UInt8] = [40, 41]
        let whollyClosedBestEffort = whollyClosedPatch.withUnsafeBufferPointer { raw in
            buffer.overwrite(at: 0, bytes: raw.baseAddress!, count: raw.count)
        }
        var bytesAfterWhollyClosedPatch: Data?
        if let claim = stage.claim() {
            _ = claim.withBytes { bytesAfterWhollyClosedPatch = Data([UInt8]($0)) }
            claim.release()
        }
        check("open stage mutation: a patch wholly below the mutable base remains a safe best effort",
              whollyClosedBestEffort
                  && bytesAfterWhollyClosedPatch == Data([92, 93, 6, 7, 8, 9, 10, 11]))

        let exactUpperPatch: [UInt8] = [60, 61]
        let exactUpperAccepted = exactUpperPatch.withUnsafeBufferPointer { raw in
            buffer.overwrite(at: 10, bytes: raw.baseAddress!, count: raw.count)
        }
        check("open stage mutation: a patch ending exactly at the produced head is accepted",
              exactUpperAccepted && stage.snapshot.logicalEndOffset == 12)

        let closedPrefixPatch: [UInt8] = [70, 71, 72, 73, 74, 75]
        let closedPrefixBestEffort = closedPrefixPatch.withUnsafeBufferPointer { raw in
            buffer.overwrite(at: 1, bytes: raw.baseAddress!, count: raw.count)
        }
        var patchedOpenBytes: Data?
        if let claim = stage.claim() {
            _ = claim.withBytes { patchedOpenBytes = Data([UInt8]($0)) }
            claim.release()
        }
        check("open stage mutation: an evicted closed prefix is best effort but overlapping mutable bytes are mandatory",
              closedPrefixBestEffort
                  && patchedOpenBytes?.prefix(3) == Data([73, 74, 75]))

        guard let activeClaim = stage.claim() else {
            check("open stage: active prefix can be claimed", false)
            return
        }
        var mappedCopy: Data?
        let mapped = activeClaim.withBytes { mappedCopy = Data([UInt8]($0)) }
        check("open stage mmap: a claim exposes the full durable prefix synchronously and returns no mapping",
              mapped
                  && mappedCopy == Data([73, 74, 75, 7, 8, 9, 60, 61])
                  && stage.snapshot.activeClaimReads == 0)

        let readEntered = DispatchSemaphore(value: 0)
        let allowReadFinish = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = activeClaim.withBytes { _ in
                readEntered.signal()
                allowReadFinish.wait()
            }
            readFinished.signal()
        }
        let blockingReadStarted = readEntered.wait(timeout: .now() + 2) == .success
        let fileBytesBeforeBlockedClose = active.fileURL.flatMap { try? Data(contentsOf: $0) }
        let blockedKey = VortXHLSSessionSpool.ResourceKey.video(segmentID: 99)
        let closeWhileReading = stage.closePrefix(
            activeClaim,
            endOffset: 8,
            key: blockedKey,
            durationMilliseconds: 4_000,
            additionalResources: [])
        let duringBlockedClose = stage.snapshot
        let fileBytesAfterBlockedClose = active.fileURL.flatMap { try? Data(contentsOf: $0) }
        check("open stage claim race: close cannot consume, truncate, or rename while claim bytes are in use",
              blockingReadStarted
                  && !closeWhileReading
                  && duringBlockedClose.storage == .active
                  && duringBlockedClose.activeClaimReads == 1
                  && duringBlockedClose.baseOffset == 4
                  && duringBlockedClose.logicalEndOffset == 12
                  && !spool.contains(blockedKey)
                  && fileBytesAfterBlockedClose == fileBytesBeforeBlockedClose)
        allowReadFinish.signal()
        let blockingReadFinished = readFinished.wait(timeout: .now() + 2) == .success
        check("open stage claim race: completing the read restores the same exact claim for close",
              blockingReadFinished && stage.snapshot.activeClaimReads == 0)

        let video0 = VortXHLSSessionSpool.ResourceKey.video(segmentID: 0)
        check("open stage active P+S: close copies only S and atomically transfers P into final accounting",
              stage.closePrefix(
                  activeClaim,
                  endOffset: 8,
                  key: video0,
                  durationMilliseconds: 4_000,
                  additionalResources: [])
                  && spool.contains(video0)
                  && readAll(spool.openResource(video0, now: 0)) == Data([73, 74, 75, 7])
                  && stage.snapshot.baseOffset == 8
                  && stage.snapshot.logicalEndOffset == 12
                  && stage.snapshot.storage == .active
                  && spool.accounting.finalBytes == 4
                  && spool.accounting.openBytes == 4
                  && spool.accounting.transientCopyBytes == 0
                  && spool.accounting.peakTransientCopyBytes == 4
                  && spool.accounting.admittedBytes == 8
                  && spool.accounting.physicalBytes == 8)

        let activeAppendRoot = scratchDirectory("open-stage-active-append-physical-cap")
        defer { try? FileManager.default.removeItem(at: activeAppendRoot) }
        let activeAppendBuffer = VortXRemuxBuffer(windowFloorBytes: 8, producerLeadBytes: 1)
        if let activeAppendSpool = VortXHLSSessionSpool(
            parentDirectory: activeAppendRoot,
            capacityBytes: 26,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let activeAppendStage = activeAppendSpool.attachOpenStage(to: activeAppendBuffer) {
            let auxiliaryAccepted = activeAppendSpool.setAuxiliaryBytes(2)
            append([0, 1, 2, 3, 4, 5, 6, 7, 8], to: activeAppendBuffer)
            let armed = activeAppendStage.arm(base: 1)
            let exactCapAuxiliaryAccepted = activeAppendSpool.setAuxiliaryBytes(8)
            let backingAfterActivation = activeAppendBuffer.residentBackingSnapshot
            append([9, 10], to: activeAppendBuffer)
            append([11, 12], to: activeAppendBuffer)
            append([13, 14], to: activeAppendBuffer)

            let blocker = BlockingStageProbe()
            activeAppendSpool.installFileOperationProbe(blocker.callAsFunction)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                append([15, 16], to: activeAppendBuffer)
                finished.signal()
            }
            let entered = blocker.entered.wait(timeout: .now() + 2) == .success
            let peak = activeAppendSpool.accounting
            let backingAtExactCap = activeAppendBuffer.residentBackingSnapshot
            let claimDuringAppend = activeAppendStage.claim()
            claimDuringAppend?.release()
            let spillRejected = !activeAppendSpool.spill([.init(
                key: .subtitle(renditionID: 0, segmentID: 19),
                data: Data([1]),
                durationMilliseconds: 1_000)])
            let auxiliaryRejected = !activeAppendSpool.setAuxiliaryBytes(9)
            blocker.release.signal()
            let ended = finished.wait(timeout: .now() + 2) == .success
            let backingAfterAppends = activeAppendBuffer.residentBackingSnapshot
            let snapshot = activeAppendStage.snapshot
            var claimedBytes: Data?
            if let claim = activeAppendStage.claim() {
                _ = claim.withBytes { claimedBytes = Data([UInt8]($0)) }
                claim.release()
            }
            let fileBytes = snapshot.fileURL.flatMap { try? Data(contentsOf: $0) }
            check("open stage active append physical cap: each sub-floor append is admitted at the exact ceiling",
                  auxiliaryAccepted
                      && armed
                      && exactCapAuxiliaryAccepted
                      && entered
                      && peak.openBytes == 14
                      && peak.reservedBytes == 2
                      && peak.admittedBytes == 24
                      && peak.transientCopyBytes == 2
                      && peak.physicalBytes == 26
                      && claimDuringAppend == nil
                      && spillRejected
                      && auxiliaryRejected
                      && ended
                      && activeAppendSpool.accounting.openBytes == 16
                      && activeAppendSpool.accounting.reservedBytes == 0
                      && activeAppendSpool.accounting.transientCopyBytes == 0
                      && activeAppendSpool.accounting.physicalBytes == 24)
            check("open stage active append backing: durable appends never materialize into resident Data",
                  backingAfterActivation.capacityBytes == 0
                      && backingAfterActivation.logicalBytes == 0
                      && backingAtExactCap == backingAfterActivation
                      && backingAfterAppends == backingAfterActivation
                      && activeAppendBuffer.residentByteRange == 17..<17)
            check("open stage active append continuity: durable storage owns every byte with no buffer gap",
                  activeAppendBuffer.status().produced == 17
                      && activeAppendBuffer.status().failure == nil
                      && snapshot.storage == .active
                      && snapshot.baseOffset == 1
                      && snapshot.logicalEndOffset == 17
                      && snapshot.durableEndOffset == 17
                      && fileBytes == Data([1, 2, 3, 4, 5, 6, 7, 8,
                                            9, 10, 11, 12, 13, 14, 15, 16])
                      && claimedBytes == fileBytes)
        } else {
            check("open stage active append physical cap: fixture is creatable", false)
        }

        let ramBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 32)
        guard let ramSpool = VortXHLSSessionSpool(
            parentDirectory: root,
            capacityBytes: 35,
            chunkSize: 2,
            scavengeStaleSessions: false),
              let ramStage = ramSpool.attachOpenStage(to: ramBuffer) else {
            check("open stage RAM P+S: fixture is creatable", false)
            return
        }
        append([0, 1, 2, 3], to: ramBuffer)
        guard ramStage.arm(base: 4) else {
            check("open stage RAM P+S: empty frontier arms", false)
            return
        }
        append([10, 11, 12, 13, 14, 15], to: ramBuffer)
        guard let ramClaim = ramStage.claim() else {
            check("open stage RAM P+S: prefix can be claimed", false)
            return
        }
        let ramVideo = VortXHLSSessionSpool.ResourceKey.video(segmentID: 20)
        let ramClosed = ramStage.closePrefix(
            ramClaim,
            endOffset: 7,
            key: ramVideo,
            durationMilliseconds: 3_000,
            additionalResources: [])
        check("open stage RAM P+S: duplicate-copy charge spans the full old backing until exact compaction",
              ramClosed
                  && readAll(ramSpool.openResource(ramVideo, now: 0)) == Data([10, 11, 12])
                  && ramStage.snapshot.storage == .memory
                  && ramStage.snapshot.baseOffset == 7
                  && ramStage.snapshot.logicalEndOffset == 10
                  && ramSpool.accounting.finalBytes == 3
                  && ramSpool.accounting.openBytes == 3
                  && ramSpool.accounting.transientCopyBytes == 0
                  && ramSpool.accounting.peakTransientCopyBytes == 19
                  && ramSpool.accounting.physicalBytes == 19
                  && ramBuffer.residentBackingSnapshot.capacityBytes == 16
                  && ramBuffer.residentBackingSnapshot.logicalBytes == 3
                  && ramBuffer.residentByteRange == 7..<10
                  && ramBuffer.snapshotChunk(offset: 7, length: 3) == Data([13, 14, 15]))

        let ramCapRoot = scratchDirectory("open-stage-ram-physical-cap")
        defer { try? FileManager.default.removeItem(at: ramCapRoot) }
        let ramCapBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 32)
        if let ramCapSpool = VortXHLSSessionSpool(
            parentDirectory: ramCapRoot,
            capacityBytes: Int.max,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let ramCapStage = ramCapSpool.attachOpenStage(to: ramCapBuffer) {
            let auxiliary = Int.max - 35
            _ = ramCapSpool.setAuxiliaryBytes(auxiliary)
            append([0, 1, 2, 3], to: ramCapBuffer)
            _ = ramCapStage.arm(base: 4)
            append([10, 11, 12, 13, 14, 15], to: ramCapBuffer)
            if let claim = ramCapStage.claim() {
                let blocker = BlockingStageProbe()
                ramCapSpool.installFileOperationProbe(blocker.callAsFunction)
                let result = LockedBool()
                let finished = DispatchSemaphore(value: 0)
                let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 21)
                DispatchQueue.global(qos: .userInitiated).async {
                    result.set(ramCapStage.closePrefix(
                        claim,
                        endOffset: 7,
                        key: key,
                        durationMilliseconds: 3_000,
                        additionalResources: []))
                    finished.signal()
                }
                let entered = blocker.entered.wait(timeout: .now() + 2) == .success
                let peak = ramCapSpool.accounting
                let spillRejected = !ramCapSpool.spill([.init(
                    key: .subtitle(renditionID: 0, segmentID: 21),
                    data: Data([1]),
                    durationMilliseconds: 3_000)])
                let auxiliaryRejected = !ramCapSpool.setAuxiliaryBytes(auxiliary + 1)
                blocker.release.signal()
                let ended = finished.wait(timeout: .now() + 2) == .success
                check("open stage RAM physical cap: full old backing is reserved at exact capacity",
                      entered
                          && peak.admittedBytes == Int.max - 29
                          && peak.transientCopyBytes == 19
                          && peak.physicalBytes == Int.max
                          && spillRejected
                          && auxiliaryRejected
                          && ended
                          && result.value
                          && ramCapSpool.contains(key)
                          && ramCapSpool.accounting.transientCopyBytes == 0
                          && ramCapSpool.accounting.physicalBytes == Int.max - 16
                          && ramCapBuffer.residentByteRange == 7..<10)
            } else {
                check("open stage RAM physical cap: exact claim is available", false)
            }
        } else {
            check("open stage RAM physical cap: fixture is creatable", false)
        }

        let ramRejectRoot = scratchDirectory("open-stage-ram-transient-reject")
        defer { try? FileManager.default.removeItem(at: ramRejectRoot) }
        let ramRejectBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 32)
        if let ramRejectSpool = VortXHLSSessionSpool(
            parentDirectory: ramRejectRoot,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let ramRejectStage = ramRejectSpool.attachOpenStage(to: ramRejectBuffer) {
            append([0, 1, 2, 3], to: ramRejectBuffer)
            _ = ramRejectStage.arm(base: 4)
            append([10, 11, 12, 13, 14, 15], to: ramRejectBuffer)
            if let claim = ramRejectStage.claim() {
                let rejected = !ramRejectStage.closePrefix(
                    claim,
                    endOffset: 7,
                    key: .video(segmentID: 22),
                    durationMilliseconds: 3_000,
                    additionalResources: [])
                check("open stage RAM physical cap: no transient headroom rejects before any artifact",
                      rejected
                          && ramRejectSpool.accounting.openBytes == 6
                          && ramRejectSpool.accounting.reservedBytes == 0
                          && ramRejectSpool.accounting.transientCopyBytes == 0
                          && ramRejectSpool.fileNamesOnDisk.isEmpty
                          && ramRejectBuffer.status().failure != nil)
            } else {
                check("open stage RAM physical cap rejection: exact claim is available", false)
            }
        } else {
            check("open stage RAM physical cap rejection: fixture is creatable", false)
        }

        let retainedInitRoot = scratchDirectory("open-stage-retained-init-cap")
        defer { try? FileManager.default.removeItem(at: retainedInitRoot) }
        let retainedInitBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        if let retainedInitSpool = VortXHLSSessionSpool(
            parentDirectory: retainedInitRoot,
            capacityBytes: 4,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let retainedInitStage = retainedInitSpool.attachOpenStage(to: retainedInitBuffer) {
            append([0, 1, 2, 3, 4, 5, 6, 7], to: retainedInitBuffer)
            check("open stage arm physical cap: retained pre-base backing cannot hide outside admission",
                  !retainedInitStage.arm(base: 4)
                      && retainedInitStage.snapshot.storage == .dormant
                      && retainedInitSpool.accounting.openBytes == 0
                      && retainedInitSpool.accounting.physicalBytes == 0)
        } else {
            check("open stage arm physical cap: retained-init fixture is creatable", false)
        }
    }

    private static func testMutableOpenStageFailuresAndCleanup() {
        func makeStage(
            _ label: String,
            injection: VortXHLSSessionSpool.FailureInjection
        ) -> (URL, VortXRemuxBuffer, VortXHLSSessionSpool, VortXHLSSessionSpool.OpenStage)? {
            let root = scratchDirectory(label)
            let buffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
            guard let spool = VortXHLSSessionSpool(
                parentDirectory: root,
                capacityBytes: 34,
                chunkSize: 2,
                failureInjection: injection,
                scavengeStaleSessions: false),
                  let stage = spool.attachOpenStage(to: buffer) else {
                try? FileManager.default.removeItem(at: root)
                return nil
            }
            append([0, 1, 2, 3, 4], to: buffer)
            guard stage.arm(base: 1) else {
                try? FileManager.default.removeItem(at: root)
                return nil
            }
            return (root, buffer, spool, stage)
        }

        if let (root, buffer, spool, stage) = makeStage(
            "open-stage-rollback",
            injection: .openStageForwardWrite(afterBytes: 1, rollbackFails: false)) {
            defer { try? FileManager.default.removeItem(at: root) }
            let before = spool.accounting
            append([5, 6, 7], to: buffer)
            check("open stage failure: a partial forward write truncates to the old durable end",
                  buffer.status().failure != nil
                      && stage.snapshot.storage == .active
                      && stage.snapshot.logicalEndOffset == 5
                      && stage.snapshot.durableEndOffset == 5)
            check("open stage failure: failed growth releases its uncovered reservation",
                  spool.accounting.openBytes == before.openBytes
                      && spool.accounting.reservedBytes == 0
                      && spool.accounting.admittedBytes == before.admittedBytes)
        } else {
            check("open stage failure: rollback fixture is creatable", false)
        }

        if let (root, buffer, spool, stage) = makeStage(
            "open-stage-future-backpatch",
            injection: .openStageFstat) {
            defer { try? FileManager.default.removeItem(at: root) }
            let futurePatch: [UInt8] = [80, 81]
            let accepted = futurePatch.withUnsafeBufferPointer { raw in
                buffer.overwrite(at: 4, bytes: raw.baseAddress!, count: raw.count)
            }
            check("open stage mutation: a patch extending beyond the produced head is terminally rejected",
                  !accepted
                      && buffer.status().failure != nil
                      && stage.snapshot.logicalEndOffset == 5)
            withExtendedLifetime(spool) {}
        } else {
            check("open stage mutation: future-backpatch fixture is creatable", false)
        }

        if let (root, buffer, spool, stage) = makeStage(
            "open-stage-poison",
            injection: .openStageForwardWrite(afterBytes: 1, rollbackFails: true)) {
            defer { try? FileManager.default.removeItem(at: root) }
            append([5, 6, 7], to: buffer)
            let laterAdmissionRejected = !spool.setAuxiliaryBytes(1)
            check("open stage failure: failed partial-write rollback poisons the stage",
                  buffer.status().failure != nil
                      && stage.snapshot.storage == .poisoned
                      && laterAdmissionRejected)
            withExtendedLifetime(spool) {}
        } else {
            check("open stage failure: poison fixture is creatable", false)
        }

        let activationCapRoot = scratchDirectory("open-stage-activation-physical-cap")
        defer { try? FileManager.default.removeItem(at: activationCapRoot) }
        let activationCapBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        if let activationCapSpool = VortXHLSSessionSpool(
            parentDirectory: activationCapRoot,
            capacityBytes: Int.max,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let activationCapStage = activationCapSpool.attachOpenStage(to: activationCapBuffer) {
            let auxiliary = Int.max - 20
            _ = activationCapSpool.setAuxiliaryBytes(auxiliary)
            append([0, 1, 2, 3, 4], to: activationCapBuffer)
            let blocker = BlockingStageProbe()
            activationCapSpool.installFileOperationProbe(blocker.callAsFunction)
            let armed = LockedBool()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                armed.set(activationCapStage.arm(base: 1))
                finished.signal()
            }
            let entered = blocker.entered.wait(timeout: .now() + 2) == .success
            let peak = activationCapSpool.accounting
            let spillRejected = !activationCapSpool.spill([.init(
                key: .subtitle(renditionID: 0, segmentID: 30),
                data: Data([1]),
                durationMilliseconds: 1_000)])
            let auxiliaryRejected = !activationCapSpool.setAuxiliaryBytes(auxiliary + 1)
            blocker.release.signal()
            let ended = finished.wait(timeout: .now() + 2) == .success
            check("open stage activation physical cap: full RAM range is charged at exact capacity",
                  entered
                      && peak.admittedBytes == Int.max - 16
                      && peak.transientCopyBytes == 4
                      && peak.physicalBytes == Int.max
                      && spillRejected
                      && auxiliaryRejected
                      && ended
                      && armed.value
                      && activationCapStage.snapshot.storage == .active
                      && activationCapSpool.accounting.transientCopyBytes == 0
                      && activationCapSpool.accounting.physicalBytes
                          == activationCapSpool.accounting.admittedBytes
                      && activationCapBuffer.residentByteRange == 5..<5)
        } else {
            check("open stage activation physical cap: fixture is creatable", false)
        }

        let activationRejectRoot = scratchDirectory("open-stage-activation-transient-reject")
        defer { try? FileManager.default.removeItem(at: activationRejectRoot) }
        let activationRejectBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        if let activationRejectSpool = VortXHLSSessionSpool(
            parentDirectory: activationRejectRoot,
            capacityBytes: 19,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let activationRejectStage = activationRejectSpool.attachOpenStage(to: activationRejectBuffer) {
            _ = activationRejectSpool.setAuxiliaryBytes(3)
            append([0, 1, 2, 3, 4], to: activationRejectBuffer)
            let rejected = !activationRejectStage.arm(base: 1)
            check("open stage activation physical cap: no transient headroom fails before file creation",
                  rejected
                      && activationRejectStage.snapshot.storage == .poisoned
                      && activationRejectSpool.accounting.openBytes == 0
                      && activationRejectSpool.accounting.auxiliaryBytes == 3
                      && activationRejectSpool.accounting.reservedBytes == 0
                      && activationRejectSpool.accounting.transientCopyBytes == 0
                      && activationRejectSpool.fileNamesOnDisk.isEmpty
                      && activationRejectBuffer.status().failure != nil)
        } else {
            check("open stage activation physical cap rejection: fixture is creatable", false)
        }

        let activationCancelRoot = scratchDirectory("open-stage-activation-cancel")
        defer { try? FileManager.default.removeItem(at: activationCancelRoot) }
        let activationCancelBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        if let activationCancelSpool = VortXHLSSessionSpool(
            parentDirectory: activationCancelRoot,
            capacityBytes: 32,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let activationCancelStage = activationCancelSpool.attachOpenStage(to: activationCancelBuffer) {
            append([0, 1, 2, 3, 4], to: activationCancelBuffer)
            let blocker = BlockingStageProbe()
            activationCancelSpool.installFileOperationProbe(blocker.callAsFunction)
            let armed = LockedBool()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                armed.set(activationCancelStage.arm(base: 1))
                finished.signal()
            }
            let entered = blocker.entered.wait(timeout: .now() + 2) == .success
            activationCancelSpool.invalidateSession()
            blocker.release.signal()
            let ended = finished.wait(timeout: .now() + 2) == .success
            check("open stage activation cancellation: cleanup balances the transient reservation",
                  entered
                      && ended
                      && !armed.value
                      && activationCancelStage.snapshot.storage == .poisoned
                      && activationCancelSpool.accounting.openBytes == 0
                      && activationCancelSpool.accounting.reservedBytes == 0
                      && activationCancelSpool.accounting.transientCopyBytes == 0
                      && activationCancelSpool.fileNamesOnDisk.isEmpty
                      && activationCancelBuffer.status().failure != nil)
            activationCancelSpool.producerDidTerminate()
            activationCancelSpool.listenerDidRetire()
            check("open stage activation cancellation: terminal cleanup releases the session",
                  !FileManager.default.fileExists(
                      atPath: activationCancelSpool.sessionDirectory.path)
                      && activationCancelSpool.accounting.physicalBytes == 0)
        } else {
            check("open stage activation cancellation: fixture is creatable", false)
        }

        let activationQuarantineRoot = scratchDirectory("open-stage-activation-quarantine")
        defer { try? FileManager.default.removeItem(at: activationQuarantineRoot) }
        let activationQuarantineBuffer = VortXRemuxBuffer(
            windowFloorBytes: 1, producerLeadBytes: 4)
        if let activationQuarantineSpool = VortXHLSSessionSpool(
            parentDirectory: activationQuarantineRoot,
            capacityBytes: 32,
            chunkSize: 2,
            failureInjection: .openStageActivationCleanupRemoveOnce,
            scavengeStaleSessions: false),
           let activationQuarantineStage = activationQuarantineSpool.attachOpenStage(
               to: activationQuarantineBuffer) {
            append([0, 1, 2, 3, 4], to: activationQuarantineBuffer)
            let rejected = !activationQuarantineStage.arm(base: 1)
            let retained = activationQuarantineSpool.accounting
            let receipts = activationQuarantineSpool.quarantinedFileNames
            let spillRejected = !activationQuarantineSpool.spill([.init(
                key: .subtitle(renditionID: 0, segmentID: 31),
                data: Data([1]),
                durationMilliseconds: 1_000)])
            check("open stage activation cleanup failure: surviving receipt is quarantined before charge release",
                  rejected
                      && receipts.count == 1
                      && activationQuarantineSpool.fileNamesOnDisk == receipts
                      && retained.openBytes == 0
                      && retained.reservedBytes == 0
                      && retained.transientCopyBytes == 0
                      && retained.quarantinedBytes == 4
                      && retained.physicalBytes == 4
                      && spillRejected
                      && activationQuarantineStage.snapshot.storage == .poisoned
                      && activationQuarantineBuffer.status().failure != nil)
            activationQuarantineSpool.producerDidTerminate()
            activationQuarantineSpool.listenerDidRetire()
            check("open stage activation cleanup failure: terminal retry clears quarantine accounting",
                  !FileManager.default.fileExists(
                      atPath: activationQuarantineSpool.sessionDirectory.path)
                      && activationQuarantineSpool.quarantinedFileNames.isEmpty
                      && activationQuarantineSpool.accounting.physicalBytes == 0)
        } else {
            check("open stage activation cleanup failure: fixture is creatable", false)
        }

        for (label, injection) in [
            ("create", VortXHLSSessionSpool.FailureInjection.openStageCreatePermission),
            ("move", VortXHLSSessionSpool.FailureInjection.openStageMovePermission),
        ] {
            let root = scratchDirectory("open-stage-\(label)-permission")
            defer { try? FileManager.default.removeItem(at: root) }
            let buffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 32)
            guard let spool = VortXHLSSessionSpool(
                parentDirectory: root,
                capacityBytes: 34,
                chunkSize: 2,
                failureInjection: injection,
                scavengeStaleSessions: false),
                  let stage = spool.attachOpenStage(to: buffer) else {
                check("open stage permission: \(label) fixture is creatable", false)
                continue
            }
            append([0, 1, 2, 3, 4, 5], to: buffer)
            guard stage.arm(base: 2), let claim = stage.claim() else {
                check("open stage permission: \(label) RAM claim is available", false)
                continue
            }
            let key = VortXHLSSessionSpool.ResourceKey.video(
                segmentID: label == "create" ? 93 : 94)
            check("open stage permission: post-\(label) verification failure rolls back every artifact",
                  !stage.closePrefix(
                      claim,
                      endOffset: 4,
                      key: key,
                      durationMilliseconds: 2_000,
                      additionalResources: [])
                      && !spool.contains(key)
                      && spool.accounting.finalBytes == 0
                      && spool.accounting.reservedBytes == 0
                      && spool.fileNamesOnDisk.isEmpty
                      && buffer.status().failure != nil)
        }

        let quarantineRoot = scratchDirectory("open-stage-permission-quarantine")
        defer { try? FileManager.default.removeItem(at: quarantineRoot) }
        let quarantineBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 2)
        if let quarantineSpool = VortXHLSSessionSpool(
            parentDirectory: quarantineRoot,
            capacityBytes: 32,
            chunkSize: 2,
            failureInjection: .openStageMovePermissionCleanupRemoveOnce,
            scavengeStaleSessions: false),
           let quarantineStage = quarantineSpool.attachOpenStage(to: quarantineBuffer) {
            append([0, 1, 2, 3, 4, 5, 6, 7, 8], to: quarantineBuffer)
            if quarantineStage.arm(base: 1), let claim = quarantineStage.claim() {
                let failed = !quarantineStage.closePrefix(
                    claim,
                    endOffset: 5,
                    key: .video(segmentID: 98),
                    durationMilliseconds: 4_000,
                    additionalResources: [])
                let retained = quarantineSpool.accounting
                let receiptNames = quarantineSpool.quarantinedFileNames
                let diskNames = quarantineSpool.fileNamesOnDisk
                let spillRejected = !quarantineSpool.spill([.init(
                    key: .subtitle(renditionID: 0, segmentID: 98),
                    data: Data([1]),
                    durationMilliseconds: 4_000)])
                let auxiliaryRejected = !quarantineSpool.setAuxiliaryBytes(1)
                check("open stage permission quarantine: failed first removal retains receipt, charge and invalidation",
                      failed
                          && receiptNames.count == 1
                          && diskNames == receiptNames
                          && retained.openBytes == 8
                          && retained.reservedBytes == 0
                          && retained.transientCopyBytes == 0
                          && retained.quarantinedBytes == 4
                          && retained.physicalBytes == 12
                          && spillRejected
                          && auxiliaryRejected
                          && quarantineBuffer.status().failure != nil)
                quarantineSpool.producerDidTerminate()
                quarantineSpool.listenerDidRetire()
                check("open stage permission quarantine: terminal directory retry clears receipts and accounting",
                      !FileManager.default.fileExists(atPath: quarantineSpool.sessionDirectory.path)
                          && quarantineSpool.quarantinedFileNames.isEmpty
                          && quarantineSpool.accounting.admittedBytes == 0
                          && quarantineSpool.accounting.physicalBytes == 0
                          && VortXHLSSessionSpool.registeredSessionCount(
                              parentDirectory: quarantineRoot) == 0)
            } else {
                check("open stage permission quarantine: active claim is available", false)
            }
        } else {
            check("open stage permission quarantine: fixture is creatable", false)
        }

        for (label, injection) in [
            ("fstat", VortXHLSSessionSpool.FailureInjection.openStageFstat),
            ("mmap", VortXHLSSessionSpool.FailureInjection.openStageMMap),
        ] {
            guard let (root, buffer, spool, stage) = makeStage("open-stage-\(label)", injection: injection) else {
                check("open stage failure: \(label) fixture is creatable", false)
                continue
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let claim = stage.claim()
            let mapped = claim?.withBytes { _ in } ?? false
            claim?.release()
            check("open stage failure: injected \(label) failure is terminal instead of falling back to RAM",
                  !mapped && buffer.status().failure != nil)
            withExtendedLifetime(spool) {}
        }

        let atomicRoot = scratchDirectory("open-stage-atomic-arm")
        defer { try? FileManager.default.removeItem(at: atomicRoot) }
        let atomicBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        if let atomicSpool = VortXHLSSessionSpool(
            parentDirectory: atomicRoot,
            capacityBytes: 18,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let atomicStage = atomicSpool.attachOpenStage(to: atomicBuffer) {
            _ = atomicSpool.setAuxiliaryBytes(2)
            append([0, 1, 2, 3], to: atomicBuffer)
            check("open stage arm: next auxiliary plus adopted open bytes reject atomically at the cap",
                  !atomicStage.arm(base: 2, auxiliaryBytes: 5)
                      && atomicStage.snapshot.storage == .dormant
                      && atomicSpool.accounting.auxiliaryBytes == 2
                      && atomicSpool.accounting.openBytes == 0
                      && atomicSpool.accounting.admittedBytes == 2)
        } else {
            check("open stage arm: atomic-admission fixture is creatable", false)
        }

        let auxiliaryRoot = scratchDirectory("open-stage-auxiliary-generation")
        defer { try? FileManager.default.removeItem(at: auxiliaryRoot) }
        let auxiliaryBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 2)
        if let auxiliarySpool = VortXHLSSessionSpool(
            parentDirectory: auxiliaryRoot,
            capacityBytes: 31,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let auxiliaryStage = auxiliarySpool.attachOpenStage(to: auxiliaryBuffer) {
            let auxiliaryLedger = VortXHLSAuxiliaryAccounting(spool: auxiliarySpool)
            let audioCharged = auxiliaryLedger.update(alternateAudioInit: 4)
            append([0, 1, 2, 3, 4, 5, 6, 7], to: auxiliaryBuffer)
            let activationBlocker = BlockingStageProbe()
            auxiliarySpool.installFileOperationProbe(activationBlocker.callAsFunction)
            let armResult = LockedBool()
            let armFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                armResult.set(auxiliaryLedger.armPrimary(
                    stage: auxiliaryStage,
                    base: 2,
                    primaryInitBytes: 3))
                armFinished.signal()
            }
            let activationEntered = activationBlocker.entered.wait(timeout: .now() + 2) == .success
            let timeoutCleared = auxiliaryLedger.omitAlternateAudioInitOnTimeout()
            let afterTimeout = auxiliarySpool.accounting
            let componentSnapshot = auxiliaryLedger.snapshot
            let retainedPrimaryConsumesCapacity = !auxiliarySpool.spill([.init(
                key: .subtitle(renditionID: 0, segmentID: 96),
                data: Data(repeating: 7, count: 23),
                durationMilliseconds: 4_000)])
            activationBlocker.release.signal()
            let armEnded = armFinished.wait(timeout: .now() + 2) == .success
            check("open stage auxiliary transaction: timeout after coordinator charge retains primary init capacity",
                  audioCharged
                      && activationEntered
                      && timeoutCleared
                      && afterTimeout.openBytes == 6
                      && afterTimeout.auxiliaryBytes == 3
                      && afterTimeout.transientCopyBytes == 6
                      && afterTimeout.physicalBytes == 25
                      && componentSnapshot.primaryInitBytes == 3
                      && componentSnapshot.alternateAudioInitBytes == 0
                      && retainedPrimaryConsumesCapacity
                      && armEnded
                      && armResult.value
                      && auxiliaryStage.snapshot.storage == .active)
        } else {
            check("open stage auxiliary transaction: fixture is creatable", false)
        }

        let armingAppendRoot = scratchDirectory("open-stage-arming-append")
        defer { try? FileManager.default.removeItem(at: armingAppendRoot) }
        let armingAppendBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 16)
        if let armingAppendSpool = VortXHLSSessionSpool(
            parentDirectory: armingAppendRoot,
            capacityBytes: 16,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let armingAppendStage = armingAppendSpool.attachOpenStage(to: armingAppendBuffer) {
            append([0, 1, 2, 3], to: armingAppendBuffer)
            let accountingBlocker = BlockingStageProbe()
            armingAppendSpool.installOpenStageArmAccountingProbe(accountingBlocker.callAsFunction)
            let armResult = LockedBool()
            let armFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                armResult.set(armingAppendStage.arm(base: 1))
                armFinished.signal()
            }
            let accountingEntered = accountingBlocker.entered.wait(timeout: .now() + 2) == .success
            let appendFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                append([4, 5], to: armingAppendBuffer)
                appendFinished.signal()
            }
            let duringArming = armingAppendStage.snapshot
            let initiallyCharged = armingAppendSpool.accounting.openBytes
            accountingBlocker.release.signal()
            let armEnded = armFinished.wait(timeout: .now() + 2) == .success
            let appendEnded = appendFinished.wait(timeout: .now() + 2) == .success
            let adopted = armingAppendStage.snapshot
            check("open stage arming: a forward append racing the first snapshot is adopted exactly once",
                  accountingEntered
                      && duringArming.storage == .arming
                      && initiallyCharged == 3
                      && armEnded
                      && appendEnded
                      && armResult.value
                      && adopted.storage == .memory
                      && adopted.baseOffset == 1
                      && adopted.logicalEndOffset == 6
                      && armingAppendSpool.accounting.openBytes == 5
                      && armingAppendBuffer.producedCount == 6
                      && armingAppendBuffer.status().failure == nil)
        } else {
            check("open stage arming: append-race fixture is creatable", false)
        }

        let repeatedArmRoot = scratchDirectory("open-stage-repeated-arm")
        defer { try? FileManager.default.removeItem(at: repeatedArmRoot) }
        let repeatedArmBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 2)
        if let repeatedArmSpool = VortXHLSSessionSpool(
            parentDirectory: repeatedArmRoot,
            capacityBytes: 24,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let repeatedArmStage = repeatedArmSpool.attachOpenStage(to: repeatedArmBuffer) {
            append([0, 1, 2, 3, 4, 5, 6, 7, 8], to: repeatedArmBuffer)
            if repeatedArmStage.arm(base: 1), let claim = repeatedArmStage.claim() {
                let closeBlocker = BlockingStageProbe()
                repeatedArmSpool.installFileOperationProbe(closeBlocker.callAsFunction)
                let closeResult = LockedBool()
                let closeFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    closeResult.set(repeatedArmStage.closePrefix(
                        claim,
                        endOffset: 5,
                        key: .video(segmentID: 97),
                        durationMilliseconds: 4_000,
                        additionalResources: []))
                    closeFinished.signal()
                }
                let closeEntered = closeBlocker.entered.wait(timeout: .now() + 2) == .success
                let peak = repeatedArmSpool.accounting
                let repeatedAccountingBlocker = BlockingStageProbe()
                repeatedArmSpool.installOpenStageArmAccountingProbe(
                    repeatedAccountingBlocker.callAsFunction)
                let repeatedResult = LockedBool()
                let repeatedFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    repeatedResult.set(repeatedArmStage.arm(base: 9, auxiliaryBytes: 7))
                    repeatedFinished.signal()
                }
                let repeatedEnded = repeatedFinished.wait(timeout: .now() + 1) == .success
                let accountingWasTouched = repeatedAccountingBlocker.entered.wait(
                    timeout: .now() + 0.05) == .success
                if accountingWasTouched { repeatedAccountingBlocker.release.signal() }
                closeBlocker.release.signal()
                let closeEnded = closeFinished.wait(timeout: .now() + 2) == .success
                check("open stage arming: repeated arm during transient close never mutates coordinator accounting",
                      closeEntered
                          && peak.openBytes == 8
                          && peak.transientCopyBytes == 4
                          && peak.physicalBytes == 12
                          && repeatedEnded
                          && !repeatedResult.value
                          && !accountingWasTouched
                          && repeatedArmSpool.accounting.auxiliaryBytes == 0
                          && closeEnded
                          && closeResult.value)
            } else {
                check("open stage arming: repeated-arm claim is available", false)
            }
        } else {
            check("open stage arming: repeated-arm fixture is creatable", false)
        }

        let physicalRoot = scratchDirectory("open-stage-physical-cap")
        defer { try? FileManager.default.removeItem(at: physicalRoot) }
        let physicalBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        if let physicalSpool = VortXHLSSessionSpool(
            parentDirectory: physicalRoot,
            capacityBytes: Int.max,
            chunkSize: 2,
            scavengeStaleSessions: false),
           let physicalStage = physicalSpool.attachOpenStage(to: physicalBuffer) {
            let initialAuxiliary = Int.max - 12
            append([0, 1, 2, 3, 4, 5, 6, 7, 8], to: physicalBuffer)
            let armed = physicalStage.arm(base: 1)
            let auxiliaryCharged = physicalSpool.setAuxiliaryBytes(initialAuxiliary)
            if armed, auxiliaryCharged, let claim = physicalStage.claim() {
                let blocker = BlockingStageProbe()
                physicalSpool.installFileOperationProbe(blocker.callAsFunction)
                let finished = DispatchSemaphore(value: 0)
                let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 95)
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = physicalStage.closePrefix(
                        claim,
                        endOffset: 5,
                        key: key,
                        durationMilliseconds: 4_000,
                        additionalResources: [])
                    finished.signal()
                }
                let entered = blocker.entered.wait(timeout: .now() + 2) == .success
                let peak = physicalSpool.accounting
                let spillRejected = !physicalSpool.spill([.init(
                    key: .subtitle(renditionID: 0, segmentID: 95),
                    data: Data([1]),
                    durationMilliseconds: 4_000)])
                let auxiliaryRejected = !physicalSpool.setAuxiliaryBytes(Int.max - 11)
                blocker.release.signal()
                let ended = finished.wait(timeout: .now() + 2) == .success
                check("open stage physical cap: transient suffix copy blocks concurrent spill and auxiliary growth",
                      entered
                          && peak.admittedBytes == Int.max - 4
                          && peak.transientCopyBytes == 4
                          && peak.physicalBytes == Int.max
                          && spillRejected
                          && auxiliaryRejected
                          && ended
                          && physicalSpool.contains(key)
                          && physicalSpool.accounting.transientCopyBytes == 0)
            } else {
                check("open stage physical cap: exact active claim is available", false)
            }
        } else {
            check("open stage physical cap: fixture is creatable", false)
        }

        let raceRoot = scratchDirectory("open-stage-registry-race")
        defer { try? FileManager.default.removeItem(at: raceRoot) }
        let raceBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        if let raceSpool = VortXHLSSessionSpool(
            parentDirectory: raceRoot,
            capacityBytes: 32,
            chunkSize: 2,
            failureInjection: .openStageCancelBeforeRegistry,
            scavengeStaleSessions: false),
           let raceStage = raceSpool.attachOpenStage(to: raceBuffer) {
            append([0, 1, 2, 3, 4], to: raceBuffer)
            _ = raceStage.arm(base: 1)
            let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 90)
            if let claim = raceStage.claim() {
                check("open stage promotion race: cancellation between moves and registry publishes no partial final",
                      !raceStage.closePrefix(
                          claim,
                          endOffset: 3,
                          key: key,
                          durationMilliseconds: 2_000,
                          additionalResources: [])
                          && !raceSpool.contains(key)
                          && raceSpool.accounting.finalBytes == 0
                          && raceSpool.accounting.reservedBytes == 0
                          && raceSpool.accounting.transientCopyBytes == 0
                          && raceStage.snapshot.storage == .poisoned
                          && raceBuffer.status().failure != nil
                          && raceSpool.fileNamesOnDisk.isEmpty)
            } else {
                check("open stage promotion race: exact active claim is available", false)
            }
        } else {
            check("open stage promotion race: fixture is creatable", false)
        }

        let postCommitRoot = scratchDirectory("open-stage-post-commit-cancel")
        defer { try? FileManager.default.removeItem(at: postCommitRoot) }
        let postCommitBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        if let postCommitSpool = VortXHLSSessionSpool(
            parentDirectory: postCommitRoot,
            capacityBytes: 32,
            chunkSize: 2,
            failureInjection: .openStageCancelAfterRegistry,
            scavengeStaleSessions: false),
           let postCommitStage = postCommitSpool.attachOpenStage(to: postCommitBuffer) {
            append([0, 1, 2, 3, 4], to: postCommitBuffer)
            _ = postCommitStage.arm(base: 1)
            let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 91)
            if let claim = postCommitStage.claim() {
                let published = postCommitStage.closePrefix(
                    claim,
                    endOffset: 3,
                    key: key,
                    durationMilliseconds: 2_000,
                    additionalResources: [])
                check("open stage post-commit race: cancellation prevents the close success used for playlist publication",
                      !published
                          && postCommitSpool.contains(key)
                          && postCommitSpool.accounting.finalBytes == 2
                          && postCommitSpool.accounting.openBytes == 2
                          && postCommitSpool.accounting.reservedBytes == 0
                          && postCommitSpool.accounting.transientCopyBytes == 0
                          && postCommitStage.snapshot.storage == .poisoned
                          && postCommitBuffer.status().failure != nil)
                postCommitSpool.producerDidTerminate()
                postCommitSpool.listenerDidRetire()
                check("open stage post-commit race: committed ownership drains only through terminal cleanup",
                      !FileManager.default.fileExists(atPath: postCommitSpool.sessionDirectory.path)
                          && !postCommitSpool.contains(key)
                          && postCommitSpool.accounting.admittedBytes == 0
                          && postCommitSpool.accounting.physicalBytes == 0)
            } else {
                check("open stage post-commit race: exact active claim is available", false)
            }
        } else {
            check("open stage post-commit race: fixture is creatable", false)
        }

        let orphanRoot = scratchDirectory("open-stage-owner-release")
        defer { try? FileManager.default.removeItem(at: orphanRoot) }
        let orphanBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        var orphanSpool: VortXHLSSessionSpool? = VortXHLSSessionSpool(
            parentDirectory: orphanRoot,
            capacityBytes: 32,
            chunkSize: 2,
            scavengeStaleSessions: false)
        weak let releasedOwner = orphanSpool
        if let orphanStage = orphanSpool?.attachOpenStage(to: orphanBuffer) {
            append([0, 1, 2, 3], to: orphanBuffer)
            _ = orphanStage.arm(base: 1)
            if let orphanClaim = orphanStage.claim() {
                orphanSpool = nil
                let closeWithoutOwner = orphanStage.closePrefix(
                    orphanClaim,
                    endOffset: 3,
                    key: .video(segmentID: 92),
                    durationMilliseconds: 2_000,
                    additionalResources: [])
                orphanClaim.release()
                let replacement = orphanStage.claim()
                check("open stage owner loss: close does not consume and strand a claim after spool teardown",
                      releasedOwner == nil && !closeWithoutOwner && replacement != nil)
                replacement?.release()
            } else {
                check("open stage owner loss: exact claim is available", false)
            }
        } else {
            check("open stage owner loss: fixture is creatable", false)
        }

        let normalDeinitRoot = scratchDirectory("open-stage-normal-deinit")
        defer { try? FileManager.default.removeItem(at: normalDeinitRoot) }
        var normalSpool: VortXHLSSessionSpool? = VortXHLSSessionSpool(
            parentDirectory: normalDeinitRoot,
            capacityBytes: 32,
            chunkSize: 2,
            scavengeStaleSessions: false)
        let normalSessionDirectory = normalSpool?.sessionDirectory
        let joinedBeforeDeinit = VortXHLSSessionSpool.registeredSessionCount(
            parentDirectory: normalDeinitRoot)
        normalSpool = nil
        check("open stage registry: normal deinit leaves membership while preserving the orphan for scavenging",
              joinedBeforeDeinit == 1
                  && VortXHLSSessionSpool.registeredSessionCount(
                      parentDirectory: normalDeinitRoot) == 0
                  && normalSessionDirectory.map {
                      FileManager.default.fileExists(atPath: $0.path)
                  } == true)

        let cleanupRoot = scratchDirectory("open-stage-cleanup-retry")
        defer { try? FileManager.default.removeItem(at: cleanupRoot) }
        let cleanupBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 8)
        guard let cleanupSpool = VortXHLSSessionSpool(
            parentDirectory: cleanupRoot,
            capacityBytes: 32,
            chunkSize: 2,
            failureInjection: .cleanupRemove(failures: 1),
            scavengeStaleSessions: false),
              let cleanupStage = cleanupSpool.attachOpenStage(to: cleanupBuffer) else {
            check("open stage cleanup: fixture is creatable", false)
            return
        }
        append([0, 1, 2, 3], to: cleanupBuffer)
        _ = cleanupStage.arm(base: 1)
        cleanupSpool.invalidateSession()
        cleanupSpool.listenerDidRetire()
        check("open stage cleanup: invalidation still waits for the producer terminal edge",
              FileManager.default.fileExists(atPath: cleanupSpool.sessionDirectory.path))
        cleanupSpool.producerDidReachEOF()
        check("open stage cleanup: a failed directory removal remains retryable and registered",
              FileManager.default.fileExists(atPath: cleanupSpool.sessionDirectory.path)
                  && VortXHLSSessionSpool.registeredSessionCount(
                      parentDirectory: cleanupRoot) == 1)
        cleanupSpool.invalidateSession()
        check("open stage cleanup: a later lifecycle edge retries and completes directory removal",
              !FileManager.default.fileExists(atPath: cleanupSpool.sessionDirectory.path)
                  && VortXHLSSessionSpool.registeredSessionCount(
                      parentDirectory: cleanupRoot) == 0)

        let operationRoot = scratchDirectory("open-stage-cleanup-operation")
        defer { try? FileManager.default.removeItem(at: operationRoot) }
        let operationBuffer = VortXRemuxBuffer(windowFloorBytes: 1, producerLeadBytes: 4)
        guard let operationSpool = VortXHLSSessionSpool(
            parentDirectory: operationRoot,
            capacityBytes: 32,
            chunkSize: 2,
            scavengeStaleSessions: false),
              let operationStage = operationSpool.attachOpenStage(to: operationBuffer) else {
            check("open stage cleanup operation: fixture is creatable", false)
            return
        }
        append([0, 1, 2, 3, 4], to: operationBuffer)
        let blocker = BlockingStageProbe()
        operationSpool.installFileOperationProbe(blocker.callAsFunction)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = operationStage.arm(base: 1)
            finished.signal()
        }
        let entered = blocker.entered.wait(timeout: .now() + 2) == .success
        operationSpool.invalidateSession()
        operationSpool.listenerDidRetire()
        operationSpool.producerDidTerminate()
        check("open stage cleanup operation: teardown waits for an in-flight stage filesystem operation",
              entered
                  && operationSpool.activeOpenStageOperationCount == 1
                  && FileManager.default.fileExists(atPath: operationSpool.sessionDirectory.path))
        blocker.release.signal()
        let ended = finished.wait(timeout: .now() + 2) == .success
        check("open stage cleanup operation: the last operation completion triggers gated cleanup",
              ended
                  && operationSpool.activeOpenStageOperationCount == 0
                  && !FileManager.default.fileExists(atPath: operationSpool.sessionDirectory.path))
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

        let overlappingLeaseA = spool.openResource(v1, now: 130)
        let overlappingLeaseB = spool.openResource(v1, now: 130)
        check("capacity union: retained plus two leases for the same key remains one committed byte range",
              overlappingLeaseA != nil
                  && overlappingLeaseB != nil
                  && spool.activeLeaseCount == 2
                  && spool.accounting.finalBytes == 30)
        let disjointLease = spool.openResource(v2, now: 130)
        check("capacity union: a disjoint leased key adds only its already-committed range once",
              disjointLease != nil
                  && spool.activeLeaseCount == 3
                  && spool.accounting.finalBytes == 30)
        overlappingLeaseA?.close(now: 130)
        overlappingLeaseB?.close(now: 130)
        disjointLease?.close(now: 130)

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

    private static func testBoundaryKeyAgreement() {
        check("boundary agreement: segment zero rejects both one-sided IDR/key claims",
              VortXHLSBoundaryPolicy.decision(
                  hasOpenSegment: false,
                  incomingIsIDR: true,
                  incomingHasKeyFlag: false,
                  elapsed: 0) == .failSoft
                  && VortXHLSBoundaryPolicy.decision(
                      hasOpenSegment: false,
                      incomingIsIDR: false,
                      incomingHasKeyFlag: true,
                      elapsed: 0) == .failSoft)
        check("boundary agreement: one-sided evidence cannot cut an open segment",
              VortXHLSBoundaryPolicy.decision(
                  hasOpenSegment: true,
                  incomingIsIDR: true,
                  incomingHasKeyFlag: false,
                  elapsed: 1) == .continueOpen
                  && VortXHLSBoundaryPolicy.decision(
                      hasOpenSegment: true,
                      incomingIsIDR: false,
                      incomingHasKeyFlag: true,
                      elapsed: 1) == .continueOpen)
    }

    private static func testProductionWiring() {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let playerURL = testsURL.deletingLastPathComponent().appendingPathComponent("Sources/Player")
        let server = try? String(contentsOf: playerURL.appendingPathComponent("VortXRemuxHLSServer.swift"),
                                 encoding: .utf8)
        let stream = try? String(contentsOf: playerURL.appendingPathComponent("VortXMKVRemuxStream.swift"),
                                 encoding: .utf8)
        let policy = try? String(contentsOf: playerURL.appendingPathComponent("DVPlaybackPolicy.swift"),
                                 encoding: .utf8)
        let remuxBuffer = try? String(
            contentsOf: playerURL.appendingPathComponent("VortXRemuxBuffer.swift"),
            encoding: .utf8)
        let display = try? String(contentsOf: playerURL.appendingPathComponent("HDRDisplayMode.swift"),
                                  encoding: .utf8)
        let engine = try? String(contentsOf: playerURL.appendingPathComponent("AVPlayerEngine.swift"),
                                 encoding: .utf8)
        let engineContract = try? String(contentsOf: playerURL.appendingPathComponent("PlayerEngine.swift"),
                                         encoding: .utf8)
        let avPlayerView = try? String(contentsOf: playerURL.appendingPathComponent("AVPlayerEngineView.swift"),
                                      encoding: .utf8)
        let resumePolicy = try? String(contentsOf: playerURL.appendingPathComponent("RemuxResumePolicy.swift"),
                                       encoding: .utf8)
        let playerScreen = try? String(contentsOf: testsURL.deletingLastPathComponent()
            .appendingPathComponent("Sources/PlayerScreen.swift"), encoding: .utf8)
        let tvPlayer = try? String(contentsOf: testsURL.deletingLastPathComponent()
            .appendingPathComponent("SourcesTV/TVPlayerView.swift"), encoding: .utf8)
        let initialAVMount = sourceSection(
            avPlayerView,
            from: "private func makeHostView()",
            to: "#if os(macOS)")
        let playerScreenLoad = sourceSection(
            playerScreen,
            from: "private func loadIntoPlayer(",
            to: "private func retryResumeSameSource()")
        let tvPlayerLoad = sourceSection(
            tvPlayer,
            from: "private func loadIntoPlayer(",
            to: "/// Switch the playing source")
        let remuxSeekMapping = sourceSection(
            engine,
            from: "func seek(to seconds: Double)",
            to: "func seek(by seconds: Double)")
        let remuxDurationMapping = sourceSection(
            engine,
            from: "private func handleStatus(_ item: AVPlayerItem",
            to: "private func logDVVideoTrackDiagnostics(")
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
        let serverStartup = sourceSection(
            server,
            from: "func start()",
            to: "/// The source MKV runtime")
        let mountWaits = sourceSection(
            server,
            from: "private func waitForMount",
            to: "// MARK: - Resources")
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
        let runLifecycle = sourceSection(
            stream,
            from: "private func run()",
            to: "// MARK: - Custom AVIO write/seek")
        let openStageClose = sourceSection(
            remuxBuffer,
            from: "func closePrefix(_ claim: OpenClaim,",
            to: "fileprivate func releaseClaim(id:")
        let openStageForward = sourceSection(
            remuxBuffer,
            from: "fileprivate func acceptForward(",
            to: "fileprivate func completeForward(")
        let openStageClaimRead = sourceSection(
            remuxBuffer,
            from: "private func withClaimBytes(",
            to: "private func finishClaimRead()")
        let spoolDeinit = sourceSection(
            remuxBuffer,
            from: "deinit {\n        var removed =",
            to: "var accounting: Accounting")
        let videoTiming = sourceSection(
            stream,
            from: "private func hlsVideoStep(",
            to: "private func hlsApplyVideoStep(")
        let pendingVideoPublication = sourceSection(
            stream,
            from: "private func hlsApplyVideoStep(",
            to: "private func hlsCloseSegment(")
        let lateAlternatePublication = sourceSection(
            stream,
            from: "private func publishAlternateAudioResource(",
            to: "private func registerAlternateAudioResource(")
        let eofPublication = sourceSection(
            stream,
            from: "// EOF: drain the transcoder's decoder/FIFO/encoder tail",
            to: "// MARK: - Custom AVIO write/seek")
        let appURL = testsURL.deletingLastPathComponent()
        let whatsNew = try? String(contentsOf: appURL.appendingPathComponent("SourcesShared/WhatsNew.swift"),
                                   encoding: .utf8)
        let changelog = try? String(contentsOf: appURL.deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let beta7Changelog = sourceSection(
            changelog,
            from: "## 0.3.14 Beta 7",
            to: "## 0.3.14 Beta 6")

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
        // The startup floor is the FLAT 4-second/two-segment budget; the 3x-target multiplication was the
        // build 189 regression (36s of media before the master, while the start watchdog fires at 10s).
        check("wiring: master waits for the flat two-segment startup floor",
              masterPublication?.contains("DVPlaybackPolicy.pinnedStartupCohort(") == true
                  && masterPublication?.contains(
                    "minimumSegmentCount: startupReadiness.minimumSegmentCount") == true
                  && masterPublication?.contains(
                    "startupReadiness.minimumRenderedDurationMilliseconds") == true
                  && policy?.contains("static let startupFloorMilliseconds = 4_000") == true
                  && policy?.contains("frozenTarget.seconds.multipliedReportingOverflow(by: 3)") == false
                  && server?.contains("minimumStartupDurationMilliseconds = 15_000") == false)
        check("wiring: one frozen target renders identically across video, audio and subtitle routes",
              server?.components(separatedBy:
                  "targetDuration: startupReadiness.frozenTarget.seconds").count == 4
                  && stream?.contains(
                      "self.hlsTarget = VortXHLSTargetPolicy.conservativeTarget") == true
                  && stream?.contains("freeze(indexEvidence: nil)!") == false
                  && server?.contains(
                      "guard let startupReadiness = VortXHLSStartupReadiness(") == true
                  && server?.contains("stream.cancel()") == true
                  && server?.contains("stream.listenerDidRetire()") == true)
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
        check("wiring: primary arm and alternate timeout share the versioned auxiliary ledger",
              stream?.contains("hlsAuxiliaryAccounting.armPrimary(") == true
                  && alternateTimeout?.contains(
                      "hlsAuxiliaryAccounting?.omitAlternateAudioInitOnTimeout()") == true
                  && remuxBuffer?.contains("final class VortXHLSAuxiliaryAccounting") == true)
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
        check("wiring: key evidence is mandatory and production passes the actual packet flag",
              policy?.contains("incomingHasKeyFlag: Bool = true") == false
                  && videoTiming?.contains("let hasKeyFlag = pkt.pointee.flags & AV_PKT_FLAG_KEY_CONST != 0") == true
                  && videoTiming?.contains("incomingHasKeyFlag: hasKeyFlag") == true
                  && videoTiming?.contains("incomingHasKeyFlag: true") == false)
        check("wiring: delayed-init boundaries use a FIFO tail and cannot overwrite an older key",
              videoTiming?.contains(
                  "hlsPendingBoundaries.logicalSegmentStartSeconds ?? publishedStart") == true
                  && videoTiming?.contains(
                      "let id = _hlsSegments.count + hlsPendingBoundaries.count") == true
                  && videoTiming?.contains("hlsPendingBoundaries.append(") == true
                  && videoTiming?.contains(
                      "frozenTargetSeconds: Double(hlsTarget.seconds)") == true
                  && videoTiming?.contains("effectiveBoundaryDecision") == false
                  && videoTiming?.contains("guard hlsInitState.mayPublishMedia else") == false)
        check("wiring: one production machine owns the init gate and permitted nil drain",
              sourceContainsInOrder(pendingVideoPublication, [
                  "avio_flush(outCtx.pointee.pb)",
                  "return hlsPublishPendingBoundaries(outCtx: outCtx)",
                  "let result = hlsPendingBoundaries.advance(",
                  "initMayPublishMedia: { hlsInitState.mayPublishMedia }",
                  "performPostInitDrain:",
                  "let flushRc = av_interleaved_write_frame(outCtx, nil)",
              ]))
        check("wiring: parser-incomplete bytes never advance or publish a pending boundary",
              sourceContainsInOrder(pendingVideoPublication, [
                  "proveNextFragment: { hlsParserProvenFirstSegmentEndByte() }",
                  "publish: { pending, provenEndByte in",
                  "hlsCloseSegment(",
              ]))
        check("wiring: every pre-close parser-claim failure releases the exact stored claim",
              sourceContainsInOrder(pendingVideoPublication, [
                  "guard pending.segmentID == nextPublishedID",
                  "releaseHLSParserOpenClaim()",
                  "HLS pending boundary did not match the publication frontier",
              ])
                  && sourceContainsInOrder(closeVideoSegment, [
                      "hlsSegmentStartPacketProven else {",
                      "releaseHLSParserOpenClaim()",
                      "guard let endByte",
                      "releaseHLSParserOpenClaim()",
                      "hlsParserOpenClaim = nil",
                      "defer { openClaim.release() }",
                  ]))
        check("wiring: remux-thread exit releases any terminal parser claim before producer teardown",
              sourceContainsInOrder(runLifecycle, [
                  "defer {",
                  "releaseHLSParserOpenClaim()",
                  "hlsSpool?.producerDidTerminate()",
              ]))
        check("wiring: owner loss cannot consume and strand the exact open-stage claim",
              sourceContainsInOrder(openStageClose, [
                  "guard let owner",
                  "claim.consume()",
                  "owner.closeOpenStagePrefix(",
              ]))
        check("wiring: RAM forwards copy directly into the one accounted resident backing",
              openStageForward?.contains("residentData = Data(bytes:") == false
                  && remuxBuffer?.contains("residentData: Data?") == false)
        check("wiring: RAM parser claims borrow the accounted backing without snapshot allocation",
              openStageClaimRead?.contains("snapshotChunk(") == false
                  && openStageClaimRead?.contains("withResidentBytes(") == true)
        check("wiring: physical proof reports the live resident allocation rather than helper-call receipts",
              remuxBuffer?.contains("struct ResidentBackingReceipt") == false
                  && remuxBuffer?.contains("residentBackingSnapshot") == true
                  && remuxBuffer?.contains("malloc_size(") == true
                  && remuxBuffer?.contains("MAP_PRIVATE | MAP_ANON") == true
                  && remuxBuffer?.contains("munmap(pointer, capacity)") == true)
        check("wiring: normal deinit leaves the registry while failed invalidated cleanup remains registered",
              spoolDeinit?.contains("if registryJoined, !invalidated || removed") == true)
        check("wiring: a failed durable close cannot cross the production playlist-publication guard",
              sourceContainsInOrder(closeVideoSegment, [
                  "guard hlsOpenStage.closePrefix(",
                  "return false",
                  "_hlsSegments.append(videoSegment)",
              ]))
        check("wiring: aggregate parser proof remains separate from first-fragment FIFO proof",
              pendingVideoPublication?.contains(
                  "VortXFMP4FragmentParser.proveFirstMediaFragment(") == true
                  && pendingVideoPublication?.contains(
                      "VortXFMP4FragmentParser.proveMediaRange(") == true)
        check("wiring: one monotonic deadline starts before production and gates readyToPlay",
              sourceContainsInOrder(serverStartup, [
                  "mountDeadline.start(now: now)",
                  "queue.asyncAfter",
                  "stream.start()",
                  "func markEngineReady() -> Bool",
                  "mountDeadline.markReady(now: now)",
              ])
                  && mountWaits?.contains("remainingMountBudget(now: now)") == true
                  && mountWaits?.contains(
                      "if let value = probe() { return gateMountProbe(value) }") == true
                  && mountWaits?.contains("return gateMountProbe(value)") == true
                  && mountWaits?.contains("mountDeadline.gateSuccessfulProbe(") == true
                  && mountWaits?.contains(
                      "guard let accepted = result.value, !isInvalidated else") == true
                  && mountWaits?.contains("Date().addingTimeInterval") == false
                  && engine?.contains(
                      "if let server = remuxHLSServer, !server.markEngineReady()") == true)
        check("wiring: timeout callback is generation-safe and emits one fatal chrome event",
              engine?.contains("onStartupTimeout: { [weak self] timedOutServer in") == true
                  && engine?.contains("remuxHLSServer === timedOutServer") == true
                  && engine?.contains("activeLoadToken == loadToken") == true
                  && engine?.contains("!isReady") == true
                  && engine?.contains("!fatalErrorEmitted") == true
                  && engine?.contains("fatalErrorEmitted = true") == true
                  && engine?.contains("MPVProperty.endFileError") == true)
        check("wiring: owner-only permissions are applied and verified for directories and media files",
              remuxBuffer?.contains("NSNumber(value: 0o700)") == true
                  && remuxBuffer?.contains("NSNumber(value: 0o600)") == true
                  && remuxBuffer?.contains("ensureOwnerOnlyFile(item.partURL)") == true
                  && remuxBuffer?.contains("ensureOwnerOnlyFile(item.finalURL)") == true
                  && remuxBuffer?.contains("attributesOfItem(atPath:") == true)
        check("wiring: late alternate audio is retained by pending video ID",
              lateAlternatePublication?.contains("if !videoExists") == true
                  && lateAlternatePublication?.contains(
                      "guard hlsPendingBoundaries.attachPayload(") == true
                  && lateAlternatePublication?.contains(
                      "resource, toSegmentID: resource.segmentID) else") == true
                  && lateAlternatePublication?.contains(
                      "markAlternateAudioFailed(.discontinuity)") == true)
        check("wiring: EOF settles queued boundaries before assigning the final ID and start",
              sourceContainsInOrder(eofPublication, [
                  "av_write_trailer(outCtx)",
                  "hlsPublishPendingBoundaries(",
                  "!hlsPendingBoundaries.hasPendingBoundary",
                  "let start = hlsSegmentStartSec",
                  "let finalID = _hlsSegments.count",
                  "finishAlternateAudio(",
                  "hlsCloseSegment(",
              ]))
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
        check("wiring: remux seek maps source bounds before player bounds and preserves the non-remux clamp",
              sourceContainsInOrder(remuxSeekMapping, [
                "let sourceDuration =",
                "sourceSeconds: seconds",
                "authoritativeSourceDurationSeconds: sourceDuration",
                "playerDurationSeconds: dur",
                "producedEdgePlayerSeconds: producedEdgeSeconds",
                "} else {",
                "clamped = (dur.isFinite && dur > 1)",
              ]))
        check("wiring: ready status always maps remux duration into source time",
              sourceContainsInOrder(remuxDurationMapping, [
                "let authoritativeDuration =",
                "RemuxResumePolicy.reportedDuration(",
                "playerDurationSeconds: dur",
                "origin: remuxTimelineOrigin",
                "authoritativeSourceDurationSeconds: authoritativeDuration",
                "seekable = emittedDuration.isFinite && emittedDuration > 0",
              ]))
        check("wiring: initial AV host configures its origin immediately before the synchronous load",
              sourceContainsInOrder(initialAVMount, [
                "engine.configureResumeOrigin(seconds: resumeOriginSeconds)",
                "engine.loadFile(",
              ]))
        check("wiring: both surfaces provide a pre-mount origin and tvOS waits for async account resume",
              playerScreen?.contains(".resumeOrigin(avSurfaceResumeOrigin ?? resumeSeconds)") == true
                  && tvPlayer?.contains("if let resumeOrigin = initialAVResumeOrigin") == true
                  && tvPlayer?.contains(".resumeOrigin(resumeOrigin)") == true
                  && tvPlayer?.contains("resumeSeconds = await account.resumeOffset(for: m)") == true)
        check("wiring: every in-place surface load configures origin before loadFile",
              sourceContainsInOrder(playerScreenLoad, [
                "player.configureResumeOrigin(seconds: requestedResumeOrigin)",
                "player.loadFile(",
              ])
                  && sourceContainsInOrder(tvPlayerLoad, [
                    "player.configureResumeOrigin(seconds: requestedResumeOrigin)",
                    "candidateToken = player.loadFile(",
                  ]))
        check("wiring: subtitle sync is gated by the exact live capability on both surfaces",
              engineContract?.contains("var subtitleDelayAvailable: Bool { get }") == true
                  && engine?.contains("var subtitleDelayAvailable: Bool { externalSubActive }") == true
                  && playerScreen?.contains("coordinator.player?.subtitleDelayAvailable == true") == true
                  && tvPlayer?.contains("coordinator.player?.subtitleDelayAvailable == true") == true
                  && playerScreen?.contains("Sync unavailable · external subtitles only") == true
                  && tvPlayer?.contains("Sync unavailable · external subtitles only") == true)
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
        check("release: Beta 7 copy distinguishes fresh starts and states the real progress-aware fallback",
              beta7Changelog?.contains("titles start at the beginning") == false
                  && beta7Changelog?.contains("after about fifteen seconds without remux progress") == true
                  && beta7Changelog?.contains("two-minute hard limit") == true
                  && whatsNew?.contains("after about fifteen seconds without remux progress") == true
                  && whatsNew?.contains("two-minute hard limit") == true)
    }
}
